# Pistes d'amélioration — Flock & sdl3-cr

Classé par impact. `[ ]` à faire. Concerne `flock/` et le shard voisin `sdl3-cr/`.

## Flock

### Correctness / robustesse (prioritaire)
- [x] **Libérer les ressources GPU.** `Resource#release` (+ ordre) + `World#shutdown` appelé
      par `App#run` ; `GpuContext`/`Renderer2D`/`Material`/`Texture` libèrent leurs handles.
- [x] **Capturer les erreurs wgpu.** `Flock.request_device` crée le device avec les callbacks
      `uncaptured error` + `device lost` (journalisés sur STDERR) ; le runner appelle
      `instance_process_events` par frame pour les flusher. Vérifié : un buffer invalide
      déclenche `[wgpu][Validation]`.
- [x] **Récupérer une surface perdue.** `Renderer2D#render` décode le statut de
      `surface_get_current_texture` : rend sur `SuccessOptimal`/`Suboptimal`, reconfigure via
      `GpuContext#reconfigure_to_window` sur `Outdated`/`Lost`, saute sur Timeout/Error/transitoire.
- [x] **Tests de rendu automatisés (readback).** `examples/readback_test.cr` : rendu offscreen
      → `copy_texture_to_buffer` → map → assertions pixel (centre rouge / coin noir), exit 0/1.
      `Renderer2D#render_into` sépare le rendu de l'acquisition de surface. A déjà attrapé un
      bug réel : `Sprite.size` n'était pas appliqué au modèle (quads 1×1).

### Fonctionnalités manquantes
- [x] **Souris** : `Input#mouse_position` (pixels framebuffer, HiDPI) + `mouse_pressed?` /
      `just_pressed?` / `just_released?` (`MouseButton`), + `Camera2D#screen_to_world`. Vérifié
      (`spec/camera_spec.cr`, `examples/mouse_demo.cr`). Molette exposée (`Input#mouse_wheel`,
      via events). Reste : curseur (masquer/capturer/mode relatif).
- [x] **Rendu de texte / police** via SDL_ttf : `Flock::Font.load` + `font.render_texture(gpu,
      text)` → `Texture` dessinée comme sprite (teintable). Vérifié par `examples/text_test.cr`
      (readback) ; titre intégré dans Space Invaders. Reste : cache par chaîne, atlas de glyphes.
- [ ] **Matériaux par sprite** — `Material` ne fait que le plein écran ; le renderer a un seul
      pipeline. Permettre à un `Sprite` de référencer un matériau custom (batch par matériau
      puis texture).
- [ ] **Fixed timestep** (`FixedUpdate` + accumulateur) pour une physique stable.
- [ ] **Événements / états** façon Bevy (`Events` inter-systèmes, machine à états de jeu).
- [ ] **Audio** : `play` crée un stream par lecture et le récupère à `queued==0`, ce qui peut
      couper la fin du son ; ajouter volume (`SDL_SetAudioStreamGain`), musique en boucle, `stop`.

### Confort / archi
- [ ] **Ordre des systèmes** dans un schedule (labels, `before`/`after`, conditions `run_if`).
- [x] **Asset manager** (`Flock::Assets`, via `AssetsPlugin`/DefaultPlugins) : cache par clé
      pour textures (`texture(path)`), polices (`font(path, size)`) et sons (`sound(path)`) +
      `store_texture` ; libération centralisée (`release`, avant le device). Vérifié
      (`examples/assets_test.cr`) ; titre de Space Invaders routé via le cache.
- [ ] **Multi-viewport / clear par région** : le clear porte sur toute l'attache → un viewport
      ne peut pas s'effacer dans sa propre couleur (vrai split-screen : scissor ou passes séparées).
- [ ] **Sampler configurable** (linear vs nearest, mipmaps) — actuellement nearest only.
- [ ] **Rendu 3D** de meshes consommant `Camera3D` (la math perspective/look_at est prête).

## sdl3-cr

- [x] **Portabilité du linking.** Passé de `/opt/homebrew/lib` en dur à des annotations
      `@[Link(pkg_config: "sdl3" / "sdl3-image" / "sdl3-ttf")]` (portable macOS/Linux ; Windows
      via vcpkg/msys2). Repli `-lSDL3*` si pkg-config absent.
- [x] **Montage de surface multi-plateforme.** `WindowPlugin#make_surface` dispatche par
      plateforme via `SDL_GetWindowProperties` : Metal (macOS), X11/Wayland (Linux, détection
      runtime via `SDL_GetCurrentVideoDriver`), HWND (Windows). macOS testé au runtime ;
      Linux et Windows **vérifiés en cross-compilation** (`crystal build --cross-compile`), pas
      encore au runtime. Reste : valider sur de vraies machines Linux/Windows.
- [x] **Exposer les données d'événements.** Structs `MouseWheelEvent` / `TextInputEvent` +
      constantes de type ; le runner de WindowPlugin dispatche les events et route molette +
      texte vers `Input` (`mouse_wheel`, `text_input`, `start_text_input`). Vérifié
      (`examples/events_test.cr`, `events_demo.cr`). L'infra permet d'ajouter d'autres types
      (clavier/gamepad événementiels) facilement.
- [ ] **Étendre la couverture** selon les besoins Flock : souris, `SDL_SetAudioStreamGain`,
      `SDL_RumbleGamepad`, events fenêtre (focus/minimize), `SDL_GetVersion`.
- [ ] **Constantes en dur fragiles.** `PIXELFORMAT_RGBA32`, valeurs d'événements… sont figées
      (et little-endian). Binder `SDL_GetVersion` + un spec de sanity ; idéalement un générateur
      depuis les headers (comme wgpu-cr).
- [ ] **Aucun test.** Spec headless minimal (`SDL_Init(0)` + version) pour détecter une casse
      de linking/ABI.

## Prochaines étapes suggérées

- **Axe fiabilité** : (1) libération des ressources + callback d'erreur wgpu, (2) test de
  rendu par readback de pixel, (3) souris.
- **Axe élargissement** : (1) portabilité du linking sdl3-cr (Linux/Windows), (2) rendu de
  texte, (3) matériaux par sprite.
