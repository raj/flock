module Flock
  # Ordered stages of the game loop. Systems are grouped by schedule and run in
  # this order every frame (Startup only once at startup).
  enum Schedule
    Startup     # once, before the loop
    First       # start of frame (e.g. input collection)
    FixedUpdate # fixed timestep: 0..N times per frame (stable physics)
    Update      # game logic (once per frame)
    Render      # rendering
    Last        # end of frame (cleanup)
  end
end
