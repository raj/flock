module Flock
  # Ressource : tout l'état GPU partagé (créé par WindowPlugin, consommé par le
  # renderer). Handles wgpu bruts — libérés à la fermeture par WindowPlugin.
  class GpuContext < Resource
    property instance : LibWGPU::Instance
    property adapter : LibWGPU::Adapter
    property device : LibWGPU::Device
    property queue : LibWGPU::Queue
    property surface : LibWGPU::Surface
    property format : LibWGPU::TextureFormat
    property width : UInt32
    property height : UInt32
    property window : LibSDL::Window
    property view : LibSDL::MetalView

    def initialize(@instance, @adapter, @device, @queue, @surface, @format,
                   @width, @height, @window, @view)
    end

    def aspect : Float32
      @height == 0 ? 1.0f32 : @width.to_f32 / @height.to_f32
    end

    # Reconfigure la surface (appelé au démarrage et sur redimensionnement).
    def reconfigure(w : UInt32, h : UInt32) : Nil
      return if w == 0 || h == 0
      @width = w
      @height = h
      config = LibWGPU::SurfaceConfiguration.new
      config.device = @device
      config.format = @format
      config.usage = LibWGPU::TextureUsage::RenderAttachment
      config.width = w
      config.height = h
      config.present_mode = LibWGPU::PresentMode::Fifo
      config.alpha_mode = LibWGPU::CompositeAlphaMode::Auto
      LibWGPU.surface_configure(@surface, pointerof(config))
    end
  end
end
