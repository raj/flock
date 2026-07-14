# Headless test of event accumulation (mouse wheel + text) in Input.
require "../src/flock/gpu"
input = Flock::Input.new
input.push_wheel(1.0f32, -2.0f32)
input.push_text("Hi")
input.push_text("!")
ok = input.mouse_wheel.x == 1.0f32 && input.mouse_wheel.y == -2.0f32 && input.text_input == "Hi!"
input.clear_frame_events
ok &&= input.mouse_wheel.x == 0.0f32 && input.text_input == ""
puts ok ? "✅ events OK" : "❌ events FAILED"
exit(ok ? 0 : 1)
