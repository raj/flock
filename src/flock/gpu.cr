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
require "./render/render_target"
require "./render/font"
require "./render/mesh"
require "./render/gltf_scene"
require "./render/ibl"
require "./render/components"
require "./render/shader"
require "./render/material"
require "./render/renderer2d"
require "./render/glyph_atlas"
require "./render/text_label"
require "./render/render_types"
require "./render/post"         # modular post-processing stack (FullscreenPass + effects + PostStack)
require "./render/render_graph" # declarative render graph (named resources + nodes + auto-alias)
require "./render/renderer3d"
require "./render/renderer3d_shaders"
require "./render/renderer3d_shadow_post_ibl"
require "./render/renderer3d_skin_morph"
require "./render/render_plugin"

require "./pack"                 # Flock::Pack / PackWriter — .flkpack asset archives (native)
require "./assets"
require "./render/text_provider" # Flock::Text facade (needs GpuContext/Renderer2D/Assets)
require "./render/materials"     # Flock::Materials registry (needs Renderer2D)
require "./diagnostics"
require "./default_plugins"
