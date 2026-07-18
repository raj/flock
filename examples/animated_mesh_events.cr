# Flock equivalent of Bevy's animation/animated_mesh_events.rs.
#
# A GPU-skinned fox gallops (glTF Fox.glb, "Gallop" clip). Flock has no baked animation
# events, so we synthesize them: each frame we detect when the looping animation time
# crosses one of four configured footstep instants and send a `Footstep` event carrying a
# ground position. A reader spawns a glowing translucent "ripple" at each footstep; the
# ripples expand and fade out, then despawn. Demonstrates GPU skinning + animation playback
# + Flock's event system + transparent/emissive effects, all in one scene.
#
#   crystal run examples/animated_mesh_events.cr
#   WGPU_FRAMES=240 crystal run examples/animated_mesh_events.cr   # headless smoke
require "../src/flock/gpu"

GALLOP = 3 # animation clip index in Fox.glb

# A spawned footstep ripple: expands + fades over `lifetime` seconds, then despawns.
struct Ripple
  include Flock::Component
  property age : Float32
  property lifetime : Float32

  def initialize(@lifetime : Float32 = 0.8f32, @age : Float32 = 0.0f32)
  end
end

# The "animation event": a footstep at a ground position (like Bevy's AnimationEvent).
struct Footstep
  getter pos : Flock::Vec3

  def initialize(@pos : Flock::Vec3)
  end
end

# Where each footstep lands (front/back, left/right of the galloping fox), in world units.
FOOT_SPOTS = [
  Flock::Vec3.new(0.35, 0.0, -1.7), Flock::Vec3.new(-0.35, 0.0, -1.7),
  Flock::Vec3.new(0.35, 0.0, 1.7), Flock::Vec3.new(-0.35, 0.0, 1.7),
]
# Footstep instants as fractions of the gallop cycle.
STEP_FRACTIONS = [0.02f32, 0.27f32, 0.52f32, 0.77f32]

# All state the demo carries across frames (Bevy-style resource):
# the skinned fox, the shared ripple disc, the footstep instants, the previous
# animation time, the auto-orbit camera, and the round-robin footstep index.
class AnimState < Flock::Resource
  property fox : Flock::GpuSkinnedModel?
  property disc : Flock::Mesh?
  property step_times : Array(Float32)
  property prev_t : Float32
  property orbit : Flock::OrbitCamera
  property step_index : Int32

  def initialize(@orbit : Flock::OrbitCamera)
    @fox = nil
    @disc = nil
    @step_times = [] of Float32
    @prev_t = 0.0f32
    @step_index = 0
  end
end

def setup(world : Flock::World, cmd : Flock::Commands)
  world.insert_resource(AnimState.new(
    Flock::OrbitCamera.new(target: Flock::Vec3.new(0.0, 1.3, 0.0), distance: 8.5f32, yaw: 0.6f32, pitch: 0.35f32)))
  state = world.resource(AnimState)

  gpu = world.resource(Flock::GpuContext)
  renderer = world.resource(Flock::Renderer3D)

  # Soft sky/ground ambient + a key light.
  world.insert_resource(Flock::AmbientLight.new(
    sky: Flock::Color.new(0.35, 0.4, 0.5), ground: Flock::Color.new(0.12, 0.1, 0.09)))
  cmd.spawn(Flock::Transform3D.new,
    Flock::Light.directional(Flock::Vec3.new(-0.4, -1.0, -0.35), Flock::Color.new(1.0, 0.97, 0.9), 1.4, casts_shadows: true))

  # Ground slab.
  ground = Flock::Mesh.cube(gpu, color: Flock::Color.new(0.16, 0.18, 0.22))
  cmd.spawn(Flock::Transform3D.new(position: Flock::Vec3.new(0.0, -0.1, 0.0), scale: Flock::Vec3.new(24.0, 0.2, 24.0)),
    Flock::MeshRenderer.new(ground))

  cmd.spawn(Flock::Camera3D.new(clear_color: Flock::Color.new(0.05, 0.06, 0.09)))

  # The fox (GPU-skinned), galloping.
  scene = Flock::Mesh.load_gltf_scene(gpu, "examples/assets/Fox.glb")
  model = Flock::GpuSkinnedModel.spawn(scene, world, renderer, gpu)
  model.clip = GALLOP
  state.fox = model
  dur = scene.animations[GALLOP].duration
  STEP_FRACTIONS.each { |f| state.step_times << f * dur }

  # A flat disc (flattened sphere) reused by every ripple.
  state.disc = Flock::Mesh.sphere(gpu, radius: 1.0, segments: 24, rings: 12, color: Flock::Color::WHITE)
end

# Advance the animation and emit a Footstep event whenever the looping time crosses one of
# the configured instants (the "animation event" trigger).
def advance_animation(world : Flock::World, cmd : Flock::Commands)
  state = world.resource(AnimState)
  return unless model = state.fox
  dt = world.resource(Flock::Time).delta.to_f32
  model.update(dt)
  dur = model.scene.animations[GALLOP].duration
  return if dur <= 0.0f32
  t = model.time
  state.step_times.each_with_index do |st, i|
    crossed = t >= state.prev_t ? (state.prev_t < st && st <= t) : (st > state.prev_t || st <= t)
    if crossed
      world.send_event(Footstep.new(FOOT_SPOTS[state.step_index % FOOT_SPOTS.size]))
      state.step_index += 1
    end
  end
  state.prev_t = t
end

# Spawn a glowing translucent ripple at each footstep.
def spawn_ripples(world : Flock::World, cmd : Flock::Commands)
  return unless d = world.resource(AnimState).disc
  world.each_event(Footstep) do |ev|
    cmd.spawn(
      Flock::Transform3D.new(position: ev.pos, scale: Flock::Vec3.new(0.25, 0.02, 0.25)),
      Flock::MeshRenderer.new(d, tint: Flock::Color.new(1.0, 1.0, 1.0, 0.85),
        emissive_factor: Flock::Color.new(1.0, 0.7, 0.25), transparent: true, cull: false),
      Ripple.new)
  end
end

# Expand + fade ripples; despawn expired ones (deferred, so we never write through a
# pointer after despawning — see World#query's pointer-validity note).
def update_ripples(world : Flock::World, cmd : Flock::Commands)
  dt = world.resource(Flock::Time).delta.to_f32
  world.query(Ripple, Flock::Transform3D, Flock::MeshRenderer) do |e, rp, tf, mr|
    age = rp.value.age + dt
    if age >= rp.value.lifetime
      cmd.despawn(e)
      next
    end
    rp.value.age = age
    f = age / rp.value.lifetime
    r = 0.25f32 + f * 2.2f32                 # expand
    tf.value.scale = Flock::Vec3.new(r, 0.02f32, r)
    m = mr.value
    m.tint = Flock::Color.new(1.0, 1.0, 1.0, (1.0f32 - f) * 0.85f32) # fade
    mr.value = m
  end
end

# Slow auto-orbit so the whole gait is visible.
def auto_orbit(world : Flock::World, cmd : Flock::Commands)
  state = world.resource(AnimState)
  dt = world.resource(Flock::Time).delta.to_f32
  state.orbit.rotate(dt * 0.4f32, 0.0)
  world.query(Flock::Camera3D) { |_e, cam| state.orbit.apply(cam) }
end

# Esc quits (the runner honors WindowState#close_requested).
def esc_quits(world : Flock::World, cmd : Flock::Commands)
  if world.resource(Flock::Input).pressed?(Flock::Key::Escape)
    world.resource?(Flock::WindowState).try &.on_close_requested
  end
end

app = Flock::App.new
app.add_plugin(Flock::WindowPlugin.new("Flock - Animated Mesh Events (Fox)", 960, 640))
app.add_plugin(Flock::InputPlugin.new)
app.add_plugin(Flock::Render3DPlugin.new) # MSAA 4x by default
app.add_event(Footstep)

app.add_startup(&->setup(Flock::World, Flock::Commands))
app.add_system(Flock::Schedule::Update, &->advance_animation(Flock::World, Flock::Commands))
app.add_system(Flock::Schedule::Update, &->spawn_ripples(Flock::World, Flock::Commands))
app.add_system(Flock::Schedule::Update, &->update_ripples(Flock::World, Flock::Commands))
app.add_system(Flock::Schedule::Update, &->auto_orbit(Flock::World, Flock::Commands))
app.add_system(Flock::Schedule::Update, &->esc_quits(Flock::World, Flock::Commands))

app.run
