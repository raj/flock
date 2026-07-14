module Flock
  # Un plugin configure l'App : enregistre des systèmes, insère des ressources,
  # installe un runner… C'est l'unité de composition du moteur (Window, Render,
  # Input, Audio sont des plugins).
  abstract class Plugin
    abstract def build(app : App)
  end
end
