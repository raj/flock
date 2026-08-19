module Flock
  # Prefiltered image-based lighting (split-sum). An environment (a sky/horizon/ground
  # gradient, or a solid color) is precomputed on the CPU into: an irradiance cubemap
  # (diffuse), a roughness-mip prefiltered cubemap (specular) and a BRDF integration LUT.
  # These are uploaded and sampled by the PBR shader. Insert as a resource to enable IBL;
  # build it via `Renderer3D#build_ibl`.
  #
  # CPU precompute keeps the engine simple (no render-to-cubemap passes); the maps are
  # small (env 32², irradiance 8², prefiltered 32² with 5 mips, LUT 64²).
  class IblEnvironment < Resource
    ENV_SIZE  = 32
    IRR_SIZE  =  8
    PREF_SIZE = 32
    PREF_MIPS =  5
    LUT_SIZE  = 64

    getter irradiance : LibWGPU::Texture
    getter irradiance_view : LibWGPU::TextureView
    getter prefiltered : LibWGPU::Texture
    getter prefiltered_view : LibWGPU::TextureView
    getter brdf : LibWGPU::Texture
    getter brdf_view : LibWGPU::TextureView
    getter sampler : LibWGPU::Sampler
    getter group : LibWGPU::BindGroup

    def initialize(@irradiance, @irradiance_view, @prefiltered, @prefiltered_view,
                   @brdf, @brdf_view, @sampler, @group)
    end

    def release : Nil
      LibWGPU.bind_group_release(@group)
      LibWGPU.sampler_release(@sampler)
      LibWGPU.texture_view_release(@irradiance_view); LibWGPU.texture_release(@irradiance)
      LibWGPU.texture_view_release(@prefiltered_view); LibWGPU.texture_release(@prefiltered)
      LibWGPU.texture_view_release(@brdf_view); LibWGPU.texture_release(@brdf)
    end

    # --- CPU precompute -------------------------------------------------------

    # Direction (normalized) for face `f` at pixel (px,py) of a `size`x`size` face.
    def self.face_dir(f : Int32, px : Int32, py : Int32, size : Int32) : {Float64, Float64, Float64}
      sc = 2.0 * (px + 0.5) / size - 1.0
      tc = 2.0 * (py + 0.5) / size - 1.0
      x, y, z =
        case f
        when 0 then {1.0, -tc, -sc}  # +X
        when 1 then {-1.0, -tc, sc}  # -X
        when 2 then {sc, 1.0, tc}    # +Y
        when 3 then {sc, -1.0, -tc}  # -Y
        when 4 then {sc, -tc, 1.0}   # +Z
        else        {-sc, -tc, -1.0} # -Z
        end
      l = Math.sqrt(x * x + y * y + z * z)
      {x / l, y / l, z / l}
    end

    # Samples the environment (6 face color arrays, RGB float) in direction (dx,dy,dz).
    def self.sample_env(faces : Array(Array(Float64)), size : Int32, dx : Float64, dy : Float64, dz : Float64) : {Float64, Float64, Float64}
      ax = dx.abs; ay = dy.abs; az = dz.abs
      if ax >= ay && ax >= az
        f = dx > 0 ? 0 : 1; ma = ax
        sc = dx > 0 ? -dz : dz; tc = -dy
      elsif ay >= az
        f = dy > 0 ? 2 : 3; ma = ay
        sc = dx; tc = dy > 0 ? dz : -dz
      else
        f = dz > 0 ? 4 : 5; ma = az
        sc = dz > 0 ? dx : -dx; tc = -dy
      end
      u = (sc / ma + 1.0) * 0.5
      v = (tc / ma + 1.0) * 0.5
      px = (u * size).to_i.clamp(0, size - 1)
      py = (v * size).to_i.clamp(0, size - 1)
      o = (py * size + px) * 3
      face = faces[f]
      {face[o], face[o + 1], face[o + 2]}
    end

    # Generates the source environment (sky gradient by direction.y).
    def self.gen_env(sky : Color, horizon : Color, ground : Color) : Array(Array(Float64))
      Array(Array(Float64)).new(6) do |f|
        data = Array(Float64).new(ENV_SIZE * ENV_SIZE * 3, 0.0)
        ENV_SIZE.times do |py|
          ENV_SIZE.times do |px|
            _x, y, _z = face_dir(f, px, py, ENV_SIZE)
            t = y.abs
            r, g, b =
              if y >= 0
                {horizon.r + (sky.r - horizon.r) * t, horizon.g + (sky.g - horizon.g) * t, horizon.b + (sky.b - horizon.b) * t}
              else
                {horizon.r + (ground.r - horizon.r) * t, horizon.g + (ground.g - horizon.g) * t, horizon.b + (ground.b - horizon.b) * t}
              end
            o = (py * ENV_SIZE + px) * 3
            data[o] = r.to_f64; data[o + 1] = g.to_f64; data[o + 2] = b.to_f64
          end
        end
        data
      end
    end

    # Cosine-weighted hemisphere convolution of the environment → irradiance faces (RGBA8).
    def self.gen_irradiance(env : Array(Array(Float64))) : Array(Bytes)
      Array(Bytes).new(6) do |f|
        out = Bytes.new(IRR_SIZE * IRR_SIZE * 4)
        IRR_SIZE.times do |py|
          IRR_SIZE.times do |px|
            nx, ny, nz = face_dir(f, px, py, IRR_SIZE)
            # Tangent basis around N.
            upx, upy, upz = (ny.abs < 0.99 ? {0.0, 1.0, 0.0} : {1.0, 0.0, 0.0})
            tx, ty, tz = cross(upx, upy, upz, nx, ny, nz)
            tl = Math.sqrt(tx*tx + ty*ty + tz*tz); tx /= tl; ty /= tl; tz /= tl
            bx, by, bz = cross(nx, ny, nz, tx, ty, tz)
            sr = 0.0; sg = 0.0; sb = 0.0; wsum = 0.0
            phi = 0.0
            while phi < 6.2831853
              theta = 0.0
              while theta < 1.5707963
                st = Math.sin(theta); ct = Math.cos(theta)
                # sample dir in tangent space -> world
                lx = st * Math.cos(phi); ly = st * Math.sin(phi); lz = ct
                dx = tx*lx + bx*ly + nx*lz
                dy = ty*lx + by*ly + ny*lz
                dz = tz*lx + bz*ly + nz*lz
                r, g, b = sample_env(env, ENV_SIZE, dx, dy, dz)
                w = ct * st
                sr += r * w; sg += g * w; sb += b * w; wsum += w
                theta += 0.2
              end
              phi += 0.4
            end
            o = (py * IRR_SIZE + px) * 4
            out[o] = to_u8(sr / wsum); out[o + 1] = to_u8(sg / wsum); out[o + 2] = to_u8(sb / wsum); out[o + 3] = 255_u8
          end
        end
        out
      end
    end

    # GGX-prefiltered specular faces for a given roughness (one mip).
    def self.gen_prefilter(env : Array(Array(Float64)), size : Int32, roughness : Float64) : Array(Bytes)
      samples = 64
      Array(Bytes).new(6) do |f|
        out = Bytes.new(size * size * 4)
        size.times do |py|
          size.times do |px|
            nx, ny, nz = face_dir(f, px, py, size) # R = V = N
            sr = 0.0; sg = 0.0; sb = 0.0; wsum = 0.0
            i = 0
            while i < samples
              u1 = i.to_f64 / samples
              u2 = radical_inverse(i)
              hx, hy, hz = importance_ggx(u1, u2, roughness, nx, ny, nz)
              # L = reflect(-N, H)
              d = 2.0 * (nx*hx + ny*hy + nz*hz)
              lx = d*hx - nx; ly = d*hy - ny; lz = d*hz - nz
              ndotl = nx*lx + ny*ly + nz*lz
              if ndotl > 0
                r, g, b = sample_env(env, ENV_SIZE, lx, ly, lz)
                sr += r * ndotl; sg += g * ndotl; sb += b * ndotl; wsum += ndotl
              end
              i += 1
            end
            wsum = 1.0 if wsum <= 0
            o = (py * size + px) * 4
            out[o] = to_u8(sr / wsum); out[o + 1] = to_u8(sg / wsum); out[o + 2] = to_u8(sb / wsum); out[o + 3] = 255_u8
          end
        end
        out
      end
    end

    # BRDF integration LUT (scale/bias in R/G), split-sum approximation.
    def self.gen_brdf_lut : Bytes
      out = Bytes.new(LUT_SIZE * LUT_SIZE * 4)
      samples = 256
      LUT_SIZE.times do |py|
        rough = (py + 0.5) / LUT_SIZE
        LUT_SIZE.times do |px|
          ndotv = (px + 0.5) / LUT_SIZE
          vx = Math.sqrt(1.0 - ndotv * ndotv); vy = 0.0; vz = ndotv
          scale = 0.0; bias = 0.0
          i = 0
          while i < samples
            u2 = radical_inverse(i)
            hx, hy, hz = importance_ggx(i.to_f64 / samples, u2, rough, 0.0, 0.0, 1.0)
            d = 2.0 * (vx*hx + vy*hy + vz*hz)
            lx = d*hx - vx; ly = d*hy - vy; lz = d*hz - vz
            ndotl = lz.clamp(0.0, 1.0)
            ndoth = hz.clamp(0.0, 1.0)
            vdoth = (vx*hx + vy*hy + vz*hz).clamp(0.0, 1.0)
            if ndotl > 0
              g = geom_smith(ndotv, ndotl, rough)
              gvis = g * vdoth / (ndoth * ndotv + 1e-5)
              fc = (1.0 - vdoth) ** 5
              scale += (1.0 - fc) * gvis
              bias += fc * gvis
            end
            i += 1
          end
          o = (py * LUT_SIZE + px) * 4
          out[o] = to_u8(scale / samples); out[o + 1] = to_u8(bias / samples); out[o + 2] = 0_u8; out[o + 3] = 255_u8
        end
      end
      out
    end

    # --- numeric helpers ---
    private def self.cross(ax, ay, az, bx, by, bz) : {Float64, Float64, Float64}
      {ay*bz - az*by, az*bx - ax*bz, ax*by - ay*bx}
    end

    private def self.to_u8(v : Float64) : UInt8
      (v.clamp(0.0, 1.0) * 255.0).round.clamp(0.0, 255.0).to_u8
    end

    private def self.radical_inverse(i : Int32) : Float64
      bits = i.to_u32
      bits = (bits << 16) | (bits >> 16)
      bits = ((bits & 0x55555555_u32) << 1) | ((bits & 0xAAAAAAAA_u32) >> 1)
      bits = ((bits & 0x33333333_u32) << 2) | ((bits & 0xCCCCCCCC_u32) >> 2)
      bits = ((bits & 0x0F0F0F0F_u32) << 4) | ((bits & 0xF0F0F0F0_u32) >> 4)
      bits = ((bits & 0x00FF00FF_u32) << 8) | ((bits & 0xFF00FF00_u32) >> 8)
      bits.to_f64 * 2.3283064365386963e-10
    end

    # GGX importance sample: returns a half-vector around normal N.
    private def self.importance_ggx(u1 : Float64, u2 : Float64, rough : Float64, nx, ny, nz) : {Float64, Float64, Float64}
      a = rough * rough
      phi = 6.2831853 * u1
      ct = Math.sqrt((1.0 - u2) / (1.0 + (a*a - 1.0) * u2))
      st = Math.sqrt(1.0 - ct * ct)
      hx = Math.cos(phi) * st; hy = Math.sin(phi) * st; hz = ct
      upx, upy, upz = (nz.abs < 0.99 ? {0.0, 0.0, 1.0} : {1.0, 0.0, 0.0})
      tx, ty, tz = cross(upx, upy, upz, nx, ny, nz)
      tl = Math.sqrt(tx*tx + ty*ty + tz*tz); tx /= tl; ty /= tl; tz /= tl
      bx, by, bz = cross(nx, ny, nz, tx, ty, tz)
      {tx*hx + bx*hy + nx*hz, ty*hx + by*hy + ny*hz, tz*hx + bz*hy + nz*hz}
    end

    private def self.geom_smith(ndotv : Float64, ndotl : Float64, rough : Float64) : Float64
      k = (rough * rough) / 2.0
      gv = ndotv / (ndotv * (1.0 - k) + k)
      gl = ndotl / (ndotl * (1.0 - k) + k)
      gv * gl
    end
  end
end
