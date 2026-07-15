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

  # Unified 2D + 3D in a single frame: renders the 3D scene (Renderer3D, clearing
  # color + depth), then draws sprites/HUD on top (Renderer2D in overlay mode), and
  # presents once. Use it INSTEAD of RenderPlugin/Render3DPlugin when a game mixes a
  # 3D world with a 2D overlay (score, menus, crosshair…).
  class Render2D3DPlugin < Plugin
    def build(app : App) : Nil
      app.add_startup do |world, _cmd|
        gpu = world.resource(GpuContext)
        world.insert_resource(Renderer3D.new(gpu))
        world.insert_resource(Renderer2D.new(gpu))
      end

      app.add_system(Schedule::Render) do |world, _cmd|
        gpu = world.resource(GpuContext)
        r3 = world.resource(Renderer3D)
        r2 = world.resource(Renderer2D)

        st = LibWGPU::SurfaceTexture.new
        LibWGPU.surface_get_current_texture(gpu.surface, pointerof(st))
        case st.status
        when .success_optimal?, .success_suboptimal?
          view = LibWGPU.texture_create_view(st.texture, Pointer(LibWGPU::TextureViewDescriptor).null)
          r3.render_into(world, view)                                            # 3D scene (clears)
          r2.render_into(view, gpu.width, gpu.height, world, load_previous: true) # 2D overlay on top
          LibWGPU.surface_present(gpu.surface)
          LibWGPU.texture_view_release(view)
          LibWGPU.texture_release(st.texture)
        when .outdated?, .lost?
          gpu.reconfigure_to_window
        else
          # transient: skip this frame
        end
      end
    end
  end
end
