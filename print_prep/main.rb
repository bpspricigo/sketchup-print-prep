# Print Prep — main logic.
#
# Analysis model:
#   * Every group/component whose definition contains faces is a "part".
#   * A part is "solid" if SketchUp considers it manifold (or, for containers that
#     also hold nested groups, if every edge of its own faces has exactly 2 faces).
#   * Thickness is estimated by shooting a ray inward from (a sample of) the part's
#     faces and measuring the distance to where it exits the same part. The
#     smallest value is the part's minimum wall thickness at real-world size.
#   * All scale math (fit on bed, pieces, thin at 1:N) happens live in the dialog.
#   * SketchUp is frozen while Ruby runs, so big jobs are guarded: a quick count
#     first (asks before a large one) and a time limit that stops with partial results.
#   * Highlights are drawn by an overlay (overlay.rb) from world-space points kept
#     per part in @hl, so showing a problem never changes the model or selection.
#
# Units: SketchUp works in inches internally; everything sent to the dialog is mm.

require 'sketchup.rb'
require 'json'
require_relative 'overlay' if defined?(Sketchup::Overlay)
require_relative 'updater'

module BrunoTools
  module PrintPrep
    MAX_RAYS_PER_PART = 800       # cap per part so big models stay fast
    RAY_EPS           = 0.0005    # inches; start offset so a ray doesn't hit its own face
    MAX_RAY_HOPS      = 4         # how many foreign hits to skip through
    CONFIRM_RAYS      = 20_000    # estimated rays above which we ask before starting
    TIME_LIMIT        = 60        # seconds; analysis stops here and shows what it has
    SETTINGS_KEY      = 'BrunoTools_PrintPrep'.freeze

    class TimeUp < StandardError; end

    # ------------------------------------------------------------------ dialog

    def self.show_dialog
      if @dialog && @dialog.visible?
        @dialog.bring_to_front
        return
      end

      @dialog = UI::HtmlDialog.new(
        dialog_title:    'Print Prep',
        preferences_key: SETTINGS_KEY,
        width: 560, height: 760, min_width: 440, min_height: 420,
        resizable: true,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      @dialog.set_file(File.join(__dir__, 'dialog.html'))

      @dialog.add_action_callback('ready')         { |_c| send_settings }
      @dialog.add_action_callback('analyze')       { |_c, scope| run_analysis(scope.to_s) }
      @dialog.add_action_callback('highlight')     { |_c, json| highlight(JSON.parse(json.to_s)) }
      @dialog.add_action_callback('clear_highlight') { |_c| clear_highlight }
      @dialog.add_action_callback('save_settings') do |_c, json|
        Sketchup.write_default(SETTINGS_KEY, 'settings', json.to_s)
      end

      @dialog.set_on_closed { clear_highlight }
      @dialog.show
    end

    def self.send_settings
      raw  = Sketchup.read_default(SETTINGS_KEY, 'settings', nil)
      data = begin
        raw ? JSON.parse(raw) : nil
      rescue JSON::ParserError
        nil
      end
      js('loadSettings', data)
    end

    def self.js(fn, payload)
      return unless @dialog
      @dialog.execute_script("#{fn}(#{payload.to_json})")
    end

    # ---------------------------------------------------------------- analysis

    def self.run_analysis(scope)
      model    = Sketchup.active_model
      clear_highlight
      @parts   = []
      @hl      = []
      @overall = Geom::BoundingBox.new
      loose    = 0

      if scope == 'selection'
        roots     = model.selection.to_a
        base_path = model.active_path || []
        base_tr   = model.edit_transform
        if roots.empty?
          js('analysisError', 'Nothing is selected. Select the parts to check, or choose "Whole model".')
          return
        end
      else
        roots     = model.entities.to_a
        base_path = []
        base_tr   = Geom::Transformation.new
      end

      total_parts, total_faces, est_rays = estimate(roots)
      if est_rays > CONFIRM_RAYS
        msg = "This is a big job: #{delimit(total_parts)} parts with #{delimit(total_faces)} faces.\n\n" \
              "SketchUp will be unresponsive while it runs (at most #{TIME_LIMIT} s, then it " \
              "stops and shows the parts checked so far).\n\n" \
              "Tip: select one section and use \"Selection only\" instead.\n\nContinue anyway?"
        unless UI.messagebox(msg, MB_YESNO) == IDYES
          js('analysisCancelled', nil)
          return
        end
      end

      started   = Time.now
      @deadline = started + TIME_LIMIT
      stopped   = false
      begin
        roots.each do |e|
          if instance?(e)
            walk(e, base_path, base_tr)
          elsif e.is_a?(Sketchup::Face)
            loose += 1
            e.vertices.each { |v| @overall.add(v.position.transform(base_tr)) }
          end
        end
      rescue TimeUp
        stopped = true
      end
      Sketchup.status_text = ''
      watch(model)

      size = if @overall.empty?
               [0, 0, 0]
             else
               [@overall.width, @overall.height, @overall.depth].map { |v| v.to_mm.round(1) }
             end

      js('renderResults', {
        scope:       scope,
        size_mm:     size,
        loose_faces: loose,
        parts:       @parts,
        seconds:     (Time.now - started).round(1),
        stopped:     stopped,
        total_parts: total_parts
      })
    rescue StandardError => e
      Sketchup.status_text = ''
      js('analysisError', "Analysis failed: #{e.class}: #{e.message}")
    end

    def self.instance?(e)
      e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
    end

    def self.printable?(e)
      return false if e.hidden?
      layer = e.layer
      layer.nil? || layer.visible?
    end

    # Cheap pre-pass over the same parts walk() will visit: [parts, faces, rays].
    # Face counts are cached per definition, since bricks etc. are often one
    # component placed thousands of times.
    def self.estimate(roots)
      counts = Hash.new do |h, d|
        h[d] = d.entities.count { |c| c.is_a?(Sketchup::Face) && !c.hidden? }
      end
      totals = [0, 0, 0]
      visit  = lambda do |inst|
        next unless printable?(inst)
        n = counts[inst.definition]
        if n > 0
          totals[0] += 1
          totals[1] += n
          totals[2] += [n, MAX_RAYS_PER_PART].min
        end
        inst.definition.entities.each { |c| visit.call(c) if instance?(c) }
      end
      roots.each { |e| visit.call(e) if instance?(e) }
      totals
    end

    def self.delimit(n)
      n.to_s.reverse.scan(/\d{1,3}/).join(',').reverse
    end

    def self.check_time
      raise TimeUp if Time.now > @deadline
    end

    def self.walk(inst, parent_path, parent_tr)
      return unless printable?(inst)

      path     = parent_path + [inst]
      tr       = parent_tr * inst.transformation
      ents     = inst.definition.entities
      faces    = ents.grep(Sketchup::Face).select { |f| !f.hidden? }
      children = ents.select { |c| instance?(c) }

      record_part(inst, path, tr, faces, !children.empty?) unless faces.empty?
      children.each { |c| walk(c, path, tr) }
    end

    def self.record_part(inst, path, tr, faces, has_children)
      check_time
      Sketchup.status_text = "Print Prep: checking part #{@parts.size + 1}…"

      bb = Geom::BoundingBox.new
      faces.each { |f| f.vertices.each { |v| bb.add(v.position.transform(tr)) } }
      @overall.add(bb)

      solid = has_children ? faces_closed?(faces) : inst.manifold?
      thick = measure_thickness(path, tr, faces)
      edges = solid ? { open: [], multi: [], stray: [] } : bad_edges(inst.definition.entities, tr)

      @parts << {
        idx:     @parts.size,
        name:    part_name(inst),
        path:    path.map { |p| part_name(p) }.join(' › '),
        solid:   solid,
        mixed:   has_children,
        faces:   faces.size,
        dims:    [bb.width, bb.height, bb.depth].map { |v| v.to_mm.round(1) },
        thick:   thick[:min_mm] && thick[:min_mm].round(2),
        sampled: thick[:sampled],
        issues:  edges.transform_values { |pts| pts.size / 2 }
      }
      @hl << { box: bb, edges: edges, faces: thick[:faces], spot: thick[:spot], solid: solid }
    end

    def self.part_name(inst)
      n = inst.name.to_s
      n = inst.definition.name.to_s if n.empty? && inst.is_a?(Sketchup::ComponentInstance)
      n = 'Group' if n.empty?
      n
    end

    # Closed if every edge used by these faces is shared by exactly two faces.
    def self.faces_closed?(faces)
      faces.flat_map(&:edges).uniq.all? { |e| e.faces.size == 2 }
    end

    # Edges that stop a part being solid, as world-space point pairs:
    #   open: only 1 face (a hole)   multi: 3+ faces (internal faces)   stray: no face
    def self.bad_edges(ents, tr)
      out = { open: [], multi: [], stray: [] }
      ents.grep(Sketchup::Edge).each do |e|
        n   = e.faces.size
        key = if n.zero? then :stray
              elsif n == 1 then :open
              elsif n > 2 then :multi
              end
        out[key] << e.start.position.transform(tr) << e.end.position.transform(tr) if key
      end
      out
    end

    # -------------------------------------------------------------- thickness

    def self.measure_thickness(path, tr, faces)
      model  = Sketchup.active_model
      step   = [(faces.size.to_f / MAX_RAYS_PER_PART).ceil, 1].max
      best   = nil
      spot   = nil
      done   = []

      faces.each_with_index do |f, i|
        next unless (i % step).zero?
        check_time if (i / step % 50).zero?   # one part can hold up to 800 rays
        tris = face_triangles(f, tr)
        pt, normal = face_sample(f, tr, tris)
        next unless pt
        d, exit_pt = thickness_at(model, pt, normal, path)
        next unless d
        done << [tris.flatten, d]
        if best.nil? || d < best
          best = d
          spot = [pt, exit_pt, d]
        end
      end

      { min_mm: best && best.to_mm, spot: spot, faces: done, sampled: step > 1 }
    end

    # The face's triangles in world coordinates, as [[a, b, c], ...].
    def self.face_triangles(face, tr)
      mesh = face.mesh(0)
      (1..mesh.count_polygons).map do |k|
        mesh.polygon_points_at(k).map { |p| p.transform(tr) }
      end
    end

    # A point guaranteed to lie on the face (centroid of its largest triangle)
    # plus the outward normal, both in world coordinates.
    def self.face_sample(face, tr, tris)
      return nil if tris.empty?

      best_tri  = nil
      best_area = -1.0
      tris.each do |a, b, c|
        cross = (b - a) * (c - a)
        area  = cross.length
        if area > best_area
          best_area = area
          best_tri  = [a, b, c, cross]
        end
      end
      return nil if best_tri.nil? || best_area <= 1e-12

      a, b, c, normal = best_tri
      normal.normalize!
      # Triangle winding isn't guaranteed; align with the face's own normal.
      normal.reverse! if normal.dot(face.normal.transform(tr)) < 0

      centroid = Geom::Point3d.new((a.x + b.x + c.x) / 3.0,
                                   (a.y + b.y + c.y) / 3.0,
                                   (a.z + b.z + c.z) / 3.0)
      [centroid, normal]
    end

    # Distance from pt, going inward (against the normal), to where the ray
    # exits the same part, plus that exit point. Skips hits on other geometry
    # in between.
    def self.thickness_at(model, pt, normal, path)
      dir       = normal.reverse
      start     = pt.offset(dir, RAY_EPS)
      travelled = RAY_EPS

      MAX_RAY_HOPS.times do
        res = model.raytest([start, dir], true)
        return nil unless res

        hit_pt, hit_path = res
        travelled += start.distance(hit_pt)
        return [travelled, hit_pt] if hit_path.last.is_a?(Sketchup::Face) && hit_path[0..-2] == path

        start      = hit_pt.offset(dir, RAY_EPS)
        travelled += RAY_EPS
      end
      nil
    end

    # ------------------------------------------------------------- highlights

    # opts (from the dialog): mode 'all' | 'part' | 'spot', idx, scale, minWall (mm),
    # zoom (false when only the scale or min. wall changed: redraw, don't move).
    def self.highlight(opts)
      return js('analysisError', 'Highlights need SketchUp 2023 or newer.') unless defined?(HighlightOverlay)
      return if @hl.nil? || @stale

      model = @model
      return unless model && model.valid? && model == Sketchup.active_model

      mode  = opts['mode'].to_s.to_sym
      idx   = opts['idx'].to_i
      scale = [opts['scale'].to_f, 1].max
      limit = (opts['minWall'].to_f * scale).mm
      return unless mode == :all || @hl[idx]

      ov = overlay(model)
      ov.set(mode, idx, limit, scale.round)
      ov.enabled = true
      zoom_to(model.active_view, mode, idx) if opts['zoom']
      model.active_view.invalidate
    end

    def self.clear_highlight
      ov = @overlays && @model && @overlays[@model]
      return unless ov
      ov.clear
      @model.active_view.invalidate if @model.valid?
    end

    # One overlay per model, added the first time it's needed.
    def self.overlay(model)
      @overlays ||= {}
      ov = @overlays[model]
      unless ov
        ov = HighlightOverlay.new
        model.overlays.add(ov)
        @overlays[model] = ov
      end
      ov.parts = @hl unless ov.parts.equal?(@hl)
      ov
    end

    # Keeps the current view direction and moves the camera so the target fills the view.
    def self.zoom_to(view, mode, idx)
      bb = Geom::BoundingBox.new
      if mode == :all
        @hl.each { |p| bb.add(p[:box]) }
      elsif mode == :spot && @hl[idx][:spot]
        a, b, d = @hl[idx][:spot]
        mid = Geom.linear_combination(0.5, a, 0.5, b)
        pad = [d * 4, @hl[idx][:box].diagonal * 0.1].max
        bb.add(mid.offset(Geom::Vector3d.new(pad, pad, pad)),
               mid.offset(Geom::Vector3d.new(-pad, -pad, -pad)))
      else
        bb.add(@hl[idx][:box])
      end
      return if bb.empty?

      cam    = view.camera
      center = bb.center
      radius = [bb.diagonal / 2.0 * 1.15, 0.1].max
      aspect = view.vpwidth.to_f / [view.vpheight, 1].max

      if cam.perspective?
        vfov = cam.fov.degrees
        hfov = 2 * Math.atan(Math.tan(vfov / 2) * aspect)
        dist = radius / Math.sin([vfov, hfov].min / 2)
      else
        dist = radius * 3
        cam.height = 2 * radius / [aspect, 1].min
      end
      cam.set(center.offset(cam.direction.reverse, dist), center, cam.up)
      view.camera = cam
    end

    # Any edit or undo makes the stored highlight points unreliable.
    class ChangeWatcher < Sketchup::ModelObserver
      def onTransactionCommit(_model)
        PrintPrep.model_changed
      end

      def onTransactionUndo(_model)
        PrintPrep.model_changed
      end

      def onTransactionRedo(_model)
        PrintPrep.model_changed
      end
    end

    def self.watch(model)
      @watcher ||= ChangeWatcher.new
      @model.remove_observer(@watcher) if @model && @model.valid?
      model.add_observer(@watcher)
      @model = model
      @stale = false
    end

    def self.model_changed
      return if @stale
      @stale = true
      clear_highlight
      js('markStale', nil)
    end

    # ------------------------------------------------------------------- menu

    unless file_loaded?(__FILE__)
      UI.menu('Extensions').add_item('Print Prep…') { show_dialog }
      UI.menu('Extensions').add_item('Print Prep: Check for updates') { Updater.check(manual: true) }
      file_loaded(__FILE__)
    end
  end
end
