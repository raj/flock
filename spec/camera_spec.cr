require "./spec_helper"
require "../src/flock/render/color"
require "../src/flock/render/camera"

# Camera2D#screen_to_world est de la math pure (pas de GPU) : testable en headless.
describe Flock::Camera2D do
  it "centre de l'écran -> position de la caméra" do
    cam = Flock::Camera2D.new(position: Flock::Vec2.new(100, 50))
    w = cam.screen_to_world(Flock::Vec2.new(320, 240), 640.0f32, 480.0f32)
    w.x.should be_close(100.0f32, 1e-3)
    w.y.should be_close(50.0f32, 1e-3)
  end

  it "y écran inversé (haut de l'écran -> monde y positif)" do
    cam = Flock::Camera2D.new
    w = cam.screen_to_world(Flock::Vec2.new(320, 0), 640.0f32, 480.0f32)
    w.y.should be_close(240.0f32, 1e-3)
  end

  it "le zoom réduit l'étendue monde par pixel" do
    cam = Flock::Camera2D.new(zoom: 2.0f32)
    w = cam.screen_to_world(Flock::Vec2.new(640, 240), 640.0f32, 480.0f32)
    w.x.should be_close(160.0f32, 1e-3) # 320 px / zoom 2 = 160 unités
  end
end
