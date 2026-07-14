module Flock
  # Crée la fenêtre SDL3 + la surface wgpu (via le CAMetalLayer de SDL), insère la
  # ressource GpuContext, et installe le runner : la boucle principale (événements
  # SDL + une frame par tour). `WGPU_FRAMES=N` quitte après N frames (test headless).
  class WindowPlugin < Plugin
    def initialize(@title : String = "Flock", @width : Int32 = 800, @height : Int32 = 600)
    end

    def build(app : App) : Nil
      unless LibSDL.init(LibSDL::INIT_VIDEO | LibSDL::INIT_GAMEPAD | LibSDL::INIT_AUDIO)
        raise "SDL_Init: #{String.new(LibSDL.get_error)}"
      end

      flags = LibSDL::WINDOW_METAL | LibSDL::WINDOW_RESIZABLE | LibSDL::WINDOW_HIGH_PIXEL_DENSITY
      window = LibSDL.create_window(@title.to_unsafe, @width, @height, flags)
      raise "SDL_CreateWindow: #{String.new(LibSDL.get_error)}" if window.null?

      view = LibSDL.metal_create_view(window)
      layer = LibSDL.metal_get_layer(view)
      raise "SDL_Metal_GetLayer null" if layer.null?

      instance = WGPU.create_instance
      source = LibWGPU::SurfaceSourceMetalLayer.new
      source.chain.s_type = LibWGPU::SType::SurfaceSourceMetalLayer
      source.layer = layer
      sdesc = LibWGPU::SurfaceDescriptor.new
      sdesc.label = WGPU.empty_string_view
      sdesc.next_in_chain = pointerof(source).as(Pointer(LibWGPU::ChainedStruct))
      surface = LibWGPU.instance_create_surface(instance, pointerof(sdesc))
      raise "instance_create_surface failed" if surface.null?

      adapter = WGPU.request_adapter(instance, compatible_surface: surface)
      device = WGPU.request_device(instance, adapter)
      queue = LibWGPU.device_get_queue(device)

      caps = LibWGPU::SurfaceCapabilities.new
      LibWGPU.surface_get_capabilities(surface, adapter, pointerof(caps))
      format = caps.formats[0]
      LibWGPU.surface_capabilities_free_members(caps)

      LibSDL.get_window_size_in_pixels(window, out fb_w, out fb_h)
      gpu = GpuContext.new(instance, adapter, device, queue, surface, format,
        fb_w.to_u32, fb_h.to_u32, window, view)
      gpu.reconfigure(fb_w.to_u32, fb_h.to_u32)
      app.world.insert_resource(gpu)

      install_runner(app, gpu)
    end

    private def install_runner(app : App, gpu : GpuContext) : Nil
      app.runner do |a|
        max_frames = ENV["WGPU_FRAMES"]?.try(&.to_i?)
        frame = 0
        running = true
        event = LibSDL::Event.new

        while running
          break if max_frames && frame >= max_frames

          while LibSDL.poll_event(pointerof(event))
            running = false if event.type == LibSDL::EVENT_QUIT
          end

          # Redimensionnement : reconfigure la surface si la taille a changé.
          LibSDL.get_window_size_in_pixels(gpu.window, out w, out h)
          if w.to_u32 != gpu.width || h.to_u32 != gpu.height
            gpu.reconfigure(w.to_u32, h.to_u32)
          end

          a.update
          frame += 1
        end

        # La libération (wgpu + SDL) est faite par App#run -> World#shutdown ->
        # GpuContext#release (ordre garanti : renderer avant device).
        puts "[Flock] fenêtre fermée (#{frame} frames)"
      end
    end
  end
end
