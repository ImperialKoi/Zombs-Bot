import AppKit
import ApplicationServices
import AssistantCore

/// Owns every synthesized event. The watchdog also works when the main UI is stalled.
final class InputDriver {
    static let eventTag: Int64 = 0x5A4F4D4253
    private let lock = NSRecursiveLock()
    private let source = CGEventSource(stateID: .hidSystemState)
    private var mouseHeld = false
    /// Interact held down at an air drop; released by any decision that does not ask for it.
    private var interactHeld = false
    private var pressedKeys=Set<UInt16>()
    private let releaseQueue=DispatchQueue(label:"input.key-release",qos:.userInteractive)
    private var enabled = false
    private var windowID: CGWindowID = 0
    private var lastObservation: Observation?
    private var aim: Point?
    private var watchdog: DispatchSourceTimer?
    var bindings = KeyBindings()
    var profiles: [String:ItemProfile] = [:]
    var settings = CombatSettings()
    init() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "input.watchdog", qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(30))
        timer.setEventHandler { [weak self] in self?.checkWatchdog() }
        timer.resume(); watchdog = timer
    }
    deinit { watchdog?.cancel(); releaseAll() }
    func setEnabled(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        enabled = value
        if !value { releaseAll() }
    }
    func apply(_ decision: Decision, observation o: Observation, frame: CaptureFrame) {
        lock.lock(); defer { lock.unlock() }
        windowID = frame.windowID; lastObservation = o
        guard enabled, bindings.isValid, AXIsProcessTrusted(), CaptureService.isFocused(windowID) else { releaseAll(); return }
        let guardrail = ActionGuard(profiles: profiles, settings: settings)
        let bounds = frame.windowBounds, content = frame.contentRect
        if interactHeld && !decision.intents.contains(where: { if case .holdOpen = $0 { return true }; return false }) { releaseInteract() }
        for intent in decision.intents {
            guard CaptureService.isFocused(windowID), guardrail.permits(intent, observation: o, now: ProcessInfo.processInfo.systemUptime, aim: aim) else { releaseAll(); return }
            switch intent {
            case .releaseAll: releaseAll()
            case .aim(let point):
                aim = point
                // Viewport coordinates cover the captured game area below Chrome's toolbar.
                let x: Double = Double(bounds.minX + content.minX) + point.x * Double(content.width)
                let y: Double = Double(bounds.minY + content.minY) + point.y * Double(content.height)
                let screen = CGPoint(x: x, y: y)
                post(CGEvent(mouseEventSource: source, mouseType: mouseHeld ? .leftMouseDragged : .mouseMoved, mouseCursorPosition: screen, mouseButton: .left))
            case .fire, .useConsumable:
                if !mouseHeld { post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: CGEvent(source:nil)?.location ?? .zero, mouseButton:.left)); mouseHeld = true }
            case .selectSlot(let index): releaseAll(); tap(bindings.slots[index - 1])
            case .reload: releaseAll(); tap(bindings.reload)
            case .pickup, .open: releaseAll(); tap(bindings.interact)
            case .holdOpen:
                if !interactHeld, KeyBindings.allowed.contains(bindings.interact) {
                    post(CGEvent(keyboardEventSource: source, virtualKey: bindings.interact, keyDown: true)); interactHeld = true
                }
            }
        }
    }
    func releaseAll() {
        lock.lock(); defer { lock.unlock() }
        if mouseHeld { post(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: CGEvent(source:nil)?.location ?? .zero, mouseButton:.left)); mouseHeld = false }
        for key in pressedKeys { post(CGEvent(keyboardEventSource:source,virtualKey:key,keyDown:false)) }
        pressedKeys.removeAll()
        releaseInteract()
        aim = nil
    }
    private func releaseInteract() {
        lock.lock(); defer { lock.unlock() }
        if interactHeld { post(CGEvent(keyboardEventSource: source, virtualKey: bindings.interact, keyDown: false)); interactHeld = false }
    }
    private func tap(_ key: UInt16) {
        guard KeyBindings.allowed.contains(key), !pressedKeys.contains(key) else { return }
        pressedKeys.insert(key)
        post(CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true))
        releaseQueue.asyncAfter(deadline:.now()+0.035) { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            if self.pressedKeys.remove(key) != nil { self.post(CGEvent(keyboardEventSource:self.source,virtualKey:key,keyDown:false)) }
        }
    }
    private func post(_ event: CGEvent?) {
        event?.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        event?.post(tap: .cghidEventTap)
    }
    private func checkWatchdog() {
        lock.lock(); defer { lock.unlock() }
        guard mouseHeld || interactHeld || !pressedKeys.isEmpty else { return }
        guard enabled, let o = lastObservation, Policy.haltReason(o, now: ProcessInfo.processInfo.systemUptime) == nil,
              AXIsProcessTrusted(), CaptureService.isFocused(windowID) else { releaseAll(); return }
    }
}

/// Passive event tap: never consumes, rewrites or releases the user's movement keys.
final class ManualInputMonitor {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let lock = NSLock()
    private var held: Set<Int64> = []
    private var option = false
    private var yieldUntil = 0.0
    var bindings = KeyBindings()
    /// Called with the reason input must stop.
    var onStop: ((String) -> Void)?
    /// Called when "=" is pressed in Chrome: start or stop sending input.
    var onToggle: (() -> Void)?
    static let toggleKey: Int64 = 24 // "="
    private var lastToggle = 0.0
    var onYield: (() -> Void)?
    var running: Bool { tap != nil }
    var shouldYield: Bool {
        lock.lock(); defer { lock.unlock() }
        return option || !held.isEmpty || ProcessInfo.processInfo.systemUptime < yieldUntil
    }
    func start() -> Bool {
        if tap != nil { return true }
        let mask = [CGEventType.keyDown,.keyUp,.flagsChanged,.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.scrollWheel].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<ManualInputMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.receive(type, event)
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
    private func receive(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByUserInput {
            // Secure input (a password field) hides keys from the monitor, including Escape.
            onStop?("Input stopped: macOS secure input (a password field) hid the keyboard. Press = in the game to start again."); if let tap { CGEvent.tapEnable(tap: tap, enable: true) }; return
        }
        if type == .tapDisabledByTimeout {
            // macOS pauses a slow monitor; resume it and give control back briefly instead of disarming.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            lock.lock(); yieldUntil = ProcessInfo.processInfo.systemUptime + 0.75; lock.unlock()
            onYield?(); return
        }
        guard event.getIntegerValueField(.eventSourceUserData) != InputDriver.eventTag else { return }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyDown && key == 53 { onStop?("Input stopped: Escape pressed. Press = in the game to start again."); return }
        if type == .keyDown && key == Self.toggleKey && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 && CaptureService.chromeActive {
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock(); let fresh = now - lastToggle > 0.3; if fresh { lastToggle = now }; lock.unlock()
            if fresh { onToggle?() }
            return
        }
        lock.lock()
        var yields = false
        if type == .flagsChanged {
            option = event.flags.contains(.maskAlternate)
            // Command or Control (Cmd-Tab, shortcuts) lets go at once, while Chrome still gets the key-up for a held E.
            yields = option || event.flags.contains(.maskCommand) || event.flags.contains(.maskControl)
        }
        let watched = Set(([bindings.interact,bindings.reload] + bindings.slots).map(Int64.init))
        if watched.contains(key) && [.keyDown,.keyUp].contains(type) {
            if type == .keyDown { held.insert(key) } else { held.remove(key) }
            yields = true
        }
        if [.leftMouseDown,.rightMouseDown].contains(type) { held.insert(type == .leftMouseDown ? -1 : -2); yields = true }
        if [.leftMouseUp,.rightMouseUp].contains(type) { held.remove(type == .leftMouseUp ? -1 : -2); yields = true }
        if type == .scrollWheel { yields = true }
        if yields { yieldUntil = ProcessInfo.processInfo.systemUptime + 0.75 }
        lock.unlock()
        if yields { onYield?() }
    }
    deinit {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
    }
}
