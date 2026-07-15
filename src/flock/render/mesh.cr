require "json"
require "base64"

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

    # glTF 2.0 loader (`.gltf` with a `.bin`/data-URI buffer, or binary `.glb`).
    # Merges every primitive of every mesh into one Mesh: reads POSITION and NORMAL
    # (computed flat if absent) and the indices (drawn sequentially if absent). Node
    # transforms, materials, textures and animation are ignored; every vertex gets
    # `color` unless the file carries COLOR_0.
    #
    # Component/type coverage: POSITION/NORMAL as FLOAT VEC3 (other component types
    # are converted); indices as (UNSIGNED_)BYTE/SHORT/INT SCALAR.
    def self.load_gltf(gpu : GpuContext, path : String, color : Color = Color::WHITE) : Mesh
      json_text, glb_bin = read_gltf_container(path)
      doc = JSON.parse(json_text)
      buffers = gltf_buffers(doc, File.dirname(path), glb_bin)

      dr, dg, db = color.r, color.g, color.b
      verts = [] of Float32
      indices = [] of UInt32

      accessors = doc["accessors"].as_a
      views = doc["bufferViews"].as_a

      (doc["meshes"]?.try(&.as_a) || [] of JSON::Any).each do |mesh|
        mesh["primitives"].as_a.each do |prim|
          attrs = prim["attributes"]
          pos, _ = gltf_read_floats(accessors, views, buffers, attrs["POSITION"].as_i)
          vcount = pos.size // 3

          if ni = attrs["NORMAL"]?
            nrm, _ = gltf_read_floats(accessors, views, buffers, ni.as_i)
          else
            nrm = nil
          end
          if ci = attrs["COLOR_0"]?
            colf, cn = gltf_read_floats(accessors, views, buffers, ci.as_i)
          else
            colf, cn = nil, 0
          end

          # Indices (or sequential fan if the primitive has none).
          prim_indices =
            if idx = prim["indices"]?
              gltf_read_indices(accessors, views, buffers, idx.as_i)
            else
              Array(UInt32).new(vcount) { |k| k.to_u32 }
            end

          base = (verts.size // 9).to_u32
          vcount.times do |v|
            px, py, pz = pos[v * 3], pos[v * 3 + 1], pos[v * 3 + 2]
            if nrm
              nx, ny, nz = nrm[v * 3], nrm[v * 3 + 1], nrm[v * 3 + 2]
            else
              nx, ny, nz = 0.0f32, 0.0f32, 0.0f32 # filled below if still zero
            end
            if colf
              r = colf[v * cn]; g = colf[v * cn + 1]; b = colf[v * cn + 2]
            else
              r, g, b = dr, dg, db
            end
            verts.push(px, py, pz, nx, ny, nz, r, g, b)
          end
          prim_indices.each { |i| indices << base + i }

          # If normals were absent, compute a flat normal per triangle.
          unless nrm
            t = 0
            while t + 2 < prim_indices.size
              gltf_flat_normal(verts, base, prim_indices[t], prim_indices[t + 1], prim_indices[t + 2])
              t += 3
            end
          end
        end
      end

      raise "glTF #{path}: no geometry" if indices.empty?
      build(gpu, verts, indices)
    end

    # Returns {json, glb_binary_chunk?}. For .glb, splits the container; for .gltf,
    # reads the text and there is no embedded binary chunk (nil).
    private def self.read_gltf_container(path : String) : {String, Bytes?}
      data = File.read(path).to_slice
      if data.size >= 12 && data[0] == 0x67 && data[1] == 0x6C && data[2] == 0x54 && data[3] == 0x46 # "glTF"
        io = IO::Memory.new(data)
        io.pos = 12 # skip magic(4) + version(4) + length(4)
        json_bytes = nil.as(Bytes?)
        bin_bytes = nil.as(Bytes?)
        while io.pos + 8 <= data.size
          len = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
          kind = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
          start = io.pos
          chunk = data[start, len.to_i]
          io.pos = start + len
          if kind == 0x4E4F534A # "JSON"
            json_bytes = chunk
          elsif kind == 0x004E4942 # "BIN\0"
            bin_bytes = chunk
          end
        end
        {String.new(json_bytes || Bytes.empty), bin_bytes}
      else
        {String.new(data), nil}
      end
    end

    # Resolves each glTF buffer to raw bytes (external file, base64 data-URI, or the
    # GLB binary chunk when a buffer has no URI).
    private def self.gltf_buffers(doc : JSON::Any, dir : String, glb_bin : Bytes?) : Array(Bytes)
      (doc["buffers"]?.try(&.as_a) || [] of JSON::Any).map do |buf|
        if uri = buf["uri"]?.try(&.as_s)
          if uri.starts_with?("data:")
            Base64.decode(uri.split(",", 2)[1])
          else
            File.read(File.join(dir, uri)).to_slice
          end
        else
          glb_bin || raise("glTF buffer has no uri and no GLB binary chunk")
        end
      end
    end

    TYPE_COMPONENTS = {"SCALAR" => 1, "VEC2" => 2, "VEC3" => 3, "VEC4" => 4, "MAT2" => 4, "MAT3" => 9, "MAT4" => 16}

    private def self.gltf_component_size(ct : Int32) : Int32
      case ct
      when 5120, 5121 then 1 # (U)BYTE
      when 5122, 5123 then 2 # (U)SHORT
      else                 4 # (U)INT / FLOAT
      end
    end

    private def self.gltf_read_component(io : IO::Memory, ct : Int32) : Float32
      case ct
      when 5126 then io.read_bytes(Float32, IO::ByteFormat::LittleEndian)
      when 5125 then io.read_bytes(UInt32, IO::ByteFormat::LittleEndian).to_f32
      when 5123 then io.read_bytes(UInt16, IO::ByteFormat::LittleEndian).to_f32
      when 5122 then io.read_bytes(Int16, IO::ByteFormat::LittleEndian).to_f32
      when 5121 then (io.read_byte || 0_u8).to_f32
      when 5120 then (io.read_byte || 0_u8).to_i8!.to_f32
      else           0.0f32
      end
    end

    # Reads an accessor as a flat Float32 array; returns {data, components_per_element}.
    private def self.gltf_read_floats(accessors, views, buffers : Array(Bytes), ai : Int32) : {Array(Float32), Int32}
      acc = accessors[ai]
      bv = views[acc["bufferView"].as_i]
      ncomp = TYPE_COMPONENTS[acc["type"].as_s]
      ct = acc["componentType"].as_i
      count = acc["count"].as_i
      csize = gltf_component_size(ct)
      base = (bv["byteOffset"]?.try(&.as_i) || 0) + (acc["byteOffset"]?.try(&.as_i) || 0)
      stride = bv["byteStride"]?.try(&.as_i) || (ncomp * csize)
      io = IO::Memory.new(buffers[bv["buffer"].as_i])
      out = Array(Float32).new(count * ncomp)
      count.times do |e|
        ncomp.times do |c|
          io.pos = base + e * stride + c * csize
          out << gltf_read_component(io, ct)
        end
      end
      {out, ncomp}
    end

    private def self.gltf_read_indices(accessors, views, buffers : Array(Bytes), ai : Int32) : Array(UInt32)
      acc = accessors[ai]
      bv = views[acc["bufferView"].as_i]
      ct = acc["componentType"].as_i
      count = acc["count"].as_i
      csize = gltf_component_size(ct)
      base = (bv["byteOffset"]?.try(&.as_i) || 0) + (acc["byteOffset"]?.try(&.as_i) || 0)
      stride = bv["byteStride"]?.try(&.as_i) || csize
      io = IO::Memory.new(buffers[bv["buffer"].as_i])
      out = Array(UInt32).new(count)
      count.times do |e|
        io.pos = base + e * stride
        out << gltf_read_component(io, ct).to_u32
      end
      out
    end

    # Writes a flat per-triangle normal into the three vertices' normal slots.
    private def self.gltf_flat_normal(verts : Array(Float32), base : UInt32, ia : UInt32, ib : UInt32, ic : UInt32) : Nil
      a = ((base + ia) * 9).to_i; b = ((base + ib) * 9).to_i; c = ((base + ic) * 9).to_i
      ux = verts[b] - verts[a]; uy = verts[b + 1] - verts[a + 1]; uz = verts[b + 2] - verts[a + 2]
      vx = verts[c] - verts[a]; vy = verts[c + 1] - verts[a + 1]; vz = verts[c + 2] - verts[a + 2]
      nx = uy * vz - uz * vy; ny = uz * vx - ux * vz; nz = ux * vy - uy * vx
      len = Math.sqrt(nx * nx + ny * ny + nz * nz)
      len = 1.0f32 if len == 0
      {a, b, c}.each do |o|
        verts[o + 3] = (nx / len).to_f32
        verts[o + 4] = (ny / len).to_f32
        verts[o + 5] = (nz / len).to_f32
      end
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
