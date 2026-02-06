# AGENTS.md — MacMic Development Guide

## Project Overview

MacMic is a macOS menu bar app that streams audio in real-time from any microphone to any speaker. Users select an input device (mic) and output device (speaker) from the menu bar popover, and the app routes audio between them with minimal latency.

## Architecture

### Audio Pipeline (CoreAudio, no AVAudioEngine)

The app uses **low-level CoreAudio** for audio routing. AVAudioEngine was abandoned because it does not support setting specific input/output devices on its managed audio units (the output node rejects `kAudioOutputUnitProperty_CurrentDevice` even after uninitialization).

**The pipeline:**

1. **Aggregate Device** — `AudioHardwareCreateAggregateDevice` creates a private virtual device combining the selected input and output devices into a single synchronized clock domain.
2. **HAL Output Audio Unit** (`kAudioUnitSubType_HALOutput`) — A single AUHAL unit is created with the aggregate device. Input is enabled on element 1, output on element 0.
3. **Render Callback** — A C-compatible function (`auRenderCallback`) on element 0's input scope pulls audio from element 1 via `AudioUnitRender`. This is zero-copy within the same aggregate device.
4. **Format Negotiation** — A canonical Float32 non-interleaved format is set as the client format on both sides. The AUHAL handles conversion between each device's native hardware format and this client format.

**Key file:** `MacMic/AudioManager.swift`

### AUHAL Element/Scope Reference

This is the most confusing part of CoreAudio. For a HAL Output unit:

| Element | Scope  | Meaning                                      |
|---------|--------|----------------------------------------------|
| 1       | Input  | Hardware input format (mic) — read only       |
| 1       | Output | Client input format — what `AudioUnitRender` delivers to your code |
| 0       | Input  | Client output format — what your render callback provides |
| 0       | Output | Hardware output format (speaker) — read only  |

### Device Enumeration

`MacMic/AudioDevice.swift` uses CoreAudio's `AudioObjectGetPropertyData` to enumerate all system audio devices. Each device is checked for input/output capability via `kAudioDevicePropertyStreamConfiguration` (channel count per scope).

**Known quirk:** `AudioObjectGetPropertyData` for `CFString` properties (device name, UID) produces a compiler warning about forming unsafe pointers to reference types. This is unavoidable when bridging CoreAudio's C API and is safe in practice.

### UI Layer (SwiftUI)

- **`MacMicApp.swift`** — App entry point. Uses `MenuBarExtra` with `.window` style. The menu bar icon changes between `mic.fill` (idle) and `waveform` (streaming).
- **`ContentView.swift`** — Menu bar popover with device pickers, start/stop button, level meter, and quit button. Keyboard shortcuts: `Return` (start/stop), `Cmd+Q` (quit).
- **`Info.plist`** — `LSUIElement=true` hides the app from the Dock. `NSMicrophoneUsageDescription` is required for the mic permission dialog.

### State Management

`AudioManager` is an `@MainActor ObservableObject` injected via `@EnvironmentObject`. It owns the audio unit lifecycle, device enumeration, mic permission handling, and level metering.

The level meter uses `nonisolated(unsafe)` for a `_currentLevel` float that the audio render callback writes to (on the audio thread) and a `Timer` polls from (on the main thread). This is a deliberate data race on a single float — acceptable for a visual meter.

## Build & Run

**Requirements:** Xcode 16+, macOS 14+ (Sonoma), [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```bash
# Regenerate the Xcode project after modifying project.yml
xcodegen generate

# Build from command line
xcodebuild -project MacMic.xcodeproj -scheme MacMic -configuration Debug build

# Run
open ~/Library/Developer/Xcode/DerivedData/MacMic-*/Build/Products/Debug/MacMic.app
```

Or open `MacMic.xcodeproj` in Xcode and press `Cmd+R`.

## Important Implementation Notes

- **No App Sandbox** — The entitlements file disables sandbox (`com.apple.security.app-sandbox = false`). Sandbox blocks `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)` and `AudioHardwareCreateAggregateDevice`. If App Store distribution is needed, this will require significant rework (likely using the system default devices only).
- **Aggregate device init delay** — After `AudioHardwareCreateAggregateDevice`, a 100ms sleep is needed before using the device. Without this, the AUHAL's IO threads collide with the aggregate device's still-initializing threads (`HALB_IOThread::_Start: there already is a thread`).
- **Enable IO before setting device** — `kAudioOutputUnitProperty_EnableIO` on element 1 must be called before `kAudioOutputUnitProperty_CurrentDevice`. Otherwise the AUHAL doesn't configure input paths.
- **Bluetooth limitations** — When a BT device's mic is activated, macOS switches from A2DP to HFP/SCO profile, dropping output quality to ~16kHz. This is a Bluetooth protocol limitation.
- **Console noise** — `AddInstanceForFactory`, `throwing -10877`, `Unable to obtain task name port`, `fopen failed for data file` are all harmless CoreAudio system messages that appear in every macOS audio app. They are not errors.
- **Aggregate device cleanup** — `AudioHardwareDestroyAggregateDevice` must be called in `stopStreaming` / `teardownAudio`. Leaked aggregate devices persist until reboot.

## File Reference

| File | Purpose |
|------|---------|
| `MacMic/MacMicApp.swift` | `@main` entry point, `MenuBarExtra` scene |
| `MacMic/ContentView.swift` | SwiftUI popover UI, device pickers, level meter |
| `MacMic/AudioManager.swift` | Audio engine: aggregate device, AUHAL, render callback, level metering, mic permission |
| `MacMic/AudioDevice.swift` | CoreAudio device enumeration (name, UID, channel count) |
| `MacMic/Info.plist` | `LSUIElement`, `NSMicrophoneUsageDescription` |
| `MacMic/MacMic.entitlements` | Sandbox disabled |
| `MacMic/Assets.xcassets/` | Asset catalog (app icon placeholder) |
| `project.yml` | XcodeGen project spec |
