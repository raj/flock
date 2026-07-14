module Flock
  # Capture des erreurs wgpu. `WGPU.request_device` (wgpu-cr) crée le device sans
  # callback d'erreur : une erreur de validation passe alors en silence. Flock crée
  # donc le device lui-même en branchant deux callbacks qui journalisent sur STDERR :
  #   - uncaptured error (validation, out-of-memory, interne)
  #   - device lost
  #
  # Les callbacks C doivent être des procs NON capturants (contrainte FFI Crystal) :
  # ils n'utilisent que leurs arguments + des méthodes/constantes de module.

  # Callback d'erreur non capturée.
  UNCAPTURED_ERROR_CALLBACK = ->(_device : Pointer(LibWGPU::Device), type : LibWGPU::ErrorType,
                                 message : LibWGPU::StringView, _u1 : Void*, _u2 : Void*) do
    STDERR.puts "[wgpu][#{type}] #{WGPU.to_s(message)}"
    nil
  end

  # Callback de perte de device.
  DEVICE_LOST_CALLBACK = ->(_device : Pointer(LibWGPU::Device), reason : LibWGPU::DeviceLostReason,
                            message : LibWGPU::StringView, _u1 : Void*, _u2 : Void*) do
    STDERR.puts "[wgpu][device lost: #{reason}] #{WGPU.to_s(message)}"
    nil
  end

  # Reçoit le device via userdata pendant la requête asynchrone.
  struct DeviceRequestResult
    property handle : LibWGPU::Device
    property status : LibWGPU::RequestDeviceStatus
    property done : Bool

    def initialize
      @handle = Pointer(Void).null.as(LibWGPU::Device)
      @status = LibWGPU::RequestDeviceStatus::Success
      @done = false
    end
  end

  # Équivalent de `WGPU.request_device` mais avec les callbacks d'erreur branchés.
  def self.request_device(instance : LibWGPU::Instance, adapter : LibWGPU::Adapter) : LibWGPU::Device
    result = DeviceRequestResult.new

    desc = LibWGPU::DeviceDescriptor.new
    desc.label = WGPU.empty_string_view

    ue = LibWGPU::UncapturedErrorCallbackInfo.new
    ue.callback = UNCAPTURED_ERROR_CALLBACK
    desc.uncaptured_error_callback_info = ue

    dl = LibWGPU::DeviceLostCallbackInfo.new
    dl.mode = LibWGPU::CallbackMode::AllowProcessEvents
    dl.callback = DEVICE_LOST_CALLBACK
    desc.device_lost_callback_info = dl

    cb = ->(status : LibWGPU::RequestDeviceStatus, device : LibWGPU::Device,
            _message : LibWGPU::StringView, u1 : Void*, _u2 : Void*) do
      r = u1.as(Pointer(DeviceRequestResult))
      r.value.handle = device
      r.value.status = status
      r.value.done = true
      nil
    end

    info = LibWGPU::RequestDeviceCallbackInfo.new
    info.mode = LibWGPU::CallbackMode::AllowProcessEvents
    info.callback = cb
    info.userdata1 = pointerof(result).as(Void*)

    LibWGPU.adapter_request_device(adapter, pointerof(desc), info)
    100_000.times do
      break if result.done
      LibWGPU.instance_process_events(instance)
      sleep(1.milliseconds)
    end

    raise "Flock.request_device a échoué : #{result.status}" unless result.status.success?
    result.handle
  end
end
