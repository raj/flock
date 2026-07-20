module Flock
  # Parent link: gives an entity a parent, so its Transform2D/Transform3D is treated as LOCAL and
  # composed with the parent's world transform by `HierarchyPlugin`. Saveable — the link (an
  # entity reference) is remapped on load, so parent/child hierarchies survive save/restore. The
  # resolved world matrix lives in the child's `matrix_override` (transient, recomputed each frame).
  struct Parent
    include Component
    include Saveable
    property entity : Entity

    def initialize(@entity : Entity)
    end

    entity_fields entity
  end

  # Transform hierarchy propagation. Composes each parented entity's local transform up its parent
  # chain into a world matrix, written to the child's `matrix_override` (which the renderers use).
  module Hierarchy
    extend self

    MAX_DEPTH = 64 # cycle guard

    # Recomputes every parented entity's world matrix. 2D and 3D chains are handled separately;
    # a chain is assumed homogeneous (2D under 2D, 3D under 3D).
    def propagate(world : World) : Nil
      apply(world, Transform2D) { |w, e| world_matrix(w, e, Transform2D) }
      apply(world, Transform3D) { |w, e| world_matrix(w, e, Transform3D) }
    end

    # Collects (entity, world-matrix) for every entity that has both Parent and T, then writes the
    # matrices back (collecting first avoids mutating a storage mid-query).
    private def apply(world : World, t : T.class, & : World, Entity -> Mat4) : Nil forall T
      updates = [] of {Entity, Mat4}
      world.query(Parent, t) { |e, _p, _tf| updates << {e, yield(world, e)} }
      updates.each do |(e, m)|
        if ptr = world.storage(t).get_ptr(e)
          tf = ptr.value
          tf.matrix_override = m
          ptr.value = tf
        end
      end
    end

    # World matrix of `e` = product of local matrices from the root down to `e`.
    private def world_matrix(world : World, e : Entity, t : T.class) : Mat4 forall T
      m = world.get(e, t).not_nil!.local_matrix
      cur = e
      depth = 0
      while (par = world.get(cur, Parent)) && (depth += 1) < MAX_DEPTH
        p = par.entity
        break unless world.alive?(p)
        if pt = world.get(p, t)
          m = pt.local_matrix * m
        end
        cur = p
      end
      m
    end
  end

  # Runs `Hierarchy.propagate` each frame so parented entities follow their parents. Add it BEFORE
  # the render plugin so world matrices are resolved before drawing.
  class HierarchyPlugin < Plugin
    def build(app : App) : Nil
      app.add_system(Schedule::Render) { |world, _cmd| Hierarchy.propagate(world) }
    end
  end
end
