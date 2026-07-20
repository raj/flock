# Relative-mouse (FPS look) demo: the cursor is grabbed and hidden, and the camera looks
# around from raw mouse deltas — this is what `Input#relative_mouse_mode` + `Input#mouse_delta`
# are for. Move with WASD (Space/LShift = up/down); press Tab to release/re-grab the cursor.
#
#   crystal run examples/relative_mouse_demo.cr
#   WGPU_FRAMES=120 crystal run examples/relative_mouse_demo.cr   # headless smoke
require "../src/flock/gpu"

SENSITIVITY = 0.0025f32

# Mutable camera state carried across frames (Bevy-style resource).
class FlyState < Flock::Resource
  property fly : Flock::FlyCamera
  property grabbed : Bool

  def initialize(@fly : Flock::FlyCamera, @grabbed : Bool = true)
  end
end

def setup(world : Flock::World, cmd : Flock::Commands)
  world.insert_resource(FlyState.new(Flock::FlyCamera.new(position: Flock::Vec3.new(0, 1, 8))))
  # Grab + hide the cursor so motion arrives as deltas only (mouse_position stays frozen).
  world.resource(Flock::Input).relative_mouse_mode = true

  gpu = world.resource(Flock::GpuContext)
  ground = Flock::Mesh.cube(gpu, color: Flock::Color.new(0.4, 0.42, 0.5))
  cube = Flock::Mesh.cube(gpu, color: Flock::Color.new(0.8, 0.5, 0.3))
  cmd.spawn(Flock::Transform3D.new(position: Flock::Vec3.new(0, -1, 0), scale: Flock::Vec3.new(20, 0.4, 20)),
    Flock::MeshRenderer.new(ground))
  # A grid of cubes to look around at.
  (-2..2).each do |gx|
    (-2..2).each do |gz|
      cmd.spawn(Flock::Transform3D.new(position: Flock::Vec3.new(gx * 3.0f32, 0, gz * 3.0f32)),
        Flock::MeshRenderer.new(cube))
    end
  end
  cmd.spawn(Flock::Transform3D.new,
    Flock::Light.directional(Flock::Vec3.new(-0.5, -1.0, -0.3), Flock::Color::WHITE, 1.4, casts_shadows: true))
  cmd.spawn(Flock::Camera3D.new(clear_color: Flock::Color.new(0.05, 0.06, 0.09)))
end

def fly_look(world : Flock::World, cmd : Flock::Commands)
  state = world.resource(FlyState)
  input = world.resource(Flock::Input)

  # Tab toggles the grab: release to free the cursor (so you can reach the window's close
  # button), press again to re-capture for looking.
  if input.just_pressed?(Flock::Key::Tab)
    state.grabbed = !state.grabbed
    input.relative_mouse_mode = state.grabbed
  end

  if state.grabbed
    d = input.mouse_delta # framebuffer-pixel delta, valid even while the cursor is grabbed
    # Mouse right -> yaw right (+); mouse down -> pitch down (-).
    state.fly.look(d.x * SENSITIVITY, -d.y * SENSITIVITY)

    dt = world.resource(Flock::Time).delta.to_f32
    axis = ->(pos : Flock::Key, neg : Flock::Key) do
      (input.pressed?(pos) ? 1.0f32 : 0.0f32) - (input.pressed?(neg) ? 1.0f32 : 0.0f32)
    end
    state.fly.move(
      axis.call(Flock::Key::W, Flock::Key::S),
      axis.call(Flock::Key::D, Flock::Key::A),
      axis.call(Flock::Key::Space, Flock::Key::LShift),
      dt)
  end

  world.query(Flock::Camera3D) { |_e, cam| state.fly.apply(cam) }
end

app = Flock::App.new
app.add_plugin(Flock::WindowPlugin.new("Flock — Relative Mouse (FPS look)", 900, 650))
app.add_plugin(Flock::InputPlugin.new)
app.add_plugin(Flock::Render3DPlugin.new)

app.add_startup(&->setup(Flock::World, Flock::Commands))
app.add_system(Flock::Schedule::Update, &->fly_look(Flock::World, Flock::Commands))

app.run
