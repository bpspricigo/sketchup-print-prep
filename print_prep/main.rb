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
#
# Units: SketchUp works in inches internally; everything sent to the dialog is mm.

require 'sketchup.rb'
require 'json'

module BrunoTools
  module PrintPrep
    MAX_RAYS_PER_PART = 800       # cap per part so big models stay fast
    RAY_EPS           = 0.0005    # inches; start offset so a ray doesn't hit its own face
    MAX_RAY_HOPS      = 4         # how many foreign hits to skip through
    SETTINGS_KEY      = 'BrunoTools_PrintPrep'.freeze

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
      @dialog.add_action_callback('show_part')     { |_c, idx, spot| show_part(idx.to_i, spot ? true : false) }
      @dialog.add_action_callback('save_settings') do |_c, json|
        Sketchup.write_default(SETTINGS_KEY, 'settings', json.to_s)
      end

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
      @parts   = []
      @paths   = []
      @spots   = []
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

      started = Time.now
      roots.each do |e|
        if instance?(e)
          walk(e, base_path, base_tr)
        elsif e.is_a?(Sketchup::Face)
          loose += 1
          e.vertices.each { |v| @overall.add(v.position.transform(base_tr)) }
        end
      end
      Sketchup.status_text = ''

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
        seconds:     (Time.now - started).round(1)
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
      Sketchup.status_text = "Print Prep: checking part #{@parts.size + 1}…"

      bb = Geom::BoundingBox.new
      faces.each { |f| f.vertices.each { |v| bb.add(v.position.transform(tr)) } }
      @overall.add(bb)

      solid = has_children ? faces_closed?(faces) : inst.manifold?
      thick = measure_thickness(path, tr, faces)

      @parts << {
        idx:     @parts.size,
        name:    part_name(inst),
        path:    path.map { |p| part_name(p) }.join(' › '),
        solid:   solid,
        mixed:   has_children,
        faces:   faces.size,
        dims:    [bb.width, bb.height, bb.depth].map { |v| v.to_mm.round(1) },
        thick:   thick[:min_mm] && thick[:min_mm].round(2),
        sampled: thick[:sampled]
      }
      @paths << path
      @spots << thick[:face]
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

    # -------------------------------------------------------------- thickness

    def self.measure_thickness(path, tr, faces)
      model  = Sketchup.active_model
      step   = [(faces.size.to_f / MAX_RAYS_PER_PART).ceil, 1].max
      best   = nil
      face   = nil

      faces.each_with_index do |f, i|
        next unless (i % step).zero?
        pt, normal = face_sample(f, tr)
        next unless pt
        d = thickness_at(model, pt, normal, path)
        next unless d
        if best.nil? || d < best
          best = d
          face = f
        end
      end

      { min_mm: best && best.to_mm, face: face, sampled: step > 1 }
    end

    # A point guaranteed to lie on the face (centroid of its largest triangle)
    # plus the outward normal, both in world coordinates.
    def self.face_sample(face, tr)
      mesh = face.mesh(0)
      n    = mesh.count_polygons
      return nil if n.zero?

      best_tri  = nil
      best_area = -1.0
      (1..[n, 8].min).each do |k|
        a, b, c = mesh.polygon_points_at(k).map { |p| p.transform(tr) }
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
    # exits the same part. Skips hits on other geometry in between.
    def self.thickness_at(model, pt, normal, path)
      dir       = normal.reverse
      start     = pt.offset(dir, RAY_EPS)
      travelled = RAY_EPS

      MAX_RAY_HOPS.times do
        res = model.raytest([start, dir], true)
        return nil unless res

        hit_pt, hit_path = res
        travelled += start.distance(hit_pt)
        return travelled if hit_path.last.is_a?(Sketchup::Face) && hit_path[0..-2] == path

        start      = hit_pt.offset(dir, RAY_EPS)
        travelled += RAY_EPS
      end
      nil
    end

    # ------------------------------------------------------------- navigation

    def self.show_part(idx, spot)
      path = @paths && @paths[idx]
      return unless path && path.all?(&:valid?)

      model  = Sketchup.active_model
      target = spot ? @spots[idx] : path.last
      ctx    = spot ? path : path[0..-2]
      return unless target && target.valid?

      begin
        model.active_path = ctx.empty? ? nil : ctx
      rescue ArgumentError, NoMethodError
        # Older SketchUp or invalid path: fall back to the top-level parent.
        target = path.first
      end

      model.selection.clear
      model.selection.add(target)
      model.active_view.zoom(model.selection)
    end

    # ------------------------------------------------------------------- menu

    unless file_loaded?(__FILE__)
      UI.menu('Extensions').add_item('Print Prep…') { show_dialog }
      file_loaded(__FILE__)
    end
  end
end
