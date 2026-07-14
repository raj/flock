module Flock
  # Crée la fenêtre SDL3 + la surface wgpu (dispatchée par plateforme : Metal sur
  # macOS, X11/Wayland sur Linux, HWND sur Windows — via `make_surface`), insère la
  # ressource GpuContext, et installe le runner : la boucle principale (événements
  # SDL + une frame par tour). `WGPU_FRAMES=N` quitte après N frames (test headless).
  class WindowPlugin < Plugin
    def initialize(@title : String = "Flock", @width : Int32 = 800, @height : Int32 = 600)
    end

    def build(app : App) : Nil
      unless LibSDL.init(LibSDL::INIT_VIDEO | LibSDL::INIT_GAMEPAD | LibSDL::INIT_AUDIO)
        raise "SDL_Init: #{String.new(LibSDL.get_error)}"
      end

      flags = LibSDL::WINDOW_RESIZABLE | LibSDL::WINDOW_HIGH_PIXEL_DENSITY
      {% if flag?(:darwin) %}
        flags |= LibSDL::WINDOW_METAL # vue Metal (macOS)
      {% end %}
      window = LibSDL.create_window(@title.to_unsafe, @width, @height, flags)
      raise "SDL_CreateWindow: #{String.new(LibSDL.get_error)}" if window.null?

      instance = WGPU.create_instance
      surface, view = make_surface(instance, window)

      adapter = WGPU.request_adapter(instance, compatible_surface: surface)
      device = Flock.request_device(instance, adapter) # device + callbacks d'erreur wgpu
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

    # Crée la surface wgpu selon la plateforme, via les handles natifs exposés par SDL
    # (`SDL_GetWindowProperties`). Retourne {surface, MetalView} (la vue n'existe que
    # sur macOS ; null ailleurs). Les branches non-macOS sont écrites mais n'ont pas
    # été testées au runtime sur cette machine.
    private def make_surface(instance : LibWGPU::Instance, window : LibSDL::Window) : {LibWGPU::Surface, LibSDL::MetalView}
      no_view = Pointer(Void).null.as(LibSDL::MetalView)
      {% if flag?(:darwin) %}
        view = LibSDL.metal_create_view(window)
        layer = LibSDL.metal_get_layer(view)
        raise "SDL_Metal_GetLayer null" if layer.null?
        src = LibWGPU::SurfaceSourceMetalLayer.new
        src.chain.s_type = LibWGPU::SType::SurfaceSourceMetalLayer
        src.layer = layer
        {create_surface_from(instance, pointerof(src).as(Pointer(Void))), view}
      {% elsif flag?(:win32) %}
        props = LibSDL.get_window_properties(window)
        src = LibWGPU::SurfaceSourceWindowsHWND.new
        src.chain.s_type = LibWGPU::SType::SurfaceSourceWindowsHWND
        src.hwnd = LibSDL.get_pointer_property(props, "SDL.window.win32.hwnd".to_unsafe, Pointer(Void).null)
        src.hinstance = LibSDL.get_pointer_property(props, "SDL.window.win32.instance".to_unsafe, Pointer(Void).null)
        {create_surface_from(instance, pointerof(src).as(Pointer(Void))), no_view}
      {% elsif flag?(:linux) %}
        props = LibSDL.get_window_properties(window)
        driver = String.new(LibSDL.get_current_video_driver)
        if driver == "wayland"
          src = LibWGPU::SurfaceSourceWaylandSurface.new
          src.chain.s_type = LibWGPU::SType::SurfaceSourceWaylandSurface
          src.display = LibSDL.get_pointer_property(props, "SDL.window.wayland.display".to_unsafe, Pointer(Void).null)
          src.surface = LibSDL.get_pointer_property(props, "SDL.window.wayland.surface".to_unsafe, Pointer(Void).null)
          {create_surface_from(instance, pointerof(src).as(Pointer(Void))), no_view}
        else # x11
          src = LibWGPU::SurfaceSourceXlibWindow.new
          src.chain.s_type = LibWGPU::SType::SurfaceSourceXlibWindow
          src.display = LibSDL.get_pointer_property(props, "SDL.window.x11.display".to_unsafe, Pointer(Void).null)
          src.window = LibSDL.get_number_property(props, "SDL.window.x11.window".to_unsafe, 0_i64).to_u64
          {create_surface_from(instance, pointerof(src).as(Pointer(Void))), no_view}
        end
      {% else %}
        {% raise "Flock : création de surface non supportée sur cette plateforme" %}
      {% end %}
    end

    private def create_surface_from(instance : LibWGPU::Instance, source : Pointer(Void)) : LibWGPU::Surface
      sdesc = LibWGPU::SurfaceDescriptor.new
      sdesc.label = WGPU.empty_string_view
      sdesc.next_in_chain = source.as(Pointer(LibWGPU::ChainedStruct))
      surface = LibWGPU.instance_create_surface(instance, pointerof(sdesc))
      raise "instance_create_surface a échoué" if surface.null?
      surface
    end

    private def install_runner(app : App, gpu : GpuContext) : Nil
      app.runner do |a|
        max_frames = ENV["WGPU_FRAMES"]?.try(&.to_i?)
        frame = 0
        running = true
        event = LibSDL::Event.new

        while running
          break if max_frames && frame >= max_frames

          # Dispatch des événements : fermeture, molette, texte (routés vers Input).
          input = a.world.resource?(Input)
          input.try &.clear_frame_events
          while LibSDL.poll_event(pointerof(event))
            case event.type
            when LibSDL::EVENT_QUIT
              running = false
            when LibSDL::EVENT_MOUSE_WHEEL
              if inp = input
                we = pointerof(event).as(Pointer(LibSDL::MouseWheelEvent)).value
                inp.push_wheel(we.x, we.y)
              end
            when LibSDL::EVENT_TEXT_INPUT
              if inp = input
                te = pointerof(event).as(Pointer(LibSDL::TextInputEvent)).value
                inp.push_text(String.new(te.text)) unless te.text.null?
              end
            end
          end

          # Redimensionnement : reconfigure la surface si la taille a changé.
          LibSDL.get_window_size_in_pixels(gpu.window, out w, out h)
          if w.to_u32 != gpu.width || h.to_u32 != gpu.height
            gpu.reconfigure(w.to_u32, h.to_u32)
          end

          a.update
          LibWGPU.instance_process_events(gpu.instance) # flush les callbacks d'erreur wgpu
          frame += 1
        end

        # La libération (wgpu + SDL) est faite par App#run -> World#shutdown ->
        # GpuContext#release (ordre garanti : renderer avant device).
        puts "[Flock] fenêtre fermée (#{frame} frames)"
      end
    end
  end
end
