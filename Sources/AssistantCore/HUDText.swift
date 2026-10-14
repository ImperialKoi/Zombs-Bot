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

    /// Interprets the interaction panel's text lines, top to bottom. Chests and crates become `.chest`;
    /// anything else that is not a recognizable weapon or consumable becomes `.other`, which is never acted on.
    /// - Parameter key: the interact key's name ("E"); a different key letter rejects the panel.
    public static func prompt(lines rawLines: [String], confidence: Double, catalog: ItemCatalog, key: String? = nil) -> InteractionPrompt? {
        var lines = rawLines.map { promptLine($0) }.filter { !$0.isEmpty }
        var count: Int?
        // The stack badge sits beside the name; OCR may split it off or append it, and reads "x2" as "XZ" or "x20" as "K2O".
        lines = lines.compactMap { line in
            if let value = badgeCount(line) { count = value; return nil }
            if let range = line.range(of: #"\s[xX×]\s?[0-9]{1,3}$"#, options: .regularExpression) {
                count = Int(line[range].filter(\.isNumber)); return String(line[..<range.lowerBound])
            }
            return line
        }
        var keyLetter: String?
        lines = lines.enumerated().filter { index, line in
            if line.count == 1, line.first!.isLetter || line.first!.isNumber { if line.first!.isLetter { keyLetter = line.uppercased() }; return false }
            // After the name, a one- or two-character line is the key box or a stray mark ("Eo", "00"), never the subtitle.
            if index > 0 && line.count <= 2 { if line.first?.uppercased() == key?.uppercased() { keyLetter = key?.uppercased() }; return false }
            return true
        }.map(\.element)
        guard lines.count >= 2 else { return nil }
        let name = lines[0]
        var subtitle = lines[1]
        if let key, let keyLetter, keyLetter != key.uppercased() {
            return InteractionPrompt(name: name, subtitle: subtitle, kind: .other, count: count, confidence: confidence)
        }
        // A subtitle one letter off a known one ("Uncommon SMC", "Rare ARO", "egendary Sniper") is read as that one.
        if !knownSubtitle(subtitle, catalog: catalog), let corrected = nearestSubtitle(subtitle, catalog: catalog) { subtitle = corrected }
        let words = subtitle.split(separator: " ").map(String.init)
        if let first = words.first, let rarity = Rarity(word: first) {
            let phrase = words.dropFirst().joined(separator: " ").lowercased()
            if let weaponClass = catalog.classWords[phrase] {
                return InteractionPrompt(name: name, subtitle: subtitle, kind: .weapon, itemID: catalog.weaponID(weaponClass, rarity, name: name),
                                         weaponClass: weaponClass, rarity: rarity, count: count, confidence: confidence)
            }
            if catalog.throwableWords.contains(where: { phrase.contains($0) }) {
                return InteractionPrompt(name: name, subtitle: subtitle, kind: .throwable, itemID: catalog.throwable(named: name)?.id ?? ItemCatalog.throwableID,
                                         rarity: rarity, count: count, confidence: confidence)
            }
            if catalog.healingWords.contains(phrase), let heal = catalog.heal(named: name) {
                return InteractionPrompt(name: name, subtitle: subtitle, kind: .healing, itemID: heal.id, rarity: rarity, count: count, confidence: confidence)
            }
            // Unique items are named, not classed ("Gift Launcher / Legendary Unique", "Crossbow / Mythic Unique"). A launcher,
            // bow or the Healing Gun the catalog names gets its class; launchers and bows only ever finish combos, and the Healing
            // Gun only heals. A throwable of that name (the Shuriken) is a throwable. Other unique guns (the Minigun, the
            // Flamethrower) stay unrecognized, as before. A healing word in place of "Unique" is read the same way.
            if phrase == "unique" || catalog.healingWords.contains(phrase) {
                if let model = catalog.model(named: name, weaponClass: nil), catalog.weapon(model.weaponClass)?.role == nil {
                    return InteractionPrompt(name: name, subtitle: subtitle, kind: .weapon, itemID: catalog.weaponID(model.weaponClass, rarity, name: name),
                                             weaponClass: model.weaponClass, rarity: rarity, count: count, confidence: confidence)
                }
                if let throwable = catalog.throwable(named: name) {
                    return InteractionPrompt(name: name, subtitle: subtitle, kind: .throwable, itemID: throwable.id, rarity: rarity, count: count, confidence: confidence)
                }
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
            return InteractionPrompt(name: name, subtitle: subtitle, kind: .throwable, itemID: catalog.throwable(named: name)?.id ?? ItemCatalog.throwableID,
                                     count: count, confidence: confidence)
        }
        if isContainer(name: name, subtitle: subtitle) {
            return InteractionPrompt(name: name, subtitle: subtitle, kind: .chest, count: count, confidence: confidence)
        }
        return InteractionPrompt(name: name, subtitle: subtitle, kind: .other, count: count, confidence: confidence)
    }

    /// Chests and crates, e.g. "Gold Chest", "Ammo Chest", "Air Drop Chest", "Present Crate" or "Crate (Mystic)",
    /// always with the subtitle "Interact" (read as "Interast" or "Unteract" now and then). Doors ("Open"/"Close"),
    /// vehicles and revives never match.
    static func isContainer(name: String, subtitle: String) -> Bool {
        let words = name.lowercased().split { !$0.isLetter }
        return words.contains { $0 == "chest" || $0 == "crate" } && editDistance(ItemCatalog.letters(subtitle), "interact") <= 2
    }

    /// The stack size of a badge line: "x2", "×15", or OCR look-alikes such as "XZ" (x2), "XI5" (x15) and "K2O" (x20).
    static func badgeCount(_ line: String) -> Int? {
        guard line.range(of: #"^[xX×K]\s?[0-9ZzIlOoS]{1,3}$"#, options: .regularExpression) != nil else { return nil }
        let digits: [Character: Character] = ["Z": "2", "z": "2", "I": "1", "l": "1", "O": "0", "o": "0", "S": "5"]
        return Int(String(line.dropFirst().filter { $0 != " " }.map { digits[$0] ?? $0 }))
    }

    /// The subtitle phrases the panel can show: "<rarity> <class>", consumable and throwable words, "Interact".
    static func subtitles(_ catalog: ItemCatalog) -> [String] {
        var phrases = Rarity.allCases.flatMap { rarity in catalog.classWords.keys.map { "\(rarity.name.lowercased()) \($0)" } }
        phrases += Rarity.allCases.flatMap { rarity in (catalog.throwableWords + ["unique"]).map { "\(rarity.name.lowercased()) \($0)" } }
        return phrases + catalog.healingWords + catalog.throwableWords + ["interact"]
    }
    static func knownSubtitle(_ subtitle: String, catalog: ItemCatalog) -> Bool {
        let lowered = subtitle.lowercased()
        let words = lowered.split(separator: " ")
        if let first = words.first, Rarity(word: String(first)) != nil {
            let phrase = words.dropFirst().joined(separator: " ")
            if catalog.classWords[phrase] != nil || catalog.throwableWords.contains(where: { phrase.contains($0) }) || catalog.healingWords.contains(phrase)
                || phrase == "unique" { return true }
        }
        return catalog.healingWords.contains(lowered) || catalog.throwableWords.contains(lowered) || lowered == "interact"
    }
    /// The known subtitle one edit away (two for long ones), when exactly one is that close.
    static func nearestSubtitle(_ subtitle: String, catalog: ItemCatalog) -> String? {
        let lowered = subtitle.lowercased()
        guard lowered.count >= 4 else { return nil }
        let limit = lowered.count >= 12 ? 2 : 1
        let ranked = subtitles(catalog).map { ($0, editDistance(lowered, $0)) }.filter { $0.1 <= limit }.sorted { $0.1 < $1.1 }
        guard let best = ranked.first, ranked.dropFirst().first.map({ $0.1 > best.1 }) ?? true else { return nil }
        return best.0
    }

    /// What the panel says while a consumable is in your hand: "Left Click to Consume" over its effect, e.g.
    /// "Charge shield by 25% up to 50%". Returns that consumable's catalog ID.
    public static func heldConsumable(lines rawLines: [String], catalog: ItemCatalog) -> String? {
        let lines = rawLines.map { promptLine($0) }
        guard lines.contains(where: { nameSimilarity($0, "Left Click to Consume") >= 0.8 || nameKey($0).hasSuffix("toconsume") }) else { return nil }
        return catalog.heal(hintLines: lines)?.id
    }

    /// Levenshtein distance between two strings.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count), current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[y.count]
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
