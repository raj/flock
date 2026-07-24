# Flock — data-oriented game engine in Crystal.
# See plan.md for the overall design.
#
# Phases 1-2 (ECS + math): self-contained, testable without SDL or GPU.
# The platform (SDL3) and rendering (wgpu) layers are required separately once
# implemented (they pull in native dependencies).

require "./flock/math/math3d"
require "./flock/color"
require "./flock/ecs/entity"
require "./flock/ecs/component"
require "./flock/transform"
require "./flock/sprite2d"
require "./flock/keys"                  # Flock::Key enum (shared by native + web input)
require "./flock/render/camera"         # Camera2D/3D + Viewport (backend-agnostic; used by native + web)
require "./flock/render/sprite_shaders" # built-in Sprite2D material shaders (pure strings)
require "./flock/ecs/bundle"
require "./flock/ecs/sparse_set"
require "./flock/ecs/world"
require "./flock/input_map"             # Flock::InputMap(A): logical actions ← keys (portable)
require "./flock/ecs/commands"
require "./flock/ecs/events"
require "./flock/ecs/state"
require "./flock/scene/registry"
require "./flock/scene/scene"

# App / loop / plugins (headless: no native dependency).
require "./flock/app/schedule"
require "./flock/app/plugin"
require "./flock/time"
require "./flock/app/app"
require "./flock/app/parallel"    # opt-in parallel scheduler (Access + wave batching + executor)
require "./flock/hierarchy"        # Parent component + HierarchyPlugin (needs Component, Plugin, Schedule)
require "./flock/scene/save_plugin" # periodic autosave (needs Scene, Plugin, Time)

module Flock
  VERSION = "0.1.0"
end
