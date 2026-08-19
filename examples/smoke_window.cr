# Smoke test: SDL3 window -> wgpu surface -> colored clear.
# Validates the platform/rendering bridge (the riskiest part) before building
# the renderer on top. `WGPU_FRAMES=N` quits after N frames (headless test).
#
#   crystal run examples/smoke_window.cr
#   WGPU_FRAMES=3 crystal run examples/smoke_window.cr
require "wgpu"
require "sdl3"

WIDTH  = 800
HEIGHT = 600

abort "SDL_Init failed: #{String.new(LibSDL.get_error)}" unless LibSDL.init(LibSDL::INIT_VIDEO)

flags = LibSDL::WINDOW_METAL | LibSDL::WINDOW_RESIZABLE | LibSDL::WINDOW_HIGH_PIXEL_DENSITY
window = LibSDL.create_window("Flock — smoke", WIDTH, HEIGHT, flags)
abort "SDL_CreateWindow failed: #{String.new(LibSDL.get_error)}" if window.null?

view = LibSDL.metal_create_view(window)
layer = LibSDL.metal_get_layer(view)
abort "SDL_Metal_GetLayer returned null" if layer.null?

# --- wgpu: surface from the CAMetalLayer provided by SDL ---
instance = WGPU.create_instance

source = LibWGPU::SurfaceSourceMetalLayer.new
source.chain.s_type = LibWGPU::SType::SurfaceSourceMetalLayer
source.layer = layer
sdesc = LibWGPU::SurfaceDescriptor.new
sdesc.label = WGPU.empty_string_view
sdesc.next_in_chain = pointerof(source).as(Pointer(LibWGPU::ChainedStruct))
surface = LibWGPU.instance_create_surface(instance, pointerof(sdesc))
abort "instance_create_surface failed" if surface.null?

adapter = WGPU.request_adapter(instance, compatible_surface: surface)
device = WGPU.request_device(instance, adapter)
queue = LibWGPU.device_get_queue(device)

puts "Flock smoke — wgpu-native #{WGPU::NATIVE_VERSION} + SDL3"

caps = LibWGPU::SurfaceCapabilities.new
LibWGPU.surface_get_capabilities(surface, adapter, pointerof(caps))
format = caps.formats[0]
LibWGPU.surface_capabilities_free_members(caps)

LibSDL.get_window_size_in_pixels(window, out fb_w, out fb_h)
config = LibWGPU::SurfaceConfiguration.new
config.device = device
config.format = format
config.usage = LibWGPU::TextureUsage::RenderAttachment
config.width = fb_w.to_u32
config.height = fb_h.to_u32
config.present_mode = LibWGPU::PresentMode::Fifo
config.alpha_mode = LibWGPU::CompositeAlphaMode::Auto
LibWGPU.surface_configure(surface, pointerof(config))

# --- Loop ---
max_frames = ENV["WGPU_FRAMES"]?.try(&.to_i?)
frame = 0
running = true
event = LibSDL::Event.new
puts "Rendering — close the window to quit."

while running
  break if max_frames && frame >= max_frames

  while LibSDL.poll_event(pointerof(event))
    running = false if event.type == LibSDL::EVENT_QUIT
  end

  st = LibWGPU::SurfaceTexture.new
  LibWGPU.surface_get_current_texture(surface, pointerof(st))
  next unless st.status.success_optimal? || st.status.success_suboptimal?

  tview = LibWGPU.texture_create_view(st.texture, Pointer(LibWGPU::TextureViewDescriptor).null)

  color = LibWGPU::RenderPassColorAttachment.new
  color.view = tview
  color.depth_slice = 0xFFFFFFFF_u32
  color.load_op = LibWGPU::LoadOp::Clear
  color.store_op = LibWGPU::StoreOp::Store
  color.clear_value = LibWGPU::Color.new(r: 0.10, g: 0.15, b: 0.30, a: 1.0)

  pass_desc = LibWGPU::RenderPassDescriptor.new
  pass_desc.label = WGPU.empty_string_view
  pass_desc.color_attachment_count = 1_u64
  pass_desc.color_attachments = pointerof(color)

  enc_desc = LibWGPU::CommandEncoderDescriptor.new
  enc_desc.label = WGPU.empty_string_view
  encoder = LibWGPU.device_create_command_encoder(device, pointerof(enc_desc))
  pass = LibWGPU.command_encoder_begin_render_pass(encoder, pointerof(pass_desc))
  LibWGPU.render_pass_encoder_end(pass)

  cmd_desc = LibWGPU::CommandBufferDescriptor.new
  cmd_desc.label = WGPU.empty_string_view
  cmd = LibWGPU.command_encoder_finish(encoder, pointerof(cmd_desc))
  cmds = StaticArray(LibWGPU::CommandBuffer, 1).new(cmd)
  LibWGPU.queue_submit(queue, 1_u64, cmds.to_unsafe)
  LibWGPU.surface_present(surface)

  LibWGPU.command_buffer_release(cmd)
  LibWGPU.render_pass_encoder_release(pass)
  LibWGPU.command_encoder_release(encoder)
  LibWGPU.texture_view_release(tview)
  LibWGPU.texture_release(st.texture)
  frame += 1
end

LibWGPU.surface_release(surface)
LibWGPU.queue_release(queue)
LibWGPU.device_release(device)
LibWGPU.adapter_release(adapter)
LibWGPU.instance_release(instance)
LibSDL.destroy_window(window)
LibSDL.quit
puts "OK (#{frame} frames)"
