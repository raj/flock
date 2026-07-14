# Test headless du cache d'assets : deux `font(path, size)` identiques -> même instance.
require "../src/flock/gpu"

FONT = "/System/Library/Fonts/Supplemental/Arial.ttf"

instance = WGPU.create_instance
adapter = WGPU.request_adapter(instance)
device = Flock.request_device(instance, adapter)
queue = LibWGPU.device_get_queue(device)
gpu = Flock::GpuContext.new(instance, adapter, device, queue,
  WGPU.null(LibWGPU::Surface), LibWGPU::TextureFormat::RGBA8Unorm,
  1_u32, 1_u32, Pointer(Void).null.as(LibSDL::Window), Pointer(Void).null.as(LibSDL::MetalView))

assets = Flock::Assets.new(gpu)
a = assets.font(FONT, 24)
b = assets.font(FONT, 24)  # même clé -> cache
c = assets.font(FONT, 48)  # taille différente -> autre instance

hit = a.same?(b)
distinct = !a.same?(c)
puts "font(24)==font(24) : #{hit}   font(24)!=font(48) : #{distinct}"

assets.release
gpu.release
ok = hit && distinct
puts ok ? "✅ cache d'assets OK" : "❌ cache KO"
exit(ok ? 0 : 1)
