module Flock
  # Texture GPU 2D (RGBA8). Créée depuis un tableau de pixels (procédural) — le
  # chargement PNG via SDL_image s'ajoute par-dessus (voir `Texture.load`).
  class Texture
    getter texture : LibWGPU::Texture
    getter view : LibWGPU::TextureView
    getter width : UInt32
    getter height : UInt32

    def initialize(@texture : LibWGPU::Texture, @view : LibWGPU::TextureView,
                   @width : UInt32, @height : UInt32)
    end

    # `pixels` : RGBA8, `width * height * 4` octets, ligne par ligne.
    def self.from_pixels(gpu : GpuContext, width : Int, height : Int, pixels : Bytes) : Texture
      w = width.to_u32
      h = height.to_u32

      desc = LibWGPU::TextureDescriptor.new
      desc.label = WGPU.empty_string_view
      desc.usage = LibWGPU::TextureUsage::TextureBinding | LibWGPU::TextureUsage::CopyDst
      desc.dimension = LibWGPU::TextureDimension::N2D
      desc.size = LibWGPU::Extent3D.new(width: w, height: h, depth_or_array_layers: 1_u32)
      desc.format = LibWGPU::TextureFormat::RGBA8Unorm
      desc.mip_level_count = 1_u32
      desc.sample_count = 1_u32
      tex = LibWGPU.device_create_texture(gpu.device, pointerof(desc))

      dest = LibWGPU::TexelCopyTextureInfo.new
      dest.texture = tex
      dest.mip_level = 0_u32
      dest.origin = LibWGPU::Origin3D.new(x: 0_u32, y: 0_u32, z: 0_u32)
      dest.aspect = LibWGPU::TextureAspect::All

      layout = LibWGPU::TexelCopyBufferLayout.new
      layout.offset = 0_u64
      layout.bytes_per_row = w * 4_u32
      layout.rows_per_image = h

      ext = LibWGPU::Extent3D.new(width: w, height: h, depth_or_array_layers: 1_u32)
      LibWGPU.queue_write_texture(gpu.queue, pointerof(dest),
        pixels.to_unsafe.as(Void*), pixels.size.to_u64, pointerof(layout), pointerof(ext))

      view = LibWGPU.texture_create_view(tex, Pointer(LibWGPU::TextureViewDescriptor).null)
      Texture.new(tex, view, w, h)
    end

    # Texture blanche 1x1 : sprite sans texture = couleur pleine (texture * teinte).
    def self.white(gpu : GpuContext) : Texture
      from_pixels(gpu, 1, 1, Bytes[255_u8, 255_u8, 255_u8, 255_u8])
    end
  end
end
