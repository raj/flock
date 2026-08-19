require "json"
require "base64"
require "uri"

module Flock
  # A GPU mesh: interleaved vertex buffer (position + normal + color + uv0 + uv1, 13 floats
  # / 52 bytes per vertex) + a UInt32 index buffer. Consumed by Renderer3D through a
  # `MeshRenderer` component.
  class Mesh
    STRIDE = 52_u64 # 13 f32 (pos3 + normal3 + color3 + uv2 + uv1_2)
    FLOATS =     13 # floats per vertex (two UV sets; uv1 defaults to uv0)

    getter vertex_buf : LibWGPU::Buffer
    getter index_buf : LibWGPU::Buffer
    getter index_count : UInt32
    getter vertex_bytes : UInt64
    getter index_bytes : UInt64
    # Local-space bounding sphere (for frustum culling). Default radius Float32::MAX
    # means "unknown" -> never culled.
    getter bounds_center : Vec3
    getter bounds_radius : Float32

    def initialize(@vertex_buf : LibWGPU::Buffer, @index_buf : LibWGPU::Buffer,
                   @index_count : UInt32, @vertex_bytes : UInt64, @index_bytes : UInt64,
                   @bounds_center : Vec3 = Vec3.new, @bounds_radius : Float32 = Float32::MAX)
    end

    # Uploads interleaved vertices (pos.xyz, normal.xyz, color.rgb per vertex) + indices.
    def self.build(gpu : GpuContext, vertices : Array(Float32), indices : Array(UInt32)) : Mesh
      vbuf = make_buffer(gpu, (vertices.size * 4).to_u64,
        LibWGPU::BufferUsage::Vertex | LibWGPU::BufferUsage::CopyDst)
      LibWGPU.queue_write_buffer(gpu.queue, vbuf, 0_u64, vertices.to_unsafe.as(Void*), (vertices.size * 4).to_u64)

      ibuf = make_buffer(gpu, (indices.size * 4).to_u64,
        LibWGPU::BufferUsage::Index | LibWGPU::BufferUsage::CopyDst)
      LibWGPU.queue_write_buffer(gpu.queue, ibuf, 0_u64, indices.to_unsafe.as(Void*), (indices.size * 4).to_u64)

      center, radius = bounding_sphere(vertices)
      new(vbuf, ibuf, indices.size.to_u32, (vertices.size * 4).to_u64, (indices.size * 4).to_u64, center, radius)
    end

    # AABB-derived bounding sphere from interleaved vertices (pos = first 3 floats,
    # stride FLOATS). Center = AABB midpoint, radius = half the diagonal (conservative).
    private def self.bounding_sphere(vertices : Array(Float32)) : {Vec3, Float32}
      return {Vec3.new, 0.0f32} if vertices.size < FLOATS
      minx = miny = minz = Float32::MAX
      maxx = maxy = maxz = -Float32::MAX
      i = 0
      while i + 2 < vertices.size
        x = vertices[i]; y = vertices[i + 1]; z = vertices[i + 2]
        minx = x if x < minx; miny = y if y < miny; minz = z if z < minz
        maxx = x if x > maxx; maxy = y if y > maxy; maxz = z if z > maxz
        i += FLOATS
      end
      cx = (minx + maxx) * 0.5f32; cy = (miny + maxy) * 0.5f32; cz = (minz + maxz) * 0.5f32
      dx = maxx - cx; dy = maxy - cy; dz = maxz - cz
      {Vec3.new(cx, cy, cz), Math.sqrt(dx * dx + dy * dy + dz * dz).to_f32}
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

      # Per-face quad UVs (0,0)-(1,1) matching the 4 corners.
      uvs = [{0.0f32, 1.0f32}, {1.0f32, 1.0f32}, {1.0f32, 0.0f32}, {0.0f32, 0.0f32}]
      verts = [] of Float32
      indices = [] of UInt32
      faces.each do |(normal, corners)|
        base = (verts.size // FLOATS).to_u32
        corners.each_with_index do |c, k|
          verts.push(c[0].to_f32, c[1].to_f32, c[2].to_f32,
            normal[0].to_f32, normal[1].to_f32, normal[2].to_f32, r, g, b,
            uvs[k][0], uvs[k][1], uvs[k][0], uvs[k][1]) # uv1 = uv0
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
            nx.to_f32, ny.to_f32, nz.to_f32, r, g, b, u.to_f32, v.to_f32, u.to_f32, v.to_f32)
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
      texcoords = [] of Tuple(Float32, Float32)
      verts = [] of Float32
      indices = [] of UInt32
      cache = {} of Tuple(Int32, Int32, Int32) => UInt32 # (posIdx, uvIdx, normIdx) -> output index

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
        when "vt"
          # OBJ texture v is bottom-up; flip to top-down (image space).
          texcoords << {parts[1].to_f32, 1.0f32 - parts[2].to_f32}
        when "f"
          # Each face vertex: "p", "p/t", "p//n" or "p/t/n" (1-based / negative).
          refs = parts[1..].map do |tok|
            f = tok.split('/')
            pi = resolve.call(f[0], positions.size)
            ti = (f.size >= 2 && !f[1].empty?) ? resolve.call(f[1], texcoords.size) : -1
            ni = (f.size >= 3 && !f[2].empty?) ? resolve.call(f[2], normals.size) : -1
            {pi, ti, ni}
          end
          # Fan-triangulate.
          (1...(refs.size - 1)).each do |k|
            tri = {refs[0], refs[k], refs[k + 1]}
            # Flat normal if any corner lacks one.
            flat = nil.as(Tuple(Float32, Float32, Float32)?)
            if tri[0][2] < 0 || tri[1][2] < 0 || tri[2][2] < 0
              p0 = positions[tri[0][0]]; p1 = positions[tri[1][0]]; p2 = positions[tri[2][0]]
              ux, uy, uz = p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2]
              vx, vy, vz = p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2]
              nx = uy * vz - uz * vy; ny = uz * vx - ux * vz; nz = ux * vy - uy * vx
              len = Math.sqrt(nx * nx + ny * ny + nz * nz)
              len = 1.0f32 if len == 0
              flat = {(nx / len).to_f32, (ny / len).to_f32, (nz / len).to_f32}
            end
            tri.each do |(pi, ti, ni)|
              key = {pi, ti, ni}
              idx = cache[key]?
              unless idx
                pos = positions[pi]
                nrm = ni >= 0 ? normals[ni] : flat.not_nil!
                uv = ti >= 0 ? texcoords[ti] : {0.0f32, 0.0f32}
                verts.push(pos[0], pos[1], pos[2], nrm[0], nrm[1], nrm[2], r, g, b, uv[0], uv[1], uv[0], uv[1])
                idx = (verts.size // FLOATS - 1).to_u32
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
    # Walks the scene graph, baking each node's world transform into the geometry it
    # references (translation/rotation-quaternion/scale or an explicit matrix; nodes
    # may reuse a mesh at several transforms). Reads POSITION and NORMAL (computed flat
    # if absent) and the indices (sequential if absent). Vertex color per primitive =
    # its material's `baseColorFactor`, else COLOR_0, else the `color` argument.
    #
    # Everything is merged/baked into one Mesh. Textures and animation are not applied
    # here (see `load_gltf_textured` for base-color textures).
    def self.load_gltf(gpu : GpuContext, path : String, color : Color = Color::WHITE) : Mesh
      json_text, glb_bin = read_gltf_container(path)
      doc = JSON.parse(json_text)
      buffers = gltf_buffers(doc, File.dirname(path), glb_bin)

      verts = [] of Float32
      indices = [] of UInt32
      accessors = doc["accessors"].as_a
      views = doc["bufferViews"].as_a
      meshes = doc["meshes"]?.try(&.as_a) || [] of JSON::Any

      gltf_instances(doc).each do |(mesh_idx, world)|
        meshes[mesh_idx]["primitives"].as_a.each do |prim|
          gltf_append_primitive(prim, world, doc, accessors, views, buffers, color, verts, indices)
        end
      end

      raise "glTF #{path}: no geometry" if indices.empty?
      build(gpu, verts, indices)
    end

    # Appends one primitive's vertices/indices (baked by `world`) into the buffers.
    private def self.gltf_append_primitive(prim : JSON::Any, world : Mat4, doc : JSON::Any,
                                           accessors, views, buffers : Array(Bytes), color : Color,
                                           verts : Array(Float32), indices : Array(UInt32)) : Nil
      nmat = world.normal_matrix
      attrs = prim["attributes"]
      pos, _ = gltf_read_floats(accessors, views, buffers, attrs["POSITION"].as_i)
      vcount = pos.size // 3
      nrm = (ni = attrs["NORMAL"]?) ? gltf_read_floats(accessors, views, buffers, ni.as_i)[0] : nil
      colf, cn = (ci = attrs["COLOR_0"]?) ? gltf_read_floats(accessors, views, buffers, ci.as_i) : {nil, 0}
      uvf = (ti = attrs["TEXCOORD_0"]?) ? gltf_read_floats(accessors, views, buffers, ti.as_i)[0] : nil
      uvf1 = (ti1 = attrs["TEXCOORD_1"]?) ? gltf_read_floats(accessors, views, buffers, ti1.as_i)[0] : nil
      uvt = gltf_texture_transform(doc, prim) # KHR_texture_transform on the base-color texture
      mr, mg, mb = gltf_material_rgb(doc, prim, color)

      prim_indices =
        if idx = prim["indices"]?
          gltf_read_indices(accessors, views, buffers, idx.as_i)
        else
          Array(UInt32).new(vcount) { |k| k.to_u32 }
        end

      base = (verts.size // FLOATS).to_u32
      vcount.times do |v|
        p = world.transform_point(Vec3.new(pos[v * 3], pos[v * 3 + 1], pos[v * 3 + 2]))
        if nrm
          n = nmat.transform_point(Vec3.new(nrm[v * 3], nrm[v * 3 + 1], nrm[v * 3 + 2])).normalize
          nx, ny, nz = n.x, n.y, n.z
        else
          nx, ny, nz = 0.0f32, 0.0f32, 0.0f32
        end
        if colf
          r = colf[v * cn]; g = colf[v * cn + 1]; b = colf[v * cn + 2]
        else
          r, g, b = mr, mg, mb
        end
        u = uvf ? uvf[v * 2] : 0.0f32
        vv = uvf ? uvf[v * 2 + 1] : 0.0f32
        u, vv = apply_uv_transform(u, vv, uvt) if uvt # KHR_texture_transform
        # Second UV set (TEXCOORD_1); falls back to uv0 so texCoord:1 lookups stay sane.
        u1 = uvf1 ? uvf1[v * 2] : u
        vv1 = uvf1 ? uvf1[v * 2 + 1] : vv
        verts.push(p.x, p.y, p.z, nx, ny, nz, r, g, b, u, vv, u1, vv1)
      end
      prim_indices.each { |i| indices << base + i }

      unless nrm
        t = 0
        while t + 2 < prim_indices.size
          gltf_flat_normal(verts, base, prim_indices[t], prim_indices[t + 1], prim_indices[t + 2])
          t += 3
        end
      end
    end

    # Loads a glTF as an animatable scene: builds a Mesh per mesh-bearing node (geometry
    # in node-LOCAL space, i.e. transforms are NOT baked), keeps the node hierarchy, and
    # parses node (TRS) animations. Drive it with `Flock::AnimatedModel`.
    def self.load_gltf_scene(gpu : GpuContext, path : String, color : Color = Color::WHITE) : GltfScene
      json_text, glb_bin = read_gltf_container(path)
      doc = JSON.parse(json_text)
      buffers = gltf_buffers(doc, File.dirname(path), glb_bin)
      accessors = doc["accessors"].as_a
      views = doc["bufferViews"].as_a
      gltf_meshes = doc["meshes"]?.try(&.as_a) || [] of JSON::Any
      json_nodes = doc["nodes"]?.try(&.as_a) || [] of JSON::Any

      # Morph meshes (primitives with `targets`) get a dedicated mesh + captured base
      # vertices and per-target deltas, so their vertex buffer can be re-blended each frame.
      # Keyed by mesh index -> {base vertices, indices, per-target deltas}. The Mesh (vertex
      # buffer) is built PER referencing node below, so multiple instances of the same morph
      # mesh deform independently.
      morph_data = {} of Int32 => {Array(Float32), Array(UInt32), Array(Array(Float32))}
      gltf_meshes.each_with_index do |gm, mi|
        prims = gm["primitives"].as_a
        next unless prims.any? { |p| p["targets"]? }
        verts = [] of Float32
        indices = [] of UInt32
        # Every target must cover ALL vertices (across primitives), with zero deltas where a
        # given primitive lacks that target — otherwise the per-vertex blend goes out of bounds.
        ntargets = prims.map { |p| p["targets"]?.try(&.as_a.size) || 0 }.max? || 0
        targets = Array(Array(Float32)).new(ntargets) { [] of Float32 }
        prims.each do |prim|
          vstart = verts.size // FLOATS
          gltf_append_primitive(prim, Mat4.identity, doc, accessors, views, buffers, color, verts, indices)
          pvc = verts.size // FLOATS - vstart
          ptargets = prim["targets"]?.try(&.as_a) || [] of JSON::Any
          ntargets.times do |ti|
            acc = targets[ti]
            (acc.size...(vstart * 6)).each { acc << 0.0f32 } # pad earlier primitives' gap
            if ti < ptargets.size
              tg = ptargets[ti]
              pos = gltf_read_floats(accessors, views, buffers, tg["POSITION"].as_i)[0]
              nrm = (ni = tg["NORMAL"]?) ? gltf_read_floats(accessors, views, buffers, ni.as_i)[0] : nil
              pvc.times do |v|
                acc << pos[v * 3] << pos[v * 3 + 1] << pos[v * 3 + 2]
                if nrm
                  acc << nrm[v * 3] << nrm[v * 3 + 1] << nrm[v * 3 + 2]
                else
                  acc << 0.0f32 << 0.0f32 << 0.0f32
                end
              end
            else
              (pvc * 6).times { acc << 0.0f32 } # this primitive has no such target
            end
          end
        end
        morph_data[mi] = {verts, indices, targets}
      end

      # One Flock Mesh per glTF mesh index (local space), built lazily. Morph meshes reuse
      # their pre-built dedicated mesh.
      built = {} of Int32 => Mesh
      local_mesh = ->(mi : Int32) do
        built[mi] ||= begin
          if md = morph_data[mi]?
            build(gpu, md[0], md[1]) # morph source (morph nodes normally carry mesh=nil)
          else
            verts = [] of Float32
            indices = [] of UInt32
            gltf_meshes[mi]["primitives"].as_a.each do |prim|
              gltf_append_primitive(prim, Mat4.identity, doc, accessors, views, buffers, color, verts, indices)
            end
            build(gpu, verts, indices)
          end
        end
      end

      nodes = json_nodes.map do |n|
        t = (tr = n["translation"]?) ? Vec3.new(tr[0].as_f, tr[1].as_f, tr[2].as_f) : Vec3.new
        s = (sc = n["scale"]?) ? Vec3.new(sc[0].as_f, sc[1].as_f, sc[2].as_f) : Vec3.new(1, 1, 1)
        rot =
          if r = n["rotation"]?
            StaticArray[r[0].as_f.to_f32, r[1].as_f.to_f32, r[2].as_f.to_f32, r[3].as_f.to_f32]
          else
            StaticArray[0.0f32, 0.0f32, 0.0f32, 1.0f32]
          end
        # Skinned nodes (SkinnedPart) and morph nodes (MorphPart) are driven by their own
        # models, not as rigid node meshes — leave their `mesh` nil so AnimatedModel /
        # mesh_nodes don't also spawn them (which would double-draw the morph mesh).
        mi = n["mesh"]?
        mesh = (n["skin"]?.nil? && mi && !morph_data.has_key?(mi.as_i)) ? local_mesh.call(mi.as_i) : nil
        children = n["children"]?.try(&.as_a.map(&.as_i)) || [] of Int32
        # A node may give a full column-major `matrix` instead of TRS (common for joints).
        mat =
          if mm = n["matrix"]?
            a = StaticArray(Float32, 16).new(0.0f32)
            mm.as_a.each_with_index { |v, i| a[i] = v.as_f.to_f32 }
            Mat4.new(a)
          end
        GltfNode.new(t, rot, s, mesh, children, mat)
      end

      roots =
        if (scene = doc["scene"]?) && (scenes = doc["scenes"]?)
          scenes.as_a[scene.as_i]["nodes"].as_a.map(&.as_i)
        else
          (0...nodes.size).to_a
        end

      animations = (doc["animations"]?.try(&.as_a) || [] of JSON::Any).map do |anim|
        samplers = anim["samplers"].as_a
        channels = anim["channels"].as_a.compact_map do |ch|
          target = ch["target"]
          node = target["node"]?.try(&.as_i)
          next nil unless node
          smp = samplers[ch["sampler"].as_i]
          times = gltf_read_floats(accessors, views, buffers, smp["input"].as_i)[0]
          values = gltf_read_floats(accessors, views, buffers, smp["output"].as_i)[0]
          interp = smp["interpolation"]?.try(&.as_s) || "LINEAR"
          path = target["path"].as_s
          # A "weights" channel packs `targetCount` values per keyframe (x3 for CUBICSPLINE).
          stride = if path == "weights" && !times.empty?
                     values.size // (times.size * (interp == "CUBICSPLINE" ? 3 : 1))
                   end
          GltfChannel.new(node, path, times, values, interp, stride)
        end
        GltfAnimation.new(anim["name"]?.try(&.as_s) || "", channels)
      end

      skins = [] of SkinnedPart
      json_nodes.each_with_index do |n, ni|
        next unless n["skin"]? && n["mesh"]?
        skins << gltf_build_skinned_part(gpu, doc, n, ni, accessors, views, buffers, color)
      end

      # Morph parts: ONE per node referencing a morph mesh (not per mesh), each with its own
      # vertex buffer + node weights, so two nodes instancing the same morph mesh with
      # different weight animations both spawn and animate independently.
      morphs = [] of MorphPart
      json_nodes.each_with_index do |n, ni|
        mi = n["mesh"]?.try(&.as_i) || next
        md = morph_data[mi]? || next
        base_verts, indices, targets = md
        defaults =
          (n["weights"]?.try(&.as_a) ||
            gltf_meshes[mi]["weights"]?.try(&.as_a) || [] of JSON::Any).map(&.as_f.to_f32)
        defaults = Array(Float32).new(targets.size, 0.0f32) if defaults.size < targets.size
        morphs << MorphPart.new(build(gpu, base_verts, indices), base_verts, targets, ni, defaults)
      end

      GltfScene.new(nodes, roots, animations, skins, morphs)
    end

    # Builds a CPU-skinned part for a node that has both a mesh and a skin: the bind-pose
    # vertices (identity local space), per-vertex JOINTS_0/WEIGHTS_0, and the skin's joint
    # node indices + inverse-bind matrices.
    private def self.gltf_build_skinned_part(gpu : GpuContext, doc : JSON::Any, node : JSON::Any, node_idx : Int32,
                                             accessors, views, buffers : Array(Bytes), color : Color) : SkinnedPart
      skin = doc["skins"].as_a[node["skin"].as_i]
      joint_nodes = skin["joints"].as_a.map(&.as_i)
      # inverseBindMatrices is optional: absent (or short) => identity for those joints.
      ibm = (ibi = skin["inverseBindMatrices"]?) ? gltf_read_floats(accessors, views, buffers, ibi.as_i)[0] : [] of Float32
      inverse_binds = Array(Mat4).new(joint_nodes.size) do |j|
        if (j + 1) * 16 <= ibm.size
          a = StaticArray(Float32, 16).new(0.0f32)
          16.times { |k| a[k] = ibm[j * 16 + k] } # glTF matrices are column-major
          Mat4.new(a)
        else
          Mat4.identity
        end
      end

      verts = [] of Float32
      indices = [] of UInt32
      joints = [] of Int32
      weights = [] of Float32
      doc["meshes"].as_a[node["mesh"].as_i]["primitives"].as_a.each do |prim|
        gltf_append_primitive(prim, Mat4.identity, doc, accessors, views, buffers, color, verts, indices)
        attrs = prim["attributes"]
        j0 = gltf_read_floats(accessors, views, buffers, attrs["JOINTS_0"].as_i)[0]
        w0 = gltf_read_floats(accessors, views, buffers, attrs["WEIGHTS_0"].as_i)[0]
        # A vertex may have a second influence set (JOINTS_1/WEIGHTS_1, up to 8 bones). Rather
        # than widen the vertex + shader, reduce to the 4 most significant bones per vertex:
        # the 5th–8th weights are tiny, so keeping the top 4 (then renormalizing below) is
        # visually equivalent and keeps the 4-bone GPU/CPU skinning path unchanged.
        j1 = attrs["JOINTS_1"]?.try { |a| gltf_read_floats(accessors, views, buffers, a.as_i)[0] }
        w1 = attrs["WEIGHTS_1"]?.try { |a| gltf_read_floats(accessors, views, buffers, a.as_i)[0] }
        vcount = w0.size // 4
        vcount.times do |v|
          infl = Array({Int32, Float32}).new(8)
          4.times { |i| infl << {j0[v * 4 + i].to_i, w0[v * 4 + i]} }
          if j1 && w1
            4.times { |i| infl << {j1[v * 4 + i].to_i, w1[v * 4 + i]} }
          end
          infl.sort_by! { |(_, w)| -w } # largest weight first; keep the top 4
          4.times do |i|
            jt, wt = i < infl.size ? infl[i] : {0, 0.0f32}
            joints << jt
            weights << wt
          end
        end
      end

      # Renormalize each vertex's (top-4) weights to sum to 1 (glTF permits un-normalized
      # weights, and the reduction above drops a little weight). Zero-sum vertices untouched.
      vi = 0
      while vi + 3 < weights.size
        s = weights[vi] + weights[vi + 1] + weights[vi + 2] + weights[vi + 3]
        if s > 0.0f32
          weights[vi] /= s; weights[vi + 1] /= s; weights[vi + 2] /= s; weights[vi + 3] /= s
        end
        vi += 4
      end

      SkinnedPart.new(build(gpu, verts, indices), verts, joints, weights, joint_nodes, inverse_binds, node_idx)
    end

    # Like `load_gltf`, but also loads the first material's base-color texture (from an
    # external image file, a base64 data-URI, or an embedded bufferView). Returns
    # {mesh, texture?}; assign the texture to `MeshRenderer#texture`.
    def self.load_gltf_textured(gpu : GpuContext, path : String, color : Color = Color::WHITE) : {Mesh, Texture?}
      mesh = load_gltf(gpu, path, color)
      json_text, glb_bin = read_gltf_container(path)
      doc = JSON.parse(json_text)
      buffers = gltf_buffers(doc, File.dirname(path), glb_bin)
      {mesh, gltf_base_color_texture(gpu, doc, buffers, File.dirname(path))}
    end

    # Full PBR (glTF metallic-roughness) loader. Returns the mesh plus the first
    # material's maps, scalar factors, emissive/occlusion and alpha mode, ready to feed a
    # `MeshRenderer`. NOTE: map fields may ALIAS the same `Texture` when the material reuses
    # one image across slots (e.g. a packed occlusion-roughness-metallic texture). Release
    # the returned textures through a de-duplicating set, never once per field.
    #   m = Mesh.load_gltf_pbr(gpu, "model.glb")
    #   cmd.spawn(Transform3D.new, MeshRenderer.new(m[:mesh], texture: m[:base_color],
    #     metallic_roughness: m[:metallic_roughness], normal_map: m[:normal],
    #     metallic: m[:metallic], roughness: m[:roughness],
    #     emissive: m[:emissive], emissive_factor: m[:emissive_factor],
    #     occlusion: m[:occlusion], transparent: m[:transparent], alpha_cutoff: m[:alpha_cutoff]))
    def self.load_gltf_pbr(gpu : GpuContext, path : String, color : Color = Color::WHITE)
      mesh = load_gltf(gpu, path, color)
      json_text, glb_bin = read_gltf_container(path)
      doc = JSON.parse(json_text)
      buffers = gltf_buffers(doc, File.dirname(path), glb_bin)
      dir = File.dirname(path)

      base = nil.as(Texture?); mr = nil.as(Texture?); normal = nil.as(Texture?)
      emissive = nil.as(Texture?); occlusion = nil.as(Texture?)
      metallic = 1.0f32; roughness = 1.0f32
      emissive_factor = Color::BLACK
      transparent = false; alpha_cutoff = 0.0f32
      unlit = false
      tex_coords = 0_u32 # UV-set bitmask (bit i set = texture i uses TEXCOORD_1)

      # This convenience loader returns ONE material's worth of maps/factors: the first.
      # (Multi-material meshes need per-primitive handling — use load_gltf_scene.) Reading a
      # single material keeps the factors, maps, and alpha mode mutually consistent, and a
      # per-index cache avoids uploading the same image twice (e.g. shared base/emissive).
      if (mats = doc["materials"]?) && (m = mats.as_a[0]?)
        # Cache is keyed by (image index, sRGB) so a packed image reused as both a color and
        # a data map gets the correct format for each role (rare, but correct).
        cache = {} of Tuple(Int32, Bool) => Texture
        tex = ->(ref : JSON::Any, bit : UInt32, srgb : Bool) do
          tex_coords |= bit if (ref["texCoord"]?.try(&.as_i) || 0) == 1
          ti = ref["index"].as_i
          cache[{ti, srgb}] ||= gltf_texture_at(gpu, doc, buffers, dir, ti, srgb)
        end
        if pbr = m["pbrMetallicRoughness"]?
          metallic = pbr["metallicFactor"]?.try(&.as_f.to_f32) || 1.0f32
          roughness = pbr["roughnessFactor"]?.try(&.as_f.to_f32) || 1.0f32
          if bc = pbr["baseColorTexture"]?
            base = tex.call(bc, 1_u32, true) # base-color is sRGB
          end
          if m2 = pbr["metallicRoughnessTexture"]?
            mr = tex.call(m2, 2_u32, false)
          end
        end
        if nt = m["normalTexture"]?
          normal = tex.call(nt, 4_u32, false)
        end
        if et = m["emissiveTexture"]?
          emissive = tex.call(et, 8_u32, true) # emissive is sRGB
        end
        if ot = m["occlusionTexture"]?
          occlusion = tex.call(ot, 16_u32, false)
        end
        if ef = m["emissiveFactor"]?.try(&.as_a)
          emissive_factor = Color.new(ef[0].as_f, ef[1].as_f, ef[2].as_f)
        end
        # KHR_materials_emissive_strength scales the emissive (values may exceed 1 → HDR glow).
        str = read_emissive_strength(m)
        if str != 1.0f32
          emissive_factor = Color.new(emissive_factor.r * str, emissive_factor.g * str, emissive_factor.b * str)
        end
        # Alpha mode: BLEND -> transparent pass; MASK -> hard cutout (default cutoff 0.5).
        case m["alphaMode"]?.try(&.as_s)
        when "BLEND" then transparent = true
        when "MASK"  then alpha_cutoff = m["alphaCutoff"]?.try(&.as_f.to_f32) || 0.5f32
        end
        unlit = read_unlit(m)
      end

      {mesh: mesh, base_color: base, metallic_roughness: mr, normal: normal,
       metallic: metallic, roughness: roughness, emissive: emissive,
       emissive_factor: emissive_factor, occlusion: occlusion,
       transparent: transparent, alpha_cutoff: alpha_cutoff, tex_coords: tex_coords, unlit: unlit}
    end

    private def self.gltf_texture_at(gpu : GpuContext, doc : JSON::Any, buffers : Array(Bytes),
                                     dir : String, ti : Int32, srgb : Bool = false) : Texture
      tex = doc["textures"].as_a[ti]
      img = doc["images"].as_a[tex["source"].as_i]
      gltf_load_image(gpu, doc, img, buffers, dir, srgb)
    end

    # Finds the first material's base-color texture and decodes it (or nil if none).
    private def self.gltf_base_color_texture(gpu : GpuContext, doc : JSON::Any,
                                             buffers : Array(Bytes), dir : String) : Texture?
      mats = doc["materials"]?.try(&.as_a) || return nil
      mats.each do |m|
        bct = m["pbrMetallicRoughness"]?.try(&.["baseColorTexture"]?)
        next unless bct
        tex = doc["textures"].as_a[bct["index"].as_i]
        img = doc["images"].as_a[tex["source"].as_i]
        return gltf_load_image(gpu, doc, img, buffers, dir, srgb: true) # base-color is sRGB
      end
      nil
    end

    # `srgb: true` for color maps (base-color, emissive) so the GPU decodes their sRGB
    # encoding to linear on sample; data maps (normal / metallic-roughness / occlusion) stay
    # linear.
    private def self.gltf_load_image(gpu : GpuContext, doc : JSON::Any, img : JSON::Any,
                                     buffers : Array(Bytes), dir : String, srgb : Bool = false) : Texture
      if uri = img["uri"]?.try(&.as_s)
        if uri.starts_with?("data:")
          Texture.from_encoded(gpu, Base64.decode(uri.split(",", 2)[1]), srgb: srgb)
        else
          # Non-data URIs are percent-encoded per the glTF spec (e.g. "my%20model.png").
          Texture.load(gpu, gltf_resolve_uri(dir, uri), SamplerFilter::Linear, SamplerWrap::Repeat, srgb: srgb)
        end
      else
        bv = doc["bufferViews"].as_a[img["bufferView"].as_i]
        off = bv["byteOffset"]?.try(&.as_i) || 0
        len = bv["byteLength"].as_i
        Texture.from_encoded(gpu, buffers[bv["buffer"].as_i][off, len], srgb: srgb)
      end
    end

    # Flattens the scene graph to {mesh index, world matrix} pairs. Falls back to every
    # mesh at identity when the file has no nodes/scene.
    private def self.gltf_instances(doc : JSON::Any) : Array({Int32, Mat4})
      acc = [] of {Int32, Mat4}
      nodes = doc["nodes"]?.try(&.as_a)
      unless nodes
        (doc["meshes"]?.try(&.as_a) || [] of JSON::Any).each_index { |i| acc << {i, Mat4.identity} }
        return acc
      end

      roots =
        if (scene = doc["scene"]?) && (scenes = doc["scenes"]?)
          scenes.as_a[scene.as_i]["nodes"].as_a.map(&.as_i)
        else
          (0...nodes.size).to_a
        end
      roots.each { |r| gltf_visit_node(nodes, r, Mat4.identity, acc) }
      acc
    end

    # Recursively accumulates {mesh index, world matrix} for a node and its children.
    # `seen` guards against a malformed cyclic / multi-parent graph (glTF must be a forest).
    private def self.gltf_visit_node(nodes : Array(JSON::Any), idx : Int32, parent : Mat4,
                                     acc : Array({Int32, Mat4}), seen = Set(Int32).new) : Nil
      return unless seen.add?(idx)
      node = nodes[idx]
      world = parent * gltf_node_matrix(node)
      if mi = node["mesh"]?
        acc << {mi.as_i, world}
      end
      node["children"]?.try &.as_a.each { |c| gltf_visit_node(nodes, c.as_i, world, acc, seen) }
    end

    # Walks the scene graph and returns every {node JSON, world matrix} pair (all nodes,
    # not just meshes). Falls back to a flat list at identity when there are no nodes.
    private def self.gltf_scene_nodes(doc : JSON::Any) : Array({JSON::Any, Mat4})
      acc = [] of {JSON::Any, Mat4}
      nodes = doc["nodes"]?.try(&.as_a) || return acc
      roots =
        if (scene = doc["scene"]?) && (scenes = doc["scenes"]?)
          scenes.as_a[scene.as_i]["nodes"].as_a.map(&.as_i)
        else
          (0...nodes.size).to_a
        end
      seen = Set(Int32).new
      visit = uninitialized Int32, Mat4 -> Nil
      visit = ->(idx : Int32, parent : Mat4) do
        if seen.add?(idx) # guard cycles / shared children
          node = nodes[idx]
          world = parent * gltf_node_matrix(node)
          acc << {node, world}
          node["children"]?.try &.as_a.each { |c| visit.call(c.as_i, world) }
        end
        nil
      end
      roots.each { |r| visit.call(r, Mat4.identity) }
      acc
    end

    # Loads the glTF `KHR_lights_punctual` lights as `{Light, position}` pairs with world
    # transforms applied. Spawn them with a `Transform3D` at the returned position:
    #   Mesh.load_gltf_lights(path).each do |light, pos|
    #     cmd.spawn(Transform3D.new(position: pos), light)
    #   end
    def self.load_gltf_lights(path : String) : Array({Light, Vec3})
      json_text, _ = read_gltf_container(path)
      doc = JSON.parse(json_text)
      defs = doc.dig?("extensions", "KHR_lights_punctual", "lights").try(&.as_a) || return [] of {Light, Vec3}

      out = [] of {Light, Vec3}
      gltf_scene_nodes(doc).each do |node, world|
        li = node.dig?("extensions", "KHR_lights_punctual", "light") || next
        ld = defs[li.as_i]
        color = (c = ld["color"]?) ? Color.new(c[0].as_f, c[1].as_f, c[2].as_f) : Color::WHITE
        intensity = ld["intensity"]?.try(&.as_f.to_f32) || 1.0f32
        range = ld["range"]?.try(&.as_f.to_f32) || 0.0f32
        pos = world.transform_point(Vec3.new)
        # glTF lights aim along their node's local -Z.
        dir = world.transform_direction(Vec3.new(0, 0, -1)).normalize
        light =
          case ld["type"].as_s
          when "point"
            Light.point(color, intensity, range > 0 ? range : 10.0)
          when "spot"
            spot = ld["spot"]?
            inner = spot.try(&.["innerConeAngle"]?).try(&.as_f.to_f32) || 0.0f32
            outer = spot.try(&.["outerConeAngle"]?).try(&.as_f.to_f32) || (Math::PI / 4).to_f32
            Light.spot(dir, color, intensity, range > 0 ? range : 10.0, inner, outer)
          else # "directional"
            Light.directional(dir, color, intensity)
          end
        out << {light, pos}
      end
      out
    end

    # Loads the glTF cameras placed in the scene as ready-to-use `Camera3D`s (world
    # position + orientation applied; perspective yfov/near/far, or a sensible fov for
    # orthographic cameras which Camera3D approximates as perspective).
    def self.load_gltf_cameras(path : String) : Array(Camera3D)
      json_text, _ = read_gltf_container(path)
      doc = JSON.parse(json_text)
      cams = doc["cameras"]?.try(&.as_a) || return [] of Camera3D

      out = [] of Camera3D
      gltf_scene_nodes(doc).each do |node, world|
        ci = node["camera"]? || next
        cd = cams[ci.as_i]
        pos = world.transform_point(Vec3.new)
        fwd = world.transform_direction(Vec3.new(0, 0, -1)).normalize
        up = world.transform_direction(Vec3.new(0, 1, 0)).normalize
        persp = cd["perspective"]?
        fov = persp.try(&.["yfov"]?).try(&.as_f.to_f32) || 1.0f32
        near = persp.try(&.["znear"]?).try(&.as_f.to_f32) || 0.1f32
        far = persp.try(&.["zfar"]?).try(&.as_f.to_f32) || 1000.0f32
        out << Camera3D.new(position: pos, target: pos + fwd, up: up, fov_y: fov, near: near, far: far)
      end
      out
    end

    private def self.gltf_node_matrix(node : JSON::Any) : Mat4
      if m = node["matrix"]?
        a = StaticArray(Float32, 16).new(0.0f32)
        m.as_a.each_with_index { |v, i| a[i] = v.as_f.to_f32 } # glTF matrices are column-major
        return Mat4.new(a)
      end
      t = (tr = node["translation"]?) ? Vec3.new(tr[0].as_f, tr[1].as_f, tr[2].as_f) : Vec3.new
      s = (sc = node["scale"]?) ? Vec3.new(sc[0].as_f, sc[1].as_f, sc[2].as_f) : Vec3.new(1, 1, 1)
      rot =
        if r = node["rotation"]?
          Mat4.rotation_quaternion(r[0].as_f, r[1].as_f, r[2].as_f, r[3].as_f)
        else
          Mat4.identity
        end
      Mat4.translation(t) * rot * Mat4.scale(s)
    end

    private def self.gltf_material_rgb(doc : JSON::Any, prim : JSON::Any, fallback : Color) : {Float32, Float32, Float32}
      if (mi = prim["material"]?) && (mats = doc["materials"]?)
        pbr = mats.as_a[mi.as_i]["pbrMetallicRoughness"]?
        if pbr && (bcf = pbr["baseColorFactor"]?)
          a = bcf.as_a
          return {a[0].as_f.to_f32, a[1].as_f.to_f32, a[2].as_f.to_f32}
        end
        # A material with no baseColorFactor defaults to white (glTF spec); this also
        # keeps a base-color texture unmodulated (white * texture = texture).
        return {1.0f32, 1.0f32, 1.0f32}
      end
      {fallback.r, fallback.g, fallback.b}
    end

    # --- KHR extensions (load-time) ---

    # Parses `KHR_texture_transform` from a texture-info extension: {offset_x, offset_y,
    # scale_x, scale_y, rotation}. Defaults: no offset, unit scale, no rotation.
    def self.read_texture_transform(tt : JSON::Any) : Tuple(Float32, Float32, Float32, Float32, Float32)
      off = tt["offset"]?.try(&.as_a)
      scl = tt["scale"]?.try(&.as_a)
      ox = off ? off[0].as_f.to_f32 : 0.0f32
      oy = off ? off[1].as_f.to_f32 : 0.0f32
      sx = scl ? scl[0].as_f.to_f32 : 1.0f32
      sy = scl ? scl[1].as_f.to_f32 : 1.0f32
      rot = tt["rotation"]?.try(&.as_f.to_f32) || 0.0f32
      {ox, oy, sx, sy, rot}
    end

    # Applies a KHR_texture_transform (scale → rotate → translate, per spec) to a UV.
    def self.apply_uv_transform(u : Float32, v : Float32,
                                tt : Tuple(Float32, Float32, Float32, Float32, Float32)) : Tuple(Float32, Float32)
      ox, oy, sx, sy, rot = tt
      su = u * sx
      sv = v * sy
      c = Math.cos(rot); s = Math.sin(rot)
      {(c * su + s * sv).to_f32 + ox, (-s * su + c * sv).to_f32 + oy}
    end

    # KHR_materials_emissive_strength multiplier (default 1.0 when absent).
    def self.read_emissive_strength(m : JSON::Any) : Float32
      m.dig?("extensions", "KHR_materials_emissive_strength", "emissiveStrength").try(&.as_f.to_f32) || 1.0f32
    end

    # KHR_materials_unlit: the material renders as flat base color (no lighting).
    def self.read_unlit(m : JSON::Any) : Bool
      !m.dig?("extensions", "KHR_materials_unlit").nil?
    end

    # The base-color texture's KHR_texture_transform for a primitive's material, or nil.
    private def self.gltf_texture_transform(doc : JSON::Any, prim : JSON::Any) : Tuple(Float32, Float32, Float32, Float32, Float32)?
      return nil unless (mi = prim["material"]?) && (mats = doc["materials"]?)
      return nil unless mat = mats.as_a[mi.as_i]?
      return nil unless ref = mat.dig?("pbrMetallicRoughness", "baseColorTexture")
      return nil unless tt = ref.dig?("extensions", "KHR_texture_transform")
      read_texture_transform(tt)
    end

    # Resolves a glTF external URI to a local path, confining it to the model's directory:
    # absolute paths and any `..` segment are rejected (a hostile .gltf/.glb must not be
    # able to read files outside the folder it lives in).
    private def self.gltf_resolve_uri(dir : String, uri : String) : String
      decoded = URI.decode(uri)
      raise "glTF URI is absolute: #{uri.inspect}" if decoded.starts_with?('/')
      if decoded.split('/').includes?("..")
        raise "glTF URI escapes the model directory: #{uri.inspect}"
      end
      File.join(dir, decoded)
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
          # Chunk length must fit in the file (a corrupt/hostile GLB must not slice past it).
          raise "GLB chunk (#{kind}) overruns file: len=#{len}, available=#{data.size - start}" if start + len > data.size
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
            File.read(gltf_resolve_uri(dir, uri)).to_slice
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

    # Reads one component. When `normalized`, integer types are mapped to [0,1] (unsigned)
    # or [-1,1] (signed) per the glTF spec — required for ubyte/ushort COLOR_0, WEIGHTS_0, UVs.
    private def self.gltf_read_component(io : IO::Memory, ct : Int32, normalized : Bool = false) : Float32
      case ct
      when 5126 then io.read_bytes(Float32, IO::ByteFormat::LittleEndian)
      when 5125
        v = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian).to_f32
        normalized ? v / 4294967295.0f32 : v
      when 5123
        v = io.read_bytes(UInt16, IO::ByteFormat::LittleEndian).to_f32
        normalized ? v / 65535.0f32 : v
      when 5122
        v = io.read_bytes(Int16, IO::ByteFormat::LittleEndian).to_f32
        normalized ? Math.max(v / 32767.0f32, -1.0f32) : v
      when 5121
        v = (io.read_byte || 0_u8).to_f32
        normalized ? v / 255.0f32 : v
      when 5120
        v = (io.read_byte || 0_u8).to_i8!.to_f32
        normalized ? Math.max(v / 127.0f32, -1.0f32) : v
      else 0.0f32
      end
    end

    # Reads an accessor as a flat Float32 array; returns {data, components_per_element}.
    private def self.gltf_read_floats(accessors, views, buffers : Array(Bytes), ai : Int32) : {Array(Float32), Int32}
      acc = accessors[ai]
      ncomp = TYPE_COMPONENTS[acc["type"].as_s]
      ct = acc["componentType"].as_i
      count = acc["count"].as_i
      raise "glTF sparse accessors are not supported" if acc["sparse"]?
      # An accessor with no bufferView is defined as all-zero (per spec).
      bvi = acc["bufferView"]?
      return {Array(Float32).new(count * ncomp, 0.0f32), ncomp} unless bvi
      bv = views[bvi.as_i]
      normalized = acc["normalized"]?.try(&.as_bool) || false
      csize = gltf_component_size(ct)
      base = (bv["byteOffset"]?.try(&.as_i) || 0) + (acc["byteOffset"]?.try(&.as_i) || 0)
      stride = bv["byteStride"]?.try(&.as_i) || (ncomp * csize)
      buf = buffers[bv["buffer"].as_i]
      io = IO::Memory.new(buf)
      # The accessor must fit inside its buffer: a hostile file declaring a huge `count`
      # would otherwise allocate an arbitrary amount before failing on the first read.
      if count < 0 || base < 0 || base + (count - 1) * stride + ncomp * csize > buf.size
        raise "glTF accessor #{ai} overruns its buffer (count=#{count}, stride=#{stride}, base=#{base}, buffer=#{buf.size}B)"
      end
      out = Array(Float32).new(count * ncomp)
      count.times do |e|
        ncomp.times do |c|
          io.pos = base + e * stride + c * csize
          out << gltf_read_component(io, ct, normalized)
        end
      end
      {out, ncomp}
    end

    private def self.gltf_read_indices(accessors, views, buffers : Array(Bytes), ai : Int32) : Array(UInt32)
      acc = accessors[ai]
      count = acc["count"].as_i
      raise "glTF sparse index accessors are not supported" if acc["sparse"]?
      bvi = acc["bufferView"]?
      return Array(UInt32).new(count, 0_u32) unless bvi # no bufferView -> zeros (spec)
      bv = views[bvi.as_i]
      ct = acc["componentType"].as_i
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
      a = ((base + ia) * FLOATS).to_i; b = ((base + ib) * FLOATS).to_i; c = ((base + ic) * FLOATS).to_i
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
