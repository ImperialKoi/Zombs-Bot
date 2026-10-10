import Foundation

/// Strict parsing of observed HUD labels. Never substitutes similar-looking letters.
public enum HUDText {
    public static func healthOrShield(_ text: String, requiringMaximum: Bool = false) -> Double? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        if requiringMaximum && parts.count != 2 { return nil }
        guard (1...2).contains(parts.count), let value = integer(String(parts[0])), value <= 100 else { return nil }
        if parts.count == 2, integer(String(parts[1])) != 100 { return nil }
        return Double(value)
    }

    public static func ammunition(_ text: String) -> (loaded: Int, reserve: Int)? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let loaded = integer(String(parts[0])),
              let reserve = integer(String(parts[1])) else { return nil }
        return (loaded, reserve)
    }

    /// A count printed on a slot or reserve counter ("1,132", "33").
    public static func count(_ text: String) -> Int? { integer(text) }

    private static func integer(_ text: String) -> Int? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(?:[0-9]{1,5}|[0-9]{1,2},[0-9]{3})$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return Int(value.replacingOccurrences(of: ",", with: ""))
    }

    /// Interprets the interaction panel's text lines, top to bottom. Anything that is not
    /// a recognizable weapon or consumable becomes `.other`, which is never picked up.
    /// - Parameter key: the interact key's name ("E"); a different key letter rejects the panel.
    public static func prompt(lines rawLines: [String], confidence: Double, catalog: ItemCatalog, key: String? = nil) -> InteractionPrompt? {
        var lines = rawLines.map { promptLine($0) }.filter { !$0.isEmpty }
        var count: Int?
        let badge = #"^[xX×]\s?([0-9]{1,3})$"#
        // The stack badge sits beside the name; OCR may split it off or append it.
        lines = lines.compactMap { line in
            if line.range(of: badge, options: .regularExpression) != nil { count = Int(line.drop(while: { !$0.isNumber })); return nil }
            if let range = line.range(of: #"\s[xX×]\s?[0-9]{1,3}$"#, options: .regularExpression) {
                count = Int(line[range].filter(\.isNumber)); return String(line[..<range.lowerBound])
            }
            return line
        }
        var keyLetter: String?
        lines = lines.filter { line in
            if line.count == 1, line.first!.isLetter || line.first!.isNumber { keyLetter = line.uppercased(); return false }
            return true
        }
        guard lines.count >= 2 else { return nil }
        let name = lines[0], subtitle = lines[1]
        if let key, let keyLetter, keyLetter != key.uppercased() {
            return InteractionPrompt(name: name, subtitle: subtitle, kind: .other, count: count, confidence: confidence)
        }
        let words = subtitle.split(separator: " ").map(String.init)
        if let first = words.first, let rarity = Rarity(word: first) {
            let phrase = words.dropFirst().joined(separator: " ").lowercased()
            if let weaponClass = catalog.classWords[phrase] {
                return InteractionPrompt(name: name, subtitle: subtitle, kind: .weapon, itemID: ItemCatalog.weaponID(weaponClass, rarity),
                                         weaponClass: weaponClass, rarity: rarity, count: count, confidence: confidence)
            }
            if catalog.throwableWords.contains(where: { phrase.contains($0) }) {
                return InteractionPrompt(name: name, subtitle: subtitle, kind: .throwable, itemID: ItemCatalog.throwableID,
                                         rarity: rarity, count: count, confidence: confidence)
            }
            if catalog.healingWords.contains(phrase), let heal = catalog.heal(named: name) {
                return InteractionPrompt(name: name, subtitle: subtitle, kind: .healing, itemID: heal.id, rarity: rarity, count: count, confidence: confidence)
            }
            return InteractionPrompt(name: name, subtitle: subtitle, kind: .other, rarity: rarity, count: count, confidence: confidence)
        }
        let lowered = subtitle.lowercased()
        if catalog.healingWords.contains(lowered) {
            // An unrecognized consumable stays unidentified, so it is never used or swapped in.
            return InteractionPrompt(name: name, subtitle: subtitle, kind: .healing, itemID: catalog.heal(named: name)?.id,
                                     count: count, confidence: confidence)
        }
        if catalog.throwableWords.contains(lowered) {
            return InteractionPrompt(name: name, subtitle: subtitle, kind: .throwable, itemID: ItemCatalog.throwableID,
                                     count: count, confidence: confidence)
        }
        return InteractionPrompt(name: name, subtitle: subtitle, kind: .other, count: count, confidence: confidence)
    }

    /// Text recognition sometimes returns Cyrillic look-alikes inside English words ("Еріс SMG").
    /// Prompt words are only accepted when they then match the catalog exactly, so mapping them is safe.
    static let lookalikes: [Character: Character] = [
        "А": "A", "В": "B", "Е": "E", "К": "K", "М": "M", "Н": "H", "О": "O", "Р": "P", "С": "C", "Т": "T", "Х": "X", "І": "I", "Ј": "J", "Ѕ": "S",
        "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "у": "y", "х": "x", "і": "i", "ј": "j", "ѕ": "s", "ԁ": "d", "ԛ": "q", "ԝ": "w",
    ]
    /// Collapses spaces, maps look-alike letters and trims stray symbols at either end ("•Close", "Uncommon AR •").
    static func promptLine(_ text: String) -> String {
        let mapped = String(text.map { lookalikes[$0] ?? $0 })
        let words = mapped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let keep = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ")"))
        let trimmedStart = words.drop { $0.unicodeScalars.allSatisfy { !keep.contains($0) } }
        return String(String(trimmedStart).reversed().drop { $0.unicodeScalars.allSatisfy { !keep.contains($0) } }.reversed())
    }

    /// Letters and digits only, lowercased, for comparing OCR'd player names.
    public static func nameKey(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Normalized edit similarity in 0...1 between two player names.
    public static func nameSimilarity(_ a: String, _ b: String) -> Double {
        let x = Array(nameKey(a)), y = Array(nameKey(b))
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var previous = Array(0...y.count), current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }
}
