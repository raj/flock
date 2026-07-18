# Split-screen: two Camera2D side by side, each clearing its own viewport to its own
# color, both viewing the same green square at the world origin.
#   crystal run examples/split_screen.cr
#   WGPU_FRAMES=5 crystal run examples/split_screen.cr
require "../src/flock/gpu"

def setup(world : Flock::World, cmd : Flock::Commands)
  gpu = world.resource(Flock::GpuContext)
  w = gpu.width.to_f32
  h = gpu.height.to_f32
  half = w / 2.0f32

  # Viewports are in framebuffer pixels (HiDPI-aware via gpu.width/height).
  cmd.spawn(Flock::Camera2D.new(
    viewport: Flock::Viewport.new(0.0f32, 0.0f32, half, h),
    clear_color: Flock::Color.new(0.25, 0.08, 0.10), order: 0))
  cmd.spawn(Flock::Camera2D.new(
    viewport: Flock::Viewport.new(half, 0.0f32, w - half, h),
    clear_color: Flock::Color.new(0.08, 0.10, 0.25), order: 1))

  cmd.spawn(Flock::Transform2D.at(0, 0),
    Flock::Sprite.new(Flock::Vec2.new(120, 120), Flock::Color::GREEN))
end

app = Flock::App.new
app.add_plugin(Flock::WindowPlugin.new("Flock — split screen", 800, 400))
app.add_plugin(Flock::RenderPlugin.new)

app.add_startup(&->setup(Flock::World, Flock::Commands))

app.run
