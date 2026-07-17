# Runs the backend-agnostic SharedScene (examples/shared_scene.cr) on the NATIVE renderer
# — the exact same scene source the web target runs. The only target-specific glue is the
# texture loader (here: SDL_image → a Renderer2D texture-bank id) and a Camera2D framing
# the scene's [0,WIDTH]×[0,HEIGHT] space.
#
#   crystal run examples/shared_scene_native.cr
#   WGPU_FRAMES=120 crystal run examples/shared_scene_native.cr   # headless smoke
require "../src/flock/gpu"
require "./shared_scene"

app = Flock::App.new
app.add_plugin(Flock::DefaultPlugins.new("Flock — shared scene (native)", 800, 600))

# Camera centered on the scene so world [0,800]×[0,600] fills the window.
app.add_startup do |_world, cmd|
  cmd.spawn(Flock::Camera2D.new(
    position: Flock::Vec2.new(SharedScene::WIDTH * 0.5f32, SharedScene::HEIGHT * 0.5f32),
    clear_color: Flock::Color.new(0.04, 0.04, 0.07)))
end

# Native texture loader: load a file via SDL_image and register it in the Renderer2D bank.
SharedScene.setup(app, ->(name : String) {
  gpu = app.world.resource(Flock::GpuContext)
  renderer = app.world.resource(Flock::Renderer2D)
  renderer.register_texture(Flock::Texture.load(gpu, "examples/assets/#{name}", Flock::SamplerFilter::Linear))
})

app.run
