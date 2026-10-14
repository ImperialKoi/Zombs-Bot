import SwiftUI
import AssistantCore
import Perception

/// Settings the user confirms. HUD regions are found automatically, so only the game area,
/// mode, key bindings and weapon ranges are set here.
struct CalibrationEditor:View {
    @ObservedObject var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft:Calibration
    init(model:AppModel) { self.model=model; _draft=State(initialValue:model.calibration) }
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack { Text("Settings").font(.title2.bold()); Spacer(); Button("Cancel") { dismiss() } }
            GroupBox("Game area") {
                VStack(alignment:.leading,spacing:8) {
                    Text("The capture starts this many points below the top of the Chrome window, so tabs, address and bookmarks bars are excluded. The preview should show the game's top edge, and the HUD outlines should sit on the inventory slots.")
                        .font(.callout).foregroundStyle(.secondary)
                    Slider(value:$draft.topInset,in:0...200,step:1) { Text("Top edge: \(Int(draft.topInset)) pt") }
                    HStack {
                        Button("Reset to 87 pt") { draft.topInset=87 }
                        Text(hudStatus).font(.callout).foregroundStyle(.secondary)
                    }
                    if let image=model.report?.image {
                        Image(decorative:image,scale:1).resizable().aspectRatio(contentMode:.fit).frame(maxHeight:200).clipShape(RoundedRectangle(cornerRadius:8))
                    }
                }.padding(6)
            }
            GroupBox("Mode and keys") {
                VStack(alignment:.leading,spacing:8) {
                    Picker("Current game mode",selection:$draft.mode) { ForEach(GameMode.allCases,id:\.self) { Text($0.rawValue.capitalized).tag($0) } }.frame(width:280)
                    Text("In Duo and Squad the assistant only fires at players without a teammate's name tag. A visible team roster switches it to team rules even when Solo is selected.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        keyPicker("Interact",binding:$draft.keyBindings.interact)
                        keyPicker("Reload",binding:$draft.keyBindings.reload)
                        ForEach(0..<6,id:\.self) { i in keyPicker("\(i+1)",binding:$draft.keyBindings.slots[i]) }
                    }
                }.padding(6)
            }
            GroupBox("Weapon ranges") {
                VStack(alignment:.leading,spacing:8) {
                    Text("Distances are fractions of the game view's width from your character. Closer than the first: shotgun. Farther than the second: sniper. Between: assault rifle.")
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value:$draft.combat.closeCutoff,in:0.06...0.25,step:0.01) { Text(String(format:"Shotgun inside %.2f",draft.combat.closeCutoff)).frame(width:170,alignment:.leading) }
                    Slider(value:$draft.combat.longCutoff,in:0.2...0.5,step:0.01) { Text(String(format:"Sniper beyond %.2f",draft.combat.longCutoff)).frame(width:170,alignment:.leading) }
                    Slider(value:$draft.combat.switchDwell,in:0.2...2,step:0.1) { Text(String(format:"Hold a gun %.1f s",draft.combat.switchDwell)).frame(width:170,alignment:.leading) }
                    Slider(value:$draft.combat.leadLatency,in:0...0.25,step:0.01) { Text(String(format:"Aim lead +%.0f ms",draft.combat.leadLatency*1000)).frame(width:170,alignment:.leading) }
                    Text("Shots lead a moving opponent by the bullet's flight plus this delay. Raise it if shots trail behind opponents, lower it if they land in front.")
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value:$draft.combat.aimRadius,in:0.15...0.45,step:0.01) { Text(String(format:"Crosshair circle %.0f%%",draft.combat.aimRadius*100)).frame(width:170,alignment:.leading) }
                    Text("The crosshair stays within this share of the view's height from your character, pointing the same way at opponents farther out, so clicks never land on the window's edges.")
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value:$draft.combat.throwRadius,in:0.2...1.25,step:0.05) {
                        Text(draft.combat.throwRadius >= 1.25 ? "Grenade circle: all" : String(format:"Grenade circle %.0f%%",draft.combat.throwRadius*100)).frame(width:170,alignment:.leading)
                    }
                    Text("Grenades land where you click, so Reverse Impulses and grenades are thrown within this share of the view's height from your character. At the far right they may land anywhere on screen, except near its edges. The inventory, buttons, minimap, vitals and the item panel are never clicked.")
                        .font(.caption).foregroundStyle(.secondary)
                    Stepper("Keep \(draft.combat.minHealSlots) slots for heals and utility when picking up a missing gun",value:$draft.combat.minHealSlots,in:0...4)
                    Text("The loadout the assistant works toward: sniper, AR, SMG, then a utility item (grenades, Reverse Impulses, a Grappling Hook) or heals, and heals.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(6)
            }
            Toggle("I verified the mode and key bindings against the game",isOn:$draft.verified)
            HStack {
                if !draft.isValid { Text("The long range must exceed the short range, and keys must be unique.").font(.caption).foregroundStyle(.red) }
                Spacer()
                Button("Save") { Task { await model.saveCalibration(draft); dismiss() } }.buttonStyle(.borderedProminent).disabled(!draft.isValid)
            }
        }.padding(24).frame(width:880)
    }
    private var hudStatus:String {
        guard let report=model.report else { return "Start observing to preview." }
        if report.observation.phase == .alive { return "HUD found." }
        return report.hud == nil ? "HUD not found yet: it appears once you are in a match." : "HUD found; waiting for a live match."
    }
    private func keyPicker(_ name:String,binding:Binding<UInt16>)->some View {
        Picker(name,selection:binding) { ForEach(KeyBindings.allowed.sorted(),id:\.self) { Text(KeyNames.name($0)).tag($0) } }.frame(minWidth:90)
    }
}
