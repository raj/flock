module Flock
  # Regroupe les plugins standard : fenêtre + rendu + entrées + audio. Démarrage en
  # une ligne : `app.add_plugin(Flock::DefaultPlugins.new)`.
  class DefaultPlugins < Plugin
    def initialize(@title : String = "Flock", @width : Int32 = 800, @height : Int32 = 600)
    end

    def build(app : App) : Nil
      app.add_plugin(WindowPlugin.new(@title, @width, @height))
      app.add_plugin(RenderPlugin.new)
      app.add_plugin(InputPlugin.new)
      app.add_plugin(AudioPlugin.new)
    end
  end
end
