module Flock
  # Creates the SDL3 window + the wgpu surface (dispatched per platform: Metal on
  # macOS, X11/Wayland on Linux, HWND on Windows — via `make_surface`), inserts the
  # GpuContext resource, and installs the runner: the main loop (SDL events + one
  # frame per turn). `WGPU_FRAMES=N` quits after N frames (headless test).
  class WindowPlugin < Plugin
    def initialize(@title : String = "Flock", @width : Int32 = 800, @height : Int32 = 600)
    end

    def build(app : App) : Nil
      unless LibSDL.init(LibSDL::INIT_VIDEO | LibSDL::INIT_GAMEPAD | LibSDL::INIT_AUDIO)
        raise "SDL_Init: #{String.new(LibSDL.get_error)}"
      end

      flags = LibSDL::WINDOW_RESIZABLE | LibSDL::WINDOW_HIGH_PIXEL_DENSITY
      {% if flag?(:darwin) %}
        flags |= LibSDL::WINDOW_METAL # Metal view (macOS)
      {% end %}
      window = LibSDL.create_window(@title.to_unsafe, @width, @height, flags)
      raise "SDL_CreateWindow: #{String.new(LibSDL.get_error)}" if window.null?

      instance = WGPU.create_instance
      surface, view = make_surface(instance, window)

      adapter = WGPU.request_adapter(instance, compatible_surface: surface)
      device = Flock.request_device(instance, adapter) # device + wgpu error callbacks
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

    # Creates the wgpu surface per platform, via the native handles exposed by SDL
    # (`SDL_GetWindowProperties`). Returns {surface, MetalView} (the view exists only
    # on macOS; null elsewhere). The non-macOS branches are written but have not
    # been tested at runtime on this machine.
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
        {% raise "Flock: surface creation not supported on this platform" %}
      {% end %}
    end

    private def create_surface_from(instance : LibWGPU::Instance, source : Pointer(Void)) : LibWGPU::Surface
      sdesc = LibWGPU::SurfaceDescriptor.new
      sdesc.label = WGPU.empty_string_view
      sdesc.next_in_chain = source.as(Pointer(LibWGPU::ChainedStruct))
      surface = LibWGPU.instance_create_surface(instance, pointerof(sdesc))
      raise "instance_create_surface failed" if surface.null?
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

          # Event dispatch: close, wheel, text (routed to Input).
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

          # Resize: reconfigure the surface if the size changed.
          LibSDL.get_window_size_in_pixels(gpu.window, out w, out h)
          if w.to_u32 != gpu.width || h.to_u32 != gpu.height
            gpu.reconfigure(w.to_u32, h.to_u32)
          end

          a.update
          LibWGPU.instance_process_events(gpu.instance) # flush the wgpu error callbacks
          frame += 1
        end

        # The release (wgpu + SDL) is done by App#run -> World#shutdown ->
        # GpuContext#release (guaranteed order: renderer before device).
        puts "[Flock] window closed (#{frame} frames)"
      end
    end
  end
end
