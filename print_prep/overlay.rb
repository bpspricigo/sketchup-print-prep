# Print Prep — viewport overlay (SketchUp 2023+).
#
# Draws problem highlights on top of the model without touching it: no
# selection, no materials, no undo entries. Everything it draws comes from
# world-space points captured during analysis, so it never reads entities.
#
# Per-part highlight data (built in main.rb):
#   box:   Geom::BoundingBox, world space
#   edges: { open: [p1, p2, ...], multi: [...], stray: [...] }  point pairs
#   faces: [[tri_points, thickness_in], ...]  tri_points is a flat list, 3 per triangle
#   spot:  [entry_pt, exit_pt, thickness_in] or nil
#   solid: true/false

module BrunoTools
  module PrintPrep
    class HighlightOverlay < Sketchup::Overlay
      COLOR_EDGE  = Sketchup::Color.new(220, 40, 30)
      COLOR_THIN  = Sketchup::Color.new(240, 140, 20, 110)
      COLOR_SPOT  = Sketchup::Color.new(200, 0, 160)
      COLOR_BOX   = Sketchup::Color.new(60, 110, 220)
      COLOR_LABEL = Sketchup::Color.new(255, 255, 255)

      def initialize
        super('bruno.print_prep.highlight', 'Print Prep highlights',
              description: 'Problem parts found by Print Prep.')
        @parts = []
        @mode  = :none
      end

      attr_reader :parts

      # parts: the per-part highlight data list (see header).
      def parts=(parts)
        @parts = parts || []
        @mode  = :none
        @thin  = {}
      end

      # mode: :none, :all, :part or :spot. limit_in: thin limit in real-world inches.
      def set(mode, idx, limit_in, scale)
        @mode  = mode
        @idx   = idx
        @scale = scale
        @limit = limit_in
        @thin  = {}
        visible_parts.each do |i, p|
          pts = []
          p[:faces].each { |tris, d| pts.concat(tris) if d < limit_in }
          @thin[i] = pts
        end
      end

      def clear
        @mode = :none
        @thin = {}
      end

      def active?
        @mode != :none
      end

      def getExtents
        bb = Geom::BoundingBox.new
        visible_parts.each { |_i, p| bb.add(p[:box]) }
        bb
      end

      def draw(view)
        return unless active?

        visible_parts.each do |i, p|
          draw_box(view, p) if @mode != :all || unclear?(p)
          draw_faces(view, @thin[i])
          draw_edges(view, p[:edges])
          draw_spot(view, p, @mode == :spot) if show_spot?(p)
        end
      end

      private

      def visible_parts
        case @mode
        when :all          then @parts.each_with_index.map { |p, i| [i, p] }
        when :part, :spot  then @parts[@idx] ? [[@idx, @parts[@idx]]] : []
        else []
        end
      end

      # Not solid, but no bad edge to point at (e.g. reversed faces).
      def unclear?(p)
        !p[:solid] && p[:edges].values.all?(&:empty?)
      end

      def show_spot?(p)
        return false unless p[:spot]
        @mode == :spot || p[:spot][2] < @limit
      end

      def draw_box(view, p)
        bb = p[:box]
        c  = (0..7).map { |k| bb.corner(k) }
        # corner order: x varies fastest, then y, then z
        pairs = [0, 1, 2, 3, 4, 5, 6, 7, 0, 2, 1, 3, 4, 6, 5, 7, 0, 4, 1, 5, 2, 6, 3, 7]
        view.drawing_color = unclear?(p) ? COLOR_EDGE : COLOR_BOX
        view.line_width    = unclear?(p) ? 2 : 1
        view.line_stipple  = '-'
        view.draw(GL_LINES, pairs.map { |k| c[k] })
        view.line_stipple  = ''
      end

      def draw_faces(view, pts)
        return if pts.nil? || pts.empty?
        view.drawing_color = COLOR_THIN
        view.draw(GL_TRIANGLES, pts)
      end

      # Drawn in 2D so the edges stay visible behind other geometry.
      def draw_edges(view, edges)
        pts = edges[:open] + edges[:multi] + edges[:stray]
        return if pts.empty?
        view.drawing_color = COLOR_EDGE
        view.line_width    = 4
        view.line_stipple  = ''
        view.draw2d(GL_LINES, screen_pairs(view, pts))
      end

      def draw_spot(view, p, label)
        a, b, d = p[:spot]
        view.drawing_color = COLOR_SPOT
        view.line_width    = 4
        view.line_stipple  = ''
        view.draw2d(GL_LINES, screen_pairs(view, [a, b]))
        view.draw_points([a, b], 8, 2, COLOR_SPOT)
        return unless label

        mid = Geom.linear_combination(0.5, a, 0.5, b)
        return unless in_front?(view, mid)
        at   = view.screen_coords(mid)
        text = format('%.2f mm at 1:%d', d.to_mm / @scale, @scale)
        pos  = Geom::Point3d.new(at.x + 12, at.y - 22, 0)
        view.drawing_color = COLOR_SPOT
        view.draw2d(GL_QUADS, label_box(pos, text))
        view.draw_text(pos, text, size: 12, bold: true, color: COLOR_LABEL)
      end

      def label_box(pos, text)
        w = text.length * 8 + 8
        x = pos.x - 4
        y = pos.y - 3
        [[x, y, 0], [x + w, y, 0], [x + w, y + 22, 0], [x, y + 22, 0]].map { |q| Geom::Point3d.new(q) }
      end

      # Screen-space line pairs, dropping any pair with a point behind the camera.
      def screen_pairs(view, pts)
        out = []
        pts.each_slice(2) do |a, b|
          next unless b && in_front?(view, a) && in_front?(view, b)
          out << view.screen_coords(a) << view.screen_coords(b)
        end
        out
      end

      def in_front?(view, pt)
        cam = view.camera
        return true unless cam.perspective?
        (pt - cam.eye).dot(cam.direction) > 0
      end
    end
  end
end
