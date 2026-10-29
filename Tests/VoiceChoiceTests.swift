import XCTest
@testable import PeoplemapsCore

final class VoiceChoiceTests: XCTestCase {
    private func v(_ id: String, _ lang: String, _ q: VoiceCandidate.Quality) -> VoiceCandidate { .init(identifier: id, language: lang, quality: q) }
    private let compact = VoiceCandidate(identifier: "com.apple.voice.compact.en-US.Samantha", language: "en-US", quality: .standard)

    func testPremiumBeatsEnhancedBeatsStandard() {
        let voices = [compact, v("e", "en-US", .enhanced), v("p", "en-US", .premium)]
        XCTAssertEqual(VoiceChoice.pick(from: voices, language: "en-US", usesAssistiveSettings: false), .voice("p"))
        XCTAssertEqual(VoiceChoice.pick(from: [compact, v("e", "en-US", .enhanced)], language: "en-US", usesAssistiveSettings: false), .voice("e"))
    }

    func testNoveltyAndEloquenceIgnored() {
        let voices = [compact, v("com.apple.speech.synthesis.voice.Zarvox", "en-US", .premium), v("com.apple.eloquence.en-US.Rocko", "en-US", .enhanced)]
        XCTAssertEqual(VoiceChoice.pick(from: voices, language: "en-US", usesAssistiveSettings: false), .voice(compact.identifier))
    }

    func testExactRegionPreferredAmongEqualQuality() {
        let voices = [v("gb", "en-GB", .enhanced), v("us", "en-US", .enhanced)]
        XCTAssertEqual(VoiceChoice.pick(from: voices, language: "en-US", usesAssistiveSettings: false), .voice("us"))
    }

    func testBetterQualityBeatsExactRegion() {
        let voices = [v("gb", "en-GB", .premium), v("us", "en-US", .standard)]
        XCTAssertEqual(VoiceChoice.pick(from: voices, language: "en-US", usesAssistiveSettings: false), .voice("gb"))
    }

    func testOtherLanguagesIgnoredAndFallback() {
        XCTAssertEqual(VoiceChoice.pick(from: [v("fr", "fr-FR", .premium)], language: "en-US", usesAssistiveSettings: false), .systemDefault)
    }

    func testSpokenContentSettingsWin() {
        XCTAssertEqual(VoiceChoice.pick(from: [v("p", "en-US", .premium)], language: "en-US", usesAssistiveSettings: true), .systemSpokenContent)
    }

    func testUpgradeSuggestedOnlyWithoutBetterVoice() {
        XCTAssertTrue(VoiceChoice.shouldSuggestUpgrade(from: [compact], language: "en-US", usesAssistiveSettings: false))
        XCTAssertFalse(VoiceChoice.shouldSuggestUpgrade(from: [compact, v("e", "en-US", .enhanced)], language: "en-US", usesAssistiveSettings: false))
        XCTAssertFalse(VoiceChoice.shouldSuggestUpgrade(from: [compact], language: "en-US", usesAssistiveSettings: true))
        XCTAssertTrue(VoiceChoice.shouldSuggestUpgrade(from: [v("z", "en-US", .premium).withId("com.apple.speech.synthesis.voice.Zarvox")], language: "en-US", usesAssistiveSettings: false))
    }
}

private extension VoiceCandidate {
    func withId(_ id: String) -> VoiceCandidate { .init(identifier: id, language: language, quality: quality) }
}
