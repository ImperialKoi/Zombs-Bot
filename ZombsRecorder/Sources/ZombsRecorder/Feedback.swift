import AppKit

/// Short sounds: audible during a match and no permission to ask for.
enum Feedback {
    static func started() { NSSound(named: "Tink")?.play() }
    static func stopped() { NSSound(named: "Pop")?.play() }
    static func failed() { NSSound(named: "Basso")?.play() }
}
