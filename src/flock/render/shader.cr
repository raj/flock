module Flock
  # WGSL shader module, wgpu-style. Follows the wgpu-cr pattern:
  # WGSL -> ShaderSourceWGSL -> device_create_shader_module. The raw handle
  # (`module`) remains accessible for advanced use.
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
      # wgpu-native copies the source at creation: `wgsl` need not outlive it.
      Shader.new(LibWGPU.device_create_shader_module(gpu.device, pointerof(desc)))
    end

    def self.from_file(gpu : GpuContext, path : String) : Shader
      from_source(gpu, File.read(path))
    end
  end
end
