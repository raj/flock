require "./spec_helper"

describe Flock::SpriteSheet do
  it "maps frame index → UV sub-rect (row-major)" do
    s = Flock::SpriteSheet.new(cols: 4, rows: 2) # 8 frames, each 0.25 × 0.5
    umin, usize = s.uv(0)
    umin.x.should eq(0.0f32); umin.y.should eq(0.0f32)
    usize.x.should eq(0.25f32); usize.y.should eq(0.5f32)

    umin2, _ = s.uv(5) # col 1, row 1
    umin2.x.should eq(0.25f32); umin2.y.should eq(0.5f32)
  end
end

describe Flock::SpriteAnimation do
  sheet = Flock::SpriteSheet.new(cols: 4, rows: 1)

  it "advances one frame per 1/fps seconds" do
    a = Flock::SpriteAnimation.new(sheet, [0, 1, 2, 3], fps: 10) # 0.1 s/frame
    a.current.should eq(0)
    a.step(0.05f32)
    a.current.should eq(0) # not enough time yet
    a.step(0.06f32)        # total 0.11 → one step
    a.current.should eq(1)
    a.step(0.30f32) # +3 frames → wraps (loop) 1→2→3→0
    a.current.should eq(0)
  end

  it "stops at the last frame when not looping" do
    a = Flock::SpriteAnimation.new(sheet, [0, 1, 2], fps: 10, loops: false)
    a.step(1.0f32) # way past the end
    a.current.should eq(2)
    a.playing.should be_false
  end

  it "ping-pongs (bounces at the ends)" do
    a = Flock::SpriteAnimation.new(sheet, [0, 1, 2], fps: 100, ping_pong: true)
    seq = [] of Int32
    12.times { a.step(0.01f32); seq << a.current }
    # 0 →1→2→1→0→1→2→1→0→1→2→1→0
    seq.first(8).should eq([1, 2, 1, 0, 1, 2, 1, 0])
  end

  it "maps the current frame to the sheet UV" do
    a = Flock::SpriteAnimation.new(sheet, [0, 2], fps: 10)
    a.step(0.11f32) # → frame index 1 in the list = sheet frame 2
    umin, _ = a.uv
    umin.x.should eq(0.5f32) # col 2 of 4
  end
end
