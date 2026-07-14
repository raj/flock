# Démo : molette + saisie de texte (interactif). Scroll et frappe s'affichent.
require "../src/flock/gpu"
app = Flock::App.new
app.add_plugin(Flock::DefaultPlugins.new("Flock — events", 640, 480))
app.add_startup { |_w, cmd| cmd.spawn(Flock::Camera2D.new(clear_color: Flock::Color.new(0.1,0.1,0.12))) }
app.add_system(Flock::Schedule::Update) do |world, _|
  input = world.resource(Flock::Input)
  w = input.mouse_wheel
  puts "molette: #{w.x}, #{w.y}" if w.x != 0 || w.y != 0
  puts "texte: #{input.text_input}" unless input.text_input.empty?
end
app.run
