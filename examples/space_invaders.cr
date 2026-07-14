# Space Invaders — démo assemblant ECS + caméra + entrées (clavier ET manette) +
# audio (bips procéduraux) + sprites (quads colorés).
#
#   crystal run examples/space_invaders.cr
#   WGPU_FRAMES=120 crystal run examples/space_invaders.cr   # smoke headless
#
# Contrôles : flèches / A-D ou stick gauche pour bouger, Espace / bouton A pour tirer.
require "../src/flock/gpu"

# --- Composants de jeu ---
struct Player
  include Flock::Component
  property speed : Float32
  property next_shot : Float64

  def initialize(@speed : Float32 = 350.0f32, @next_shot : Float64 = 0.0)
  end
end

struct Invader
  include Flock::Component
end

struct Bullet
  include Flock::Component
end

struct Velocity
  include Flock::Component
  property linear : Flock::Vec2

  def initialize(@linear : Flock::Vec2 = Flock::Vec2.new)
  end
end

# --- Ressources ---
class InvaderState < Flock::Resource
  property dir : Float32 = 1.0f32
  property speed : Float32 = 45.0f32
end

class Sfx < Flock::Resource
  getter shoot : Flock::Sound
  getter explosion : Flock::Sound

  def initialize
    @shoot = Flock::Sound.beep(660.0, 0.07, 0.18)
    @explosion = Flock::Sound.beep(110.0, 0.20, 0.30)
  end
end

app = Flock::App.new
app.add_plugin(Flock::DefaultPlugins.new("Flock — Space Invaders", 800, 600))

# --- Startup : caméra, joueur, grille d'invaders ---
app.add_startup do |world, cmd|
  world.insert_resource(InvaderState.new)
  world.insert_resource(Sfx.new)

  cmd.spawn(Flock::Camera2D.new(clear_color: Flock::Color.new(0.03, 0.03, 0.07)))

  # Titre (rendu de texte via SDL_ttf) ; police et texture gérées par l'asset manager.
  begin
    gpu = world.resource(Flock::GpuContext)
    assets = world.resource(Flock::Assets)
    font = assets.font("/System/Library/Fonts/Supplemental/Arial.ttf", 36)
    title = assets.store_texture("title", font.render_texture(gpu, "SPACE INVADERS"))
    cmd.spawn(
      Flock::Transform2D.at(0, 260),
      Flock::Sprite.new(Flock::Vec2.new(title.width, title.height), Flock::Color.new(0.6, 0.9, 1.0), title, z: 10.0f32))
  rescue ex
    puts "titre ignoré (police indisponible) : #{ex.message}"
  end

  cmd.spawn(
    Player.new(360.0f32),
    Flock::Transform2D.at(0, -250),
    Flock::Sprite.new(Flock::Vec2.new(60, 20), Flock::Color.new(0.3, 0.9, 0.45)),
  )

  8.times do |c|
    5.times do |r|
      cmd.spawn(
        Invader.new,
        Flock::Transform2D.at(-245.0 + c * 70.0, 220.0 - r * 46.0),
        Flock::Sprite.new(Flock::Vec2.new(40, 28), Flock::Color.new(0.9, 0.4, 0.55)),
      )
    end
  end
end

# --- Déplacement + tir du joueur ---
app.add_system(Flock::Schedule::Update) do |world, cmd|
  input = world.resource(Flock::Input)
  time = world.resource(Flock::Time)
  dt = time.delta.to_f32

  dx = 0.0f32
  dx -= 1.0f32 if input.pressed?(Flock::Key::Left) || input.pressed?(Flock::Key::A)
  dx += 1.0f32 if input.pressed?(Flock::Key::Right) || input.pressed?(Flock::Key::D)
  if pad = input.gamepad?
    ax = pad.axis(Flock::Axis::LeftX)
    dx = ax if ax != 0.0f32
  end

  fire = input.pressed?(Flock::Key::Space) || (input.gamepad?.try(&.pressed?(Flock::Button::South)) || false)

  world.query(Player, Flock::Transform2D) do |_e, pl, tf|
    nx = (tf.value.position.x + dx * pl.value.speed * dt).clamp(-380.0f32, 380.0f32)
    tf.value.position = Flock::Vec2.new(nx, tf.value.position.y)

    if fire && time.elapsed >= pl.value.next_shot
      pl.value.next_shot = time.elapsed + 0.35
      cmd.spawn(
        Bullet.new,
        Flock::Transform2D.at(nx, tf.value.position.y + 20.0),
        Flock::Sprite.new(Flock::Vec2.new(6, 16), Flock::Color.new(1.0, 1.0, 0.4)),
        Velocity.new(Flock::Vec2.new(0, 480)),
      )
      world.resource(Flock::Audio).play(world.resource(Sfx).shoot)
    end
  end
end

# --- Intégration du mouvement (tout ce qui a une Velocity) ---
app.add_system(Flock::Schedule::Update) do |world, _cmd|
  dt = world.resource(Flock::Time).delta.to_f32
  world.query(Flock::Transform2D, Velocity) do |_e, tf, vel|
    tf.value.position = tf.value.position + vel.value.linear * dt
  end
end

# --- Marche des invaders (groupe : rebond sur les bords + descente) ---
app.add_system(Flock::Schedule::Update) do |world, _cmd|
  state = world.resource(InvaderState)
  dt = world.resource(Flock::Time).delta.to_f32

  minx = Float32::MAX
  maxx = -Float32::MAX
  world.query(Invader, Flock::Transform2D) do |_e, _inv, tf|
    x = tf.value.position.x
    minx = x if x < minx
    maxx = x if x > maxx
  end

  drop = false
  if maxx > 360.0f32 && state.dir > 0
    state.dir = -1.0f32; drop = true
  elsif minx < -360.0f32 && state.dir < 0
    state.dir = 1.0f32; drop = true
  end

  dx = state.dir * state.speed * dt
  world.query(Invader, Flock::Transform2D) do |_e, _inv, tf|
    ny = drop ? tf.value.position.y - 24.0f32 : tf.value.position.y
    tf.value.position = Flock::Vec2.new(tf.value.position.x + dx, ny)
  end
end

# --- Nettoyage des bullets sorties de l'écran ---
app.add_system(Flock::Schedule::Update) do |world, cmd|
  world.query(Bullet, Flock::Transform2D) do |e, _b, tf|
    cmd.despawn(e) if tf.value.position.y > 320.0f32
  end
end

# --- Collisions bullet x invader (AABB) ---
app.add_system(Flock::Schedule::Update) do |world, cmd|
  bullets = [] of {Flock::Entity, Flock::Vec2, Flock::Vec2}
  world.query(Bullet, Flock::Transform2D, Flock::Sprite) do |e, _b, tf, sp|
    bullets << {e, tf.value.position, sp.value.size * 0.5f32}
  end
  invaders = [] of {Flock::Entity, Flock::Vec2, Flock::Vec2}
  world.query(Invader, Flock::Transform2D, Flock::Sprite) do |e, _i, tf, sp|
    invaders << {e, tf.value.position, sp.value.size * 0.5f32}
  end

  dead = [] of UInt32
  bullets.each do |(be, bp, bh)|
    invaders.each do |(ie, ip, ih)|
      next if dead.includes?(ie.id)
      if (bp.x - ip.x).abs < (bh.x + ih.x) && (bp.y - ip.y).abs < (bh.y + ih.y)
        cmd.despawn(be)
        cmd.despawn(ie)
        dead << ie.id
        world.resource(Flock::Audio).play(world.resource(Sfx).explosion)
        break
      end
    end
  end
end

app.run
