import SwiftUI
import AssistantCore
import Perception

@main
struct ZombsAssistantApp:App {
    @StateObject private var model=AppModel()
    var body:some Scene {
        WindowGroup("Zombs Assistant") { Dashboard(model:model).frame(minWidth:1060,minHeight:720) }
            .defaultSize(width:1320,height:860)
        Settings { Text("Game area, mode, key bindings and ranges are in the main window's Settings.").padding(30) }
    }
}

struct Dashboard:View {
    @ObservedObject var model:AppModel
    @State private var showSettings=false
    var body:some View {
        HStack(spacing:0) {
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    VStack(alignment:.leading,spacing:6) {
                        HStack {
                            Text("ZOMBS ASSISTANT").font(.caption.weight(.bold)).tracking(2).foregroundStyle(.secondary)
                            Text("BETA").font(.caption2.weight(.bold)).padding(.horizontal,6).padding(.vertical,2).background(.orange.opacity(0.25),in:Capsule())
                        }
                        Text("You move.\nThe assistant aims, shoots,\nswitches guns and loots.").font(.title3.weight(.semibold))
                    }
                    Divider()
                    VStack(alignment:.leading,spacing:10) {
                        Text("GAME WINDOW").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Picker("Chrome",selection:$model.selectedWindowID) {
                            Text("Select a window").tag(UInt32(0))
                            ForEach(model.windows,id:\.windowID) { window in Text(window.title ?? "Chrome").tag(window.windowID) }
                        }.labelsHidden().disabled(model.capturing)
                        Button("Refresh windows",systemImage:"arrow.clockwise") { Task { await model.refreshWindows() } }.disabled(model.capturing)
                        Button(model.capturing ? "Stop observing" : "Start observing",systemImage:model.capturing ? "stop.circle" : "viewfinder") {
                            Task { if model.capturing { await model.stopCapture() } else { await model.startCapture() } }
                        }.buttonStyle(.borderedProminent).disabled(!model.capturing && model.selectedWindowID==0)
                    }
                    VStack(alignment:.leading,spacing:10) {
                        Text("AUTOMATION").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Toggle("Aim, shoot & switch guns",isOn:$model.features.combat)
                        Toggle("Pick up guns & heals",isOn:$model.features.loot)
                        Toggle("Open chests & crates",isOn:$model.features.chests)
                        Toggle("Carry the sniper when it's quiet",isOn:$model.features.idleWeapon)
                        Toggle("Reverse Impulse combos",isOn:$model.features.combos)
                        Toggle("Heal during safe gaps",isOn:$model.features.healing)
                        Button(model.armed ? "Turn off supervised input" : "Enable supervised input",systemImage:model.armed ? "power" : "play.fill") {
                            if model.armed { model.pause() } else { model.arm() }
                        }.disabled(!model.capturing || (!model.armed && !model.inputReady))
                        Text("Once enabled, press = in the game to start and = again to stop.\nOption: manual control · Escape: stop input").font(.caption).foregroundStyle(.secondary)
                    }
                    ReadinessList(model:model)
                    Divider()
                    VStack(alignment:.leading,spacing:10) {
                        Text("SETUP & DATA").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Button("Settings: game area, mode, keys, ranges",systemImage:"slider.horizontal.3") { model.pause(); showSettings=true }
                        Button("Set up input permissions",systemImage:"keyboard") { model.requestAccessibility() }
                        Button(model.recording ? "Finish this recording" : "Record a match",systemImage:model.recording ? "stop.circle.fill" : "record.circle") { model.toggleRecording() }.disabled(!model.capturing)
                        Button("Open data & model folder",systemImage:"folder") { if let root=model.workspace?.root { NSWorkspace.shared.open(root) } }
                    }
                    Label("Movement stays yours",systemImage:"arrow.up.and.down.and.arrow.left.and.right").font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }.frame(width:310).background(.thinMaterial)
            VStack(alignment:.leading,spacing:14) {
                InputStateBanner(model:model)
                HStack {
                    Spacer()
                    if let r=model.report {
                        Text(String(format:"%.1f FPS · %.0f ms p95 · HUD %.0f ms · detector %.0f ms",r.fps,r.latency.isFinite ? r.latency*1000 : 0,r.hudMilliseconds,r.detectorMilliseconds))
                            .font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary)
                    }
                }
                DiagnosticCanvas(report:model.report).environment(\.colorScheme,.dark).clipShape(RoundedRectangle(cornerRadius:14))
                HStack(spacing:26) {
                    stat("HEALTH",model.observation.health.map { String(Int($0.rounded())) } ?? "—")
                    stat("SHIELD",model.observation.shield.map { String(Int($0.rounded())) } ?? "—")
                    stat("SLOT",model.observation.selectedSlot.map(String.init) ?? "—")
                    stat("MODE",model.observation.teamMode ? "Team" : model.calibration.mode.rawValue.capitalized)
                    stat("RANGE",model.report?.band?.rawValue.capitalized ?? "—")
                    Spacer()
                    if model.recording { Label("Recording",systemImage:"record.circle.fill").foregroundStyle(.red) }
                }
                InventoryStrip(observation:model.observation,hud:model.report?.hud)
                VStack(alignment:.leading,spacing:6) {
                    if let notice=model.notice { Label(notice,systemImage:"exclamationmark.triangle.fill").font(.callout.weight(.semibold)).foregroundStyle(.orange) }
                    Text(model.status).font(.headline)
                    if let prompt=model.observation.prompt {
                        Text("Prompt: \(prompt.name) — \(prompt.subtitle) · \(prompt.isItem ? "item" : "not an item")\(prompt.stable ? "" : " (settling)")").font(.callout)
                    } else if let lines=model.report?.promptLines, !lines.isEmpty {
                        Text("Prompt text: \(lines.joined(separator:" / "))").font(.callout).foregroundStyle(.secondary)
                    }
                    if let roster=model.report?.roster, !roster.isEmpty { Text("Teammates: \(roster.joined(separator:", "))").font(.callout).foregroundStyle(.secondary) }
                    ForEach(model.report?.problems ?? [],id:\.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(14).background(.quaternary,in:RoundedRectangle(cornerRadius:12))
            }.padding(24)
        }
        .sheet(isPresented:$showSettings) { CalibrationEditor(model:model) }
        .alert("Zombs Assistant",isPresented:Binding(get:{ model.error != nil },set:{ if !$0 { model.error=nil } })) { Button("OK") { model.error=nil } } message: { Text(model.error ?? "") }
        .onDisappear { model.pause() }
    }
    private func stat(_ label:String,_ value:String)->some View { VStack(alignment:.leading,spacing:4) { Text(label).font(.caption2.weight(.bold)).foregroundStyle(.secondary); Text(value).font(.title3.monospacedDigit()) } }
}

/// Shows at a glance whether the assistant is sending input.
struct InputStateBanner:View {
    @ObservedObject var model:AppModel
    var body:some View {
        let (title,detail,color):(String,String,Color) = {
            switch model.inputState {
            case .active:
                if let problem=model.report?.focusProblem { return ("ASSISTANT ON · PAUSED","\(problem). Input resumes when Chrome is in front. Press = to stop.",.yellow) }
                return ("ASSISTANT ON","Aiming, shooting, switching guns and looting. Press = in the game to stop.",.green)
            case .ready:
                return ("SUPERVISED INPUT READY","Press = in the game to start. Nothing is sent until then.",.blue)
            case .off:
                return model.capturing ? ("OBSERVING · INPUT OFF","Click Enable supervised input to turn it on.",.orange) : ("PAUSED","Start observing to begin.",.gray)
            }
        }()
        HStack(spacing:12) {
            Circle().fill(color).frame(width:14,height:14)
            VStack(alignment:.leading,spacing:2) {
                Text(title).font(.headline.weight(.bold)).tracking(0.5)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12).background(color.opacity(0.18),in:RoundedRectangle(cornerRadius:12))
        .overlay(RoundedRectangle(cornerRadius:12).stroke(color.opacity(0.7),lineWidth:1.5))
    }
}

struct ReadinessList:View {
    @ObservedObject var model:AppModel
    var body:some View {
        let r=model.report
        VStack(alignment:.leading,spacing:6) {
            Text("READINESS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            row(r?.recognitionReady == true, "Detector", model.detectorSummary)
            row(r?.observation.phase == .alive, "HUD", r?.hud == nil ? "Not found yet: start a match" : r?.observation.phase == .alive ? "Found; in a match" : "Waiting for a live match")
            row(model.calibration.verified, "Settings", model.calibration.verified ? "Mode and keys verified" : "Open Settings and verify mode and keys")
            row(r?.performancePasses == true, "Speed", r.map { String(format:"%.0f updates/s, p95 %.0f ms (beta needs 15/s, 100 ms)",$0.fps,$0.latency.isFinite ? $0.latency*1000 : 0) } ?? "Measured while observing")
            row(AXIsProcessTrusted(), "Input permission", AXIsProcessTrusted() ? "Accessibility granted" : "Grant Accessibility")
        }
    }
    private func row(_ ok:Bool,_ title:String,_ detail:String)->some View {
        HStack(alignment:.top,spacing:6) {
            Image(systemName:ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? .green : .secondary)
            VStack(alignment:.leading,spacing:1) { Text(title).font(.callout.weight(.medium)); Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct InventoryStrip:View {
    var observation:Observation
    var hud:HUDSnapshot?
    var body:some View {
        HStack(spacing:8) {
            ForEach(1...6,id:\.self) { index in
                let slot=observation.slot(index)
                let selected=observation.selectedSlot==index
                VStack(alignment:.leading,spacing:2) {
                    Text("\(index)").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    Text(title(slot)).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(detail(slot)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth:.infinity,alignment:.leading).padding(8)
                .background(color(slot).opacity(0.22),in:RoundedRectangle(cornerRadius:8))
                .overlay(RoundedRectangle(cornerRadius:8).stroke(selected ? Color.white : .clear,lineWidth:2))
            }
        }
    }
    private func title(_ slot:InventorySlot?)->String {
        guard let slot else { return "—" }
        if slot.isKnownEmpty { return "Empty" }
        guard let id=slot.itemID else { return "Unknown item" }
        if let (weaponClass,_) = ItemCatalog.parseWeaponID(id) { return slot.label.map { "\($0) (\(weaponClass.rawValue.uppercased()))" } ?? weaponClass.rawValue.uppercased() }
        return slot.label ?? id
    }
    private func detail(_ slot:InventorySlot?)->String {
        guard let slot, !slot.isKnownEmpty else { return " " }
        var parts:[String]=[]
        if let rarity=slot.rarity { parts.append(rarity.name) }
        if let ammo=slot.ammo, let reserve=slot.reserveAmmo { parts.append("\(ammo)/\(reserve)") }
        else if let total=slot.totalAmmo { parts.append("\(total) rounds") }
        else if slot.itemID != nil && ItemCatalog.parseWeaponID(slot.itemID!) == nil && slot.count>1 { parts.append("×\(slot.count)") }
        return parts.isEmpty ? " " : parts.joined(separator:" · ")
    }
    private func color(_ slot:InventorySlot?)->Color {
        switch slot?.rarity {
        case .uncommon?: return .green
        case .rare?: return .blue
        case .epic?: return .purple
        case .legendary?: return .yellow
        case .mythic?: return .red
        default: return .gray
        }
    }
}

struct DiagnosticCanvas:View {
    var report:FrameReport?
    var body:some View {
        GeometryReader { geometry in
            ZStack {
                Color(red:0.055,green:0.07,blue:0.09)
                if let report, let image=report.image {
                    let size=fitSize(image,inside:geometry.size)
                    Image(decorative:image,scale:1).resizable().frame(width:size.width,height:size.height)
                    Canvas { context,_ in
                        let sw=Double(size.width), sh=Double(size.height)
                        func box(_ r:Rect)->CGRect { CGRect(x:r.x*sw,y:r.y*sh,width:r.width*sw,height:r.height*sh) }
                        for d in report.detections {
                            let rect=box(d.bounds)
                            let player=report.observation.players.first { $0.id==d.id && d.label=="player" }
                            let color:Color = player.map { $0.affiliation == .enemy ? .red : $0.affiliation == .teammate ? .green : .yellow } ?? .orange
                            context.stroke(Path(rect),with:.color(color),lineWidth:player == nil ? 1 : 2)
                            if let player { context.draw(Text("\(player.affiliation.rawValue) \(Int(d.confidence*100))%\(player.confirmed ? "" : " ?")\(player.predicted ? " ~" : "")").font(.system(size:10,design:.monospaced)).foregroundColor(color),at:CGPoint(x:rect.minX,y:max(5,rect.minY-7)),anchor:.leading) }
                        }
                        if let hud=report.hud {
                            let l=hud.layout
                            let fx=sw/Double(l.width), fy=sh/Double(l.height)
                            func pixels(_ r:PixelRect)->CGRect { CGRect(x:r.x*fx,y:r.y*fy,width:r.width*fx,height:r.height*fy) }
                            for i in 1...6 { context.stroke(Path(pixels(l.slot(i))),with:.color(i==hud.selectedSlot ? .white : .cyan.opacity(0.6)),lineWidth:i==hud.selectedSlot ? 2 : 1) }
                            if let panel=hud.promptRect { context.stroke(Path(pixels(panel)),with:.color(.mint),lineWidth:1.5) }
                            context.stroke(Path(pixels(l.readout)),with:.color(.cyan.opacity(0.5)),lineWidth:1)
                        }
                        // Where clicks may go: inside the safe margin, off the HUD areas, and for throws within the grenade circle.
                        if !report.observation.hudAreas.isEmpty {
                            let m=Policy.edgeMargin*sh, p=report.observation.player, r=report.throwRadius*sh
                            context.stroke(Path(CGRect(x:m,y:m,width:sw-2*m,height:sh-2*m)),with:.color(.white.opacity(0.25)),style:StrokeStyle(lineWidth:1,dash:[2,4]))
                            for area in report.observation.hudAreas { context.stroke(Path(box(area)),with:.color(.red.opacity(0.55)),style:StrokeStyle(lineWidth:1,dash:[3,3])) }
                            context.stroke(Path(ellipseIn:CGRect(x:p.x*sw-r,y:p.y*sh-r,width:2*r,height:2*r)),with:.color(.orange.opacity(0.35)),lineWidth:1)
                        }
                        for intent in report.decision.intents {
                            if case .aim(let p)=intent {
                                let c=CGPoint(x:p.x*sw,y:p.y*sh)
                                context.stroke(Path(ellipseIn:CGRect(x:c.x-8,y:c.y-8,width:16,height:16)),with:.color(.red),lineWidth:2)
                            } else if case .throwAt(let p)=intent {
                                let c=CGPoint(x:p.x*sw,y:p.y*sh)
                                context.stroke(Path(ellipseIn:CGRect(x:c.x-12,y:c.y-12,width:24,height:24)),with:.color(.orange),style:StrokeStyle(lineWidth:2,dash:[4,3]))
                            }
                        }
                    }.frame(width:size.width,height:size.height)
                } else { ContentUnavailableView("Waiting for the game",systemImage:"viewfinder",description:Text("Open ZombsRoyale in Chrome and select its window.")) }
            }
        }
    }
}

func fitSize(_ image:CGImage,inside available:CGSize)->CGSize {
    let scale=min(available.width/Double(image.width),available.height/Double(image.height))
    return CGSize(width:Double(image.width)*scale,height:Double(image.height)*scale)
}

enum KeyNames {
    static let mapping:[UInt16:String]=[0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",25:"9",26:"7",28:"8",29:"0",31:"O",32:"U",34:"I",35:"P",37:"L",38:"J",40:"K",45:"N",46:"M"]
    static func name(_ key:UInt16)->String { mapping[key] ?? String(key) }
}
