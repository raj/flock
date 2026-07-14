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

    def release : Nil
      LibWGPU.texture_view_release(@view)
      LibWGPU.texture_release(@texture)
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

    # Charge une image (PNG, JPG…) via SDL_image, convertie en RGBA8.
    def self.load(gpu : GpuContext, path : String) : Texture
      raw = LibSDL.img_load(path.to_unsafe)
      raise "IMG_Load #{path}: #{String.new(LibSDL.get_error)}" if raw.null?

      conv = LibSDL.convert_surface(raw, LibSDL::PIXELFORMAT_RGBA32)
      LibSDL.destroy_surface(raw)
      raise "SDL_ConvertSurface #{path}: #{String.new(LibSDL.get_error)}" if conv.null?

      s = conv.value
      w = s.w
      h = s.h
      pitch = s.pitch
      src = s.pixels.as(UInt8*)

      # Recopie compacte (les lignes SDL peuvent être paddées : pitch >= w*4).
      row_bytes = w * 4
      pixels = Bytes.new(h * row_bytes)
      h.times do |row|
        (pixels.to_unsafe + row * row_bytes).copy_from(src + row * pitch, row_bytes)
      end
      LibSDL.destroy_surface(conv)

      from_pixels(gpu, w, h, pixels)
    end
  end
end
