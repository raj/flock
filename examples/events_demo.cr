# Demo: mouse wheel + text input (interactive). Scroll and typing are printed.
require "../src/flock/gpu"

def setup(world : Flock::World, cmd : Flock::Commands)
  cmd.spawn(Flock::Camera2D.new(clear_color: Flock::Color.new(0.1,0.1,0.12)))
end

def report_events(world : Flock::World, cmd : Flock::Commands)
  input = world.resource(Flock::Input)
  w = input.mouse_wheel
  puts "wheel: #{w.x}, #{w.y}" if w.x != 0 || w.y != 0
  puts "text: #{input.text_input}" unless input.text_input.empty?
end

app = Flock::App.new
app.add_plugin(Flock::DefaultPlugins.new("Flock — events", 640, 480))
app.add_startup(&->setup(Flock::World, Flock::Commands))
app.add_system(Flock::Schedule::Update, &->report_events(Flock::World, Flock::Commands))
app.run
