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
require "./flock/ecs/bundle"
require "./flock/ecs/sparse_set"
require "./flock/ecs/world"
require "./flock/ecs/commands"
require "./flock/ecs/events"
require "./flock/ecs/state"

# App / loop / plugins (headless: no native dependency).
require "./flock/app/schedule"
require "./flock/app/plugin"
require "./flock/time"
require "./flock/app/app"

module Flock
  VERSION = "0.1.0"
end
