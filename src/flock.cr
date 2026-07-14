# Flock — moteur de jeu orienté données en Crystal.
# Voir plan.md pour la conception d'ensemble.
#
# Phase 1-2 (ECS + math) : autoportantes, testables sans SDL ni GPU.
# Les couches plateforme (SDL3) et rendu (wgpu) sont requises séparément une fois
# implémentées (elles tirent des dépendances natives).

require "./flock/math/math3d"
require "./flock/ecs/entity"
require "./flock/ecs/component"
require "./flock/ecs/sparse_set"
require "./flock/ecs/world"
require "./flock/ecs/commands"

# App / boucle / plugins (headless : aucune dépendance native).
require "./flock/app/schedule"
require "./flock/app/plugin"
require "./flock/time"
require "./flock/app/app"

module Flock
  VERSION = "0.1.0"
end
