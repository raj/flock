module Flock
  # A plugin configures the App: registers systems, inserts resources, installs
  # a runner… It's the engine's unit of composition (Window, Render, Input,
  # Audio are plugins).
  abstract class Plugin
    abstract def build(app : App)
  end
end
