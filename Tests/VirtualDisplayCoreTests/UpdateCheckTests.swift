import XCTest
@testable import VirtualDisplayCore

/// Version comparison is the whole decision behind "an update is available", and getting
/// it wrong either nags forever or never tells anyone. Nothing here touches the network.
final class UpdateCheckTests: XCTestCase {

    func testNewerVersionsAreRecognised() {
        XCTAssertTrue(UpdateCheck.isNewer("v1.3.0", than: "1.2.9"))
        XCTAssertTrue(UpdateCheck.isNewer("1.10.0", than: "1.9.0"))   // not a string compare
        XCTAssertTrue(UpdateCheck.isNewer("v2.0", than: "1.999.999"))
        XCTAssertTrue(UpdateCheck.isNewer("v0.1.0", than: "0.0.0"))   // unbundled dev build
    }

    func testSameOrOlderIsNotAnUpdate() {
        XCTAssertFalse(UpdateCheck.isNewer("v1.2.3", than: "1.2.3"))
        XCTAssertFalse(UpdateCheck.isNewer("v1.2", than: "1.2.0"))    // missing means zero
        XCTAssertFalse(UpdateCheck.isNewer("v1.2.0", than: "1.2"))
        XCTAssertFalse(UpdateCheck.isNewer("v1.2.3", than: "1.3.0"))
        XCTAssertFalse(UpdateCheck.isNewer("", than: "1.2.3"))
        XCTAssertFalse(UpdateCheck.isNewer("not-a-version", than: "1.2.3"))
    }

    func testParsingARelease() throws {
        let body = """
        {"tag_name": "v1.4.0", "name": "1.4.0",
         "html_url": "https://github.com/rapatao/virtual-display/releases/tag/v1.4.0"}
        """
        let release = try XCTUnwrap(UpdateCheck.parse(body))
        XCTAssertEqual(release.version, "v1.4.0")
        XCTAssertEqual(release.page,
                       "https://github.com/rapatao/virtual-display/releases/tag/v1.4.0")
    }

    /// A release with no page still has a version worth reporting, so it falls back to
    /// the releases list rather than being dropped.
    func testParsingFallsBackToTheReleasesPage() throws {
        let release = try XCTUnwrap(UpdateCheck.parse(#"{"tag_name": "v1.4.0"}"#))
        XCTAssertEqual(release.page, UpdateCheck.releasesPage)
    }

    func testUnusableBodiesAreRejected() {
        XCTAssertNil(UpdateCheck.parse("not json"))
        XCTAssertNil(UpdateCheck.parse("{}"))                    // no tag_name
        XCTAssertNil(UpdateCheck.parse(#"{"message": "Not Found"}"#))
    }
}
