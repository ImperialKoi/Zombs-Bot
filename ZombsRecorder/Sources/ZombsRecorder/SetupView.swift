import SwiftUI
import RecorderCore

/// Opens by itself until setup is done: screen recording, uploads, game area, then how to record.
struct SetupView: View {
    @ObservedObject var model: RecorderModel
    @Environment(\.dismiss) private var dismiss
    @State private var screenAllowed = CGPreflightScreenCaptureAccess()
    @State private var setupCode = ""
    @State private var accountMessage: String?
    @State private var checking = false
    @State private var preview: CGImage?
    @State private var windowSize = CGSize.zero
    @State private var showAdvanced = false

    var body: some View {
        Form {
            Section {
                Text("Zombs Recorder records the ZombsRoyale games you choose and uploads them for training. Do these checks once.")
                    .foregroundStyle(.secondary)
            }
            Section {
                if screenAllowed {
                    done("Screen recording is allowed.")
                } else {
                    Text("Needed to record the game. Click the button, switch on ZombsRecorder in System Settings, then click Quit & Reopen when macOS asks.")
                    Button("Allow Screen Recording…") { model.requestScreenRecording() }.buttonStyle(.borderedProminent)
                }
            } header: { step(1, "Screen recording", ok: screenAllowed) }
            Section {
                if let credentials = model.credentials {
                    done("Recordings upload to \(credentials.owner)'s private Kaggle.")
                } else {
                    codeField
                }
            } header: { step(2, "Uploads", ok: model.credentials != nil) }
            Section {
                gameArea
                Slider(value: $model.topInset, in: 0...200, step: 1) { Text("Top edge: \(Int(model.topInset)) pt") }
                Text("Open ZombsRoyale in Chrome. The red line should sit on the top edge of the game, just below Chrome's tabs and address bar. Only the area below it is recorded.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { step(3, "Game area", ok: preview != nil) }
            Section("How to record") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Pick Solo, Duo or Squad from the record icon in the menu bar.")
                    Text("2. Click into the game and press **\(RecordKey.label)** about 10 seconds before you join a match. You hear a tick.")
                    Text("3. Press **\(RecordKey.label)** again when you are back in the menu after the match. You hear a pop.")
                    Text("Leave Zombs Recorder open: it uploads between matches, never during them.").foregroundStyle(.secondary)
                }
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) { advanced }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Done") { model.finishSetup(); dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            .background(.bar)
        }
        .frame(width: 560, height: 700)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
        .task {
            // Permission and the game window can change while this is open (macOS settings, opening Chrome).
            while !Task.isCancelled {
                screenAllowed = CGPreflightScreenCaptureAccess()
                if screenAllowed, let result = await model.windowPreview() { preview = result.image; windowSize = result.size }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder private var advanced: some View {
        TextField("Name on recordings", text: $model.recordedBy)
        TextField("Teammates (Duo/Squad, comma-separated)", text: $model.teammates)
        Toggle("Upload finished matches", isOn: $model.uploadsEnabled)
        Toggle("Delete the local video once Kaggle has it", isOn: $model.deleteAfterUpload)
        Button("Reset the game area to \(Int(RecorderModel.defaultTopInset)) pt") { model.topInset = RecorderModel.defaultTopInset }
        if model.credentials != nil { codeField }
        if Credentials.localAccessToken() != nil {
            Button("Use this Mac's Kaggle token (~/.kaggle/access_token)") { check { await model.useLocalToken() } }.disabled(checking)
        }
        if model.credentials != nil {
            Button("Copy setup code for friends") {
                model.copySetupCode()
                accountMessage = "Copied. Send it privately: anyone with it can use this Kaggle account."
            }
        }
        Button("Open recordings folder") { model.openRecordings() }
    }

    private var codeField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SecureField("Paste a setup code", text: $setupCode)
                Button("Use code") { check { await model.useSetupCode(setupCode) } }.disabled(setupCode.isEmpty || checking)
            }
            if let accountMessage { Text(accountMessage).font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var gameArea: some View {
        if let preview, windowSize.height > 0 {
            GeometryReader { geometry in
                let scale = geometry.size.width / windowSize.width
                let line = model.topInset * scale
                ZStack(alignment: .topLeading) {
                    Image(decorative: preview, scale: 1).resizable().frame(width: geometry.size.width, height: windowSize.height * scale)
                    Rectangle().fill(.black.opacity(0.45)).frame(width: geometry.size.width, height: line)
                    Rectangle().fill(.red).frame(width: geometry.size.width, height: 2).offset(y: max(0, line - 1))
                }
            }
            .aspectRatio(windowSize.width / windowSize.height, contentMode: .fit)
        } else {
            Text(screenAllowed ? "Open ZombsRoyale in Chrome to see it here." : "Shown once screen recording is allowed.")
                .foregroundStyle(.secondary)
        }
    }

    private func step(_ number: Int, _ title: String, ok: Bool) -> some View {
        HStack {
            Text("\(number). \(title)")
            if ok { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        }
    }

    private func done(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
    }

    private func check(_ action: @escaping () async -> String?) {
        checking = true
        Task {
            let error = await action()
            accountMessage = error ?? "Connected. Recordings upload to this account."
            if error == nil { setupCode = "" }
            checking = false
        }
    }
}
