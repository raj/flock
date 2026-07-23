module Flock
  # Bundles the standard plugins: window + rendering + input + audio (SFX) + music.
  # One-line startup: `app.add_plugin(Flock::DefaultPlugins.new)`.
  class DefaultPlugins < Plugin
    def initialize(@title : String = "Flock", @width : Int32 = 800, @height : Int32 = 600)
    end

    def build(app : App) : Nil
      app.add_plugin(WindowPlugin.new(@title, @width, @height))
      app.add_plugin(RenderPlugin.new)
      app.add_plugin(InputPlugin.new)
      app.add_plugin(AudioPlugin.new)
      app.add_plugin(MusicPlugin.new)
      app.add_plugin(AssetsPlugin.new)
      app.add_plugin(TextPlugin.new)
    end
  end
end
