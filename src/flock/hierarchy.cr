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
      apply(world, Transform2D)
      apply(world, Transform3D)
    end

    # Computes each parented entity's world matrix (memoized so every parent is resolved once,
    # parents before children — topological), then writes them back. Collecting first avoids
    # mutating a storage mid-query.
    private def apply(world : World, t : T.class) : Nil forall T
      cache = {} of UInt32 => Mat4
      parented = [] of Entity
      world.query(Parent, t) { |e, _p, _tf| parented << e }
      parented.each { |e| world_matrix(world, e, t, cache) }
      parented.each do |e|
        if (m = cache[e.id]?) && (ptr = world.storage(t).get_ptr(e))
          tf = ptr.value
          tf.matrix_override = m
          ptr.value = tf
        end
      end
    end

    # World matrix of `e`: its own `local_matrix` composed with its parent's world matrix.
    # The parent's world is reused from `cache` when the parent is itself parented (computed
    # once, topologically); otherwise it's the parent's `matrix` — override-aware, so a baked
    # pose on an ancestor propagates instead of being recomputed from its local TRS. `depth`
    # caps the chain so a parent cycle can't recurse without bound (MAX_DEPTH guard).
    private def world_matrix(world : World, e : Entity, t : T.class,
                             cache : Hash(UInt32, Mat4), depth : Int32 = 0) : Mat4 forall T
      if cached = cache[e.id]?
        return cached
      end
      local = world.get(e, t).not_nil!.local_matrix
      result =
        if depth + 1 < MAX_DEPTH &&
           (par = world.get(e, Parent)) && world.alive?(par.entity) &&
           (pt = world.get(par.entity, t))
          p = par.entity
          parent_world = world.has?(p, Parent) ? world_matrix(world, p, t, cache, depth + 1) : pt.matrix
          parent_world * local
        else
          local
        end
      cache[e.id] = result
      result
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
