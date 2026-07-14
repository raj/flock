module Flock
  # Keyboard keys (value = SDL scancode). Extend as needed.
  enum Key : Int32
    A      =  4
    D      =  7
    S      = 22
    W      = 26
    Escape = 41
    Space  = 44
    Right  = 79
    Left   = 80
    Down   = 81
    Up     = 82
  end

  # Gamepad buttons (values = SDL_GamepadButton).
  enum Button : Int32
    South     =  0 # A / cross
    East      =  1 # B / circle
    West      =  2 # X / square
    North     =  3 # Y / triangle
    Back      =  4
    Guide     =  5
    Start     =  6
    DpadUp    =  7
    DpadDown  =  8
    DpadLeft  =  9
    DpadRight = 10
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
    # of each frame): wheel + typed text.
    @wheel : Vec2 = Vec2.new
    @text : String = ""

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
    end

    def push_wheel(x : Float32, y : Float32) : Nil
      @wheel = Vec2.new(@wheel.x + x, @wheel.y + y)
    end

    def push_text(str : String) : Nil
      @text += str
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

      refresh_mouse
      refresh_gamepads
    end

    private def refresh_mouse : Nil
      @mouse_previous = @mouse_current
      @mouse_current = LibSDL.get_mouse_state(out mx, out my)
      if @window.null?
        @mouse_position = Vec2.new(mx, my)
      else
        # SDL returns window points; we convert to framebuffer pixels (HiDPI).
        LibSDL.get_window_size(@window, out pw, out ph)
        LibSDL.get_window_size_in_pixels(@window, out fw, out fh)
        sx = pw > 0 ? fw.to_f32 / pw.to_f32 : 1.0f32
        sy = ph > 0 ? fh.to_f32 / ph.to_f32 : 1.0f32
        @mouse_position = Vec2.new(mx * sx, my * sy)
      end
    end

    private def refresh_gamepads : Nil
      count = 0
      ids = LibSDL.get_gamepads(pointerof(count))
      present = {} of LibSDL::JoystickID => Bool
      count.times do |i|
        id = ids[i]
        present[id] = true
        unless @open.has_key?(id)
          handle = LibSDL.open_gamepad(id)
          @open[id] = handle unless handle.null?
        end
      end
      # Closes disconnected gamepads.
      @open.reject! do |id, handle|
        if present[id]?
          false
        else
          LibSDL.close_gamepad(handle)
          true
        end
      end
      LibSDL.sdl_free(ids.as(Void*)) unless ids.null?

      @gamepads = @open.map { |id, handle| Gamepad.new(handle, id) }
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
      app.world.insert_resource(input)
      app.add_system(Schedule::First) do |world, _cmd|
        world.resource(Input).refresh
      end
    end
  end
end
