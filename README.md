# MacMic

A macOS menu bar app that streams audio in real-time from any microphone to any speaker.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift](https://img.shields.io/badge/Swift-5.9-orange)

## Features

- **Device selection** — Pick any available microphone and speaker independently
- **Real-time streaming** — Low-latency audio pass-through via CoreAudio aggregate devices
- **Live level meter** — Visual input level indicator while streaming
- **Auto-detection** — Device list updates automatically when hardware is connected/disconnected
- **Menu bar app** — Lives in the menu bar, no Dock icon

## How It Works

MacMic creates a private [aggregate device](https://developer.apple.com/documentation/coreaudio/using-voice-processing) combining the selected input and output devices, then routes audio through a HAL Output audio unit with a render callback. This is the same approach used by professional audio software to handle cross-device routing on macOS.

## Install

### Homebrew

```bash
brew tap viveksb007/tap
brew install --cask macmic
```

### Build from source

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
open MacMic.xcodeproj
```

Then press `Cmd+R` in Xcode.

## Usage

1. Click the mic icon in the menu bar
2. Select a microphone from the **Input** picker
3. Select a speaker from the **Output** picker
4. Press **Start Streaming**

**Keyboard shortcuts:** `Return` to start/stop, `Cmd+Q` to quit.

## Notes

- Selecting the same device for both input and output (e.g., MacBook mic + MacBook speakers) will cause audio feedback. Use headphones or an external speaker.
- Bluetooth devices switch from A2DP to HFP/SCO profile when their microphone is activated, which reduces output audio quality. This is a Bluetooth protocol limitation.

## Backstory

Years ago, I built [PhoneMic](https://play.google.com/store/apps/details?id=com.viveksb007.phonemic) — an Android app that does the same thing: stream microphone audio to a speaker. I wanted the same functionality on macOS, but this time on an entirely different tech stack (Swift, CoreAudio, SwiftUI) that I had no prior experience with. This app was built almost entirely with the help of AI — from the low-level aggregate device setup to the SwiftUI menu bar interface.

## License

MIT
