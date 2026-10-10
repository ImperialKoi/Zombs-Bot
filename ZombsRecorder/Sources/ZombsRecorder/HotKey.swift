import AppKit
import Carbon.HIToolbox

/// A system-wide key through Carbon's RegisterEventHotKey, which needs no Accessibility permission.
/// While registered, the key goes to the action instead of the front app.
final class HotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: Int, modifiers: Int = 0, action: @escaping () -> Void) {
        self.action = action
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetEventDispatcherTarget(), { _, _, context in
            guard let context else { return noErr }
            Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue().action()
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x5A52_4543), id: 1)  // "ZREC"
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetEventDispatcherTarget(), 0, &hotKey) == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

/// "=" starts and stops a recording while the ZombsRoyale Chrome window is in front. The key is claimed only
/// then, so "=" still types normally in every other app and tab.
@MainActor
final class RecordKey {
    static let label = "="
    private var hotKey: HotKey?
    private var poll: Timer?
    private var observer: NSObjectProtocol?
    private var lastPress = Date.distantPast
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.frontAppChanged() }
        }
        frontAppChanged()
    }

    /// Switching tabs does not switch apps, so the front window is checked twice a second, but only while Chrome is in front.
    private func frontAppChanged() {
        let chrome = (NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "").hasPrefix("com.google.Chrome")
        if chrome && poll == nil {
            poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
        } else if !chrome {
            poll?.invalidate()
            poll = nil
        }
        update()
    }

    private func update() {
        let inGame = GameWindow.frontmostGame() != nil
        if inGame && hotKey == nil {
            hotKey = HotKey(keyCode: kVK_ANSI_Equal) { [weak self] in MainActor.assumeIsolated { self?.pressed() } }
        } else if !inGame {
            hotKey = nil
        }
    }

    private func pressed() {
        guard Date().timeIntervalSince(lastPress) > 1 else { return }  // Ignore key repeat and double presses.
        lastPress = Date()
        action()
    }
}
