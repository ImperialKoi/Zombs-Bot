import Foundation
import AssistantCore

struct ReplaySummary:Encodable {
    var frames=0
    var proposedActions=0
    var rejectedActions=0
    var pickupActions=0
    var fireActions=0
    var throwActions=0
}

func run() throws {
    let args=Array(CommandLine.arguments.dropFirst())
    guard args.count>=2 else {
        print("Usage: ZombsReplay <observations.jsonl> <items.json | --catalog> [decisions.jsonl]\nReplays recorded state through the coordinator and independent input guard. --catalog uses the built-in item catalog. Sends no OS input.")
        return
    }
    let decoder=JSONDecoder(),encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
    let profiles=args[1]=="--catalog" ? ItemCatalog.standard.profiles : try decoder.decode([ItemProfile].self,from:Data(contentsOf:URL(fileURLWithPath:args[1])))
    let coordinator=Coordinator(profiles:profiles), guardrail=ActionGuard(profiles:coordinator.profiles)
    let text=try String(contentsOfFile:args[0],encoding:.utf8)
    var summary=ReplaySummary(), output=Data()
    var lastTimestamp = -Double.infinity
    for (index,line) in text.split(separator:"\n").enumerated() {
        let observation=try decoder.decode(Observation.self,from:Data(line.utf8))
        guard observation.timestamp>lastTimestamp else { throw NSError(domain:"Replay",code:1,userInfo:[NSLocalizedDescriptionKey:"Frame \(index+1): timestamps must increase"] ) }
        lastTimestamp=observation.timestamp
        let decision=coordinator.step(observation,now:observation.timestamp)
        var aim:Point?
        for intent in decision.intents {
            if case .aim(let p)=intent { aim=p }
            if intent != .releaseAll { summary.proposedActions += 1 }
            if !guardrail.permits(intent,observation:observation,now:observation.timestamp,aim:aim) { summary.rejectedActions += 1 }
            if case .pickup=intent { summary.pickupActions += 1 }
            if case .fire=intent { summary.fireActions += 1 }
            if case .fireAtPull=intent { summary.fireActions += 1 }
            if case .throwAt=intent { summary.throwActions += 1 }
        }
        summary.frames += 1
        output.append(try encoder.encode(decision)); output.append(10)
    }
    if args.count>=3 { try output.write(to:URL(fileURLWithPath:args[2]),options:.atomic) }
    print(String(data:try encoder.encode(summary),encoding:.utf8)!)
    if summary.rejectedActions>0 { exit(2) }
}
do { try run() } catch { FileHandle.standardError.write(Data("Replay failed: \(error.localizedDescription)\n".utf8)); exit(1) }
