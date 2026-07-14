module Flock
  # Point d'entrée du moteur : détient le World, les systèmes rangés par Schedule,
  # les plugins et le runner (la boucle principale).
  #
  #   Flock::App.new
  #     .add_plugin(MyPlugin.new)
  #     .add_startup { |world, cmd| ... }
  #     .add_system(Flock::Schedule::Update) { |world, cmd| ... }
  #     .run
  #
  # Un système est un `Proc(World, Commands, Nil)` : il lit/mute le World et met des
  # mutations structurelles en file via `cmd` (appliquées en fin de schedule).
  class App
    alias System = Proc(World, Commands, Nil)

    MAX_FIXED_STEPS = 8 # borne anti « spirale de la mort » si une frame est très lente

    getter world : World
    getter fixed_dt : Float64 = 1.0 / 60.0

    @systems : Hash(Schedule, Array(System)) = {} of Schedule => Array(System)
    @runner : Proc(App, Nil)? = nil
    @accumulator : Float64 = 0.0

    def initialize
      @world = World.new
      Schedule.values.each { |s| @systems[s] = [] of System }
      @world.insert_resource(Time.new)
      time.fixed_delta = @fixed_dt
    end

    # Pas de temps fixe (secondes) des systèmes FixedUpdate.
    def fixed_dt=(seconds : Float64) : Nil
      @fixed_dt = seconds
      time.fixed_delta = seconds
    end

    # Sucre : règle le pas fixe par fréquence (ex. `fixed_hz(50)`).
    def fixed_hz(hz : Number) : self
      self.fixed_dt = 1.0 / hz.to_f
      self
    end

    def time : Time
      @world.resource(Time)
    end

    # --- Configuration -----------------------------------------------------

    def add_plugin(plugin : Plugin) : self
      plugin.build(self)
      self
    end

    def add_plugins(*plugins : Plugin) : self
      plugins.each { |p| add_plugin(p) }
      self
    end

    def add_system(schedule : Schedule, &block : World, Commands ->) : self
      @systems[schedule] << block
      self
    end

    def add_startup(&block : World, Commands ->) : self
      @systems[Schedule::Startup] << block
      self
    end

    def add_fixed_system(&block : World, Commands ->) : self
      @systems[Schedule::FixedUpdate] << block
      self
    end

    # Installé par WindowPlugin pour piloter la boucle via les événements SDL.
    def runner(&block : App ->) : Nil
      @runner = block
    end

    # --- Exécution ---------------------------------------------------------

    # Lance tous les systèmes d'un schedule puis applique les commandes en file.
    def run_schedule(schedule : Schedule) : Nil
      cmd = Commands.new(@world)
      @systems[schedule].each &.call(@world, cmd)
      cmd.apply
    end

    def startup : Nil
      run_schedule(Schedule::Startup)
    end

    # Une frame : First -> (FixedUpdate × N) -> Update -> Render -> Last.
    def update : Nil
      time.tick
      run_schedule(Schedule::First)
      advance_fixed(time.delta)
      run_schedule(Schedule::Update)
      run_schedule(Schedule::Render)
      run_schedule(Schedule::Last)
    end

    # Accumule `dt` et exécute FixedUpdate autant de fois que le pas fixe y tient
    # (borné par MAX_FIXED_STEPS). Retourne le nombre de pas exécutés. Testable en
    # isolation avec un `dt` déterministe.
    def advance_fixed(dt : Float64) : Int32
      @accumulator += dt
      steps = 0
      while @accumulator >= @fixed_dt
        run_schedule(Schedule::FixedUpdate)
        @accumulator -= @fixed_dt
        steps += 1
        if steps >= MAX_FIXED_STEPS
          @accumulator = 0.0 # abandonne le retard accumulé (anti-spirale)
          break
        end
      end
      steps
    end

    # Démarre le moteur : startup puis boucle du runner installé.
    def run : Nil
      startup
      if runner = @runner
        runner.call(self)
      else
        raise "Aucun runner installé : ajoute WindowPlugin (boucle SDL) ou utilise run_headless."
      end
      @world.shutdown # libère les ressources GPU/SDL à la fermeture
    end

    # Boucle finie et déterministe, sans fenêtre — pour tests et exécution headless.
    def run_headless(ticks : Int32) : Nil
      startup
      ticks.times { update }
    end
  end
end
