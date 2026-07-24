require "./spec_helper"

private enum Act
  Fire
  Jump
  Move
end

# Minimal stand-in for a backend Flock::Input (InputMap#update only needs pressed?).
private class StubInput
  @down = Set(Flock::Key).new

  def press(k : Flock::Key) : Nil
    @down << k
  end

  def release(k : Flock::Key) : Nil
    @down.delete k
  end

  def pressed?(k : Flock::Key) : Bool
    @down.includes?(k)
  end
end

describe Flock::InputMap do
  it "maps keys to actions and reports pressed state" do
    inp = StubInput.new
    map = Flock::InputMap(Act).new
    map.bind(Act::Fire, Flock::Key::Space)

    map.update(inp)
    map.pressed?(Act::Fire).should be_false

    inp.press(Flock::Key::Space)
    map.update(inp)
    map.pressed?(Act::Fire).should be_true
  end

  it "derives just_pressed / just_released edges across frames" do
    inp = StubInput.new
    map = Flock::InputMap(Act).new
    map.bind(Act::Jump, Flock::Key::W)

    inp.press(Flock::Key::W)
    map.update(inp)
    map.just_pressed?(Act::Jump).should be_true
    map.just_released?(Act::Jump).should be_false

    map.update(inp) # still held → no edge
    map.just_pressed?(Act::Jump).should be_false
    map.pressed?(Act::Jump).should be_true

    inp.release(Flock::Key::W)
    map.update(inp)
    map.just_released?(Act::Jump).should be_true
    map.pressed?(Act::Jump).should be_false
  end

  it "binds multiple keys to one action (any pressed activates)" do
    inp = StubInput.new
    map = Flock::InputMap(Act).new
    map.bind(Act::Fire, Flock::Key::Space, Flock::Key::Return)

    inp.press(Flock::Key::Return)
    map.update(inp)
    map.pressed?(Act::Fire).should be_true
  end

  it "computes a -1/0/+1 axis from a key pair" do
    inp = StubInput.new
    map = Flock::InputMap(Act).new
    map.bind_axis(Act::Move, Flock::Key::Left, Flock::Key::Right)

    map.update(inp)
    map.axis(Act::Move).should eq(0.0f32)

    inp.press(Flock::Key::Right)
    map.update(inp)
    map.axis(Act::Move).should eq(1.0f32)
    map.pressed?(Act::Move).should be_true # non-zero axis counts as pressed
    map.just_pressed?(Act::Move).should be_true

    inp.press(Flock::Key::Left) # both → cancel
    map.update(inp)
    map.axis(Act::Move).should eq(0.0f32)
    map.just_released?(Act::Move).should be_true

    inp.release(Flock::Key::Right)
    map.update(inp)
    map.axis(Act::Move).should eq(-1.0f32)
  end
end
