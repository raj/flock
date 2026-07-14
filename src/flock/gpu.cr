# Entrée "complète" de Flock : cœur ECS + couche plateforme (SDL3) + rendu (wgpu).
# Tire les dépendances natives (SDL3 + wgpu-native). Les tests headless requièrent
# `flock` (cœur) et non ce fichier.
require "../flock"                    # cœur (math, ecs, app, time)
require "../../../wgpu-cr/src/wgpu"   # binding wgpu (shard voisin, chemin relatif)
require "../../../sdl3-cr/src/sdl3"   # binding SDL3 (shard voisin, chemin relatif)

require "./platform/gpu_errors"
require "./platform/gpu_context"
require "./platform/window"
require "./platform/input"
require "./platform/audio"

require "./render/color"
require "./render/texture"
require "./render/font"
require "./render/camera"
require "./render/components"
require "./render/shader"
require "./render/material"
require "./render/renderer2d"
require "./render/render_plugin"

require "./default_plugins"
