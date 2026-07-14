module Flock
  # Crée le Renderer2D au startup (à partir du GpuContext publié par WindowPlugin)
  # et enregistre le système de rendu dans le schedule Render.
  class RenderPlugin < Plugin
    def build(app : App) : Nil
      app.add_startup do |world, _cmd|
        gpu = world.resource(GpuContext)
        world.insert_resource(Renderer2D.new(gpu))
      end

      app.add_system(Schedule::Render) do |world, _cmd|
        world.resource?(Renderer2D).try &.render(world)
      end
    end
  end
end
