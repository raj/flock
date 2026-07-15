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

    # UV sphere of the given radius, centered at the origin. `segments` = longitude
    # divisions, `rings` = latitude divisions. Smooth normals (= normalized position).
    def self.sphere(gpu : GpuContext, radius : Float64 = 0.5, segments : Int32 = 32,
                    rings : Int32 = 16, color : Color = Color::WHITE) : Mesh
      r, g, b = color.r, color.g, color.b
      verts = [] of Float32
      indices = [] of UInt32

      (0..rings).each do |y|
        v = y.to_f / rings
        phi = v * Math::PI # 0..pi (pole to pole)
        (0..segments).each do |x|
          u = x.to_f / segments
          theta = u * 2.0 * Math::PI # 0..2pi (around)
          nx = Math.sin(phi) * Math.cos(theta)
          ny = Math.cos(phi)
          nz = Math.sin(phi) * Math.sin(theta)
          verts.push((nx * radius).to_f32, (ny * radius).to_f32, (nz * radius).to_f32,
            nx.to_f32, ny.to_f32, nz.to_f32, r, g, b)
        end
      end

      row = segments + 1
      (0...rings).each do |y|
        (0...segments).each do |x|
          i0 = (y * row + x).to_u32
          i1 = (y * row + x + 1).to_u32
          i2 = ((y + 1) * row + x).to_u32
          i3 = ((y + 1) * row + x + 1).to_u32
          indices.push(i0, i2, i1, i1, i2, i3)
        end
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
