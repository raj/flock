# Flock — plan de conception

**Flock** est un moteur de jeu en Crystal orienté données (Data-Oriented Design), inspiré de
Bevy, construit au-dessus de [`wgpu-cr`](../wgpu-cr) pour le rendu et de **SDL3** pour la
plateforme (fenêtre, entrées, manettes, audio, timing).

Objectifs directeurs :

- **Facile à utiliser** : démarrage en une ligne (`DefaultPlugins`), API ergonomique.
- **ECS performant** : sparse sets, composants `struct` cache-friendly, mutation par pointeur.
- **Rendu 2D texturé** + **caméras 2D/3D** + **viewports** + **shaders façon wgpu** (WGSL).
- **Manettes** (SDL_Gamepad, hotplug) et **audio** (mixage SDL3).
- Un **exemple jouable** : Space Invaders.

> Historique : ce plan corrige des défauts de la première ébauche — mutation des composants
> cassée, stockage indexé par `String`, query non optimale, `@free_ids` mort faute de
> `despawn`, aucune ressource/singleton, systèmes à plat.

## Décisions d'architecture

- **Composants = `struct`** (dense arrays cache-friendly). Mutation via **accès pointeur** :
  la query yield des `Pointer(T)` et `pos.value.x += v` **mute en place** (sémantique Crystal
  vérifiée : `ptr.value.field = …` écrit dans le dense array).
- **Rendu = sprites texturés** dès la phase 1 (PNG via SDL_image, sampler + bind group texture).
- **Shaders façon wgpu** : abstraction `Shader` (WGSL fichier/string → module) + `Material`
  (shader + pipeline + bind group + uniforms), avec accès aux handles `LibWGPU` bruts pour les
  cas avancés. Le sprite par défaut est un matériau intégré.
- **Caméras 2D et 3D + viewports** : abstraction caméra générique (matrice view-projection +
  sous-région d'écran). Le rendu 2D la consomme en phase 1 ; la math 3D (perspective, look_at)
  est fournie, le rendu de meshes 3D viendra plus tard.
- **Plateforme = SDL3.** Choix retenu à l'implémentation : **binding FFI maison minimal
  embarqué** (`src/flock/platform/lib_sdl.cr`, lié à SDL3 Homebrew) plutôt que le shard
  `Hadeweka/SDL-Crystal-Bindings` — linking entièrement maîtrisé, surface réduite à ce que
  Flock utilise, aucun `shards install`. Extractible en `../sdl3-cr` ou remplaçable par le
  shard plus tard. *(À confirmer avec l'utilisateur.)*
- **Rendu bas niveau = wgpu-cr**. Surface wgpu créée depuis le `CAMetalLayer` de
  `SDL_Metal_CreateView`/`SDL_Metal_GetLayer` (remplace la glue Objective-C de wgpu-cr).
- macOS/Metal d'abord. Prérequis : `brew install sdl3 sdl3_image` ; wgpu-native téléchargé par
  le postinstall de wgpu-cr.

## Arborescence

```
flock/
├── shard.yml
├── README.md
├── assets/                     # sprites .png, sons .wav
├── src/
│   ├── flock.cr
│   └── flock/
│       ├── ecs/
│       │   ├── entity.cr       # struct Entity(id, generation)
│       │   ├── component.cr    # module Component + ComponentRegistry (ids entiers denses)
│       │   ├── sparse_set.cr   # Storage (abstrait) + SparseSet(T) (accès pointeur)
│       │   ├── world.cr        # spawn/despawn, storages, ressources, query (yield pointeurs)
│       │   └── commands.cr     # mutations structurelles différées
│       ├── app/
│       │   ├── schedule.cr     # enum Schedule (Startup, First, Update, Render, Last)
│       │   ├── plugin.cr       # abstract Plugin
│       │   └── app.cr          # App : plugins, systèmes par schedule, boucle
│       ├── math/
│       │   └── math3d.cr       # Vec2, Vec3, Mat4 (ortho, perspective, look_at)
│       ├── time.cr             # ressource Time (delta, elapsed)
│       ├── platform/
│       │   ├── window.cr       # WindowPlugin : fenêtre SDL + surface wgpu + GpuContext
│       │   ├── input.cr        # InputPlugin : clavier + manettes (Input, Gamepad)
│       │   └── audio.cr        # AudioPlugin : chargement/lecture WAV (Audio, Sound)
│       └── render/
│           ├── components.cr   # Transform2D, Transform3D, Sprite
│           ├── camera.cr       # Camera2D, Camera3D, Viewport, Projection
│           ├── texture.cr      # chargement PNG (SDL_image) -> texture wgpu
│           ├── shader.cr       # Shader : WGSL (fichier/string) -> module wgpu
│           ├── material.cr     # Material : shader + pipeline + bind group + uniforms
│           ├── renderer2d.cr   # pipeline quad texturé instancié (matériau par défaut)
│           └── render_plugin.cr
├── examples/
│   └── space_invaders.cr
└── spec/
    ├── spec_helper.cr
    ├── sparse_set_spec.cr
    ├── world_spec.cr
    ├── query_spec.cr
    └── math_spec.cr            # ortho/perspective/look_at
```

## Conception détaillée

### 1. ECS — cœur (composants `struct`, mutation par pointeur)

**Entity** (`ecs/entity.cr`) : `struct Entity(id : UInt32, generation : UInt32)`. Id gardé en
`UInt32` de bout en bout (plus de `.to_i` dans le hot path).

**Component + registre** (`ecs/component.cr`) — id entier dense par type, sans hashing :

```crystal
module Flock
  module ComponentRegistry
    @@count = 0
    def self.next_id : Int32; id = @@count; @@count += 1; id; end
    def self.count : Int32; @@count; end
  end

  # struct Position; include Flock::Component; ... end
  module Component
    macro included
      class_getter component_id : Int32 = Flock::ComponentRegistry.next_id
    end
  end
end
```

**Storage + SparseSet** (`ecs/sparse_set.cr`) — interface type-erased (nécessaire pour
`despawn`), sparse en sentinelle `-1` (pas d'union nilable), et **accès pointeur** pour la
mutation en place :

```crystal
abstract class Storage
  abstract def remove_untyped(entity : Entity)
  abstract def size : Int32
end

class SparseSet(T) < Storage
  getter dense    = [] of T
  getter entities = [] of Entity
  @sparse = [] of Int32                 # -1 = absent

  def size : Int32; @dense.size; end
  def insert(entity, component : T)     # update en place ou push
  def index_of?(entity : Entity) : Int32?           # 1 lookup, contrôle de génération
  def get_ptr(entity : Entity) : Pointer(T)?        # @dense.to_unsafe + idx (nil si absent)
  def has?(entity : Entity) : Bool
  def remove(entity : Entity)           # swap-and-pop O(1)
  def remove_untyped(entity : Entity); remove(entity); end
end
```

> **Note pointeurs** : `get_ptr` renvoie un pointeur dans le dense array, valide tant qu'aucune
> insertion/suppression ne réalloue le tableau. D'où la règle : toute mutation structurelle
> pendant une itération passe par `Commands` (différé).

**World** (`ecs/world.cr`) — storages en `Array(Storage?)` indexés par `component_id` (O(1),
zéro hash), `despawn` réel alimentant `@free_ids`, ressources (singletons), et query par
pointeurs :

```crystal
class World
  @storages  = [] of Storage?
  @resources = {} of String => Resource
  # + next_entity_id / generations / free_ids

  def spawn : Entity                    # recycle via free_ids, bump generation
  def despawn(entity : Entity)          # remove_untyped sur tous les storages ; id -> free_ids
  def storage(t : T.class) : SparseSet(T) forall T   # créé à la volée, indexé par T.component_id
  def add(entity, c : T) forall T
  def get(entity, t : T.class) : T? forall T
  def remove(entity, t : T.class) forall T

  def insert_resource(r : Resource)
  def resource(t : T.class) : T forall T             # lève si absent
  def resource?(t : T.class) : T? forall T

  # Query : pilote sur le plus PETIT ensemble d'entités, 1 lookup par composant,
  # yield de POINTEURS. En Crystal un macro n'est PAS invocable sur une instance :
  # on génère donc une vraie surcharge de méthode `query` par arité (1 à 8).
  #   world.query(A, B) { |e, a, b| p = a.value; p.x += b.value.dx; a.value = p }
end

abstract class Resource; end
```

Génération des surcharges (driver = plus petite liste d'entités, un lookup par composant) :

```crystal
{% for n in 1..8 %}
  def query({% for i in 1..n %}t{{i}} : T{{i}}.class,{% end %}) : Nil forall {% ... %}
    {% for i in 1..n %} s{{i}} = storage(T{{i}}) {% end %}
    drv = s1.entities
    {% for i in 2..n %} drv = s{{i}}.entities if s{{i}}.entities.size < drv.size {% end %}
    drv.dup.each do |entity|            # dup : sûr si le bloc despawn
      {% for i in 1..n %} p{{i}} = s{{i}}.get_ptr(entity); next unless p{{i}} {% end %}
      yield entity, {% for i in 1..n %}p{{i}},{% end %}
    end
  end
{% end %}
```

> **Idiome de mutation** : le sucre `ptr.value.x += v` ne persiste PAS en Crystal (le
> compound-assign lit une copie). Utiliser le write-back du struct
> (`p = ptr.value; p.x += v; ptr.value = p`) ou l'affectation directe de champ
> (`ptr.value.x = ptr.value.x + v`, qui, elle, mute en place). Vérifié par test.

**Commands** (`ecs/commands.cr`) — mutations structurelles différées (évite d'invalider une
query en cours et les pointeurs dense), appliquées en fin de stage :

```crystal
class Commands
  def spawn(*components) : Entity       # surcharges 0..8 (id réservé tout de suite, adds en file)
  def despawn(entity : Entity)
  def add(entity, component)
  def apply(world : World)              # vidé par l'App après chaque schedule
end
```

### 2. App, Schedule, Plugins

`schedule.cr` : `enum Schedule; Startup; First; Update; Render; Last; end`.
`plugin.cr` : `abstract class Plugin; abstract def build(app : App); end`.

`app.cr` — API volontairement simple :

```crystal
Flock::App.new
  .add_plugins(Flock::DefaultPlugins)          # Window + Render + Input + Audio + Time
  .add_startup { |w| ... }
  .add_system(Schedule::Update) { |w, cmd| ... }
  .run
# run : build des plugins ; systèmes Startup une fois ;
#   boucle : SDL_PollEvent -> Time.tick -> First/Update/Render/Last ; commands.apply après chaque stage.
```

Systèmes = `Proc` (`World ->` ou `World, Commands ->`). `DefaultPlugins` agrège tout pour un
démarrage en une ligne. (Les paramètres de systèmes typés façon Bevy restent une évolution
possible.)

### 3. Math (`math/math3d.cr`)

`Vec2`, `Vec3`, `Mat4` (structs). Fonctions clés :

- `Mat4.orthographic(left, right, bottom, top, near, far)` — caméra 2D.
- `Mat4.perspective(fov_y, aspect, near, far)` — caméra 3D.
- `Mat4.look_at(eye : Vec3, target : Vec3, up : Vec3)` — vue 3D.
- multiplication `Mat4 * Mat4`, `Mat4 * Vec4`, translate/rotate/scale.

### 4. Ressource Time (`time.cr`)

`Time < Resource` : `delta`/`elapsed` (secondes) depuis `SDL_GetPerformanceCounter` /
`Frequency`. Base du mouvement indépendant du framerate.

### 5. Plateforme SDL3

**Window** (`platform/window.cr`) — `WindowPlugin` :
`SDL_Init(VIDEO|GAMEPAD|AUDIO)` ; `SDL_CreateWindow(… METAL|RESIZABLE)` ;
`SDL_Metal_CreateView` → `SDL_Metal_GetLayer` (`CAMetalLayer*`) → `SurfaceSourceMetalLayer`
→ `instance_create_surface` (puis adapter/device/queue/capabilities/`surface_configure` en
`Fifo`, chemin calqué sur `triangle.cr`). Reconfiguration sur `SDL_EVENT_WINDOW_RESIZED`.
Publie une ressource `GpuContext < Resource` (instance, adapter, device, queue, surface,
format, taille fenêtre/framebuffer).

**Input** (`platform/input.cr`) — `InputPlugin`, **polling** par frame (plus simple que les
callbacks, contraints par les procs non-capturants) :

```crystal
input = world.resource(Flock::Input)
input.pressed?(Key::Left)            # SDL_GetKeyboardState
input.just_pressed?(Key::Space)      # diff avec la frame précédente
pad = input.gamepad?(0)
pad.try &.pressed?(Button::South)    # SDL_GetGamepadButton
pad.try &.axis(Axis::LeftX)          # SDL_GetGamepadAxis, deadzone appliquée
```

Manettes : `SDL_OpenGamepad` sur `SDL_EVENT_GAMEPAD_ADDED`, fermeture sur `_REMOVED`
(hotplug), mappings intégrés SDL. `Key`/`Button`/`Axis` = enums Flock découplés du binding brut.

**Audio** (`platform/audio.cr`) — `AudioPlugin` :

```crystal
audio = world.resource(Flock::Audio)
shoot = audio.load("assets/shoot.wav")   # SDL_LoadWAV -> PCM décodé (Sound)
audio.play(shoot)                        # volume optionnel
```

Device logique via `SDL_OpenAudioDeviceStream` ; lecture simultanée via le **mixage natif
SDL3** (plusieurs `SDL_AudioStream` liés au même device). `Sound` = PCM pré-décodé (une seule
décompression par fichier). WAV en phase 1 ; OGG/MP3 (musique) via SDL3_mixer plus tard.

### 6. Caméras & viewports (`render/camera.cr`)

Abstraction générique : une caméra produit une **matrice view-projection** et rend dans un
**viewport** (sous-région d'écran). Deux composants ergonomiques, tous deux `struct` +
`include Component` :

```crystal
struct Viewport                          # sous-région en pixels (nil = plein écran)
  property x, y, width, height : Float32
end

struct Camera2D
  property position : Vec2               # centre visé
  property zoom : Float64                # 1.0 = neutre
  property rotation : Float64
  property viewport : Viewport?
  property order : Int32                 # ordre de rendu (croissant)
  property clear_color : Color?          # nil = pas de clear (superposition)
  property active : Bool
  # view_projection(fb_size) : Mat4  -> ortho(taille viewport) * inverse(transform caméra)
end

struct Camera3D
  property position : Vec3
  property target   : Vec3               # (ou orientation) ; up : Vec3
  property up       : Vec3
  property fov_y    : Float64
  property near, far : Float64
  property viewport : Viewport?
  property order    : Int32
  property clear_color : Color?
  property active   : Bool
  # view_projection(fb_size) : Mat4  -> perspective(fov, aspect du viewport) * look_at(...)
end
```

Le système de rendu :

1. Rassemble toutes les caméras (2D et 3D) actives, triées par `order`.
2. Pour chacune : calcule l'aspect ratio depuis son `viewport` (ou le framebuffer) ; appelle
   `render_pass_encoder_set_viewport` + `set_scissor_rect` (présents dans wgpu-cr) ; clear
   optionnel ; pousse la matrice view-projection dans l'uniform ; rend la scène visible.

Cas d'usage couverts : split-screen (2 caméras, 2 viewports), minimap (petite caméra en
overlay, `clear_color = nil`), HUD. **Phase 1 : seul le pass 2D (Camera2D) est câblé** ;
Camera3D + math perspective sont fournies, le pass de meshes 3D arrive plus tard.

### 7. Rendu 2D texturé (`render/`)

**Composants** (`render/components.cr`) — structs : `Transform2D` (position `Vec2`, rotation,
scale `Vec2`), `Transform3D` (Vec3 + rotation + scale, pour la 3D à venir), `Sprite`
(`texture : TextureHandle`, `color : Color` teinte, `size : Vec2`, `uv_rect` pour atlas).

**Texture** (`render/texture.cr`) : `IMG_Load` (SDL_image) → pixels RGBA →
`device_create_texture` + `queue_write_texture` ; un `Sampler` partagé. Cache par chemin
(`Hash(String, TextureHandle)`).

**Renderer2D** (`render/renderer2d.cr`) — quad texturé instancié :

- vertex buffer (quad unitaire, 4 sommets pos+uv) + index buffer (6 indices).
- instance buffer réécrit par frame (`queue_write_buffer`) : par entité (Transform2D, Sprite)
  → matrice modèle + teinte + uv_rect.
- uniform buffer : view-projection **de la caméra courante**.
- bind group : uniform + texture + sampler ; **blending alpha activé** (`ColorTargetState.blend`).
- shader WGSL inline : `vs_main` = viewproj × modèle × quad ; `fs_main` = `texture * teinte`.
- Par caméra : batch par texture (regroupe les sprites d'une même texture), `draw_indexed(6, N)`.
- Chemin par frame calqué sur `triangle.cr` (`surface_get_current_texture` → render pass →
  submit → `surface_present`).

**RenderPlugin** (`render/render_plugin.cr`) : crée Renderer2D + Sampler au Startup (depuis
`GpuContext`), enregistre le système de rendu (itère les caméras) en `Schedule::Render`.

### 8. Shaders & matériaux — façon wgpu (`render/shader.cr`, `render/material.cr`)

Objectif : exposer le modèle de shaders de wgpu (WGSL, pipeline, bind group, uniforms) de
façon idiomatique, sans masquer le bas niveau. wgpu-cr étant un binding mince, `Shader` et
`Material` sont de fines commodités typées au-dessus de `device_create_shader_module` /
`device_create_render_pipeline`, les handles `LibWGPU` restant accessibles.

**Shader** (`render/shader.cr`) — reprend le pattern de `triangle.cr` (`WGPU.string_view` →
`ShaderSourceWGSL` → `device_create_shader_module`) :

```crystal
struct Shader
  getter module : LibWGPU::ShaderModule
  def self.from_source(gpu : GpuContext, wgsl : String, *, vertex = "vs_main", fragment = "fs_main") : Shader
  def self.from_file(gpu : GpuContext, path : String, **kw) : Shader   # lit un .wgsl
end
```

**Material** (`render/material.cr`) — associe un shader à une config de pipeline et à des
uniforms utilisateur ; construit le `RenderPipeline` + bind group correspondants :

```crystal
class Material
  def self.build(gpu : GpuContext, shader : Shader, *,
                 blend      = Blend::AlphaBlend,        # ou Opaque, Additive
                 topology   = Topology::TriangleList,
                 vertex_layout : VertexLayout = VertexLayout.sprite,  # pos+uv par défaut
                 bindings   : Array(Binding) = ...) : Material         # uniforms/textures/samplers
  def set_uniform(name : String, value)   # écrit dans l'uniform buffer via queue_write_buffer
  getter pipeline : LibWGPU::RenderPipeline
  getter bind_group : LibWGPU::BindGroup
end
```

- **Matériau par défaut** : le Renderer2D en fournit un intégré (shader sprite texturé +
  teinte + view-projection). Chemin « facile » : l'utilisateur ne touche à rien.
- **Matériaux personnalisés** : `Sprite` (et plus tard `Mesh`) peut référencer un
  `MaterialHandle`. Le renderer batch par matériau puis par texture. Permet des effets par
  entité (dissolve, outline, teinte animée…).
- **Post-processing** : `PostProcess` = matériau plein écran dont le fragment lit la texture de
  scène (rendu vers une texture intermédiaire puis pass plein écran). Évolution proche ;
  l'abstraction Material le rend direct.
- **Échappatoire bas niveau** : `Shader#module`, `Material#pipeline`/`#bind_group` exposent les
  handles `LibWGPU` — un utilisateur avancé pilote le render pass à la main, « façon wgpu ».

### 9. Exemple — Space Invaders (`examples/space_invaders.cr`)

Démontre ECS + caméra + entrées (clavier **et** manette) + audio + sprites texturés :

- **Startup** : `Camera2D` (plein écran) ; joueur, grille d'invaders, sprites PNG chargés.
- **Composants jeu** : `Player`, `Invader`, `Bullet`, `Velocity` (+ Transform2D, Sprite).
- **Systèmes Update** : input joueur (clavier/manette → déplacement, tir via `Commands` +
  `audio.play(shoot)`) ; mouvement (`query(Transform2D, Velocity)` → write-back du
  Transform : `tr = t.value; tr.position += … * Time.delta; t.value = tr`) ; déplacement
  de groupe des invaders ; collisions
  bullet×invader (AABB → despawn des deux + explosion) ; nettoyage des bullets hors écran.
- **Render** : automatique (tout ce qui a Transform2D + Sprite, vu par la Camera2D).
- **Démo shader** (optionnelle) : matériau custom sur les invaders (WGSL clignotant/teinte)
  pour illustrer l'API shader.

### 10. shard.yml & linking

```yaml
name: flock
version: 0.1.0
authors: [Raj Deenoo]
crystal: ">= 1.16.0"
license: MIT
dependencies:
  wgpu: { path: ../wgpu-cr }
  sdl-crystal-bindings: { github: Hadeweka/SDL-Crystal-Bindings, version: ~> 0.5.0 }
targets:
  space_invaders: { main: examples/space_invaders.cr }
```

`@[Link]` SDL3 (Homebrew), sur le modèle wgpu-cr/GLFW :
`-L/opt/homebrew/lib -lSDL3 -lSDL3_image -Wl,-rpath,/opt/homebrew/lib`.

### 11. Tests (`spec/`)

Modèle `wgpu-cr/spec` (spec Crystal standard, headless) :

- `sparse_set_spec` : insert/get_ptr/remove, swap-and-pop, contrôle de génération.
- `world_spec` : spawn/despawn, recyclage d'id + bump génération, ressources.
- `query_spec` : driver = plus petit set, **mutation via pointeur persistante**, robustesse au
  despawn pendant l'itération (`dup`).
- `math_spec` : ortho/perspective/look_at (valeurs connues).
- Rendu/fenêtre : smoke test `WGPU_FRAMES=N` (headless), hors CI bloquante.

## État d'implémentation (toutes phases livrées et vérifiées)

Toutes les phases ci-dessous sont implémentées. Cœur testé par `crystal spec` (29 exemples,
headless) ; couches GPU/plateforme vérifiées en headless via `WGPU_FRAMES=N crystal run …`
(fenêtre + N frames + sortie propre, sans erreur de validation wgpu).

- ✅ **1. ECS** — entity, component/registry, sparse_set (pointeur), world, commands + specs.
- ✅ **2. Math** — Vec2/Vec3/Mat4 (ortho/perspective/look_at, translate/rotate/scale) + specs.
- ✅ **3. App/Schedule/Plugin + Time** — boucle, plugins, `run_headless` + specs.
- ✅ **4. Window** — SDL3 + surface wgpu (via `SDL_Metal_GetLayer`), runner, resize.
- ✅ **5. Shaders & matériaux** — `Shader` (WGSL) + `Material` plein écran (exemple plasma).
- ✅ **6. Caméras/viewports + Render2D** — quads texturés instanciés, blending, Camera2D/3D.
- ✅ **7. Entrées** — clavier + manettes (hotplug, zone morte).
- ✅ **8. Audio** — WAV + sons procéduraux, mixage SDL3.
- ✅ **9. Space Invaders** — assemblage jouable (`examples/space_invaders.cr`) + README.

Découvertes Crystal ayant infléchi la conception (détaillées plus haut) : (a) les macros ne
sont pas invocables sur une instance → `query`/`Commands#spawn` sont des **surcharges de
méthode** générées par arité ; (b) `ptr.value.x += v` ne persiste pas, mais l'affectation
directe `ptr.value.x = …` et les **méthodes mutantes** `ptr.value.move(…)` oui.

Restes (post-phase, non bloquants) : chargement PNG via SDL_image (le rendu accepte déjà des
textures — `Texture.from_pixels` marche, seul `Texture.load` PNG manque) ; matériaux
personnalisés **par sprite** dans le renderer batch ; rendu de meshes 3D consommant Camera3D.

## Roadmap d'implémentation

1. ECS (entity, component/registry, sparse_set pointeur, world, commands) + specs.
2. Math (Vec2/Vec3/Mat4, ortho/perspective/look_at) + specs.
3. App/Schedule/Plugins + Time (boucle sans fenêtre).
4. Window (SDL3 + surface wgpu) → clear à l'écran.
5. Shaders & matériaux (Shader WGSL, Material/pipeline) + matériau sprite par défaut.
6. Caméras/viewports + Render2D texturé (SDL_image, sampler, bind group).
7. Input (clavier + manettes, hotplug, deadzone).
8. Audio (WAV, mixage).
9. Space Invaders + README.
10. (ultérieur) post-processing plein écran ; rendu de meshes 3D consommant Camera3D.

## Vérification

- `brew install sdl3 sdl3_image` ; `cd flock && shards install`.
- `crystal spec` : ECS/world/query/math au vert (headless, sans SDL/GPU).
- `WGPU_FRAMES=3 crystal run examples/space_invaders.cr` : fenêtre + quelques frames + sortie
  propre (smoke test).
- Interactif : joueur déplaçable clavier **et** manette, tir audible, invaders détruits au
  contact ; démo caméra en ajoutant une 2ᵉ Camera2D avec `viewport` réduit (minimap).
