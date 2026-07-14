# Demo: window events (focus / minimize / maximize / resize) via WindowState.
# Interactive: alt-tab, minimize, or drag the window edge and watch the printout.
#
#   crystal run examples/window_events.cr
require "../src/flock/gpu"

app = Flock::App.new
app.add_plugin(Flock::DefaultPlugins.new("Flock — window events", 640, 480))
app.add_startup { |_w, cmd| cmd.spawn(Flock::Camera2D.new(clear_color: Flock::Color.new(0.1, 0.1, 0.12))) }

# Track transitions so we only print on change (state is level, not edge).
was_focused = true
was_minimized = false
app.add_system(Flock::Schedule::Update) do |world, _|
  win = world.resource(Flock::WindowState)
  if win.focused? != was_focused
    puts win.focused? ? "focus gained" : "focus lost"
    was_focused = win.focused?
  end
  if win.minimized? != was_minimized
    puts win.minimized? ? "minimized" : "restored"
    was_minimized = win.minimized?
  end
  if win.resized?
    gpu = world.resource(Flock::GpuContext)
    puts "resized -> #{gpu.width}x#{gpu.height} px"
  end
end
app.run
