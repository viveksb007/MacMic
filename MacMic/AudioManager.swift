import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

@MainActor
final class AudioManager: ObservableObject {
    @Published var inputDevices: [AudioDevice] = []
    @Published var outputDevices: [AudioDevice] = []
    @Published var selectedInputID: AudioDeviceID?
    @Published var selectedOutputID: AudioDeviceID?
    @Published var isStreaming = false
    @Published var errorMessage: String?
    @Published var inputLevel: Float = 0
    @Published var micPermissionGranted = false
    @Published var statusInfo: String = ""

    /// The AUHAL audio unit doing the actual pass-through.
    /// Accessed from the audio render thread — set before start, read during render.
    nonisolated(unsafe) fileprivate var audioUnit: AudioComponentInstance?
    /// Aggregate device combining the selected input + output devices
    private var aggregateDeviceID: AudioDeviceID = 0
    /// Timer that polls the level from the audio thread
    private var levelTimer: Timer?
    /// Written on the audio thread, read by the level timer
    nonisolated(unsafe) fileprivate var _currentLevel: Float = 0

    init() {
        refreshDevices()
        observeDeviceChanges()
        checkMicPermission()
    }

    // MARK: - Microphone Permission

    func checkMicPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            micPermissionGranted = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor [weak self] in
                    self?.micPermissionGranted = granted
                    if !granted {
                        self?.errorMessage = "Microphone access denied. Grant access in System Settings > Privacy & Security > Microphone."
                    }
                }
            }
        case .denied, .restricted:
            micPermissionGranted = false
            errorMessage = "Microphone access denied. Grant access in System Settings > Privacy & Security > Microphone."
        @unknown default:
            break
        }
    }

    // MARK: - Device Management

    func refreshDevices() {
        let allDevices = AudioDevice.allDevices()
        inputDevices = allDevices.filter(\.hasInput)
        outputDevices = allDevices.filter(\.hasOutput)

        if let sel = selectedInputID, !inputDevices.contains(where: { $0.id == sel }) {
            selectedInputID = nil
            if isStreaming { stopStreaming() }
        }
        if let sel = selectedOutputID, !outputDevices.contains(where: { $0.id == sel }) {
            selectedOutputID = nil
            if isStreaming { stopStreaming() }
        }
    }

    // MARK: - Streaming

    func startStreaming() {
        guard micPermissionGranted else {
            checkMicPermission()
            errorMessage = "Microphone access is required."
            return
        }
        guard let inputID = selectedInputID, let outputID = selectedOutputID else {
            errorMessage = "Select both a microphone and a speaker."
            return
        }
        guard let inputDevice = inputDevices.first(where: { $0.id == inputID }),
              let outputDevice = outputDevices.first(where: { $0.id == outputID }) else {
            errorMessage = "Selected device no longer available."
            return
        }

        stopStreaming()
        errorMessage = nil
        statusInfo = ""

        do {
            // --- 1. Create an aggregate device combining input + output ---
            let aggID = try createAggregateDevice(inputUID: inputDevice.uid, outputUID: outputDevice.uid)
            self.aggregateDeviceID = aggID

            // Give the aggregate device time to initialize its IO threads
            Thread.sleep(forTimeInterval: 0.1)

            // --- 2. Create a HAL Output audio unit ---
            var desc = AudioComponentDescription(
                componentType: kAudioUnitType_Output,
                componentSubType: kAudioUnitSubType_HALOutput,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0
            )
            guard let component = AudioComponentFindNext(nil, &desc) else {
                throw StreamError.msg("HAL output audio component not found.")
            }
            var au: AudioComponentInstance?
            try osCheck(AudioComponentInstanceNew(component, &au), "create audio unit")
            guard let au else { throw StreamError.msg("Audio unit instance is nil.") }

            // --- 3. Enable input (element 1) BEFORE setting the device ---
            var one: UInt32 = 1
            try osCheck(AudioUnitSetProperty(
                au, kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input, 1,
                &one, UInt32(MemoryLayout<UInt32>.size)
            ), "enable input IO")

            // --- 4. Set the aggregate device on the unit ---
            var devID = aggID
            try osCheck(AudioUnitSetProperty(
                au, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &devID, UInt32(MemoryLayout<AudioDeviceID>.size)
            ), "set aggregate device")

            // --- 5. Set up client formats ---
            // Read the hardware formats from each side
            var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

            var hwInputFormat = AudioStreamBasicDescription()
            try osCheck(AudioUnitGetProperty(
                au, kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input, 1,        // hardware input format
                &hwInputFormat, &asbdSize
            ), "get hardware input format")

            // Build a canonical Float32 non-interleaved format using the
            // input device's sample rate and channel count.  The AUHAL
            // will convert between this and each device's native format.
            var clientFormat = AudioStreamBasicDescription(
                mSampleRate: hwInputFormat.mSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: hwInputFormat.mChannelsPerFrame,
                mBitsPerChannel: 32,
                mReserved: 0
            )

            // Set client format on the input side (Output scope, element 1)
            // — this is the format AudioUnitRender will deliver to us.
            try osCheck(AudioUnitSetProperty(
                au, kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output, 1,
                &clientFormat, asbdSize
            ), "set client input format")

            // Set the same client format on the output side (Input scope, element 0)
            // — this is the format our render callback will provide.
            try osCheck(AudioUnitSetProperty(
                au, kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input, 0,
                &clientFormat, asbdSize
            ), "set client output format")

            // --- 6. Install render callback ---
            var callbackStruct = AURenderCallbackStruct(
                inputProc: auRenderCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try osCheck(AudioUnitSetProperty(
                au, kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input, 0,
                &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ), "set render callback")

            // --- 7. Initialize & start ---
            try osCheck(AudioUnitInitialize(au), "initialize audio unit")
            try osCheck(AudioOutputUnitStart(au), "start audio unit")

            self.audioUnit = au
            self.isStreaming = true
            statusInfo = String(format: "%.0f Hz / %d ch",
                                clientFormat.mSampleRate,
                                clientFormat.mChannelsPerFrame)

            // Poll the level value from the audio thread
            levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.inputLevel = self._currentLevel
                }
            }

        } catch let error as StreamError {
            errorMessage = error.message
            teardownAudio()
        } catch {
            errorMessage = error.localizedDescription
            teardownAudio()
        }
    }

    func stopStreaming() {
        levelTimer?.invalidate()
        levelTimer = nil
        teardownAudio()
        isStreaming = false
        inputLevel = 0
        statusInfo = ""
    }

    // MARK: - Internals

    private func teardownAudio() {
        if let au = audioUnit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            audioUnit = nil
        }
        if aggregateDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = 0
        }
    }

    private func createAggregateDevice(inputUID: String, outputUID: String) throws -> AudioDeviceID {
        let subDevices: [[String: Any]] = [
            [kAudioSubDeviceUIDKey as String: outputUID],
            [kAudioSubDeviceUIDKey as String: inputUID],
        ]
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "MacMic Passthrough",
            kAudioAggregateDeviceUIDKey as String: "com.macmic.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceSubDeviceListKey as String: subDevices,
            kAudioAggregateDeviceMasterSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
        ]
        var aggDeviceID: AudioDeviceID = 0
        try osCheck(
            AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggDeviceID),
            "create aggregate device"
        )
        return aggDeviceID
    }

    // MARK: - Device Change Observation

    private func observeDeviceChanges() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refreshDevices()
            }
        }
    }

    // MARK: - Helpers

    private enum StreamError: Error {
        case msg(String)
        var message: String {
            switch self { case .msg(let m): return m }
        }
    }

    private func osCheck(_ status: OSStatus, _ label: String) throws {
        guard status == noErr else {
            throw StreamError.msg("Failed to \(label) (OSStatus \(status)).")
        }
    }
}

// MARK: - Audio render callback (runs on the real-time audio thread)

/// Pulls audio from the aggregate device's input (element 1) and writes it
/// to the output (element 0). This is a C-compatible function pointer.
private func auRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let mgr = Unmanaged<AudioManager>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let au = mgr.audioUnit, let ioData else { return noErr }

    // Pull audio from input element (bus 1)
    let status = AudioUnitRender(au, ioActionFlags, inTimeStamp, 1, inNumberFrames, ioData)

    // Compute RMS level for the meter
    if status == noErr {
        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        var sum: Float = 0
        var count: Int = 0
        for buf in abl {
            guard let data = buf.mData?.assumingMemoryBound(to: Float32.self) else { continue }
            let samples = Int(buf.mDataByteSize) / MemoryLayout<Float32>.size
            for i in 0..<samples {
                let s = data[i]
                sum += s * s
            }
            count += samples
        }
        if count > 0 {
            mgr._currentLevel = min(1.0, sqrt(sum / Float(count)) * 5)
        }
    }

    return status
}
