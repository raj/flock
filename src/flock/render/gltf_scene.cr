module Flock
  # One animation channel: samples a single node's TRS property over keyframe times.
  # `values` is flat, stride 3 for translation/scale, 4 for rotation (quaternion xyzw).
  # For CUBICSPLINE each keyframe stores 3 blocks (in-tangent, value, out-tangent).
  class GltfChannel
    getter node : Int32
    getter path : String   # "translation" | "rotation" | "scale"
    getter interp : String # "LINEAR" | "STEP" | "CUBICSPLINE"
    getter times : Array(Float32)
    getter values : Array(Float32)

    def initialize(@node : Int32, @path : String, @times : Array(Float32),
                   @values : Array(Float32), @interp : String = "LINEAR")
    end

    def stride : Int32
      @path == "rotation" ? 4 : 3
    end

    def duration : Float32
      @times.empty? ? 0.0f32 : @times[-1]
    end

    # Pose value (length `stride`) at keyframe index k, accounting for the CUBICSPLINE
    # layout where each keyframe is {in-tangent, value, out-tangent}.
    private def value_at(k : Int32) : Array(Float32)
      s = stride
      base = @interp == "CUBICSPLINE" ? k * 3 * s + s : k * s
      @values[base, s]
    end

    # Sampled value (length `stride`) at time `t`, clamped to the keyframe range.
    def sample(t : Float32) : Array(Float32)
      s = stride
      n = @times.size
      return Array(Float32).new(s, 0.0f32) if n == 0
      return value_at(0) if t <= @times[0]
      return value_at(n - 1) if t >= @times[n - 1]

      i = 0
      while i < n - 1 && @times[i + 1] < t
        i += 1
      end
      span = @times[i + 1] - @times[i]
      f = span > 0 ? (t - @times[i]) / span : 0.0f32

      result =
        if @interp == "STEP"
          value_at(i)
        elsif @interp == "CUBICSPLINE"
          cubic(i, f, span, s)
        elsif @path == "rotation"
          # nlerp along the shorter arc.
          a = value_at(i); b = value_at(i + 1)
          dot = a[0]*b[0] + a[1]*b[1] + a[2]*b[2] + a[3]*b[3]
          sign = dot < 0 ? -1.0f32 : 1.0f32
          Array(Float32).new(4) { |k| a[k] + (b[k] * sign - a[k]) * f }
        else
          a = value_at(i); b = value_at(i + 1)
          Array(Float32).new(s) { |k| a[k] + (b[k] - a[k]) * f }
        end

      @path == "rotation" ? normalize4(result) : result
    end

    # Cubic Hermite spline between keyframes i and i+1 (glTF CUBICSPLINE).
    private def cubic(i : Int32, ft : Float32, td : Float32, s : Int32) : Array(Float32)
      v0 = @values[i * 3 * s + s, s]
      b0 = @values[i * 3 * s + 2 * s, s]      # out-tangent of keyframe i
      a1 = @values[(i + 1) * 3 * s, s]        # in-tangent of keyframe i+1
      v1 = @values[(i + 1) * 3 * s + s, s]
      t2 = ft * ft; t3 = t2 * ft
      h00 = 2*t3 - 3*t2 + 1; h10 = t3 - 2*t2 + ft
      h01 = -2*t3 + 3*t2; h11 = t3 - t2
      Array(Float32).new(s) { |k| h00*v0[k] + h10*td*b0[k] + h01*v1[k] + h11*td*a1[k] }
    end

    private def normalize4(q : Array(Float32)) : Array(Float32)
      len = Math.sqrt(q[0]**2 + q[1]**2 + q[2]**2 + q[3]**2)
      len = 1.0f32 if len == 0
      q.map { |v| (v / len).to_f32 }
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

  # A CPU-skinned mesh: bind-pose interleaved vertices (Mesh::FLOATS floats each) plus
  # per-vertex joint indices (into `joint_nodes`) and weights, the skin's joint node
  # indices and inverse-bind matrices, and the target Mesh whose vertex buffer is
  # rewritten each frame with the skinned positions/normals.
  class SkinnedPart
    getter mesh : Mesh
    getter bind_verts : Array(Float32)
    getter joints : Array(Int32)   # 4 per vertex
    getter weights : Array(Float32) # 4 per vertex
    getter joint_nodes : Array(Int32)
    getter inverse_binds : Array(Mat4)

    def initialize(@mesh, @bind_verts, @joints, @weights, @joint_nodes, @inverse_binds)
    end
  end

  # A loaded glTF scene graph with its animations. `world_matrices(t)` evaluates the
  # hierarchy at a given time. Covers node (TRS) animation and CPU skinning (`skins`).
  class GltfScene
    getter nodes : Array(GltfNode)
    getter roots : Array(Int32)
    getter animations : Array(GltfAnimation)
    getter skins : Array(SkinnedPart)

    def initialize(@nodes : Array(GltfNode), @roots : Array(Int32),
                   @animations : Array(GltfAnimation), @skins : Array(SkinnedPart) = [] of SkinnedPart)
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

  # Plays a skinned glTF scene: spawns each skinned mesh (identity transform — the
  # skinned vertices are already in scene space) and, each frame, computes joint
  # matrices from the animated node hierarchy and rewrites the mesh vertex buffers on
  # the CPU (Σ weight · jointMatrix · bindVertex). Correctness-first; GPU skinning is a
  # future optimization.
  class SkinnedModel
    getter scene : GltfScene
    property time : Float32 = 0.0f32
    property clip : Int32 = 0

    def initialize(@scene : GltfScene, @gpu : GpuContext)
    end

    # Spawns one entity (identity Transform3D) per skinned mesh and returns the player.
    def self.spawn(scene : GltfScene, world : World, gpu : GpuContext, tint : Color = Color::WHITE) : SkinnedModel
      scene.skins.each do |part|
        e = world.spawn
        world.add(e, Transform3D.new)
        world.add(e, MeshRenderer.new(part.mesh, tint: tint))
      end
      new(scene, gpu)
    end

    # CPU-skins every part at the current time and uploads the new vertices.
    def apply : Nil
      worlds = @scene.world_matrices(@time, @clip)
      f = Mesh::FLOATS
      @scene.skins.each do |part|
        jmats = Array(Mat4).new(part.joint_nodes.size) do |j|
          worlds[part.joint_nodes[j]] * part.inverse_binds[j]
        end
        verts = part.bind_verts.dup
        vcount = part.bind_verts.size // f
        vcount.times do |v|
          bx = part.bind_verts[v * f]; by = part.bind_verts[v * f + 1]; bz = part.bind_verts[v * f + 2]
          bnx = part.bind_verts[v * f + 3]; bny = part.bind_verts[v * f + 4]; bnz = part.bind_verts[v * f + 5]
          px = 0.0f32; py = 0.0f32; pz = 0.0f32
          nx = 0.0f32; ny = 0.0f32; nz = 0.0f32
          4.times do |i|
            w = part.weights[v * 4 + i]
            next if w == 0.0f32
            m = jmats[part.joints[v * 4 + i]]
            tp = m.transform_point(Vec3.new(bx, by, bz))
            px += tp.x * w; py += tp.y * w; pz += tp.z * w
            nd = m.transform_direction(Vec3.new(bnx, bny, bnz))
            nx += nd.x * w; ny += nd.y * w; nz += nd.z * w
          end
          nl = Math.sqrt(nx * nx + ny * ny + nz * nz)
          nl = 1.0f32 if nl == 0
          verts[v * f] = px; verts[v * f + 1] = py; verts[v * f + 2] = pz
          verts[v * f + 3] = nx / nl; verts[v * f + 4] = ny / nl; verts[v * f + 5] = nz / nl
        end
        LibWGPU.queue_write_buffer(@gpu.queue, part.mesh.vertex_buf, 0_u64,
          verts.to_unsafe.as(Void*), (verts.size * 4).to_u64)
      end
    end

    def update(dt : Float32) : Nil
      d = (@scene.animations[@clip]?.try(&.duration)) || 0.0f32
      @time += dt
      @time = @time % d if d > 0 && @time > d
      apply
    end
  end

  # GPU-skinned variant of SkinnedModel: skinning runs in the vertex shader. Each frame
  # it only uploads the joint matrices (not the vertices) to each skin's storage buffer;
  # Renderer3D draws the skinned meshes with its skinned pipeline.
  class GpuSkinnedModel
    getter scene : GltfScene
    property time : Float32 = 0.0f32
    property clip : Int32 = 0
    @skins : Array(GpuSkinnedMesh)

    def initialize(@scene : GltfScene, @gpu : GpuContext, @skins : Array(GpuSkinnedMesh))
    end

    def self.spawn(scene : GltfScene, world : World, renderer : Renderer3D, gpu : GpuContext) : GpuSkinnedModel
      skins = [] of GpuSkinnedMesh
      scene.skins.each do |part|
        gsm = renderer.build_gpu_skin(part.mesh, part.joints, part.weights, part.joint_nodes, part.inverse_binds)
        world.add(world.spawn, gsm)
        skins << gsm
      end
      new(scene, gpu, skins)
    end

    # Uploads joint matrices (worldJoint · inverseBind) for the current pose.
    def apply : Nil
      worlds = @scene.world_matrices(@time, @clip)
      @skins.each do |gsm|
        mats = Array(Float32).new(gsm.joint_count * 16)
        gsm.joint_count.times { |j| mats.concat((worlds[gsm.joint_nodes[j]] * gsm.inverse_binds[j]).m) }
        LibWGPU.queue_write_buffer(@gpu.queue, gsm.joint_buf, 0_u64, mats.to_unsafe.as(Void*), (mats.size * 4).to_u64)
      end
    end

    def update(dt : Float32) : Nil
      d = (@scene.animations[@clip]?.try(&.duration)) || 0.0f32
      @time += dt
      @time = @time % d if d > 0 && @time > d
      apply
    end
  end
end
