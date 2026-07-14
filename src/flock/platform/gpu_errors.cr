module Flock
  # wgpu error capture. `WGPU.request_device` (wgpu-cr) creates the device without
  # an error callback: a validation error then passes silently. So Flock creates
  # the device itself, hooking up two callbacks that log to STDERR:
  #   - uncaptured error (validation, out-of-memory, internal)
  #   - device lost
  #
  # The C callbacks must be NON-capturing procs (Crystal FFI constraint): they
  # only use their arguments + module methods/constants.

  # Uncaptured error callback.
  UNCAPTURED_ERROR_CALLBACK = ->(_device : Pointer(LibWGPU::Device), type : LibWGPU::ErrorType,
                                 message : LibWGPU::StringView, _u1 : Void*, _u2 : Void*) do
    STDERR.puts "[wgpu][#{type}] #{WGPU.to_s(message)}"
    nil
  end

  # Device lost callback.
  DEVICE_LOST_CALLBACK = ->(_device : Pointer(LibWGPU::Device), reason : LibWGPU::DeviceLostReason,
                            message : LibWGPU::StringView, _u1 : Void*, _u2 : Void*) do
    STDERR.puts "[wgpu][device lost: #{reason}] #{WGPU.to_s(message)}"
    nil
  end

  # Receives the device via userdata during the asynchronous request.
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

  # Equivalent of `WGPU.request_device` but with the error callbacks hooked up.
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

    raise "Flock.request_device failed: #{result.status}" unless result.status.success?
    result.handle
  end
end
