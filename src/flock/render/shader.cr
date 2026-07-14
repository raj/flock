module Flock
  # Module shader WGSL, façon wgpu. Reprend le pattern de wgpu-cr :
  # WGSL -> ShaderSourceWGSL -> device_create_shader_module. Le handle brut
  # (`module`) reste accessible pour un usage avancé.
  struct Shader
    getter module : LibWGPU::ShaderModule

    def initialize(@module : LibWGPU::ShaderModule)
    end

    def self.from_source(gpu : GpuContext, wgsl : String) : Shader
      code = WGPU.string_view(wgsl)
      src = LibWGPU::ShaderSourceWGSL.new
      src.chain.s_type = LibWGPU::SType::ShaderSourceWGSL
      src.code = code
      desc = LibWGPU::ShaderModuleDescriptor.new
      desc.label = WGPU.empty_string_view
      desc.next_in_chain = pointerof(src).as(Pointer(LibWGPU::ChainedStruct))
      # wgpu-native copie la source à la création : `wgsl` n'a pas à survivre.
      Shader.new(LibWGPU.device_create_shader_module(gpu.device, pointerof(desc)))
    end

    def self.from_file(gpu : GpuContext, path : String) : Shader
      from_source(gpu, File.read(path))
    end
  end
end
