module Flock
  # Texture sampling: magnification/minification filter and wrap mode. `Nearest` is
  # crisp (pixel-art), `Linear` is smooth. Chosen per texture; the renderer builds and
  # caches a matching GPU sampler.
  enum SamplerFilter
    Nearest
    Linear
  end

  enum SamplerWrap
    Clamp  # ClampToEdge
    Repeat
  end

  # 2D GPU texture (RGBA8). Created from a pixel array (procedural) — PNG loading
  # via SDL_image builds on top (see `Texture.load`).
  class Texture
    getter texture : LibWGPU::Texture
    getter view : LibWGPU::TextureView
    getter width : UInt32
    getter height : UInt32
    getter filter : SamplerFilter
    getter wrap : SamplerWrap

    def initialize(@texture : LibWGPU::Texture, @view : LibWGPU::TextureView,
                   @width : UInt32, @height : UInt32,
                   @filter : SamplerFilter = SamplerFilter::Nearest, @wrap : SamplerWrap = SamplerWrap::Clamp)
    end

    def release : Nil
      LibWGPU.texture_view_release(@view)
      LibWGPU.texture_release(@texture)
    end

    # `pixels`: RGBA8, `width * height * 4` bytes, row by row.
    def self.from_pixels(gpu : GpuContext, width : Int, height : Int, pixels : Bytes,
                         filter : SamplerFilter = SamplerFilter::Nearest,
                         wrap : SamplerWrap = SamplerWrap::Clamp) : Texture
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
      Texture.new(tex, view, w, h, filter, wrap)
    end

    # 1x1 white texture: sprite with no texture = solid color (texture * tint).
    def self.white(gpu : GpuContext) : Texture
      from_pixels(gpu, 1, 1, Bytes[255_u8, 255_u8, 255_u8, 255_u8])
    end

    # Creates a texture from an SDL_Surface (converted to RGBA8). Does NOT free
    # `surf` (the caller retains ownership). Reused by image loading
    # (SDL_image) and text rendering (SDL_ttf).
    def self.from_surface(gpu : GpuContext, surf : Pointer(LibSDL::Surface),
                          filter : SamplerFilter = SamplerFilter::Nearest,
                          wrap : SamplerWrap = SamplerWrap::Clamp) : Texture
      conv = LibSDL.convert_surface(surf, LibSDL::PIXELFORMAT_RGBA32)
      raise "SDL_ConvertSurface: #{String.new(LibSDL.get_error)}" if conv.null?

      s = conv.value
      w = s.w
      h = s.h
      pitch = s.pitch
      src = s.pixels.as(UInt8*)

      # Compact copy (SDL rows may be padded: pitch >= w*4).
      row_bytes = w * 4
      pixels = Bytes.new(h * row_bytes)
      h.times do |row|
        (pixels.to_unsafe + row * row_bytes).copy_from(src + row * pitch, row_bytes)
      end
      LibSDL.destroy_surface(conv)
      from_pixels(gpu, w, h, pixels, filter, wrap)
    end

    # Loads an image (PNG, JPG…) via SDL_image, converted to RGBA8.
    def self.load(gpu : GpuContext, path : String,
                  filter : SamplerFilter = SamplerFilter::Nearest,
                  wrap : SamplerWrap = SamplerWrap::Clamp) : Texture
      raw = LibSDL.img_load(path.to_unsafe)
      raise "IMG_Load #{path}: #{String.new(LibSDL.get_error)}" if raw.null?
      tex = from_surface(gpu, raw, filter, wrap)
      LibSDL.destroy_surface(raw)
      tex
    end
  end
end
