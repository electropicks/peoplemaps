import AVFoundation
import SwiftUI
import UIKit
import PeoplemapsCore
@preconcurrency import FerrostarCore

/// Ferrostar's observer owns muting and audio ducking (`.voicePrompt`); this sits under it as the synthesizer, so what
/// gets spoken is the normalised text, in the best installed voice, at a slightly calmer pace. A new instruction cuts off
/// a stale one rather than queueing behind it.
final class GuidanceSpeaker: SpeechSynthesizer {
    private let synthesizer: AVSpeechSynthesizer
    private let choice: VoiceChoice
    private let language: String

    /// Slightly under the default rate (0.5), with a short breath before each phrase.
    static let rate: Float = 0.47
    static let preDelay: TimeInterval = 0.15

    init(synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer()) {
        self.synthesizer = synthesizer
        self.language = AVSpeechSynthesisVoice.currentLanguageCode()
        self.choice = GuidanceVoice.current().choice
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    func speak(_ utterance: AVSpeechUtterance) {
        let spoken = AVSpeechUtterance(string: SpokenText.normalize(utterance.speechString))
        switch choice {
        case .systemSpokenContent: spoken.prefersAssistiveTechnologySettings = true
        case let .voice(id): spoken.voice = AVSpeechSynthesisVoice(identifier: id)
        case .systemDefault: spoken.voice = AVSpeechSynthesisVoice(language: language)
        }
        if choice != .systemSpokenContent { spoken.rate = Self.rate }
        spoken.preUtteranceDelay = Self.preDelay
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        synthesizer.speak(spoken)
    }

    @discardableResult
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { synthesizer.stopSpeaking(at: boundary) }
}

enum GuidanceVoice {
    static func candidates() -> [VoiceCandidate] {
        AVSpeechSynthesisVoice.speechVoices().map {
            VoiceCandidate(identifier: $0.identifier, language: $0.language,
                           quality: $0.quality == .premium ? .premium : $0.quality == .enhanced ? .enhanced : .standard)
        }
    }

    /// The user relies on Spoken Content when VoiceOver, Speak Screen or Speak Selection is on.
    static var usesAssistiveSettings: Bool {
        UIAccessibility.isVoiceOverRunning || UIAccessibility.isSpeakScreenEnabled || UIAccessibility.isSpeakSelectionEnabled
    }

    static func current() -> (choice: VoiceChoice, suggestUpgrade: Bool) {
        let voices = candidates(), language = AVSpeechSynthesisVoice.currentLanguageCode(), assistive = usesAssistiveSettings
        return (VoiceChoice.pick(from: voices, language: language, usesAssistiveSettings: assistive),
                VoiceChoice.shouldSuggestUpgrade(from: voices, language: language, usesAssistiveSettings: assistive))
    }
}

/// One-time tip on the arrival card, never while driving.
struct VoiceUpgradeTip: View {
    @AppStorage("voiceTipDismissed", store: ExploreView.voiceStore) private var dismissed = false
    private let suggest = GuidanceVoice.current().suggestUpgrade

    var body: some View {
        if suggest && !dismissed {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "waveform").foregroundStyle(.secondary).accessibilityHidden(true)
                Text("For a more natural voice, download an Enhanced or Premium voice in Settings › Accessibility › Spoken Content › Voices.")
                    .font(.footnote).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Got it") { dismissed = true }.font(.footnote.weight(.semibold)).accessibilityIdentifier("voice-tip-dismiss")
            }
            .padding(12).background(.panelFill, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain).accessibilityIdentifier("voice-tip")
        }
    }
}
