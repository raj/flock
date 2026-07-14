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

    getter world : World

    @systems : Hash(Schedule, Array(System)) = {} of Schedule => Array(System)
    @runner : Proc(App, Nil)? = nil

    def initialize
      @world = World.new
      Schedule.values.each { |s| @systems[s] = [] of System }
      @world.insert_resource(Time.new)
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

    # Une frame : First -> Update -> Render -> Last.
    def update : Nil
      time.tick
      run_schedule(Schedule::First)
      run_schedule(Schedule::Update)
      run_schedule(Schedule::Render)
      run_schedule(Schedule::Last)
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
