module Flock
  # Horloge de la boucle de jeu (ressource). `delta` = durée de la frame précédente,
  # `elapsed` = temps écoulé depuis le démarrage, en secondes. Sert au mouvement
  # indépendant du framerate. Basée sur l'horloge monotone stdlib (pas de dépendance
  # native).
  class Time < Resource
    getter delta : Float64 = 0.0
    getter elapsed : Float64 = 0.0
    # Pas de temps fixe (constant), à utiliser dans les systèmes FixedUpdate.
    property fixed_delta : Float64 = 1.0 / 60.0

    @last : ::Time::Instant
    @start : ::Time::Instant

    def initialize
      now = ::Time.instant
      @last = now
      @start = now
    end

    # Met à jour delta/elapsed. Appelé une fois par frame par l'App.
    def tick : Nil
      now = ::Time.instant
      @delta = (now - @last).total_seconds
      @elapsed = (now - @start).total_seconds
      @last = now
    end
  end
end
