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

    # Loads a Wavefront OBJ file. Supports `v`/`vn`/`f` (polygons are fan-triangulated;
    # vertex refs may be `v`, `v/vt`, `v//vn`, `v/vt/vn`, with negative/relative indices).
    # If a face has no normals, a flat per-face normal is computed. Texture coords are
    # ignored; every vertex gets the given `color` (OBJ carries no vertex color).
    def self.load_obj(gpu : GpuContext, path : String, color : Color = Color::WHITE) : Mesh
      r, g, b = color.r, color.g, color.b
      positions = [] of Tuple(Float32, Float32, Float32)
      normals = [] of Tuple(Float32, Float32, Float32)
      verts = [] of Float32
      indices = [] of UInt32
      cache = {} of Tuple(Int32, Int32) => UInt32 # (posIdx, normIdx) -> output index

      resolve = ->(token : String, count : Int32) do
        n = token.to_i
        n > 0 ? n - 1 : count + n # 1-based; negatives are relative to the end
      end

      File.each_line(path) do |line|
        line = line.strip
        next if line.empty? || line.starts_with?('#')
        parts = line.split(/\s+/)
        case parts[0]
        when "v"
          positions << {parts[1].to_f32, parts[2].to_f32, parts[3].to_f32}
        when "vn"
          normals << {parts[1].to_f32, parts[2].to_f32, parts[3].to_f32}
        when "f"
          # Each face vertex: "p", "p/t", "p//n" or "p/t/n" (1-based / negative).
          refs = parts[1..].map do |tok|
            f = tok.split('/')
            pi = resolve.call(f[0], positions.size)
            ni = (f.size >= 3 && !f[2].empty?) ? resolve.call(f[2], normals.size) : -1
            {pi, ni}
          end
          # Fan-triangulate.
          (1...(refs.size - 1)).each do |k|
            tri = {refs[0], refs[k], refs[k + 1]}
            # Flat normal if any corner lacks one.
            flat = nil.as(Tuple(Float32, Float32, Float32)?)
            if tri[0][1] < 0 || tri[1][1] < 0 || tri[2][1] < 0
              p0 = positions[tri[0][0]]; p1 = positions[tri[1][0]]; p2 = positions[tri[2][0]]
              ux, uy, uz = p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2]
              vx, vy, vz = p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2]
              nx = uy * vz - uz * vy; ny = uz * vx - ux * vz; nz = ux * vy - uy * vx
              len = Math.sqrt(nx * nx + ny * ny + nz * nz)
              len = 1.0f32 if len == 0
              flat = {(nx / len).to_f32, (ny / len).to_f32, (nz / len).to_f32}
            end
            tri.each do |(pi, ni)|
              key = {pi, ni}
              idx = cache[key]?
              unless idx
                pos = positions[pi]
                nrm = ni >= 0 ? normals[ni] : flat.not_nil!
                verts.push(pos[0], pos[1], pos[2], nrm[0], nrm[1], nrm[2], r, g, b)
                idx = (verts.size // 9 - 1).to_u32
                # Don't cache flat-normal verts (normal is face-specific, key ni=-1 collides).
                cache[key] = idx if ni >= 0
              end
              indices << idx
            end
          end
        end
      end
      raise "OBJ #{path}: no faces" if indices.empty?
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
