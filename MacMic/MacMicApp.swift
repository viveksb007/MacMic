import SwiftUI

@main
struct MacMicApp: App {
    @StateObject private var audioManager = AudioManager()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(audioManager)
        } label: {
            Image(systemName: audioManager.isStreaming ? "mic.circle.fill" : "mic.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
