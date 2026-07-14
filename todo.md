# Pistes d'amélioration — Flock & sdl3-cr

Classé par impact. `[ ]` à faire. Concerne `flock/` et le shard voisin `sdl3-cr/`.

## Flock

### Correctness / robustesse (prioritaire)
- [x] **Libérer les ressources GPU.** `Resource#release` (+ ordre) + `World#shutdown` appelé
      par `App#run` ; `GpuContext`/`Renderer2D`/`Material`/`Texture` libèrent leurs handles.
- [ ] **Capturer les erreurs wgpu.** Brancher un callback `uncaptured error` / `device lost`
      (aujourd'hui une erreur de validation passe en silence).
- [ ] **Récupérer une surface perdue.** Décoder le statut de `surface_get_current_texture`
      (transitoire `196609` en 1ʳᵉ frame) et reconfigurer sur `Outdated`/`Lost`, pas seulement
      au resize.
- [x] **Tests de rendu automatisés (readback).** `examples/readback_test.cr` : rendu offscreen
      → `copy_texture_to_buffer` → map → assertions pixel (centre rouge / coin noir), exit 0/1.
      `Renderer2D#render_into` sépare le rendu de l'acquisition de surface. A déjà attrapé un
      bug réel : `Sprite.size` n'était pas appliqué au modèle (quads 1×1).

### Fonctionnalités manquantes
- [ ] **Souris** (position, boutons, molette) — non exposée, bloquant pour UI/jeux.
- [ ] **Rendu de texte / police** (score, HUD) — absent.
- [ ] **Matériaux par sprite** — `Material` ne fait que le plein écran ; le renderer a un seul
      pipeline. Permettre à un `Sprite` de référencer un matériau custom (batch par matériau
      puis texture).
- [ ] **Fixed timestep** (`FixedUpdate` + accumulateur) pour une physique stable.
- [ ] **Événements / états** façon Bevy (`Events` inter-systèmes, machine à états de jeu).
- [ ] **Audio** : `play` crée un stream par lecture et le récupère à `queued==0`, ce qui peut
      couper la fin du son ; ajouter volume (`SDL_SetAudioStreamGain`), musique en boucle, `stop`.

### Confort / archi
- [ ] **Ordre des systèmes** dans un schedule (labels, `before`/`after`, conditions `run_if`).
- [ ] **Asset manager** (cache + handles) au lieu de charger les textures à la main.
- [ ] **Multi-viewport / clear par région** : le clear porte sur toute l'attache → un viewport
      ne peut pas s'effacer dans sa propre couleur (vrai split-screen : scissor ou passes séparées).
- [ ] **Sampler configurable** (linear vs nearest, mipmaps) — actuellement nearest only.
- [ ] **Rendu 3D** de meshes consommant `Camera3D` (la math perspective/look_at est prête).

## sdl3-cr

- [ ] **Portabilité du linking (vrai point faible).** `@[Link]` code en dur `/opt/homebrew/lib`
      → macOS Homebrew uniquement. Passer par `pkg-config sdl3 --libs` (ou `sdl3-config`) et
      prévoir Linux/Windows → Flock pourrait alors viser X11/Wayland/HWND (SDL abstrait la fenêtre).
- [ ] **Exposer les données d'événements.** `Event` est un blob de 128 o dont on ne lit que
      `type` → tout est en polling. Exposer les sous-structs (clavier avec scancode, souris,
      gamepad avec `which`) pour l'entrée événementielle, la saisie de texte, un `just_pressed`
      fiable.
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
