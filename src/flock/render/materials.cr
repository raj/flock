module Flock
  # Portable custom-material registry: `world.resource(Flock::Materials)` gives ids for
  # `Sprite2D#material`, from either a built-in shader name or a backend-neutral shader
  # "core" (a snippet setting `rgb`/`a` — see SpriteShaders). Same API + class name as the
  # web backend's Flock::Materials, so game code is identical. Cached.
  #
  #   mat = world.resource(Flock::Materials)
  #   glow = mat.builtin(:glow)
  #   mine = mat.register(MY_WGSL_CORE, MY_GLSL_CORE)   # glsl core ignored natively
  class Materials < Resource
    @builtins = {} of Symbol => Int32
    @customs = {} of String => Int32

    def initialize(@renderer : Renderer2D)
    end

    def builtin(name : Symbol) : Int32
      @builtins[name] ||= @renderer.register_builtin(name)
    end

    # `wgsl_core` sets `rgb`/`a`; wrapped into a full native module. `glsl_core` is for the
    # web backend (WebGL2) and ignored here.
    def register(wgsl_core : String, glsl_core : String) : Int32
      @customs[wgsl_core] ||= @renderer.register_material(SpriteShaders.native(wgsl_core))
    end
  end

  # Inserts Materials once Renderer2D exists.
  class MaterialsPlugin < Plugin
    def build(app : App) : Nil
      app.add_startup { |world, _cmd| world.insert_resource(Materials.new(world.resource(Renderer2D))) }
    end
  end
end
