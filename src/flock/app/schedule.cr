module Flock
  # Étapes ordonnées de la boucle de jeu. Les systèmes sont rangés par schedule et
  # exécutés dans cet ordre à chaque frame (Startup une seule fois au démarrage).
  enum Schedule
    Startup # une fois, avant la boucle
    First   # début de frame (ex. collecte des entrées)
    Update  # logique de jeu
    Render  # rendu
    Last    # fin de frame (nettoyage)
  end
end
