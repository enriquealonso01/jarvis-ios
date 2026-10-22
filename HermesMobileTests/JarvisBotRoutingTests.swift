import XCTest
@testable import HermesMobile

/// Bot routing (`docs/agents/bots.md` § Bot routing): which reply moves a new general chat into a
/// Bot, what the moved chat says, and how a merged Sessions list learns each Bot's look.
final class JarvisBotRoutingTests: XCTestCase {

    private func reply(_ profile: String, _ confidence: Double, title: String? = nil) -> JarvisBotRoute {
        JarvisBotRoute(profile: profile, confidence: confidence, reason: nil, title: title)
    }

    func testOnlyTheGeneralProfilesNewChatsAreRouted() {
        XCTAssertTrue(JarvisBotRouting.routes(profile: "default"))
        XCTAssertFalse(JarvisBotRouting.routes(profile: "ios"), "A chat opened in a Bot stays there")
        XCTAssertFalse(JarvisBotRouting.routes(profile: "research"), "A Profile the user picked is never moved")
    }

    func testAConfidentReplyNamingAnotherProfileMovesTheChat() {
        XCTAssertEqual(JarvisBotRouting.destination(reply("ios", 0.95), current: "default"), "ios")
        XCTAssertEqual(JarvisBotRouting.destination(reply(" ios ", 0.7), current: "default"), "ios", "At the threshold, and trimmed")
    }

    func testAnythingElseKeepsTheChatWhereItIs() {
        XCTAssertNil(JarvisBotRouting.destination(nil, current: "default"), "No reply: the box was slow or down")
        XCTAssertNil(JarvisBotRouting.destination(reply("general", 1.0), current: "default"))
        XCTAssertNil(JarvisBotRouting.destination(reply("ios", 0.69), current: "default"), "Below the threshold")
        XCTAssertNil(JarvisBotRouting.destination(reply("default", 0.99), current: "default"), "Already there")
        XCTAssertNil(JarvisBotRouting.destination(reply("", 0.99), current: "default"))
    }

    func testTheNoticeNamesTheBotByTitleElseByProfile() {
        XCTAssertEqual(JarvisBotRouting.notice(for: reply("ios", 0.9, title: "iOS Builder"), profile: "ios"), "Opened in iOS Builder")
        XCTAssertEqual(JarvisBotRouting.notice(for: reply("ios", 0.9, title: "  "), profile: "ios"), "Opened in ios")
        XCTAssertEqual(JarvisBotRouting.notice(for: reply("ios", 0.9), profile: "ios"), "Opened in ios")
    }

    func testTheBridgesReplyDecodesWithANullTitle() throws {
        let json = #"{"profile": "ios", "confidence": 0.95, "reason": "iOS app mic issue", "title": "iOS Builder"}"#
        let route = try JSONDecoder().decode(JarvisBotRoute.self, from: Data(json.utf8))
        XCTAssertEqual(route, JarvisBotRoute(profile: "ios", confidence: 0.95, reason: "iOS app mic issue", title: "iOS Builder"))

        let general = #"{"profile": "general", "confidence": 1.0, "reason": "small talk", "title": null}"#
        XCTAssertEqual(try JSONDecoder().decode(JarvisBotRoute.self, from: Data(general.utf8)).title, nil)
    }

    // MARK: Bot looks on a merged Sessions list

    func testAProfileRowWithABotLookGivesTheRowItsTitleAndFace() throws {
        let row: BotJSON = .object([
            "name": .string("ios"),
            "ui_meta": .object(["hermes-bots": .object([
                "title": .string("iOS Builder"), "custom": .bool(true), "shape": .string("squircle"),
                "color": .string("#38bdf8"), "expression": .string("attentive")
            ])])
        ])
        let look = try XCTUnwrap(HermesBotLook(profileRow: row))
        XCTAssertEqual(look.title, "iOS Builder")
        XCTAssertEqual(look.appearance.shape, "squircle")
        XCTAssertEqual(look.appearance.color, "#38bdf8")
        XCTAssertTrue(look.appearance.custom)
    }

    func testAProfileRowWithoutBotModeMetadataHasNoLook() {
        XCTAssertNil(HermesBotLook(profileRow: .object(["name": .string("default")])))
        XCTAssertNil(HermesBotLook(profileRow: .object(["name": .string("coder"), "ui_meta": .object([:])])))
        XCTAssertNil(HermesBotLook(profileRow: .object(["ui_meta": .object(["hermes-bots": .object([:])])])), "No name, no row")
    }

    // MARK: All Profiles by default on JARVIS

    func testJarvisListsEveryBotsSessionsUntilAProfileIsPicked() throws {
        let suite = "JarvisBotRoutingTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let jarvis = JarvisServer.productionAddress
        let other = try XCTUnwrap(URL(string: "https://hermes.example"))

        HermesProfilePreference.seedJarvisAllProfiles(for: other, in: defaults)
        XCTAssertFalse(HermesProfilePreference.showsAllProfiles(for: other, in: defaults), "Another host keeps Hermex's default")

        HermesProfilePreference.seedJarvisAllProfiles(for: jarvis, in: defaults)
        XCTAssertTrue(HermesProfilePreference.showsAllProfiles(for: jarvis, in: defaults))

        HermesProfilePreference.saveShowsAllProfiles(false, for: jarvis, in: defaults)
        HermesProfilePreference.seedJarvisAllProfiles(for: jarvis, in: defaults)
        XCTAssertFalse(HermesProfilePreference.showsAllProfiles(for: jarvis, in: defaults), "A pick made once is kept")
    }
}
