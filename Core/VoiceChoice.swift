import Foundation

/// A speech voice as the picker sees it, so the choice can be tested without AVFoundation.
public struct VoiceCandidate: Equatable, Sendable {
    public enum Quality: Int, Comparable, Sendable {
        case standard = 0, enhanced, premium
        public static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
    }
    public let identifier: String
    /// BCP 47, like "en-US".
    public let language: String
    public let quality: Quality

    public init(identifier: String, language: String, quality: Quality) {
        self.identifier = identifier; self.language = language; self.quality = quality
    }

    /// Novelty voices (Bells, Zarvox, Whisper…) and the Eloquence set (Grandpa, Rocko…) are never right for directions.
    var isNovelty: Bool {
        identifier.hasPrefix("com.apple.speech.synthesis.voice.") || identifier.hasPrefix("com.apple.eloquence.")
    }
}

public enum VoiceChoice: Equatable, Sendable {
    /// Let the system apply the user's Spoken Content voice and rate.
    case systemSpokenContent
    case voice(String)
    /// Nothing suitable is installed; use the system default for the language.
    case systemDefault

    /// The best installed voice for `language`: the user's Spoken Content settings if they use them, otherwise
    /// premium, then enhanced, then standard, preferring an exact region match (en-US over en-GB) among equals.
    public static func pick(from voices: [VoiceCandidate], language: String, usesAssistiveSettings: Bool) -> VoiceChoice {
        if usesAssistiveSettings { return .systemSpokenContent }
        let base = language.split(separator: "-").first.map(String.init) ?? language
        let usable = voices.filter { !$0.isNovelty && $0.language.split(separator: "-").first.map(String.init) == base }
        let best = usable.max { a, b in
            if a.quality != b.quality { return a.quality < b.quality }
            let aExact = a.language == language, bExact = b.language == language
            if aExact != bExact { return bExact }
            return a.identifier > b.identifier   // deterministic
        }
        return best.map { .voice($0.identifier) } ?? .systemDefault
    }

    /// True when the best voice we can use is only the compact/standard one, so a tip about downloading better ones helps.
    public static func shouldSuggestUpgrade(from voices: [VoiceCandidate], language: String, usesAssistiveSettings: Bool) -> Bool {
        if usesAssistiveSettings { return false }
        let base = language.split(separator: "-").first.map(String.init) ?? language
        return !voices.contains { !$0.isNovelty && $0.language.split(separator: "-").first.map(String.init) == base && $0.quality >= .enhanced }
    }
}
