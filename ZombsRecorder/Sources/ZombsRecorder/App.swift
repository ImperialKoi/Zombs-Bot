import SwiftUI
import RecorderCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor lazy var model = RecorderModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // Menu bar only, also when run outside the .app bundle.
    }

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        _ = model
    }

    /// Quitting mid-match saves the recording first.
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.recording else { return .terminateNow }
        Task {
            await model.stop(.menu)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct ZombsRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            RecorderMenu(model: delegate.model)
        } label: {
            MenuLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.menu)
        Settings { SetupView(model: delegate.model) }
    }
}

struct MenuLabel: View {
    @ObservedObject var model: RecorderModel
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Text("\(Image(systemName: model.recording ? "record.circle.fill" : "record.circle")) \(model.menuTitle)")
            .task {
                if model.needsSetup { openSettings() }  // First launch: show the setup checklist.
            }
    }
}

struct RecorderMenu: View {
    @ObservedObject var model: RecorderModel
    var body: some View {
        Text(model.statusLine)
        if model.recording {
            Button("Stop and save recording (\(RecordKey.label))") { model.toggle(.menu) }
            Button("Discard this recording") { Task { await model.discard() } }
        } else {
            Button("Start recording (\(RecordKey.label) in the game)") { model.toggle(.menu) }.disabled(model.busy)
        }
        Divider()
        Picker("Mode", selection: $model.mode) {
            ForEach(GameMode.allCases, id: \.self) { mode in Text(mode.rawValue.capitalized).tag(mode) }
        }.disabled(model.recording)
        Divider()
        Text(model.uploadLine)
        if let problem = model.upload.problem { Text(problem) }
        if model.upload.failed > 0 { Button("Retry \(model.upload.failed) failed upload(s)") { model.retryFailed() } }
        if let notice = model.notice {
            Divider()
            Text(notice)
        }
        Divider()
        SettingsLink { Text("Setup…") }
        Button("Setup guide") { model.openGuide() }
        Button("Open recordings folder") { model.openRecordings() }
        Divider()
        Button("Quit Zombs Recorder") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
