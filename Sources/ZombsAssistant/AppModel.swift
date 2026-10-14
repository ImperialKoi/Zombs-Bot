import SwiftUI
import ScreenCaptureKit
import ApplicationServices
import CoreImage
import AssistantCore
import Perception

/// What the dashboard shows for one processed frame.
struct FrameReport {
    var image: CGImage?
    var observation: Observation
    var decision: Decision
    var detections: [Detection]
    var hud: HUDSnapshot?
    var promptLines: [String]
    var roster: [String]
    var problems: [String]
    var recognitionReady: Bool
    var band: WeaponRole?
    var fps: Double
    var latency: Double
    var performancePasses: Bool
    /// Why the game window does not have focus, or nil.
    var focusProblem: String?
    var windowBounds: CGRect
    var contentRect: CGRect
    var hudMilliseconds: Double
    var detectorMilliseconds: Double
    /// The healing item the assistant is selecting or using, nil otherwise.
    var healing: String?
    /// A lethal grenade the assistant threw, and the seconds until it goes off; you are warned to keep clear.
    var grenade: (name: String, seconds: Double)?
    /// A Healing Grenade the assistant threw at your feet: seconds it still heals, and whether you stand in its circle.
    var healCircle: (seconds: Double, inside: Bool)?
    /// The grenade circle's radius in view heights, drawn on the preview.
    var throwRadius: Double
}

final class ProcessingPipeline {
    private let queue=DispatchQueue(label:"perception.pipeline",qos:.userInitiated)
    private let admission=DispatchSemaphore(value:1)
    private let coordinator:Coordinator
    private let perception:PerceptionEngine
    private let library:IconLibrary
    private let preview=CIContext(options:[.cacheIntermediates:false])
    let driver:InputDriver
    let monitor:ManualInputMonitor
    let recorder:SessionRecorder
    private let verified:Bool
    private var performance=PerformanceWindow()
    private var lastPreview = -Double.infinity
    private var lastSave=0.0
    var onResult:((FrameReport)->Void)?
    /// The installed detector and its validation state, for the dashboard.
    let detectorSummary:String

    init(workspace:Workspace,calibration:Calibration,catalog:ItemCatalog,driver:InputDriver,monitor:ManualInputMonitor,recorder:SessionRecorder) {
        self.driver=driver; self.monitor=monitor; self.recorder=recorder; verified=calibration.verified
        coordinator=Coordinator(catalog:catalog,settings:calibration.combat)
        library=IconLibrary(url:workspace.iconsURL)
        let hasModel=FileManager.default.fileExists(atPath:workspace.artifacts.appendingPathComponent("model.json").path)
        perception=PerceptionEngine(artifacts:hasModel ? workspace.artifacts : nil,
                                    settings:PerceptionSettings(mode:calibration.mode,interactKey:KeyNames.name(calibration.keyBindings.interact),catalog:catalog),
                                    library:library,text:TextReader())
        if let detector=perception.detector { detectorSummary=detector.validationReason }
        else { detectorSummary=perception.detectorProblem ?? "No detector installed" }
    }
    func setFeatures(_ features:Features) { queue.async { self.coordinator.features=features } }
    func reset() { queue.async { self.coordinator.reset() } }
    func saveLibrary() { queue.async { try? self.library.save() } }
    func offer(_ frame:CaptureFrame) {
        guard admission.wait(timeout:.now()) == .success else { return }
        queue.async { [self] in
            defer { admission.signal() }
            guard let pixels=PixelImage(pixelBuffer:frame.pixelBuffer) else { return }
            let ci=CIImage(cvPixelBuffer:frame.pixelBuffer)
            var result=perception.process(image:pixels,ciImage:ci,timestamp:frame.timestamp)
            let now=ProcessInfo.processInfo.systemUptime
            performance.record(frameTime:frame.timestamp,completedAt:now)
            let focusProblem=CaptureService.focusProblem(frame.windowID)
            result.observation.focused=focusProblem==nil
            result.observation.manualOverride=monitor.shouldYield
            result.observation.perceptionReady=result.recognitionReady && verified && performance.passes(minimumFPS:PerformanceWindow.betaMinimumFPS)
            let decision=coordinator.step(result.observation,now:now)
            driver.apply(decision,observation:result.observation,frame:frame)
            recorder.append(image:{ pixels.cgImage() },observation:result.observation,decision:decision)
            if now-lastSave>30 && library.dirty { try? library.save(); lastSave=now }
            guard let onResult, now-lastPreview>=0.1 else { return }
            lastPreview=now
            // In a match the detector has already scaled the frame down; reuse that instead of another GPU render.
            let scale=min(1,1280/Double(pixels.width))
            let image=result.detectorInput?.cgImage() ?? preview.createCGImage(ci.transformed(by:CGAffineTransform(scaleX:scale,y:scale)),
                                            from:CGRect(x:0,y:0,width:Double(pixels.width)*scale,height:Double(pixels.height)*scale))
            onResult(FrameReport(image:image,observation:result.observation,decision:decision,detections:result.detections,hud:result.hud,
                                 promptLines:result.promptLines,roster:result.roster,problems:result.problems,recognitionReady:result.recognitionReady,
                                 band:coordinator.currentBand,fps:performance.fps,latency:performance.p95,performancePasses:performance.passes(minimumFPS:PerformanceWindow.betaMinimumFPS),focusProblem:focusProblem,
                                 windowBounds:frame.windowBounds,contentRect:frame.contentRect,
                                 hudMilliseconds:result.hudMilliseconds,detectorMilliseconds:result.detectorMilliseconds,healing:coordinator.healingItem,
                                 grenade:coordinator.liveGrenade.map { ($0.name,max(0,$0.explodes-now)) },healCircle:coordinator.healCircle,
                                 throwRadius:coordinator.settings.throwRadius))
        }
    }
}

/// Supervised input: off; on and ready (waiting for "="); or active (sending input).
enum InputState: Equatable { case off, ready, active }

@MainActor
final class AppModel:ObservableObject {
    @Published var windows:[SCWindow]=[]
    @Published var selectedWindowID:CGWindowID=0
    @Published var capturing=false
    @Published var inputState=InputState.off
    var armed:Bool { inputState != .off }
    @Published var recording=false
    @Published var features=Features() { didSet { pipeline?.setFeatures(features) } }
    @Published var status="Select a Chrome window to begin observing."
    @Published var report:FrameReport?
    @Published var detectorSummary="No detector installed"
    @Published var calibration=Calibration()
    @Published var error:String?
    @Published var inputReady=false
    /// Why input last stopped; stays visible until input starts again.
    @Published var notice:String?
    let workspace:Workspace?
    private let capture=CaptureService()
    private let driver=InputDriver()
    private let monitor=ManualInputMonitor()
    private let recorder=SessionRecorder()
    private var pipeline:ProcessingPipeline?
    private var gamePID:pid_t=0
    private let badge=InputBadge()
    private let healPrompt=InputBadge(placement:.aboveCharacter)
    init() {
        ActiveApp.shared.start()
        do {
            let workspace=try Workspace()
            let calibration=try workspace.read(Calibration.self,from:workspace.calibrationURL)
            self.workspace=workspace; self.calibration=calibration
        } catch { self.workspace=nil; self.error=error.localizedDescription }
        monitor.onStop={ [weak self] reason in
            self?.driver.setEnabled(false)
            Task { @MainActor in
                guard let self, self.inputState == .active else { return }
                self.inputState = .ready; self.notice=reason; NSSound(named:"Pop")?.play(); self.updateBadge()
            }
        }
        monitor.onToggle={ [weak self] in Task { @MainActor in self?.toggleActive() } }
        monitor.onYield={ [weak self] in self?.driver.releaseAll() }
        capture.onFailure={ [weak self] error in
            self?.driver.setEnabled(false)
            Task { @MainActor in await self?.stopCapture(); self?.error=error }
        }
        recorder.onError={ [weak self] message in Task { @MainActor in self?.recording=false; self?.recorder.stop(); self?.error=message } }
    }
    var observation:Observation { report?.observation ?? Observation(timestamp:0) }
    func refreshWindows() async {
        do {
            windows=try await CaptureService.windows()
            if !windows.contains(where:{ $0.windowID==selectedWindowID }) { selectedWindowID=windows.first?.windowID ?? 0 }
            status=windows.isEmpty ? "Open ZombsRoyale in Chrome, then refresh windows." : "Choose the game window, then start observing."
        } catch { self.error="Screen Recording access is needed to list Chrome windows. \(error.localizedDescription)" }
    }
    func startCapture() async {
        guard let workspace, let window=windows.first(where:{ $0.windowID==selectedWindowID }) else { return }
        do {
            guard calibration.isValid else { throw ModelError.invalid("Invalid key bindings, range settings or game-area inset") }
            let catalog=workspace.catalog()
            driver.profiles=Dictionary(catalog.profiles.map { ($0.id,$0) },uniquingKeysWith:{ a,_ in a })
            driver.settings=calibration.combat
            driver.bindings=calibration.keyBindings; monitor.bindings=calibration.keyBindings
            let pipeline=ProcessingPipeline(workspace:workspace,calibration:calibration,catalog:catalog,driver:driver,monitor:monitor,recorder:recorder)
            self.pipeline=pipeline; pipeline.setFeatures(features)
            detectorSummary=pipeline.detectorSummary
            pipeline.onResult={ [weak self] report in
                Task { @MainActor in
                    guard let self, self.capturing else { return }
                    self.report=report; self.status=report.decision.reason
                    self.inputReady=report.observation.perceptionReady
                    self.updateBadge()
                }
            }
            capture.onFrame={ [weak pipeline] frame in pipeline?.offer(frame) }
            gamePID=window.owningApplication?.processID ?? 0
            capturing=true
            try await capture.start(window:window,topInset:calibration.topInset)
        } catch { capturing=false; self.error=error.localizedDescription }
    }
    func stopCapture() async {
        pause(); recorder.stop(); recording=false; capturing=false
        do { try await capture.stop() } catch { self.error=error.localizedDescription }
        pipeline?.saveLibrary(); pipeline=nil; inputReady=false
    }
    /// Turns supervised input on. Nothing is sent until "=" is pressed in the game.
    func arm() {
        guard capturing,inputReady else { error="Recognition, verified settings and performance must pass first."; return }
        guard AXIsProcessTrusted() else { error="Enable ZombsAssistant in System Settings → Privacy & Security → Accessibility."; return }
        guard monitor.start() else { error="Cannot watch the = key and manual controls. Check Accessibility and Input Monitoring permissions."; return }
        pipeline?.reset(); driver.setEnabled(false); notice=nil
        inputState = .ready
        NSSound(named:"Morse")?.play()
        if gamePID != 0 { CaptureService.bringToFront(selectedWindowID,pid:gamePID) }
        updateBadge()
    }
    /// "=" in the game: start or stop sending input.
    func toggleActive() {
        switch inputState {
        case .off: return
        case .ready:
            pipeline?.reset(); driver.setEnabled(true); notice=nil
            inputState = .active; NSSound(named:"Tink")?.play()
        case .active:
            driver.setEnabled(false)
            inputState = .ready; NSSound(named:"Pop")?.play()
        }
        updateBadge()
    }
    /// Turns supervised input off entirely.
    func pause() { inputState = .off; driver.setEnabled(false); pipeline?.reset(); updateBadge() }

    /// The label over the game: hidden when supervised input is off.
    private func updateBadge() {
        guard inputState != .off, capturing, let report else { badge.hide(); healPrompt.hide(); return }
        // While the assistant heals, ask you to stand still, next to your character where you are looking. While one of its
        // grenades is about to go off, warn you not to walk into it: explosions hurt you too.
        if inputState == .active, report.focusProblem == nil, !report.observation.manualOverride, let item=report.healing {
            healPrompt.show(title:"STOP MOVING",detail:"Healing with \(item)",color:.orange,windowBounds:report.windowBounds,contentRect:report.contentRect)
        } else if inputState == .active, let grenade=report.grenade {
            healPrompt.show(title:"GRENADE OUT",detail:String(format:"Keep clear: %@ goes off in %.1f s",grenade.name,grenade.seconds),color:.red,
                            windowBounds:report.windowBounds,contentRect:report.contentRect)
        } else if inputState == .active, let circle=report.healCircle {
            // A Healing Grenade's circle heals only who stands in it.
            healPrompt.show(title:circle.inside ? "STAY IN THE CIRCLE" : "BACK INTO THE CIRCLE",detail:String(format:"Healing Grenade heals you for %.1f s more",circle.seconds),
                            color:.green,windowBounds:report.windowBounds,contentRect:report.contentRect)
        } else { healPrompt.hide() }
        let title:String, color:Color, detail:String
        switch inputState {
        case .active:
            if let problem=report.focusProblem { title="ASSISTANT ON · paused"; color = .yellow; detail=problem }
            else if report.observation.manualOverride { title="ASSISTANT ON · manual control"; color = .yellow; detail="Release Option or your keys to hand back" }
            else { title="ASSISTANT ON  ·  = to stop"; color = .green; detail=report.decision.reason }
        default:
            title="ASSISTANT OFF  ·  press = to start"; color = .gray; detail=notice ?? "Supervised input is ready"
        }
        badge.show(title:title,detail:detail,color:color,windowBounds:report.windowBounds,contentRect:report.contentRect)
    }
    func requestAccessibility() {
        let options=[kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary
        _=AXIsProcessTrustedWithOptions(options)
    }
    func toggleRecording() {
        guard capturing,let workspace else { return }
        if recording { recorder.stop(); recording=false }
        else {
            do { try recorder.start(in:workspace.recordings,mode:calibration.mode); recording=true }
            catch { self.error=error.localizedDescription }
        }
    }
    func saveCalibration(_ value:Calibration) async {
        guard let workspace else { return }
        let wasCapturing=capturing
        await stopCapture()
        do { guard value.isValid else { throw ModelError.invalid("A key binding, range setting or the game-area inset is invalid") }; try workspace.save(value,to:workspace.calibrationURL); calibration=value }
        catch { self.error=error.localizedDescription }
        if wasCapturing { await startCapture() }
    }
}
