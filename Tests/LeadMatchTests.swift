import XCTest
@testable import Pianwai

/// 0.4.2: which recording a lead attaches to, and which people may stand in the bin.
@MainActor final class LeadMatchTests: XCTestCase {
    func testCreatorMatchesAcrossCreditLinesAndSmallKana() {
        // The model writes ベッツイ, the store has ベッツィ.
        XCTAssertTrue(LeadMatch.sameCreator("ベッツィ&クリス", "ベッツイ&クリス"))
        XCTAssertTrue(LeadMatch.sameCreator("桑田佳祐 & あいみょん", "あいみょん"))
        XCTAssertTrue(LeadMatch.sameCreator("平井 堅", "平井堅、あいみょん"))
        XCTAssertTrue(LeadMatch.sameCreator("陳奕迅", "陈奕迅"))
        // A cover of the same title by someone else is not the original.
        XCTAssertFalse(LeadMatch.sameCreator("小林啓子 & ビリー・バンバン", "ベッツイ&クリス"))
        XCTAssertFalse(LeadMatch.sameCreator("W", "ベッツィ&クリス"))
    }

    func testOnlyDirectCreatorsMayStandInTheBin() {
        for label in ["合唱歌手", "原唱", "剧集导演", "主演", "原作作者"] {
            XCTAssertTrue(ShopNowPage.directCreator(label), label)
        }
        for label in ["作曲及编曲", "填词", "制作人", "MV 导演", "编舞", "作曲家关联"] {
            XCTAssertFalse(ShopNowPage.directCreator(label), label)
        }
    }

    /// 0.4.3: a video is searched by artist and song on the video sites, never on Douban or Wikipedia.
    func testVideoQueriesAndPlatforms() {
        XCTAssertEqual(WorkDestinations.coreTitle("wacci『恋だろ』Music Video"), "恋だろ")
        XCTAssertEqual(WorkDestinations.coreTitle("恋だろ / THE FIRST TAKE"), "恋だろ")
        XCTAssertEqual(WorkDestinations.coreTitle("Lemon"), "Lemon")
        XCTAssertEqual(WorkDestinations.videoQuery("wacci『恋だろ』Music Video", creator: "wacci、柴田啓佑"), "wacci 恋だろ MV")
        XCTAssertEqual(WorkDestinations.videoQuery("恋だろ / THE FIRST TAKE", creator: "wacci"), "wacci 恋だろ THE FIRST TAKE")
        XCTAssertEqual(WorkDestinations.videoPlatform(URL(string: "https://music.apple.com/jp/music-video/x/1623978351")!), "Apple Music")
        XCTAssertEqual(WorkDestinations.videoPlatform(URL(string: "https://www.youtube.com/watch?v=abc")!), "YouTube")
        XCTAssertEqual(WorkDestinations.videoPlatform(URL(string: "https://www.bilibili.com/video/BV1xx")!), "哔哩哔哩")
        XCTAssertNil(WorkDestinations.videoPlatform(URL(string: "https://music.apple.com/jp/album/x/1")!))
        XCTAssertNil(WorkDestinations.videoPlatform(URL(string: "https://natalie.mu/music/news/1")!))
    }
}
