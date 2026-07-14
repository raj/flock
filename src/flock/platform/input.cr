module Flock
  # Touches clavier (valeur = scancode SDL). Étendre au besoin.
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

  # Boutons de manette (valeurs = SDL_GamepadButton).
  enum Button : Int32
    South     =  0 # A / croix
    East      =  1 # B / rond
    West      =  2 # X / carré
    North     =  3 # Y / triangle
    Back      =  4
    Guide     =  5
    Start     =  6
    DpadUp    =  7
    DpadDown  =  8
    DpadLeft  =  9
    DpadRight = 10
  end

  # Axes analogiques (valeurs = SDL_GamepadAxis).
  enum Axis : Int32
    LeftX        = 0
    LeftY        = 1
    RightX       = 2
    RightY       = 3
    LeftTrigger  = 4
    RightTrigger = 5
  end

  # Une manette ouverte. Axes normalisés dans [-1, 1] avec zone morte.
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
  end

  # Ressource d'entrées : état clavier (avec just_pressed/just_released) + manettes.
  # Rafraîchie chaque frame par InputPlugin (schedule First), en polling.
  class Input < Resource
    KEY_COUNT = 512

    @current : Array(Bool) = Array(Bool).new(KEY_COUNT, false)
    @previous : Array(Bool) = Array(Bool).new(KEY_COUNT, false)
    @gamepads : Array(Gamepad) = [] of Gamepad
    @open : Hash(LibSDL::JoystickID, LibSDL::Gamepad) = {} of LibSDL::JoystickID => LibSDL::Gamepad

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

    # Appelé une fois par frame (avant la logique de jeu).
    def refresh : Nil
      # Clavier : previous <- current, current <- état SDL.
      numkeys = 0
      ptr = LibSDL.get_keyboard_state(pointerof(numkeys))
      n = Math.min(numkeys, KEY_COUNT)
      KEY_COUNT.times { |i| @previous[i] = @current[i] }
      n.times { |i| @current[i] = ptr[i] }

      refresh_gamepads
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
      # Ferme les manettes déconnectées.
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

  # Insère la ressource Input et la rafraîchit chaque frame (schedule First).
  class InputPlugin < Plugin
    def build(app : App) : Nil
      app.world.insert_resource(Input.new)
      app.add_system(Schedule::First) do |world, _cmd|
        world.resource(Input).refresh
      end
    end
  end
end
