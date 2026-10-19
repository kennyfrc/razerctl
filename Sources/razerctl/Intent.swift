import Foundation

/// One plain-language request, mapped to an action the CLI already has.
enum Intent: String, CaseIterable {
    case connect
    case status
    case battery
    case setDPI = "set_dpi"
    case setPolling = "set_polling"
    case bluetooth
    case pair
    case matchLogitech = "match_logitech"
    case diagnose

    var summary: String {
        switch self {
        case .connect: return "check the live link and print the steps to go wireless"
        case .status: return "show device, battery, DPI and polling"
        case .battery: return "show the battery percentage and charging state"
        case .setDPI: return "set the DPI, for example \"set dpi to 1600\""
        case .setPolling: return "set the polling rate, for example \"max out the polling rate\""
        case .bluetooth: return "answer whether this model can use Bluetooth"
        case .pair: return "put the dongle in pairing mode"
        case .matchLogitech: return "set the DPI to the Logitech's DPI, read from mxctl"
        case .diagnose: return "check permissions, the device and the agent, then name the problem"
        }
    }

    var examples: [String] {
        switch self {
        case .connect:
            return ["connect this mouse to my macbook", "how do I go wireless", "set up the mouse"]
        case .status:
            return ["how is my mouse doing", "show me the status", "what dpi is it on"]
        case .battery:
            return ["how much battery is left", "is it charging"]
        case .setDPI:
            return ["set dpi to 1600", "make it slower", "change sensitivity to 3200"]
        case .setPolling:
            return ["max out the polling rate", "set polling to 1000", "reduce the polling rate"]
        case .bluetooth:
            return ["does it support bluetooth", "why is it not in the bluetooth list"]
        case .pair:
            return ["pair the dongle", "the dongle does not see the mouse"]
        case .matchLogitech:
            return ["match my logitech dpi", "same sensitivity as the mx master"]
        case .diagnose:
            return ["it is not working", "why is the cli failing", "fix my mouse"]
        }
    }
}

struct IntentMatch {
    let intent: Intent
    let score: Int
    let dpi: Int?
    let polling: Int?
}

/// Keyword matcher. No model, no network: a fixed vocabulary keeps it testable and fast.
enum IntentParser {
    /// Words that point at each intent. Multi-word phrases count for more than single words.
    static let vocabulary: [Intent: [String]] = [
        .connect: ["connect", "setup", "set up", "link", "wireless", "dongle", "get it working", "usable"],
        .status: ["status", "how is", "how's", "what dpi", "what is the state", "show me", "summary"],
        .battery: ["battery", "charge", "charging", "power left", "percent"],
        .setDPI: ["dpi", "sensitivity", "slower", "faster", "speed"],
        .setPolling: ["polling", "poll rate", "hz", "latency", "lag", "responsive"],
        .bluetooth: ["bluetooth", "bt", "pair with my phone", "pairing list"],
        .pair: ["pair the dongle", "repair", "pairing mode", "not see the mouse", "does not see"],
        .matchLogitech: ["match my logitech", "same as my logitech", "mx master", "logitech"],
        .diagnose: ["not working", "broken", "why", "fix", "problem", "issue", "failing", "not showing"],
    ]

    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let cleaned = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    static func match(_ text: String) -> IntentMatch {
        let normalized = normalize(text)
        let padded = " " + normalized + " "

        var bestIntent = Intent.diagnose
        var bestScore = 0
        for (intent, phrases) in vocabulary {
            var score = 0
            for phrase in phrases where padded.contains(" " + phrase + " ") {
                score += phrase.contains(" ") ? 3 : 1
            }
            if score > bestScore {
                bestIntent = intent
                bestScore = score
            }
        }

        // A named subject beats a vague verb: "why is bluetooth not showing" is a
        // Bluetooth question, not a diagnosis.
        if normalized.contains("logitech") || normalized.contains("mx master") {
            return IntentMatch(intent: .matchLogitech, score: bestScore + 3, dpi: nil, polling: nil)
        }
        if normalized.contains("bluetooth") {
            bestIntent = .bluetooth
            bestScore += 2
        } else if normalized.contains("dpi") {
            bestIntent = .setDPI
        } else if normalized.contains("polling") || normalized.contains("hz") {
            bestIntent = .setPolling
        }

        return IntentMatch(
            intent: bestIntent,
            score: bestScore,
            dpi: dpiValue(in: normalized, intent: bestIntent),
            polling: pollingValue(in: normalized, intent: bestIntent)
        )
    }

    static func dpiValue(in text: String, intent: Intent) -> Int? {
        guard intent == .setDPI else { return nil }
        if text.contains("max") || text.contains("highest") { return RazerCommands.dpiMax }
        if text.contains("slowest") || text.contains("lowest") { return RazerCommands.dpiMin }
        for token in text.split(separator: " ") {
            if let value = Int(token), value >= RazerCommands.dpiMin, value <= RazerCommands.dpiMax {
                return value
            }
        }
        return nil
    }

    static func pollingValue(in text: String, intent: Intent) -> Int? {
        guard intent == .setPolling else { return nil }
        if text.contains("max") || text.contains("highest") || text.contains("fastest") { return 8000 }
        if text.contains("slowest") || text.contains("lowest") { return 125 }
        if text.contains("faster") { return 2000 }
        if text.contains("slower") { return 500 }
        for token in text.split(separator: " ") {
            if let value = Int(token), RazerCommands.supportedRates.contains(value) { return value }
        }
        return nil
    }
}
