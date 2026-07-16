module Flock
  # One animation channel: samples a single node's TRS property over keyframe times.
  # `values` is flat, stride 3 for translation/scale, 4 for rotation (quaternion xyzw).
  class GltfChannel
    getter node : Int32
    getter path : String # "translation" | "rotation" | "scale"
    getter times : Array(Float32)
    getter values : Array(Float32)
    getter? step : Bool # STEP interpolation (else LINEAR)

    def initialize(@node : Int32, @path : String, @times : Array(Float32),
                   @values : Array(Float32), @step : Bool = false)
    end

    def stride : Int32
      @path == "rotation" ? 4 : 3
    end

    def duration : Float32
      @times.empty? ? 0.0f32 : @times[-1]
    end

    # Sampled value (of length `stride`) at time `t`, clamped to the keyframe range.
    # LINEAR for translation/scale, normalized-lerp for rotation; STEP holds.
    def sample(t : Float32) : Array(Float32)
      s = stride
      n = @times.size
      return Array(Float32).new(s, 0.0f32) if n == 0
      return @values[0, s] if t <= @times[0]
      return @values[(n - 1) * s, s] if t >= @times[n - 1]

      i = 0
      while i < n - 1 && @times[i + 1] < t
        i += 1
      end
      a = @values[i * s, s]
      return a if @step
      b = @values[(i + 1) * s, s]
      span = @times[i + 1] - @times[i]
      f = span > 0 ? (t - @times[i]) / span : 0.0f32

      if @path == "rotation"
        # nlerp (take the shorter arc), then normalize.
        dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
        sign = dot < 0 ? -1.0f32 : 1.0f32
        q = Array(Float32).new(4) { |k| a[k] + (b[k] * sign - a[k]) * f }
        len = Math.sqrt(q[0]**2 + q[1]**2 + q[2]**2 + q[3]**2)
        len = 1.0f32 if len == 0
        q.map { |v| (v / len).to_f32 }
      else
        Array(Float32).new(s) { |k| a[k] + (b[k] - a[k]) * f }
      end
    end
  end

  class GltfAnimation
    getter name : String
    getter channels : Array(GltfChannel)

    def initialize(@name : String, @channels : Array(GltfChannel))
    end

    def duration : Float32
      @channels.map(&.duration).max? || 0.0f32
    end
  end

  # A node of a loaded glTF scene: base local transform (TRS) + optional mesh + children.
  struct GltfNode
    property translation : Vec3
    property rotation : StaticArray(Float32, 4) # quaternion xyzw
    property scale : Vec3
    property mesh : Mesh?
    property children : Array(Int32)

    def initialize(@translation : Vec3, @rotation : StaticArray(Float32, 4), @scale : Vec3,
                   @mesh : Mesh?, @children : Array(Int32))
    end
  end

  # A loaded glTF scene graph with its animations. `world_matrices(t)` evaluates the
  # hierarchy at a given time. Node (TRS) animation only — skinning is not supported.
  class GltfScene
    getter nodes : Array(GltfNode)
    getter roots : Array(Int32)
    getter animations : Array(GltfAnimation)

    def initialize(@nodes : Array(GltfNode), @roots : Array(Int32), @animations : Array(GltfAnimation))
    end

    def mesh_nodes : Array(Int32)
      (0...@nodes.size).select { |i| !@nodes[i].mesh.nil? }
    end

    # World matrix per node index, with animation `anim` applied at time `t`.
    def world_matrices(t : Float32, anim : Int32 = 0) : Array(Mat4)
      trans = @nodes.map(&.translation)
      rots = @nodes.map(&.rotation)
      scales = @nodes.map(&.scale)

      if a = @animations[anim]?
        a.channels.each do |ch|
          v = ch.sample(t)
          case ch.path
          when "translation" then trans[ch.node] = Vec3.new(v[0], v[1], v[2])
          when "scale"       then scales[ch.node] = Vec3.new(v[0], v[1], v[2])
          when "rotation"    then rots[ch.node] = StaticArray[v[0], v[1], v[2], v[3]]
          end
        end
      end

      locals = (0...@nodes.size).map do |i|
        r = rots[i]
        Mat4.translation(trans[i]) * Mat4.rotation_quaternion(r[0], r[1], r[2], r[3]) * Mat4.scale(scales[i])
      end

      worlds = Array(Mat4).new(@nodes.size) { Mat4.identity }
      @roots.each { |r| accumulate_world(r, Mat4.identity, locals, worlds) }
      worlds
    end

    private def accumulate_world(idx : Int32, parent : Mat4, locals : Array(Mat4), worlds : Array(Mat4)) : Nil
      worlds[idx] = parent * locals[idx]
      @nodes[idx].children.each { |c| accumulate_world(c, worlds[idx], locals, worlds) }
    end
  end

  # Spawns a glTF scene's meshes into the world (one entity per mesh-bearing node) and
  # plays its node animation: `update` advances time (looping) and writes each node's
  # world matrix into its entity's Transform3D override.
  #
  #   model = Flock::AnimatedModel.spawn(scene, world)
  #   app.add_system(Flock::Schedule::Update) { |w, _| model.update(w, w.resource(Flock::Time).delta.to_f32) }
  class AnimatedModel
    getter scene : GltfScene
    property time : Float32 = 0.0f32
    property clip : Int32 = 0
    @entities : Hash(Int32, Entity)

    def initialize(@scene : GltfScene, @entities : Hash(Int32, Entity))
    end

    def self.spawn(scene : GltfScene, world : World, tint : Color = Color::WHITE) : AnimatedModel
      entities = {} of Int32 => Entity
      scene.mesh_nodes.each do |ni|
        mesh = scene.nodes[ni].mesh.not_nil!
        e = world.spawn
        world.add(e, Transform3D.new)
        world.add(e, MeshRenderer.new(mesh, tint: tint))
        entities[ni] = e
      end
      new(scene, entities)
    end

    # Writes the current pose (world matrices at `time`) into the entities.
    def apply(world : World) : Nil
      worlds = @scene.world_matrices(@time, @clip)
      @entities.each do |ni, e|
        if ptr = world.get_ptr(e, Transform3D)
          ptr.value.matrix_override = worlds[ni]
        end
      end
    end

    # Advances time (looping over the clip duration) and applies the pose.
    def update(world : World, dt : Float32) : Nil
      d = (@scene.animations[@clip]?.try(&.duration)) || 0.0f32
      @time += dt
      @time = @time % d if d > 0 && @time > d
      apply(world)
    end
  end
end
