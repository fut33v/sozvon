import SwiftUI

@main
struct CallListenerApp: App {
    @StateObject private var transcriber = SpeechTranscriber()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(transcriber)
                .frame(minWidth: 720, minHeight: 520)
                .task {
                    await transcriber.refreshPermissionStatus()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
