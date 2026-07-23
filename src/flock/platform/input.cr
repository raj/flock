module Flock
  # `Key` now lives in core (src/flock/keys.cr) so it's shared with the web backend.

  # Gamepad buttons (values = SDL_GamepadButton). NOTE the SDL3 ordering: the stick and
  # shoulder buttons occupy 7..10, so the D-pad starts at 11 (this used to be wrong).
  enum Button : Int32
    South         =  0 # A / cross
    East          =  1 # B / circle
    West          =  2 # X / square
    North         =  3 # Y / triangle
    Back          =  4
    Guide         =  5
    Start         =  6
    LeftStick     =  7
    RightStick    =  8
    LeftShoulder  =  9
    RightShoulder = 10
    DpadUp        = 11
    DpadDown      = 12
    DpadLeft      = 13
    DpadRight     = 14
    Misc1         = 15
  end

  # Mouse buttons (SDL index). `mask` = bit in the SDL_GetMouseState mask.
  enum MouseButton : Int32
    Left   = 1
    Middle = 2
    Right  = 3

    def mask : UInt32
      1_u32 << (value - 1)
    end
  end

  # Analog axes (values = SDL_GamepadAxis).
  enum Axis : Int32
    LeftX        = 0
    LeftY        = 1
    RightX       = 2
    RightY       = 3
    LeftTrigger  = 4
    RightTrigger = 5
  end

  # An open gamepad. Axes normalized to [-1, 1] with a dead zone.
  struct Gamepad
    getter id : LibSDL::JoystickID

    def initialize(@handle : LibSDL::Gamepad, @id : LibSDL::JoystickID, @deadzone : Float32 = 0.15f32)
    end

    def pressed?(button : Button) : Bool
      LibSDL.get_gamepad_button(@handle, LibSDL::GamepadButton.new(button.value))
    end

    def axis(axis : Axis) : Float32
      raw = LibSDL.get_gamepad_axis(@handle, LibSDL::GamepadAxis.new(axis.value))
      v = raw.to_f32 / 32767.0f32
      v = v.clamp(-1.0f32, 1.0f32)
      v.abs < @deadzone ? 0.0f32 : v
    end

    # Vibrates the gamepad for `ms` milliseconds. `low`/`high` (0..1) are the
    # low-/high-frequency motor intensities.
    def rumble(low : Number = 1.0, high : Number = 1.0, ms : Int = 300) : Bool
      lo = (low.clamp(0.0, 1.0) * 0xFFFF).to_u16
      hi = (high.clamp(0.0, 1.0) * 0xFFFF).to_u16
      LibSDL.rumble_gamepad(@handle, lo, hi, ms.to_u32)
    end
  end

  # Input resource: keyboard state (with just_pressed/just_released) + gamepads.
  # Refreshed each frame by InputPlugin (schedule First), by polling.
  class Input < Resource
    KEY_COUNT = 512

    @current : Array(Bool) = Array(Bool).new(KEY_COUNT, false)
    @previous : Array(Bool) = Array(Bool).new(KEY_COUNT, false)
    @gamepads : Array(Gamepad) = [] of Gamepad
    @open : Hash(LibSDL::JoystickID, LibSDL::Gamepad) = {} of LibSDL::JoystickID => LibSDL::Gamepad

    # Mouse: position in framebuffer pixels (render space, top-left origin),
    # + button masks (current / previous frame for just_pressed/released).
    @mouse_position : Vec2 = Vec2.new
    @mouse_current : UInt32 = 0_u32
    @mouse_previous : UInt32 = 0_u32
    @window : LibSDL::Window = Pointer(Void).null.as(LibSDL::Window)

    # Event-driven (fed by the runner from SDL events, reset to zero at the start
    # of each frame): wheel, typed text, and relative mouse motion.
    @wheel : Vec2 = Vec2.new
    @text : String = ""
    @mouse_delta : Vec2 = Vec2.new # accumulated raw (window-point) motion this frame
    @hidpi_scale : Vec2 = Vec2.new(1.0f32, 1.0f32)

    def pressed?(key : Key) : Bool
      @current[key.value]
    end

    def just_pressed?(key : Key) : Bool
      @current[key.value] && !@previous[key.value]
    end

    def just_released?(key : Key) : Bool
      !@current[key.value] && @previous[key.value]
    end

    def gamepad?(index : Int32 = 0) : Gamepad?
      @gamepads[index]?
    end

    def gamepad_count : Int32
      @gamepads.size
    end

    # --- Mouse ---

    # Position in framebuffer pixels (same space as rendering). For world coordinates,
    # pass to `Camera2D#screen_to_world(mouse_position, gpu.width, gpu.height)`.
    def mouse_position : Vec2
      @mouse_position
    end

    def mouse_pressed?(button : MouseButton) : Bool
      (@mouse_current & button.mask) != 0
    end

    def mouse_just_pressed?(button : MouseButton) : Bool
      (@mouse_current & button.mask) != 0 && (@mouse_previous & button.mask) == 0
    end

    def mouse_just_released?(button : MouseButton) : Bool
      (@mouse_current & button.mask) == 0 && (@mouse_previous & button.mask) != 0
    end

    # Wheel scroll accumulated over the frame (x = horizontal, y = vertical).
    def mouse_wheel : Vec2
      @wheel
    end

    # Relative mouse motion accumulated over the frame, in framebuffer pixels (same space as
    # `mouse_position`). Event-driven, so it works even when the cursor is grabbed by relative
    # mouse mode (where `mouse_position` stops moving) — use it for look/aim.
    def mouse_delta : Vec2
      Vec2.new(@mouse_delta.x * @hidpi_scale.x, @mouse_delta.y * @hidpi_scale.y)
    end

    # Relative mouse mode hides and grabs the cursor and delivers motion as deltas only
    # (`mouse_delta`); ideal for FPS-style camera control.
    def relative_mouse_mode=(enabled : Bool) : Nil
      LibSDL.set_window_relative_mouse_mode(@window, enabled) unless @window.null?
    end

    def relative_mouse_mode? : Bool
      !@window.null? && LibSDL.get_window_relative_mouse_mode(@window)
    end

    def show_cursor : Nil
      LibSDL.show_cursor
    end

    def hide_cursor : Nil
      LibSDL.hide_cursor
    end

    def cursor_visible? : Bool
      LibSDL.cursor_visible
    end

    # Warps the cursor to (x, y) in window points.
    def warp_mouse(x : Number, y : Number) : Nil
      LibSDL.warp_mouse_in_window(@window, x.to_f32, y.to_f32) unless @window.null?
    end

    # Text typed during the frame (UTF-8). Requires `start_text_input`.
    def text_input : String
      @text
    end

    # Enables/disables reception of text events for the window.
    def start_text_input : Nil
      LibSDL.start_text_input(@window) unless @window.null?
    end

    def stop_text_input : Nil
      LibSDL.stop_text_input(@window) unless @window.null?
    end

    # --- Called by the runner (WindowPlugin) ---

    def clear_frame_events : Nil
      @wheel = Vec2.new
      @text = ""
      @mouse_delta = Vec2.new
    end

    def push_wheel(x : Float32, y : Float32) : Nil
      @wheel = Vec2.new(@wheel.x + x, @wheel.y + y)
    end

    def push_text(str : String) : Nil
      @text += str
    end

    # Accumulates a MOUSE_MOTION delta (raw window points; scaled to pixels on read).
    def push_mouse_delta(x : Float32, y : Float32) : Nil
      @mouse_delta = Vec2.new(@mouse_delta.x + x, @mouse_delta.y + y)
    end

    # --- Gamepad hotplug (driven by GAMEPAD_ADDED/REMOVED events) ---

    # Opens every gamepad already connected (called once at startup; hotplug afterwards is
    # handled by the ADDED/REMOVED events routed here from the runner).
    def open_connected_gamepads : Nil
      count = 0
      ids = LibSDL.get_gamepads(pointerof(count))
      count.times { |i| on_gamepad_added(ids[i]) }
      LibSDL.sdl_free(ids.as(Void*)) unless ids.null?
    end

    def on_gamepad_added(id : LibSDL::JoystickID) : Nil
      return if @open.has_key?(id)
      handle = LibSDL.open_gamepad(id)
      return if handle.null?
      @open[id] = handle
      rebuild_gamepads
    end

    def on_gamepad_removed(id : LibSDL::JoystickID) : Nil
      if handle = @open.delete(id)
        LibSDL.close_gamepad(handle)
        rebuild_gamepads
      end
    end

    private def rebuild_gamepads : Nil
      @gamepads = @open.map { |id, handle| Gamepad.new(handle, id) }
    end

    # Set by InputPlugin: allows converting window points to framebuffer pixels
    # (HiDPI).
    def attach_window(window : LibSDL::Window) : Nil
      @window = window
    end

    # Called once per frame (before the game logic).
    def refresh : Nil
      # Keyboard: previous <- current, current <- SDL state.
      numkeys = 0
      ptr = LibSDL.get_keyboard_state(pointerof(numkeys))
      n = Math.min(numkeys, KEY_COUNT)
      KEY_COUNT.times { |i| @previous[i] = @current[i] }
      n.times { |i| @current[i] = ptr[i] }
      # Defensively clear the tail SDL didn't report (numkeys < KEY_COUNT), so no
      # stale key state lingers past the range the backend actually filled.
      (n...KEY_COUNT).each { |i| @current[i] = false }

      refresh_mouse
      # Gamepads are managed by hotplug events (on_gamepad_added/removed), not polled here;
      # per-button/axis state is read live through the Gamepad struct.
    end

    private def refresh_mouse : Nil
      @mouse_previous = @mouse_current
      @mouse_current = LibSDL.get_mouse_state(out mx, out my)
      if @window.null?
        @hidpi_scale = Vec2.new(1.0f32, 1.0f32)
        @mouse_position = Vec2.new(mx, my)
      else
        # SDL returns window points; we convert to framebuffer pixels (HiDPI). The same
        # scale is applied to the relative motion deltas so `mouse_delta` is in pixels too.
        LibSDL.get_window_size(@window, out pw, out ph)
        LibSDL.get_window_size_in_pixels(@window, out fw, out fh)
        sx = pw > 0 ? fw.to_f32 / pw.to_f32 : 1.0f32
        sy = ph > 0 ? fh.to_f32 / ph.to_f32 : 1.0f32
        @hidpi_scale = Vec2.new(sx, sy)
        @mouse_position = Vec2.new(mx * sx, my * sy)
      end
    end
  end

  # Inserts the Input resource and refreshes it each frame (schedule First).
  class InputPlugin < Plugin
    def build(app : App) : Nil
      input = Input.new
      # Attaches the window (published by WindowPlugin) for HiDPI conversion.
      if gpu = app.world.resource?(GpuContext)
        input.attach_window(gpu.window)
        input.start_text_input # enable reception of text events
      end
      input.open_connected_gamepads # hotplug afterwards is event-driven
      app.world.insert_resource(input)
      app.add_system(Schedule::First) do |world, _cmd|
        world.resource(Input).refresh
      end
    end
  end
end
