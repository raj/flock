module Flock
  # A group of components spawned together, à la Bevy's `Bundle`. Include the
  # module and implement `components` returning a Tuple of the grouped components;
  # `spawn`/`add` expand it into individual component storages.
  #
  #   struct PlayerBundle
  #     include Flock::Bundle
  #     def initialize(@pos : Flock::Vec2, @speed : Float32)
  #     end
  #
  #     def components
  #       {
  #         Player.new(@speed),
  #         Flock::Transform2D.at(@pos.x, @pos.y),
  #         Flock::Sprite.new(Flock::Vec2.new(60, 20), Flock::Color.new(0.3, 0.9, 0.45)),
  #       }
  #     end
  #   end
  #
  #   cmd.spawn(PlayerBundle.new(pos, 360f32))            # -> Player + Transform2D + Sprite
  #   cmd.spawn(PlayerBundle.new(pos, 360f32), Velocity.new) # bundles mix with components
  #
  # Bundles nest: a bundle whose tuple contains another bundle expands recursively.
  # This is purely a spawn-time convenience — there is no `Bundle` storage; each
  # component still lands in its own `SparseSet`.
  module Bundle
  end
end
