require "json"

module Flock
  struct Color
    include JSON::Serializable
    property r : Float32
    property g : Float32
    property b : Float32
    property a : Float32

    def initialize(r : Number = 0, g : Number = 0, b : Number = 0, a : Number = 1)
      @r = r.to_f32; @g = g.to_f32; @b = b.to_f32; @a = a.to_f32
    end

    def self.rgb(r : Number, g : Number, b : Number) : Color
      Color.new(r / 255.0, g / 255.0, b / 255.0, 1.0)
    end

    WHITE = Color.new(1, 1, 1, 1)
    BLACK = Color.new(0, 0, 0, 1)
    RED   = Color.new(1, 0, 0, 1)
    GREEN = Color.new(0, 1, 0, 1)
    BLUE  = Color.new(0, 0, 1, 1)
  end
end
