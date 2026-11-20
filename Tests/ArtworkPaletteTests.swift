import XCTest
import UIKit
@testable import Pianwai

final class ArtworkPaletteTests: XCTestCase {
    @MainActor func testSpecifiedFontsAreAvailable() async {
        DesignFonts.shared.prepare()
        for _ in 0..<80 where !DesignFonts.shared.songtiAvailable { try? await Task.sleep(for: .milliseconds(500)) }
        print("Songti fonts:", UIFont.fontNames(forFamilyName: "Songti SC"))
        XCTAssertNotNil(UIFont(name: "STSongti-SC-Bold", size: 23))
        XCTAssertNotNil(UIFont(name: "PingFangSC-Regular", size: 15.5))
    }
    func testThreeAuthoredCoversMeetPaletteContract() throws {
        for name in ["pool", "jane", "verified-q234598"] {
            let image = try XCTUnwrap(UIImage(named: name, in: Bundle(for: Library.self), compatibleWith: nil), name)
            let palette = ArtworkPalette.extract(image)
            XCTAssertGreaterThanOrEqual(palette.ac.contrast(with: palette.bg), 4.5, name)
            XCTAssertTrue((0.1699...0.2001).contains(palette.bg.lab.l), "\(name): \(palette.bg.lab.l)")
            XCTAssertLessThanOrEqual(palette.bg.lab.chroma, 0.0301, name)
            XCTAssertEqual(palette.bg2.lab.l - palette.bg.lab.l, 0.04, accuracy: 0.001, name)
        }
    }
}
