module Flock
  # Screen sub-region a camera renders into, in pixels (nil = full framebuffer).
  struct Viewport
    property x : Float32
    property y : Float32
    property width : Float32
    property height : Float32

    def initialize(@x : Float32, @y : Float32, @width : Float32, @height : Float32)
    end

    # Intersection with a framebuffer of `fw`×`fh` pixels. wgpu rejects viewport/scissor
    # rects that extend past the target (validation error → dropped frame), so renderers
    # clamp before setting them. Returns nil when nothing remains (fully off-screen).
    def clamp(fw : UInt32, fh : UInt32) : Viewport?
      x0 = Math.max(@x, 0.0f32)
      y0 = Math.max(@y, 0.0f32)
      x1 = Math.min(@x + @width, fw.to_f32)
      y1 = Math.min(@y + @height, fh.to_f32)
      return nil if x1 <= x0 || y1 <= y0
      Viewport.new(x0, y0, x1 - x0, y1 - y0)
    end
  end

  # Orthographic 2D camera. `position` is the world point at the center of the view,
  # `zoom` > 1 zooms in, `rotation` in radians. World space in pixels by default
  # (1 unit = 1 pixel at zoom 1).
  struct Camera2D
    include Component
    property position : Vec2
    property zoom : Float32
    property rotation : Float32
    property viewport : Viewport?
    property order : Int32
    property clear_color : Color?
    property active : Bool
    # Which window renders this camera (0 = primary; a secondary window's `slot` otherwise).
    property window : Int32

    def initialize(@position : Vec2 = Vec2.new, @zoom : Float32 = 1.0f32,
                   @rotation : Float32 = 0.0f32, @viewport : Viewport? = nil,
                   @order : Int32 = 0, @clear_color : Color? = Color::BLACK,
                   @active : Bool = true, @window : Int32 = 0)
    end

    # Converts a screen position (framebuffer pixels, top-left origin) into
    # world coordinates. Analytic inverse of `view_projection` (pan/zoom/rotation).
    # For a sub-viewport camera, `view_projection` is built from the viewport's
    # size (see renderer2d.cr), so the inverse must map relative to the viewport's
    # origin and dimensions rather than the whole framebuffer.
    def screen_to_world(screen : Vec2, fb_w : Float32, fb_h : Float32) : Vec2
      vp = @viewport
      ox = vp ? vp.x : 0.0f32
      oy = vp ? vp.y : 0.0f32
      vw = vp ? vp.width : fb_w
      vh = vp ? vp.height : fb_h
      dx = (screen.x - ox) - vw * 0.5f32
      dy = (screen.y - oy) - vh * 0.5f32
      vx = dx / @zoom
      vy = -dy / @zoom # screen y downward -> world y upward
      c = Math.cos(@rotation)
      s = Math.sin(@rotation)
      wx = (c * vx - s * vy).to_f32
      wy = (s * vx + c * vy).to_f32
      Vec2.new(@position.x + wx, @position.y + wy)
    end

    # View-projection matrix for a target of dimensions (w, h) in pixels.
    def view_projection(w : Float32, h : Float32) : Mat4
      hw = (w * 0.5f32) / @zoom
      hh = (h * 0.5f32) / @zoom
      proj = Mat4.orthographic(-hw, hw, -hh, hh, -1.0, 1.0)
      view = Mat4.rotation_z(-@rotation) * Mat4.translation(Vec3.new(-@position.x, -@position.y, 0))
      proj * view
    end
  end

  # Perspective 3D camera. Provided for the abstraction; rendering of 3D meshes that
  # consume it comes in a later phase.
  struct Camera3D
    include Component
    property position : Vec3
    property target : Vec3
    property up : Vec3
    property fov_y : Float32
    property near : Float32
    property far : Float32
    property viewport : Viewport?
    property order : Int32
    property clear_color : Color?
    property active : Bool
    # Which window renders this camera (0 = primary; a secondary window's `slot` otherwise).
    property window : Int32

    def initialize(@position : Vec3 = Vec3.new(0, 0, 5), @target : Vec3 = Vec3.new,
                   @up : Vec3 = Vec3.new(0, 1, 0), @fov_y : Float32 = 1.0f32,
                   @near : Float32 = 0.1f32, @far : Float32 = 1000.0f32,
                   @viewport : Viewport? = nil, @order : Int32 = 0,
                   @clear_color : Color? = Color::BLACK, @active : Bool = true, @window : Int32 = 0)
    end

    def view_projection(aspect : Float32) : Mat4
      proj = Mat4.perspective(@fov_y, aspect, @near, @far)
      view = Mat4.look_at(@position, @target, @up)
      proj * view
    end
  end

  # Orbit (arcball-style) controller for a Camera3D: keeps the camera looking at `target`
  # while it orbits at `distance` with `yaw`/`pitch` (radians). Input-agnostic — drive it
  # from your input each frame, then write it into the camera:
  #
  #   orbit.rotate(input.mouse_wheel.x * 0.01, 0)      # or mouse-drag deltas
  #   orbit.dolly(1.0 - input.mouse_wheel.y * 0.1)
  #   world.query(Camera3D) { |_e, cam| orbit.apply(cam) }
  struct OrbitCamera
    property target : Vec3
    property distance : Float32
    property yaw : Float32
    property pitch : Float32
    property min_pitch : Float32
    property max_pitch : Float32
    property min_distance : Float32
    property max_distance : Float32

    def initialize(@target : Vec3 = Vec3.new, @distance : Float32 = 5.0f32,
                   @yaw : Float32 = 0.0f32, @pitch : Float32 = 0.3f32,
                   @min_pitch : Float32 = -1.5f32, @max_pitch : Float32 = 1.5f32,
                   @min_distance : Float32 = 0.5f32, @max_distance : Float32 = 100.0f32)
    end

    # Accumulates orbit angles; pitch is clamped to avoid flipping over the poles.
    def rotate(dyaw : Number, dpitch : Number) : Nil
      @yaw += dyaw.to_f32
      @pitch = (@pitch + dpitch.to_f32).clamp(@min_pitch, @max_pitch)
    end

    # Multiplies the orbit distance (factor < 1 zooms in), clamped to [min, max].
    def dolly(factor : Number) : Nil
      @distance = (@distance * factor.to_f32).clamp(@min_distance, @max_distance)
    end

    # The camera eye position for the current orbit angles/distance.
    def eye : Vec3
      cp = Math.cos(@pitch); sp = Math.sin(@pitch)
      cy = Math.cos(@yaw); sy = Math.sin(@yaw)
      @target + Vec3.new(@distance * cp * sy, @distance * sp, @distance * cp * cy)
    end

    # Writes eye + target into a Camera3D (via the query pointer).
    def apply(cam : Pointer(Camera3D)) : Nil
      cam.value.position = eye
      cam.value.target = @target
    end
  end

  # First-person fly controller for a Camera3D: free `position` with `yaw`/`pitch` look
  # (radians). Input-agnostic:
  #
  #   fly.look(dx * 0.003, -dy * 0.003)                    # mouse look
  #   fly.move(fwd, right, up, dt)                         # keyboard axes in [-1, 1]
  #   world.query(Camera3D) { |_e, cam| fly.apply(cam) }
  struct FlyCamera
    property position : Vec3
    property yaw : Float32
    property pitch : Float32
    property speed : Float32
    property min_pitch : Float32
    property max_pitch : Float32

    def initialize(@position : Vec3 = Vec3.new(0, 0, 5), @yaw : Float32 = 0.0f32,
                   @pitch : Float32 = 0.0f32, @speed : Float32 = 5.0f32,
                   @min_pitch : Float32 = -1.5f32, @max_pitch : Float32 = 1.5f32)
    end

    def look(dyaw : Number, dpitch : Number) : Nil
      @yaw += dyaw.to_f32
      @pitch = (@pitch + dpitch.to_f32).clamp(@min_pitch, @max_pitch)
    end

    # Forward (view) direction. Faces -Z at yaw = pitch = 0 (matches look_at convention).
    def forward : Vec3
      cp = Math.cos(@pitch); sp = Math.sin(@pitch)
      cy = Math.cos(@yaw); sy = Math.sin(@yaw)
      Vec3.new(cp * sy, sp, -cp * cy).normalize
    end

    # The rightward direction on the ground plane (world up = +Y).
    def right : Vec3
      forward.cross(Vec3.new(0, 1, 0)).normalize
    end

    # Moves along the local basis: `fwd`/`rgt`/`up` in [-1, 1], scaled by speed * dt.
    def move(fwd : Number, rgt : Number, up : Number, dt : Number) : Nil
      step = @speed * dt.to_f32
      @position = @position + forward * (fwd.to_f32 * step) +
                  right * (rgt.to_f32 * step) + Vec3.new(0, 1, 0) * (up.to_f32 * step)
    end

    def apply(cam : Pointer(Camera3D)) : Nil
      cam.value.position = @position
      cam.value.target = @position + forward
    end
  end
end
