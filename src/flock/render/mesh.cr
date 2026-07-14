module Flock
  # A GPU mesh: interleaved vertex buffer (position + normal + color, 9 floats /
  # 36 bytes per vertex) + a UInt32 index buffer. Consumed by Renderer3D through a
  # `MeshRenderer` component.
  class Mesh
    STRIDE = 36_u64 # 9 f32 (pos3 + normal3 + color3)

    getter vertex_buf : LibWGPU::Buffer
    getter index_buf : LibWGPU::Buffer
    getter index_count : UInt32
    getter vertex_bytes : UInt64
    getter index_bytes : UInt64

    def initialize(@vertex_buf : LibWGPU::Buffer, @index_buf : LibWGPU::Buffer,
                   @index_count : UInt32, @vertex_bytes : UInt64, @index_bytes : UInt64)
    end

    # Uploads interleaved vertices (pos.xyz, normal.xyz, color.rgb per vertex) + indices.
    def self.build(gpu : GpuContext, vertices : Array(Float32), indices : Array(UInt32)) : Mesh
      vbuf = make_buffer(gpu, (vertices.size * 4).to_u64,
        LibWGPU::BufferUsage::Vertex | LibWGPU::BufferUsage::CopyDst)
      LibWGPU.queue_write_buffer(gpu.queue, vbuf, 0_u64, vertices.to_unsafe.as(Void*), (vertices.size * 4).to_u64)

      ibuf = make_buffer(gpu, (indices.size * 4).to_u64,
        LibWGPU::BufferUsage::Index | LibWGPU::BufferUsage::CopyDst)
      LibWGPU.queue_write_buffer(gpu.queue, ibuf, 0_u64, indices.to_unsafe.as(Void*), (indices.size * 4).to_u64)

      new(vbuf, ibuf, indices.size.to_u32, (vertices.size * 4).to_u64, (indices.size * 4).to_u64)
    end

    # Unit cube centered at the origin, with per-face normals for flat shading.
    def self.cube(gpu : GpuContext, color : Color = Color::WHITE) : Mesh
      r, g, b = color.r, color.g, color.b
      # {normal, [4 corners]} per face.
      faces = [
        { {0.0, 0.0, 1.0}, [{-0.5, -0.5, 0.5}, {0.5, -0.5, 0.5}, {0.5, 0.5, 0.5}, {-0.5, 0.5, 0.5}] },
        { {0.0, 0.0, -1.0}, [{0.5, -0.5, -0.5}, {-0.5, -0.5, -0.5}, {-0.5, 0.5, -0.5}, {0.5, 0.5, -0.5}] },
        { {1.0, 0.0, 0.0}, [{0.5, -0.5, 0.5}, {0.5, -0.5, -0.5}, {0.5, 0.5, -0.5}, {0.5, 0.5, 0.5}] },
        { {-1.0, 0.0, 0.0}, [{-0.5, -0.5, -0.5}, {-0.5, -0.5, 0.5}, {-0.5, 0.5, 0.5}, {-0.5, 0.5, -0.5}] },
        { {0.0, 1.0, 0.0}, [{-0.5, 0.5, 0.5}, {0.5, 0.5, 0.5}, {0.5, 0.5, -0.5}, {-0.5, 0.5, -0.5}] },
        { {0.0, -1.0, 0.0}, [{-0.5, -0.5, -0.5}, {0.5, -0.5, -0.5}, {0.5, -0.5, 0.5}, {-0.5, -0.5, 0.5}] },
      ]

      verts = [] of Float32
      indices = [] of UInt32
      faces.each do |(normal, corners)|
        base = (verts.size // 9).to_u32
        corners.each do |c|
          verts.push(c[0].to_f32, c[1].to_f32, c[2].to_f32,
            normal[0].to_f32, normal[1].to_f32, normal[2].to_f32, r, g, b)
        end
        indices.push(base, base + 1, base + 2, base, base + 2, base + 3)
      end
      build(gpu, verts, indices)
    end

    def release : Nil
      LibWGPU.buffer_release(@vertex_buf)
      LibWGPU.buffer_release(@index_buf)
    end

    private def self.make_buffer(gpu : GpuContext, size : UInt64, usage : LibWGPU::BufferUsage) : LibWGPU::Buffer
      d = LibWGPU::BufferDescriptor.new
      d.label = WGPU.empty_string_view
      d.usage = usage
      d.size = size
      d.mapped_at_creation = 0_u32
      LibWGPU.device_create_buffer(gpu.device, pointerof(d))
    end
  end
end
