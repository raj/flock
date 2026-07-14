# Flock

Un moteur de jeu **orienté données (ECS)** en Crystal, inspiré de Bevy, au-dessus de
[`wgpu-cr`](../wgpu-cr) (rendu WebGPU) et **SDL3** (fenêtre, entrées, manettes, audio).

- **ECS** : sparse sets, composants `struct` cache-friendly, mutation par pointeur,
  `query` multi-composants (pilote sur le plus petit set), ressources, commandes différées.
- **App / plugins / schedules** : `Startup / First / Update / Render / Last`.
- **Rendu 2D** : sprites texturés instanciés, caméras 2D/3D, viewports, blending alpha.
- **Shaders façon wgpu** : `Shader` (WGSL) + `Material` (pipeline + uniform), handles bruts accessibles.
- **Entrées** : clavier, **souris** (position/boutons + `Camera2D#screen_to_world`),
  **manettes** (SDL_Gamepad, hotplug, zone morte).
- **Audio** : WAV + sons procéduraux, mixage natif SDL3.

Voir [`plan.md`](plan.md) pour la conception détaillée.

## Prérequis (macOS / Metal)

```sh
brew install sdl3 sdl3_image sdl3_ttf
```

`wgpu-native` est fourni par le voisin `../wgpu-cr` (téléchargé par son `postinstall`).
Flock le référence par chemin relatif — aucun `shards install` requis pour les exemples.

**Portabilité** : le linking SDL passe par pkg-config et la création de surface est dispatchée
par plateforme (Metal macOS, X11/Wayland Linux, HWND Windows). **macOS** est testé au runtime ;
**Linux/Windows** sont vérifiés en cross-compilation mais pas encore validés sur machine réelle.

## Tester (cœur ECS + math, headless)

```sh
crystal spec        # 29 exemples, sans SDL ni GPU
```

## Lancer les exemples

```sh
crystal run examples/space_invaders.cr     # le jeu : clavier + manette + son
crystal run examples/window_app.cr         # caméra 2D + sprites colorés
crystal run examples/custom_shader.cr      # effet plasma (shader WGSL custom)
crystal run examples/mouse_demo.cr         # un carré suit la souris, rouge au clic
crystal run examples/events_demo.cr        # molette + saisie de texte (console)

# Smoke test headless (quitte après N frames) :
WGPU_FRAMES=120 crystal run examples/space_invaders.cr

# Tests headless par readback (rendu offscreen + assertions pixel ; exit 0 si OK) :
crystal run examples/readback_test.cr    # un sprite coloré
crystal run examples/text_test.cr        # rendu de texte (SDL_ttf)
crystal run examples/assets_test.cr      # cache d'assets (même clé -> même instance)
```

## Assets (cache)

```crystal
assets = world.resource(Flock::Assets)          # fourni par DefaultPlugins
tex = assets.texture("assets/player.png")       # chargé une fois, mis en cache
fnt = assets.font("assets/Roboto.ttf", 24)
snd = assets.sound("assets/shoot.wav")
# libération centralisée à la fermeture (assets.release, avant le device)
```

## Texte

```crystal
font = assets.font("/System/Library/Fonts/Supplemental/Arial.ttf", 40)
tex  = font.render_texture(gpu, "Score : 42")   # texture RGBA (texte blanc)
cmd.spawn(Flock::Transform2D.at(0, 260),
  Flock::Sprite.new(Flock::Vec2.new(tex.width, tex.height), Flock::Color::WHITE, tex))
# La teinte du sprite colore le texte. Mettre en cache pour du texte qui change souvent.
```

Space Invaders : **flèches / A-D** ou **stick gauche** pour bouger, **Espace / bouton A** pour tirer.

## Démarrage rapide

```crystal
require "../src/flock/gpu"

struct Position; include Flock::Component; property v : Flock::Vec2
  def initialize(@v = Flock::Vec2.new); end
end

app = Flock::App.new
app.add_plugin(Flock::DefaultPlugins.new("Mon jeu", 800, 600))

app.add_startup do |world, cmd|
  cmd.spawn(Flock::Camera2D.new(clear_color: Flock::Color.new(0.1, 0.1, 0.15)))
  cmd.spawn(
    Flock::Transform2D.at(0, 0),
    Flock::Sprite.new(Flock::Vec2.new(120, 120), Flock::Color::RED),
  )
end

app.add_system(Flock::Schedule::Update) do |world, _cmd|
  dt = world.resource(Flock::Time).delta.to_f32
  world.query(Flock::Transform2D) do |_e, tf|
    tf.value.position = tf.value.position + Flock::Vec2.new(30 * dt, 0)
  end
end

app.run
```

## Idiome de mutation (composants `struct`)

Les composants sont des `struct` (orienté données). `query` yield des `Pointer(T)`.
En Crystal, l'**affectation directe** et les **méthodes mutantes** persistent à travers
un pointeur, mais **pas** l'affectation composée `+=` :

```crystal
world.query(Transform2D, Velocity) do |_e, tf, vel|
  tf.value.position = tf.value.position + vel.value.linear * dt  # ✅ setter direct
  # tf.value.position.x += ...                                    # ❌ ne persiste pas
end
```

## Architecture

```
src/flock.cr              # cœur headless : math + ecs + app + time (aucune dep native)
src/flock/gpu.cr          # entrée complète : + wgpu (rendu) + SDL3 (plateforme)
src/flock/ecs/            # entity, component, sparse_set, world, commands
src/flock/app/            # schedule, plugin, app
src/flock/math/math3d.cr  # Vec2, Vec3, Mat4 (ortho/perspective/look_at)
src/flock/platform/       # lib_sdl (binding SDL3), window, input, audio, gpu_context
src/flock/render/         # color, texture, camera, components, shader, material, renderer2d
examples/                 # space_invaders, window_app, custom_shader, smoke_window
spec/                     # tests headless du cœur
```

## Licence

MIT
