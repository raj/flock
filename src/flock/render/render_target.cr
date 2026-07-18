# Offscreen render target + CPU pixel readback. Wraps the boilerplate of a
# RenderAttachment|CopySrc texture (render a scene into it via
# `Renderer3D#render_into(world, rt.view)`), plus a `read` that copies the
# result back into a dense, CPU-side `Pixels` buffer. Useful for screenshots,
# thumbnails, and headless readback tests.
module Flock
  # A dense (unpadded), CPU-side RGBA8 image: `width * height * 4` bytes with a
  # `width * 4` row stride. Pixel accessors return 0..255 channel values.
  struct Pixels
    getter width : Int32
    getter height : Int32
    getter data : Bytes

    def initialize(@width : Int32, @height : Int32, @data : Bytes)
    end

    # {r, g, b} at (x, y), each 0..255.
    def rgb(x : Int32, y : Int32) : {Int32, Int32, Int32}
      o = (y * @width + x) * 4
      {@data[o].to_i, @data[o + 1].to_i, @data[o + 2].to_i}
    end

    # {r, g, b, a} at (x, y), each 0..255.
    def rgba(x : Int32, y : Int32) : {Int32, Int32, Int32, Int32}
      o = (y * @width + x) * 4
      {@data[o].to_i, @data[o + 1].to_i, @data[o + 2].to_i, @data[o + 3].to_i}
    end
  end

  # An offscreen texture you can render into and read back. `view` is the render
  # attachment to pass to a renderer; `read` returns the current contents.
  class RenderTarget < Resource
    getter texture : LibWGPU::Texture
    getter view : LibWGPU::TextureView
    getter width : UInt32
    getter height : UInt32
    getter format : LibWGPU::TextureFormat

    def initialize(@gpu : GpuContext, width : Int, height : Int,
                   @format : LibWGPU::TextureFormat = LibWGPU::TextureFormat::RGBA8Unorm)
      @width = width.to_u32
      @height = height.to_u32
      td = LibWGPU::TextureDescriptor.new
      td.label = WGPU.empty_string_view
      td.usage = LibWGPU::TextureUsage::RenderAttachment | LibWGPU::TextureUsage::CopySrc
      td.dimension = LibWGPU::TextureDimension::N2D
      td.size = LibWGPU::Extent3D.new(width: @width, height: @height, depth_or_array_layers: 1_u32)
      td.format = @format
      td.mip_level_count = 1_u32
      td.sample_count = 1_u32
      @texture = LibWGPU.device_create_texture(@gpu.device, pointerof(td))
      @view = LibWGPU.texture_create_view(@texture, Pointer(LibWGPU::TextureViewDescriptor).null)
    end

    # Copy the texture to a mappable buffer and return its contents as dense
    # `Pixels` (row padding removed). Assumes an 8-bit-RGBA format.
    def read : Pixels
      # copy_texture_to_buffer requires bytes_per_row aligned to 256.
      unpadded = @width * 4_u32
      padded = ((unpadded + 255_u32) // 256_u32) * 256_u32
      size = (padded * @height).to_u64

      bd = LibWGPU::BufferDescriptor.new
      bd.label = WGPU.empty_string_view
      bd.usage = LibWGPU::BufferUsage::MapRead | LibWGPU::BufferUsage::CopyDst
      bd.size = size
      bd.mapped_at_creation = 0_u32
      buffer = LibWGPU.device_create_buffer(@gpu.device, pointerof(bd))

      src = LibWGPU::TexelCopyTextureInfo.new
      src.texture = @texture
      src.mip_level = 0_u32
      src.origin = LibWGPU::Origin3D.new(x: 0_u32, y: 0_u32, z: 0_u32)
      src.aspect = LibWGPU::TextureAspect::All
      lay = LibWGPU::TexelCopyBufferLayout.new
      lay.offset = 0_u64
      lay.bytes_per_row = padded
      lay.rows_per_image = @height
      dst = LibWGPU::TexelCopyBufferInfo.new
      dst.layout = lay
      dst.buffer = buffer
      ext = LibWGPU::Extent3D.new(width: @width, height: @height, depth_or_array_layers: 1_u32)

      ed = LibWGPU::CommandEncoderDescriptor.new
      ed.label = WGPU.empty_string_view
      enc = LibWGPU.device_create_command_encoder(@gpu.device, pointerof(ed))
      LibWGPU.command_encoder_copy_texture_to_buffer(enc, pointerof(src), pointerof(dst), pointerof(ext))
      cd = LibWGPU::CommandBufferDescriptor.new
      cd.label = WGPU.empty_string_view
      cmd = LibWGPU.command_encoder_finish(enc, pointerof(cd))
      cmds = StaticArray(LibWGPU::CommandBuffer, 1).new(cmd)
      LibWGPU.queue_submit(@gpu.queue, 1_u64, cmds.to_unsafe)

      WGPU.map_buffer_read(@gpu.instance, buffer, size)
      mapped = LibWGPU.buffer_get_mapped_range(buffer, 0_u64, size).as(UInt8*)

      # Densify: drop the per-row padding into a tight width*height*4 buffer.
      dense = Bytes.new((unpadded * @height).to_i)
      @height.times do |row|
        (mapped + (row * padded).to_i).copy_to(dense.to_unsafe + (row * unpadded).to_i, unpadded.to_i)
      end
      LibWGPU.buffer_unmap(buffer)
      LibWGPU.buffer_release(buffer)
      LibWGPU.command_buffer_release(cmd)
      LibWGPU.command_encoder_release(enc)

      Pixels.new(@width.to_i, @height.to_i, dense)
    end

    def release
      LibWGPU.texture_view_release(@view)
      LibWGPU.texture_release(@texture)
    end
  end
end
