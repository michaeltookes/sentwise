import SentwiseMail
import XCTest
@testable import Sentwise

/// Item 138: the follow-up prompt names the user and the recipient, keeps the
/// transcript's numbers, and never copies a learned greeting's personal name.
final class FollowUpIdentityPromptTests: XCTestCase {

    static let t1 = """
    Dana (Acme): Thanks for walking us through the pilot today.
    Lucius: Happy to. To recap, you want 10 seats for a 30-day pilot starting November 2.
    Dana (Acme): Right. I need the security questionnaire back by Friday.
    Lucius: I'll send it Thursday, along with the pilot order form.
    Dana (Acme): Great. Let's meet again on November 9 to review results.
    """

    private func profile(greeting: String) -> VoiceProfile {
        VoiceProfile(
            greeting: greeting, signOff: "Best,\nLucius", formality: "casual", tone: "warm",
            averageLength: "short", commonPhrases: [], summary: "", sampleCount: 5,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func systemPrompt(
        greeting: String = "Hi Michael,",
        recipients: [MailAddress] = [MailAddress(email: "luciusfox@prowlqa.dev")],
        text: String = FollowUpIdentityPromptTests.t1,
        labeled: Bool = true
    ) -> String {
        let voice = profile(greeting: greeting)
        return FollowUpGenerator.systemPrompt(
            voiceProfile: voice,
            context: FollowUpDraftContext(text: text, hasSpeakerLabels: labeled, source: .transcript),
            participants: FollowUpParticipants(
                userEmail: "luciusfox@prowlqa.dev", voiceProfile: voice, recipients: recipients
            )
        )
    }

    // MARK: - User identity

    func testPromptNamesTheUserAsTheIAndMatchesTheSpeakerLabel() {
        let prompt = systemPrompt()
        XCTAssertTrue(prompt.contains("every \"I\", \"me\" and \"my\" in the email is the user"))
        XCTAssertTrue(prompt.contains("luciusfox@prowlqa.dev"))
        XCTAssertTrue(prompt.contains("the speaker labeled \"Lucius\""))
        XCTAssertTrue(prompt.contains("Never assign it to anyone else"))
    }

    func testSignOffNameIdentifiesTheUserSpeakerWhenMailboxDoesNotMatch() {
        let participants = FollowUpParticipants(
            userEmail: "lf@example.com", userNameHints: ["Lucius"], recipients: []
        )
        XCTAssertEqual(participants.userSpeaker(in: ["Dana", "Lucius"]), "Lucius")
    }

    // MARK: - Recipient

    func testRecipientIsTheOtherSpeakerEvenWhenTheRecipientAddressIsTheUsers() {
        let prompt = systemPrompt()
        XCTAssertTrue(prompt.contains("addressed to Dana"))
        XCTAssertTrue(prompt.contains("Never greet the user by name"))
    }

    func testRecipientDisplayNameWinsOverTranscriptInference() {
        let prompt = systemPrompt(recipients: [MailAddress(name: "Dana Reyes", email: "dana@acme.example")])
        XCTAssertTrue(prompt.contains("addressed to Dana,"))
        XCTAssertTrue(prompt.contains("Greeting: Hi Dana,"))
    }

    func testUnlabeledTranscriptDoesNotGuessARecipientOrOwner() {
        let text = "We agreed on ten seats and a 30-day pilot. Someone will send the questionnaire Thursday."
        let prompt = systemPrompt(text: text, labeled: false)
        XCTAssertTrue(prompt.contains("the other participant(s) on the call"))
        XCTAssertFalse(prompt.contains("the speaker labeled"))
        let user = FollowUpGenerator.userPrompt(
            context: FollowUpDraftContext(text: text, hasSpeakerLabels: false, source: .transcript),
            userSuppliedFacts: nil
        )
        XCTAssertTrue(user.contains("phrase action items without guessing who owns them"))
    }

    // MARK: - Facts

    func testPromptTellsTheModelToKeepQuantitiesDurationsAndDates() {
        let prompt = systemPrompt()
        XCTAssertTrue(prompt.contains("Keep every quantity, duration, price and date exactly as stated"))
    }

    // MARK: - Greeting placeholder

    func testLearnedGreetingNameNeverReachesThePrompt() {
        let prompt = systemPrompt(greeting: "Hi Michael,")
        XCTAssertFalse(prompt.contains("Hi Michael"))
        XCTAssertTrue(prompt.contains("Greeting: Hi Dana,"))
    }

    func testNameFreeForeignGreetingsAreLeftAlone() {
        for greeting in ["Bonjour,", "Hola,", "Welcome,", "Greetings,"] {
            XCTAssertEqual(VoiceProfile.normalizedGreeting(greeting), greeting)
            XCTAssertEqual(profile(greeting: greeting).withNormalizedGreeting().greeting, greeting)
        }
        XCTAssertEqual(VoiceProfile.normalizedGreeting("Dana,", knownNames: ["Dana Reyes"]), "<first name>,")
    }

    func testUnknownRecipientGetsNameFreeGreetingInstruction() {
        let text = "We agreed on ten seats."
        let prompt = systemPrompt(greeting: "Hi <first name>,", text: text, labeled: false)
        XCTAssertTrue(prompt.contains("no name is known"))
        XCTAssertTrue(prompt.contains("uses no name"))
        XCTAssertFalse(prompt.contains("Greet them by first name"))
        XCTAssertTrue(prompt.contains("write the greeting without a name"))
    }

    func testExactSignOffMatchBeatsMailboxPrefixMatch() {
        let participants = FollowUpParticipants(
            userEmail: "jane@example.com", userNameHints: ["Jane"], recipients: []
        )
        XCTAssertEqual(participants.userSpeaker(in: ["Janet", "Jane"]), "Jane")
    }

    func testAmbiguousUserSpeakerAssertsNoOwnership() {
        let participants = FollowUpParticipants(userEmail: "jane@example.com", userNameHints: [], recipients: [])
        // Both labels are only prefix candidates: no exact identity, so no owner is claimed.
        XCTAssertNil(participants.userSpeaker(in: ["Janet", "Janel"]))
        let text = "Janet: hello\nJanel: hi"
        let prompt = systemPrompt(recipients: [], text: text)
        XCTAssertFalse(prompt.contains("the speaker labeled"))
    }

    func testUniqueMailboxPrefixIsNotEnoughToResolveTheUser() {
        let participants = FollowUpParticipants(
            userEmail: "jane@example.com", userNameHints: ["Jane"], recipients: []
        )
        // "Me" is a self label; Janet is only a prefix candidate and must not win.
        XCTAssertEqual(participants.userSpeaker(in: ["Me", "Janet"]), "Me")
        XCTAssertNil(participants.userSpeaker(in: ["Dana", "Janet"]))
        let text = "Janet: hi\nDana: hello"
        let prompt = systemPrompt(recipients: [], text: text)
        XCTAssertFalse(prompt.contains("the speaker labeled"))
        XCTAssertNil(participants.recipientFirstName(transcript: "Me: hi\nJanet: hello", hasSpeakerLabels: true)
            .flatMap { $0 == "Janet" ? nil : $0 })
    }

    func testAnonymousSpeakerLabelsNeverBecomeTheGreetingName() {
        let participants = FollowUpParticipants(
            userEmail: "lf@example.com", userNameHints: ["Lucius"], recipients: []
        )
        for text in ["Lucius: hi\nSpeaker A: hello", "Speaker A: hi\nSpeaker B: hello",
                     "Lucius: hi\nParticipant 2: hello", "Me: hi\nUnknown: hello", "Lucius: hi\nGuest: yo"] {
            XCTAssertNil(participants.recipientFirstName(transcript: text, hasSpeakerLabels: true), text)
        }
        XCTAssertEqual(
            participants.recipientFirstName(transcript: "Lucius: hi\nSpeaker B: x\nDana: hello", hasSpeakerLabels: true),
            "Dana"
        )
        let prompt = systemPrompt(recipients: [], text: "Speaker A: hi\nSpeaker B: hello")
        XCTAssertFalse(prompt.contains("Greet Speaker"))
        XCTAssertTrue(prompt.contains("uses no name"))
    }

    func testSuppliedCorrectionOverridesPreservationRule() {
        let voice = profile(greeting: "Hi <first name>,")
        let prompt = FollowUpGenerator.systemPrompt(
            voiceProfile: voice,
            context: FollowUpDraftContext(text: "Dana: starts November 2", hasSpeakerLabels: true, source: .transcript),
            participants: FollowUpParticipants(userEmail: "a@b.com", voiceProfile: voice, recipients: []),
            hasSuppliedFacts: true
        )
        XCTAssertTrue(prompt.contains("authoritative corrections"))
        XCTAssertTrue(prompt.contains("the user-supplied fact wins"))
        XCTAssertTrue(prompt.contains("Apart from those corrected facts, keep every quantity"))
        XCTAssertFalse(systemPrompt().contains("authoritative corrections"))
    }

    func testQuestionnaireOwnershipPredicate() {
        let valid = [
            "I'll send the security questionnaire on Thursday.",
            "I will email you the questionnaire by Thursday.",
            "I\u{2019}ll complete and return the security questionnaire on Thursday with the pilot order form.",
            "I'll fill out the security questionnaire and get it back to you Thursday.",
            "The questionnaire will come from me on Thursday.",
            "We'll provide the security questionnaire Thursday.",
            "Dana, the questionnaire from me lands Thursday, and I'll send the order form Monday.",
            "I'm going to share the questionnaire Thursday."
        ]
        for text in valid { XCTAssertTrue(QuestionnaireOwnership.isUserOwned(text), text) }
        let invalid = [
            "You'll send me the security questionnaire Thursday, and I'll send you the pilot order form.",
            "Dana will send the questionnaire Thursday.",
            "Dana sends the security questionnaire on Thursday.",
            "Please send your questionnaire back by Thursday. You send the questionnaire first.",
            "I'll send the pilot order form Monday.",
            "Please get your questionnaire back to me."
        ]
        for text in invalid { XCTAssertFalse(QuestionnaireOwnership.isUserOwned(text), text) }
    }

    func testPlaceholderGreetingIsExplainedWhenRecipientUnknown() {
        let block = profile(greeting: "Hi Michael,").promptBlock()
        XCTAssertTrue(block.contains("Hi <first name>,"))
        XCTAssertFalse(block.contains("Michael"))
    }

    func testGreetingNormalisation() {
        let cases: [(String, String)] = [
            ("Hi Michael,", "Hi <first name>,"),
            ("Hey Dana -", "Hey <first name> -"),
            ("Good morning Dana,", "Good morning <first name>,"),
            ("Hi {first name},", "Hi <first name>,"),
            ("Dear Ms. Reyes,", "Dear <first name>,"),
            ("Hi Dana Reyes,", "Hi <first name>,"),
            ("Thanks Dana,", "Thanks <first name>,"),
            ("Hi <first name>,", "Hi <first name>,"),
            ("Hello,", "Hello,"),
            ("Hi team,", "Hi team,"),
            ("Hi there,", "Hi there,"),
            ("Dana,", "Dana,"),
            ("Bonjour,", "Bonjour,"),
            ("", "")
        ]
        for (input, expected) in cases {
            let once = VoiceProfile.normalizedGreeting(input)
            XCTAssertEqual(once, expected, input)
            XCTAssertEqual(VoiceProfile.normalizedGreeting(once), once, "idempotent: \(input)")
        }
    }

    func testStoredProfileWithNamedGreetingMigratesWithoutDataLoss() throws {
        // The load path decodes the stored JSON and applies `withNormalizedGreeting()`.
        let stored = profile(greeting: "Hi Michael,")
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let decoded = try decoder.decode(VoiceProfile.self, from: encoder.encode(stored))
        let migrated = decoded.withNormalizedGreeting()
        var expected = stored
        expected.greeting = "Hi <first name>,"
        XCTAssertEqual(migrated, expected)
        XCTAssertEqual(migrated.withNormalizedGreeting(), migrated)
    }

    func testRequestCarriesTheIdentityBlock() async throws {
        let participants = FollowUpParticipants(
            userEmail: "luciusfox@prowlqa.dev", userNameHints: ["Lucius"], recipients: []
        )
        var captured: LLMRequest?
        _ = try await FollowUpGenerator().makeFollowUp(
            transcript: ParsedTranscript(text: Self.t1, hasSpeakerLabels: true),
            voiceProfile: profile(greeting: "Hi Michael,"),
            model: "m",
            participants: participants
        ) { request in
            captured = request
            return LLMResponse(text: "Hi Dana,\n\nBody.")
        }
        let system = try XCTUnwrap(captured?.system)
        XCTAssertTrue(system.contains("Who is who:"))
        XCTAssertFalse(system.contains("Hi Michael"))
    }
}
