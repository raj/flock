module Flock
  # Creates the Renderer2D at startup (from the GpuContext published by WindowPlugin)
  # and registers the render system in the Render schedule.
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
