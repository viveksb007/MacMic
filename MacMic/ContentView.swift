import CoreAudio
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var audioManager: AudioManager

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            deviceSelections
            Divider().opacity(0.5)
            streamingControls
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(audioManager.isStreaming
                          ? Color.green.opacity(0.15)
                          : Color.secondary.opacity(0.08))
                    .frame(width: 38, height: 38)

                Image(systemName: audioManager.isStreaming ? "waveform" : "mic.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(audioManager.isStreaming ? .green : .secondary)
                    .symbolEffect(.variableColor.iterative, isActive: audioManager.isStreaming)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("MacMic")
                    .font(.system(size: 15, weight: .bold, design: .rounded))

                Text(audioManager.isStreaming ? "Streaming audio..." : "Ready")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(audioManager.isStreaming ? .green : .secondary)
            }

            Spacer()

            if audioManager.isStreaming {
                liveBadge
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var liveBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(.red)
                .frame(width: 6, height: 6)

            Text("LIVE")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(.red)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(.red.opacity(0.12))
        )
    }

    // MARK: - Device Selections

    private var deviceSelections: some View {
        VStack(spacing: 14) {
            DevicePickerCard(
                title: "Input",
                subtitle: "Microphone",
                icon: "mic.fill",
                devices: audioManager.inputDevices,
                selection: $audioManager.selectedInputID,
                accentColor: .blue
            )

            DevicePickerCard(
                title: "Output",
                subtitle: "Speaker",
                icon: "speaker.wave.2.fill",
                devices: audioManager.outputDevices,
                selection: $audioManager.selectedOutputID,
                accentColor: .purple
            )
        }
        .padding(16)
    }

    // MARK: - Streaming Controls

    private var streamingControls: some View {
        VStack(spacing: 10) {
            if audioManager.isStreaming {
                levelMeter
            }

            Button {
                if audioManager.isStreaming {
                    audioManager.stopStreaming()
                } else {
                    audioManager.startStreaming()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: audioManager.isStreaming ? "stop.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold))

                    Text(audioManager.isStreaming ? "Stop" : "Start Streaming")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(audioManager.isStreaming ? .red : .accentColor)
            .disabled(!canStream)
            .keyboardShortcut(.return, modifiers: [])

            if let error = audioManager.errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.system(size: 11))

                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !audioManager.statusInfo.isEmpty {
                Text(audioManager.statusInfo)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
    }

    private var canStream: Bool {
        audioManager.selectedInputID != nil && audioManager.selectedOutputID != nil
    }

    // MARK: - Level Meter

    private var levelMeter: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Input Level")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(audioManager.inputLevel * 100))%")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.06))

                    RoundedRectangle(cornerRadius: 3)
                        .fill(levelGradient)
                        .frame(width: max(0, geo.size.width * CGFloat(audioManager.inputLevel)))
                        .animation(.easeOut(duration: 0.08), value: audioManager.inputLevel)
                }
            }
            .frame(height: 6)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.03))
        )
    }

    private var levelGradient: LinearGradient {
        LinearGradient(
            colors: [.green, audioManager.inputLevel > 0.7 ? .red : .yellow],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    // MARK: - Footer

    private var footer: some View {
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "power")
                    .font(.system(size: 11))
                Text("Quit")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("q")
    }
}

// MARK: - Device Picker Card

private struct DevicePickerCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let devices: [AudioDevice]
    let selection: Binding<AudioDeviceID?>
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accentColor)

                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text("(\(subtitle))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Picker(title, selection: selection) {
                Text("None selected")
                    .tag(AudioDeviceID?.none)

                ForEach(devices) { device in
                    Text(device.name).tag(Optional(device.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(accentColor.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(accentColor.opacity(0.12), lineWidth: 1)
                )
        )
    }
}
