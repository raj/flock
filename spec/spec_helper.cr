require "spec"
require "../src/flock"

# Shared test components.
struct Position
  include Flock::Component
  property x : Float64
  property y : Float64

  def initialize(@x : Float64 = 0.0, @y : Float64 = 0.0)
  end
end

struct Velocity
  include Flock::Component
  property dx : Float64
  property dy : Float64

  def initialize(@dx : Float64 = 0.0, @dy : Float64 = 0.0)
  end
end

struct Tag
  include Flock::Component
  property name : String

  def initialize(@name : String)
  end
end
