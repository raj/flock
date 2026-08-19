module Flock
  # A secondary OS window: its own SDL window + wgpu surface, sharing the primary
  # `GpuContext`'s device/queue/instance/adapter (one device, N swapchains — how real engines
  # do multi-window). Cameras bind to it via `Camera2D#window`/`Camera3D#window` == its `slot`
  # (the primary window is slot 0). Created through `Flock::Windows#open`.
  class Window
    getter sdl : LibSDL::Window
    getter id : UInt32 # SDL window id (for event routing)
    getter surface : LibWGPU::Surface
    getter format : LibWGPU::TextureFormat
    getter slot : Int32 # camera-binding id (>= 1)
    property width : UInt32
    property height : UInt32
    @view : LibSDL::MetalView
    @cur_view : LibWGPU::TextureView?
    @cur_tex : LibWGPU::Texture?

    def initialize(@gpu : GpuContext, @sdl : LibSDL::Window, @id : UInt32,
                   @surface : LibWGPU::Surface, @view : LibSDL::MetalView,
                   @format : LibWGPU::TextureFormat, @width : UInt32, @height : UInt32, @slot : Int32)
    end

    # Opens a new OS window + surface sharing `gpu`'s device.
    def self.open(gpu : GpuContext, title : String, w : Int32, h : Int32, slot : Int32) : Window
      flags = LibSDL::WINDOW_RESIZABLE | LibSDL::WINDOW_HIGH_PIXEL_DENSITY
      {% if flag?(:darwin) %}
        flags |= LibSDL::WINDOW_METAL
      {% end %}
      sdl = LibSDL.create_window(title.to_unsafe, w, h, flags)
      raise "SDL_CreateWindow (secondary): #{String.new(LibSDL.get_error)}" if sdl.null?
      surface, view = Flock.make_window_surface(gpu.instance, sdl)
      caps = LibWGPU::SurfaceCapabilities.new
      st = LibWGPU.surface_get_capabilities(surface, gpu.adapter, pointerof(caps))
      raise "surface_get_capabilities failed (status #{st})" if st != LibWGPU::Status::Success || caps.format_count == 0
      # Match the primary window's format when offered (shared pipelines), else take the first.
      format = (0...caps.format_count).any? { |i| caps.formats[i] == gpu.format } ? gpu.format : caps.formats[0]
      LibWGPU.surface_capabilities_free_members(caps)
      LibSDL.get_window_size_in_pixels(sdl, out fw, out fh)
      win = new(gpu, sdl, LibSDL.get_window_id(sdl), surface, view, format, fw.to_u32, fh.to_u32, slot)
      win.configure(fw.to_u32, fh.to_u32)
      win
    end

    def configure(w : UInt32, h : UInt32) : Nil
      return if w == 0 || h == 0
      cfg = LibWGPU::SurfaceConfiguration.new
      cfg.device = @gpu.device
      cfg.format = @format
      cfg.usage = LibWGPU::TextureUsage::RenderAttachment
      cfg.width = w
      cfg.height = h
      cfg.present_mode = LibWGPU::PresentMode::Fifo
      cfg.alpha_mode = LibWGPU::CompositeAlphaMode::Auto
      LibWGPU.surface_configure(@surface, pointerof(cfg))
      @width = w
      @height = h
    end

    # Reconfigures to the current OS window size if it changed (call on resize).
    def reconfigure_to_window : Nil
      LibSDL.get_window_size_in_pixels(@sdl, out w, out h)
      configure(w.to_u32, h.to_u32) if w.to_u32 != @width || h.to_u32 != @height
    end

    # Acquires this frame's swapchain texture view (nil if the surface must be skipped this
    # frame). Pair with `present`. Reconfigures on outdated/lost.
    def acquire : LibWGPU::TextureView?
      st = LibWGPU::SurfaceTexture.new
      LibWGPU.surface_get_current_texture(@surface, pointerof(st))
      case st.status
      when .success_optimal?, .success_suboptimal?
        view = LibWGPU.texture_create_view(st.texture, Pointer(LibWGPU::TextureViewDescriptor).null)
        @cur_view = view
        @cur_tex = st.texture
        view
      when .outdated?, .lost?
        LibWGPU.texture_release(st.texture) unless st.texture.null?
        reconfigure_to_window
        nil
      else
        LibWGPU.texture_release(st.texture) unless st.texture.null?
        nil
      end
    end

    # Presents the acquired frame and releases its view/texture.
    def present : Nil
      LibWGPU.surface_present(@surface)
      if (v = @cur_view) && (t = @cur_tex)
        WGPU.release_surface(v, t)
      end
      @cur_view = nil
      @cur_tex = nil
    end

    def release : Nil
      LibWGPU.surface_release(@surface)
      LibSDL.metal_destroy_view(@view) unless @view.null?
      LibSDL.destroy_window(@sdl)
    end
  end

  # Registry of secondary windows (resource, inserted by `MultiWindowPlugin`). `open` creates a
  # window; cameras with `window == returned.slot` render into it. Windows are released before
  # the GpuContext (default release_order 0 < GpuContext's 100).
  class Windows < Resource
    getter list : Array(Window) = [] of Window

    def initialize(@gpu : GpuContext)
    end

    # Opens a secondary window and returns it (its `slot` is the camera-binding id).
    def open(title : String, w : Int32, h : Int32) : Window
      win = Window.open(@gpu, title, w, h, @list.size + 1)
      @list << win
      win
    end

    def by_sdl_id(id : UInt32) : Window?
      @list.find { |w| w.id == id }
    end

    def close(win : Window) : Nil
      @list.delete(win)
      win.release
    end

    def each(&) : Nil
      @list.each { |w| yield w }
    end

    def release : Nil
      @list.each &.release
      @list.clear
    end
  end

  # Enables multi-window: inserts the `Windows` registry and, each Render frame, draws every
  # secondary window (its bound cameras) and presents it. Add AFTER RenderPlugin. Open windows
  # from a startup/system via `world.resource(Flock::Windows).open("Title", w, h)`, then give
  # the cameras you want there `window: that_slot`.
  class MultiWindowPlugin < Plugin
    def build(app : App) : Nil
      app.add_startup do |world, _cmd|
        world.insert_resource(Windows.new(world.resource(GpuContext)))
      end
      app.add_system(Flock::Schedule::Render) do |world, _cmd|
        wins = world.resource?(Windows)
        r2 = world.resource?(Renderer2D)
        next unless wins && r2
        wins.each do |win|
          if v = win.acquire
            r2.render_into(v, win.width, win.height, world, window: win.slot)
            win.present
          end
        end
      end
    end
  end
end
