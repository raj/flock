module Flock
  # Logical input actions decoupled from physical keys (leafwing / Bevy `InputMap` style).
  # Bind an action enum `A` to one or more `Flock::Key`s (or an axis = a negative/positive key
  # pair), call `update(input)` once per frame with the backend's `Flock::Input`, then query
  # by action — so game code says `map.just_pressed?(Action::Fire)` instead of hard-coding a key.
  #
  # Portable: `update` is duck-typed (needs only `input.pressed?(Flock::Key) : Bool`, which both
  # the native and web `Flock::Input` provide), and press/release EDGES are derived here from the
  # previous frame — so the same map + query code runs on native and web.
  #
  #   enum Act; Left; Right; Fire; Move; end
  #   map = Flock::InputMap(Act).new
  #   map.bind(Act::Fire, Flock::Key::Space)
  #   map.bind_axis(Act::Move, Flock::Key::Left, Flock::Key::Right)
  #   # each frame: map.update(world.resource(Flock::Input))
  #   map.just_pressed?(Act::Fire)   # edge
  #   map.axis(Act::Move)            # -1 / 0 / +1
  class InputMap(A) < Resource
    @keys = {} of A => Array(Flock::Key)
    @axes = {} of A => Tuple(Flock::Key, Flock::Key) # {negative, positive}
    @pressed = Set(A).new
    @prev = Set(A).new
    @just_pressed = Set(A).new
    @just_released = Set(A).new
    @values = {} of A => Float32

    # Binds one or more keys to an action (any of them pressed ⇒ the action is active).
    def bind(action : A, *keys : Flock::Key) : self
      list = (@keys[action] ||= [] of Flock::Key)
      keys.each { |k| list << k }
      self
    end

    # Binds a 1-D axis: `negative` drives `axis(action)` to -1, `positive` to +1 (0 if neither
    # or both). The action also counts as "pressed" whenever the axis is non-zero.
    def bind_axis(action : A, negative : Flock::Key, positive : Flock::Key) : self
      @axes[action] = {negative, positive}
      self
    end

    # Recomputes the action state from `input` (needs `input.pressed?(Flock::Key) : Bool`).
    # Call once per frame BEFORE querying. Press/release edges are derived vs the last update.
    def update(input) : Nil
      cur = Set(A).new
      @keys.each do |action, keys|
        cur << action if keys.any? { |k| input.pressed?(k) }
      end
      @axes.each do |action, pair|
        neg = input.pressed?(pair[0]) ? 1.0f32 : 0.0f32
        pos = input.pressed?(pair[1]) ? 1.0f32 : 0.0f32
        v = pos - neg
        @values[action] = v
        cur << action if v != 0.0f32
      end
      @just_pressed = cur - @prev
      @just_released = @prev - cur
      @prev = cur
      @pressed = cur
    end

    def pressed?(action : A) : Bool
      @pressed.includes?(action)
    end

    def just_pressed?(action : A) : Bool
      @just_pressed.includes?(action)
    end

    def just_released?(action : A) : Bool
      @just_released.includes?(action)
    end

    # Axis value in [-1, 1] (0 for an unbound action or a key-only action).
    def axis(action : A) : Float32
      @values[action]? || 0.0f32
    end

    # Removes all bindings + state (e.g. to rebind at runtime).
    def clear : Nil
      @keys.clear
      @axes.clear
      @pressed.clear
      @prev.clear
      @just_pressed.clear
      @just_released.clear
      @values.clear
    end
  end
end
