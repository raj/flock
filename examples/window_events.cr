# Demo: window events (focus / minimize / maximize / resize) via WindowState.
# Interactive: alt-tab, minimize, or drag the window edge and watch the printout.
#
#   crystal run examples/window_events.cr
require "../src/flock/gpu"

# Track transitions so we only print on change (state is level, not edge).
class WinTransitions < Flock::Resource
  property was_focused : Bool
  property was_minimized : Bool

  def initialize(@was_focused : Bool = true, @was_minimized : Bool = false)
  end
end

def setup(world : Flock::World, cmd : Flock::Commands)
  world.insert_resource(WinTransitions.new)
  cmd.spawn(Flock::Camera2D.new(clear_color: Flock::Color.new(0.1, 0.1, 0.12)))
end

def report_window_events(world : Flock::World, cmd : Flock::Commands)
  state = world.resource(WinTransitions)
  win = world.resource(Flock::WindowState)
  if win.focused? != state.was_focused
    puts win.focused? ? "focus gained" : "focus lost"
    state.was_focused = win.focused?
  end
  if win.minimized? != state.was_minimized
    puts win.minimized? ? "minimized" : "restored"
    state.was_minimized = win.minimized?
  end
  if win.resized?
    gpu = world.resource(Flock::GpuContext)
    puts "resized -> #{gpu.width}x#{gpu.height} px"
  end
end

app = Flock::App.new
app.add_plugin(Flock::DefaultPlugins.new("Flock — window events", 640, 480))
app.add_startup(&->setup(Flock::World, Flock::Commands))
app.add_system(Flock::Schedule::Update, &->report_window_events(Flock::World, Flock::Commands))
app.run
