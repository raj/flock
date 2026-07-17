# "Full" entry point of Flock: ECS core + platform layer (SDL3) + rendering (wgpu).
# Pulls in the native dependencies (SDL3 + wgpu-native). Headless tests require
# `flock` (core) and not this file.
require "../flock"                    # core (math, ecs, app, time)
require "../../../wgpu-cr/src/wgpu"   # wgpu binding (neighboring shard, relative path)
require "../../../sdl3-cr/src/sdl3"   # SDL3 binding (neighboring shard, relative path)

require "./platform/gpu_errors"
require "./platform/gpu_context"
require "./platform/window"
require "./platform/input"
require "./platform/audio"
require "./platform/music"

require "./render/texture"
require "./render/font"
require "./render/mesh"
require "./render/gltf_scene"
require "./render/ibl"
require "./render/camera"
require "./render/components"
require "./render/shader"
require "./render/material"
require "./render/renderer2d"
require "./render/render_types"
require "./render/renderer3d"
require "./render/renderer3d_shaders"
require "./render/renderer3d_shadow_post_ibl"
require "./render/renderer3d_skin_morph"
require "./render/render_plugin"

require "./assets"
require "./default_plugins"
