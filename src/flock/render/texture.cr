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

    # Full mip chain length for a `w x h` texture: floor(log2(max(w, h))) + 1.
    def self.mip_levels(w : UInt32, h : UInt32) : UInt32
      n = 1_u32
      d = Math.max(w, h)
      while d > 1
        d //= 2
        n += 1
      end
      n
    end

    # Box-downsamples an RGBA8 image to (dw x dh) by averaging each 2x2 source block.
    private def self.downsample(src : Bytes, sw : UInt32, sh : UInt32, dw : UInt32, dh : UInt32) : Bytes
      out = Bytes.new(dw.to_i * dh.to_i * 4)
      dh.times do |y|
        y0 = y * 2
        y1 = Math.min(y0 + 1, sh - 1)
        dw.times do |x|
          x0 = x * 2
          x1 = Math.min(x0 + 1, sw - 1)
          o = (y.to_i * dw.to_i + x.to_i) * 4
          4.times do |c|
            a = src[(y0.to_i * sw.to_i + x0.to_i) * 4 + c].to_u32
            b = src[(y0.to_i * sw.to_i + x1.to_i) * 4 + c].to_u32
            d = src[(y1.to_i * sw.to_i + x0.to_i) * 4 + c].to_u32
            e = src[(y1.to_i * sw.to_i + x1.to_i) * 4 + c].to_u32
            out[o + c] = ((a + b + d + e + 2) // 4).to_u8
          end
        end
      end
      out
    end

    # Uploads one mip level's RGBA8 pixels into `tex`.
    private def self.write_level(gpu : GpuContext, tex : LibWGPU::Texture, level : UInt32,
                                 w : UInt32, h : UInt32, pixels : Bytes) : Nil
      dest = LibWGPU::TexelCopyTextureInfo.new
      dest.texture = tex
      dest.mip_level = level
      dest.origin = LibWGPU::Origin3D.new(x: 0_u32, y: 0_u32, z: 0_u32)
      dest.aspect = LibWGPU::TextureAspect::All
      layout = LibWGPU::TexelCopyBufferLayout.new
      layout.offset = 0_u64
      layout.bytes_per_row = w * 4_u32
      layout.rows_per_image = h
      ext = LibWGPU::Extent3D.new(width: w, height: h, depth_or_array_layers: 1_u32)
      LibWGPU.queue_write_texture(gpu.queue, pointerof(dest),
        pixels.to_unsafe.as(Void*), pixels.size.to_u64, pointerof(layout), pointerof(ext))
    end

    # `pixels`: RGBA8, `width * height * 4` bytes, row by row. When `mipmaps` is true a full
    # box-filtered mip chain is generated on the CPU and uploaded (reduces minification
    # aliasing for textures viewed at a distance / small on screen).
    def self.from_pixels(gpu : GpuContext, width : Int, height : Int, pixels : Bytes,
                         filter : SamplerFilter = SamplerFilter::Nearest,
                         wrap : SamplerWrap = SamplerWrap::Clamp,
                         mipmaps : Bool = false) : Texture
      w = width.to_u32
      h = height.to_u32
      levels = mipmaps ? mip_levels(w, h) : 1_u32

      desc = LibWGPU::TextureDescriptor.new
      desc.label = WGPU.empty_string_view
      desc.usage = LibWGPU::TextureUsage::TextureBinding | LibWGPU::TextureUsage::CopyDst
      desc.dimension = LibWGPU::TextureDimension::N2D
      desc.size = LibWGPU::Extent3D.new(width: w, height: h, depth_or_array_layers: 1_u32)
      desc.format = LibWGPU::TextureFormat::RGBA8Unorm
      desc.mip_level_count = levels
      desc.sample_count = 1_u32
      tex = LibWGPU.device_create_texture(gpu.device, pointerof(desc))

      write_level(gpu, tex, 0_u32, w, h, pixels)
      # Successively halve the previous level to fill the rest of the chain.
      cur = pixels
      cw = w
      ch = h
      (1_u32...levels).each do |lvl|
        nw = Math.max(1_u32, cw // 2)
        nh = Math.max(1_u32, ch // 2)
        cur = downsample(cur, cw, ch, nw, nh)
        write_level(gpu, tex, lvl, nw, nh, cur)
        cw = nw
        ch = nh
      end

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
                          wrap : SamplerWrap = SamplerWrap::Clamp,
                          mipmaps : Bool = false) : Texture
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
      from_pixels(gpu, w, h, pixels, filter, wrap, mipmaps)
    end

    # Loads an image (PNG, JPG…) via SDL_image, converted to RGBA8. Real images get a mip
    # chain by default (set `mipmaps: false` for crisp pixel-art / UI).
    def self.load(gpu : GpuContext, path : String,
                  filter : SamplerFilter = SamplerFilter::Nearest,
                  wrap : SamplerWrap = SamplerWrap::Clamp,
                  mipmaps : Bool = true) : Texture
      raw = LibSDL.img_load(path.to_unsafe)
      raise "IMG_Load #{path}: #{String.new(LibSDL.get_error)}" if raw.null?
      tex = from_surface(gpu, raw, filter, wrap, mipmaps)
      LibSDL.destroy_surface(raw)
      tex
    end

    # Decodes an image held in memory (PNG/JPG… bytes, e.g. an embedded glTF texture)
    # via SDL_image, converted to RGBA8. Mipmapped by default (3D surface textures).
    def self.from_encoded(gpu : GpuContext, data : Bytes,
                          filter : SamplerFilter = SamplerFilter::Linear,
                          wrap : SamplerWrap = SamplerWrap::Repeat,
                          mipmaps : Bool = true) : Texture
      io = LibSDL.io_from_const_mem(data.to_unsafe.as(Void*), data.size)
      raise "SDL_IOFromConstMem: #{String.new(LibSDL.get_error)}" if io.null?
      raw = LibSDL.img_load_io(io, true) # closeio: frees the stream
      raise "IMG_Load_IO: #{String.new(LibSDL.get_error)}" if raw.null?
      tex = from_surface(gpu, raw, filter, wrap, mipmaps)
      LibSDL.destroy_surface(raw)
      tex
    end
  end
end
