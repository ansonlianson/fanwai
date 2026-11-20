import XCTest
@testable import Pianwai

final class WorkArtworkServiceTests: XCTestCase, @unchecked Sendable {
    func testChineseThrottlingStopsTheSharedSourceUntilCooldownWithoutImmediateRetry() async throws {
        let h = ArtworkHarness([
            .init(host: "www.wikidata.org", data: try entity(zh: "准确电影", en: "Exact Film")),
            .init(host: "zh.wikipedia.org", data: Data(), status: 503)
        ]); defer { h.close() }
        do { _ = try await h.service.fetch(qid: "Q100"); XCTFail("A throttled Wikimedia lane must wait for its cooldown") }
        catch { XCTAssertEqual(h.requests.count, 2) }
    }
    func testRealDriveMyCarResponsesKeepVerifiedPosterDespiteNumericExtensionMetadata() async throws {
        let h = ArtworkHarness([
            .init(host: "www.wikidata.org", data: try realDriveMyCar("entity")),
            .init(host: "zh.wikipedia.org", data: try realDriveMyCar("article")),
            .init(host: "zh.wikipedia.org", data: try realDriveMyCar("imageinfo"))
        ]); defer { h.close() }

        let response = try await h.service.fetch(qid: "Q107107865")

        let art = try XCTUnwrap(response.artwork)
        XCTAssertEqual(response.qid, "Q107107865")
        XCTAssertEqual(art.fileTitle, "File:Drive My Car movie poster.jpeg")
        XCTAssertEqual(art.sourcePageURL, "https://zh.wikipedia.org/wiki/File:Drive_My_Car_movie_poster.jpeg")
        XCTAssertEqual(URL(string: art.articleURL)?.path, "/wiki/驾驶我的车")
        XCTAssertEqual(art.width, 265)
        XCTAssertEqual(art.height, 376)
        XCTAssertEqual(art.rawMetadata?["CommonsMetadataExtension"], "1.2")
        XCTAssertEqual(art.credit, "thefilmstage.com")
        XCTAssertEqual(art.licenseName, "Fair use")
        XCTAssertEqual(art.isNonFree, true)
        XCTAssertEqual(h.requests.count, 3)
        XCTAssertEqual(h.parameters(h.requests[1])["titles"], "驾驶我的车")
        XCTAssertEqual(h.parameters(h.requests[2])["titles"], "File:Drive My Car movie poster.jpeg")
    }

    func testScalarMetadataIsReadableButObjectsAndNullNeverBecomeAttributionCopy() async throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: file(metadata: [:])) as? [String: Any])
        var query = try XCTUnwrap(root["query"] as? [String: Any])
        var pages = try XCTUnwrap(query["pages"] as? [[String: Any]])
        var infos = try XCTUnwrap(pages[0]["imageinfo"] as? [[String: Any]])
        let values: [String: Any] = [
            "Artist": ["name": "Not verified attribution text"], "Credit": NSNull(),
            "LicenseShortName": "Fair use", "NonFree": true,
            "CommonsMetadataExtension": 1.2, "UnknownArray": ["Not prose"]
        ]
        infos[0]["extmetadata"] = values.mapValues { ["value": $0] }
        pages[0]["imageinfo"] = infos; query["pages"] = pages; root["query"] = query
        let h = ArtworkHarness([
            .init(host: "www.wikidata.org", data: try entity()),
            .init(host: "zh.wikipedia.org", data: try article()),
            .init(host: "zh.wikipedia.org", data: try json(root))
        ]); defer { h.close() }

        let response = try await h.service.fetch(qid: "Q100")
        let art = try XCTUnwrap(response.artwork)

        XCTAssertNil(art.artist)
        XCTAssertNil(art.credit)
        XCTAssertNil(art.rawMetadata?["Artist"])
        XCTAssertNil(art.rawMetadata?["Credit"])
        XCTAssertNil(art.rawMetadata?["UnknownArray"])
        XCTAssertEqual(art.rawMetadata?["CommonsMetadataExtension"], "1.2")
        XCTAssertEqual(art.nonFreeValue, "true")
        XCTAssertEqual(art.isNonFree, true)
        XCTAssertEqual(art.licenseName, "Fair use")
        XCTAssertEqual(art.sourcePageURL, "https://zh.wikipedia.org/wiki/File:Poster.jpg")
    }

    func testExactFilmKeepsAttributionNonFreeAndActualSmallImageDimensions() async throws {
        let h = ArtworkHarness(try plans()); defer { h.close() }
        let response = try await h.service.fetch(qid: "Q100")
        let art = try XCTUnwrap(response.artwork)
        XCTAssertEqual(response.qid, "Q100")
        XCTAssertEqual(art.width, 265, "Unscaled original must not inherit the requested 320px")
        XCTAssertEqual(art.height, 376)
        XCTAssertEqual(art.fileTitle, "File:Poster.jpg")
        XCTAssertEqual(art.artist, "A Studio")
        XCTAssertEqual(art.credit, "A source")
        XCTAssertEqual(art.licenseName, "Fair use")
        XCTAssertEqual(art.isNonFree, true)
        XCTAssertEqual(art.nonFreeValue, "true")
        XCTAssertNil(art.licenseURL)
        XCTAssertEqual(art.rawMetadata?["Artist"], "<b>A Studio</b>")
        XCTAssertEqual(art.sourcePageURL, "https://zh.wikipedia.org/wiki/File:Poster.jpg")
        XCTAssertEqual(art.articleURL, "https://zh.wikipedia.org/wiki/Exact_Film")
        XCTAssertEqual(h.requests.count, 3)
        for request in h.requests {
            XCTAssertEqual(request.url?.path, "/w/api.php", "Never download image bodies")
            XCTAssertNotEqual(request.url?.host, "upload.wikimedia.org")
            XCTAssertNil(h.parameters(request)["search"])
        }
        XCTAssertEqual(h.parameters(h.requests[1])["pilicense"], "any")
        XCTAssertEqual(h.parameters(h.requests[1])["pithumbsize"], "320")
        XCTAssertEqual(h.parameters(h.requests[2])["iiurlwidth"], "320")
    }

    func testChineseWithoutImageFallsBackToExactEnglishSitelink() async throws {
        let h = ArtworkHarness([
            .init(host: "www.wikidata.org", data: try entity(zh: "准确电影", en: "Exact Film")),
            .init(host: "zh.wikipedia.org", data: try article(title: "准确电影", hasImage: false)),
            .init(host: "en.wikipedia.org", data: try article()),
            .init(host: "en.wikipedia.org", data: try file(language: "en"))
        ]); defer { h.close() }
        let response = try await h.service.fetch(qid: "Q100")
        XCTAssertEqual(response.artwork?.articleURL, "https://en.wikipedia.org/wiki/Exact_Film")
        XCTAssertEqual(response.artwork?.sourcePageURL, "https://en.wikipedia.org/wiki/File:Poster.jpg")
        XCTAssertEqual(h.parameters(h.requests[1])["titles"], "准确电影")
        XCTAssertEqual(h.parameters(h.requests[2])["titles"], "Exact Film")
        XCTAssertEqual(h.requests.count, 4)
    }

    func testWrongQIDNamespaceAndDisambiguationCannotFallBackAsIfImageWereMissing() async throws {
        for page in [try article(qid: "Q999"), try article(namespace: 1), try article(disambiguation: true)] {
            let h = ArtworkHarness([.init(host: "www.wikidata.org", data: try entity(en: "Other Film")), .init(host: "zh.wikipedia.org", data: page)]); defer { h.close() }
            do { _ = try await h.service.fetch(qid: "Q100"); XCTFail("Unverified identity accepted") }
            catch WorkArtworkError.identityMismatch { }
            XCTAssertEqual(h.requests.count, 2)
        }
    }

    func testArticleTitleChangeRequiresAPIRewriteEvidence() async throws {
        let rejected = ArtworkHarness([.init(host: "www.wikidata.org", data: try entity()), .init(host: "zh.wikipedia.org", data: try article(title: "Different Film"))]); defer { rejected.close() }
        do { _ = try await rejected.service.fetch(qid: "Q100"); XCTFail("Undeclared title substitution accepted") }
        catch WorkArtworkError.identityMismatch { }
        let h = ArtworkHarness([
            .init(host: "www.wikidata.org", data: try entity()),
            .init(host: "zh.wikipedia.org", data: try article(title: "Renamed Film", redirects: [["from": "Exact Film", "to": "Renamed Film"]])),
            .init(host: "zh.wikipedia.org", data: try file())
        ]); defer { h.close() }
        let response = try await h.service.fetch(qid: "Q100")
        XCTAssertEqual(response.artwork?.articleURL, "https://zh.wikipedia.org/wiki/Renamed_Film")
    }

    func testMissingOptionalAttributionStillReturnsThumbnailWithoutClaimingFreeUse() async throws {
        let h = ArtworkHarness(try plans(metadata: [:])); defer { h.close() }
        let response = try await h.service.fetch(qid: "Q100")
        let art = try XCTUnwrap(response.artwork)
        XCTAssertNil(art.artist)
        XCTAssertNil(art.credit)
        XCTAssertNil(art.licenseName)
        XCTAssertNil(art.licenseURL)
        XCTAssertNil(art.isNonFree, "Unknown must not become free")
        XCTAssertNil(art.nonFreeValue)
        XCTAssertFalse(art.sourcePageURL.isEmpty)
    }

    func testMissingImageinfoOrDescriptionIsFailureNotMissingArtwork() async throws {
        for data in [try file(includeInfo: false), try file(description: nil)] {
            let h = ArtworkHarness([
                .init(host: "www.wikidata.org", data: try entity()),
                .init(host: "zh.wikipedia.org", data: try article()),
                .init(host: "zh.wikipedia.org", data: data)
            ]); defer { h.close() }
            do { _ = try await h.service.fetch(qid: "Q100"); XCTFail("Incomplete provenance became artwork or nil") }
            catch WorkArtworkError.invalidResponse { }
        }
    }

    func testPeopleBooksSongsAndUnlistedCreativeSubtypesUseExactIdentityInsteadOfFilmGate() async throws {
        for type in ["Q5", "Q571", "Q8261", "Q7366", "Q999999"] {
            let h = ArtworkHarness([
                .init(host: "www.wikidata.org", data: try entity(type: type)),
                .init(host: "zh.wikipedia.org", data: try article()),
                .init(host: "zh.wikipedia.org", data: try file())
            ]); defer { h.close() }
            let response = try await h.service.fetch(qid: "Q100")
            XCTAssertNotNil(response.artwork)
            XCTAssertEqual(h.requests.count, 3)
            XCTAssertNil(h.parameters(h.requests[1])["search"])
        }
    }

    func testJapaneseSitelinkWorksWhenEnglishAndChineseHaveNoImage() async throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: entity(en: "Exact Film")) as? [String: Any])
        var entities = try XCTUnwrap(root["entities"] as? [String: [String: Any]])
        var item = try XCTUnwrap(entities["Q100"])
        var links = try XCTUnwrap(item["sitelinks"] as? [String: [String: String]])
        links["jawiki"] = ["site": "jawiki", "title": "正確な作品"]
        item["sitelinks"] = links; entities["Q100"] = item; root["entities"] = entities
        let h = ArtworkHarness([
            .init(host: "www.wikidata.org", data: try json(root)),
            .init(host: "zh.wikipedia.org", data: try article(hasImage: false)),
            .init(host: "en.wikipedia.org", data: try article(hasImage: false)),
            .init(host: "ja.wikipedia.org", data: try article(title: "正確な作品")),
            .init(host: "ja.wikipedia.org", data: try file(language: "ja"))
        ]); defer { h.close() }
        let response = try await h.service.fetch(qid: "Q100")
        XCTAssertEqual(URL(string: try XCTUnwrap(response.artwork).articleURL)?.path, "/wiki/正確な作品")
    }

    func testExactP18CommonsImageWorksWithoutAnyWikipediaSitelink() async throws {
        let h = ArtworkHarness([
            .init(host: "www.wikidata.org", data: try commonsEntity()),
            .init(host: "commons.wikimedia.org", data: try file(description: "https://commons.wikimedia.org/wiki/File:Poster.jpg"))
        ]); defer { h.close() }
        let response = try await h.service.fetch(qid: "Q100")
        let art = try XCTUnwrap(response.artwork)
        XCTAssertEqual(art.id, "commons:File:Poster.jpg")
        XCTAssertEqual(art.articleURL, "https://www.wikidata.org/wiki/Q100")
        XCTAssertEqual(art.sourcePageURL, "https://commons.wikimedia.org/wiki/File:Poster.jpg")
        XCTAssertEqual(h.parameters(h.requests[1])["titles"], "File:Poster.jpg")
        XCTAssertEqual(art.width, 265)
    }

    func testP18RejectsDeprecatedQualifiedAndNonMediaClaims() async throws {
        let cases: [[String: Any]] = [["rank": "deprecated"], ["qualifiers": ["P518": []]], ["datatype": "string"], ["snaktype": "novalue"]]
        for changes in cases {
            let h = ArtworkHarness([.init(host: "www.wikidata.org", data: try commonsEntity(changes: changes))]); defer { h.close() }
            let response = try await h.service.fetch(qid: "Q100")
            XCTAssertNil(response.artwork)
            XCTAssertEqual(h.requests.count, 1)
        }
    }

    func testP18PreferredStatementWinsAndMismatchedDescriptionNeverBecomesImage() async throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: commonsEntity()) as? [String: Any])
        var entities = try XCTUnwrap(root["entities"] as? [String: [String: Any]])
        var item = try XCTUnwrap(entities["Q100"])
        let old: [String: Any] = ["rank": "normal", "mainsnak": ["property": "P18", "snaktype": "value", "datatype": "commonsMedia", "datavalue": ["value": "Earlier.jpg"]]]
        let preferred: [String: Any] = ["rank": "preferred", "mainsnak": ["property": "P18", "snaktype": "value", "datatype": "commonsMedia", "datavalue": ["value": "Poster.jpg"]]]
        item["claims"] = ["P18": [old, preferred]]; entities["Q100"] = item; root["entities"] = entities
        let h = ArtworkHarness([
            .init(host: "www.wikidata.org", data: try json(root)),
            .init(host: "commons.wikimedia.org", data: try file(description: "https://commons.wikimedia.org/wiki/File:Other.jpg"))
        ]); defer { h.close() }
        do { _ = try await h.service.fetch(qid: "Q100"); XCTFail("Wrong source accepted") }
        catch WorkArtworkError.invalidResponse { }
        XCTAssertEqual(h.parameters(h.requests[1])["titles"], "File:Poster.jpg")
    }

    func testExactAppleArtistHeaderSuppliesPortraitWithoutUsingAlbumOrSocialCard() async throws {
        let h = ArtworkHarness([
            .init(host: "www.wikidata.org", data: try appleEntity()),
            .init(host: "music.apple.com", data: try applePage())
        ]); defer { h.close() }
        let response = try await h.service.fetch(qid: "Q100")
        let art = try XCTUnwrap(response.artwork)
        XCTAssertEqual(art.id, "apple-artist:939561587")
        XCTAssertEqual(art.thumbnailURL, "https://is1-ssl.mzstatic.com/image/thumb/Music/portrait.jpg/320x320bb.jpg")
        XCTAssertEqual(art.sourcePageURL, "https://music.apple.com/jp/artist/939561587")
        XCTAssertEqual(art.articleURL, "https://www.wikidata.org/wiki/Q100")
        XCTAssertEqual(art.rawMetadata?["IdentityProperty"], "P2850")
        XCTAssertNil(art.licenseName)
        XCTAssertNil(art.isNonFree)
    }

    func testWrongAppleArtistAndUntrustedImageHostCannotSupplyPortrait() async throws {
        for data in [try applePage(id: "123"), try applePage(imageHost: "is1-ssl.mzstatic.com.evil.example")] {
            let h = ArtworkHarness([
                .init(host: "www.wikidata.org", data: try appleEntity()),
                .init(host: "music.apple.com", data: data)
            ]); defer { h.close() }
            do { _ = try await h.service.fetch(qid: "Q100"); XCTFail("Unverified portrait accepted") }
            catch is WorkArtworkError { }
        }
    }

    func testArtistHeaderWithoutPortraitIsKnownEmptyDespiteAlbumAndSocialImage() async throws {
        let h = ArtworkHarness([
            .init(host: "www.wikidata.org", data: try appleEntity()),
            .init(host: "music.apple.com", data: try applePage(hasPortrait: false))
        ]); defer { h.close() }
        let response = try await h.service.fetch(qid: "Q100")
        XCTAssertNil(response.artwork)
    }

    func testAppleNamedAsQualifierIsPermittedButTemporalQualifierCannotEstablishIdentity() async throws {
        for qualifier in ["P1810", "P580"] {
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: appleEntity()) as? [String: Any])
            var entities = try XCTUnwrap(root["entities"] as? [String: [String: Any]])
            var item = try XCTUnwrap(entities["Q100"])
            var claims = try XCTUnwrap(item["claims"] as? [String: [[String: Any]]])
            var values = try XCTUnwrap(claims["P2850"])
            values[0]["qualifiers"] = [qualifier: [["property": qualifier, "snaktype": "value", "datatype": "string", "datavalue": ["value": "牛尾憲輔"]]]]
            claims["P2850"] = values; item["claims"] = claims; entities["Q100"] = item; root["entities"] = entities
            var plans = [ArtworkPlan(host: "www.wikidata.org", data: try json(root))]
            if qualifier == "P1810" { plans.append(.init(host: "music.apple.com", data: try applePage())) }
            let h = ArtworkHarness(plans); defer { h.close() }
            let response = try await h.service.fetch(qid: "Q100")
            XCTAssertEqual(response.artwork != nil, qualifier == "P1810")
        }
    }

    func testUnverifiedAppleExternalIdentifierDoesNotReachApple() async throws {
        for id in ["01", "939561587/../123", "https://example.com"] {
            let h = ArtworkHarness([.init(host: "www.wikidata.org", data: try appleEntity(id: id))]); defer { h.close() }
            let response = try await h.service.fetch(qid: "Q100")
            XCTAssertNil(response.artwork)
            XCTAssertEqual(h.requests.count, 1)
        }
    }

    private func appleEntity(id: String = "939561587") throws -> Data {
        let claim: [String: Any] = ["rank": "normal", "mainsnak": ["property": "P2850", "snaktype": "value", "datatype": "external-id", "datavalue": ["value": id]]]
        return try json(["success": 1, "entities": ["Q100": ["id": "Q100", "type": "item", "sitelinks": [:], "claims": ["P2850": [claim]]]]])
    }
    private func applePage(id: String = "939561587", imageHost: String = "is1-ssl.mzstatic.com", hasPortrait: Bool = true) throws -> Data {
        var item: [String: Any] = ["id": id, "contentDescriptor": ["kind": "artist", "identifiers": ["storeAdamID": id], "url": "https://music.apple.com/jp/artist/" + id]]
        if hasPortrait { item["circleArtwork"] = ["dictionary": ["url": "https://" + imageHost + "/image/thumb/Music/portrait.jpg/{w}x{h}{c}.{f}", "width": 1200, "height": 1200]] }
        let payload = try json(["data": [["itemKind": "album", "artwork": "https://example.com/wrong.jpg"], ["itemKind": "artistDetailHeader", "items": [item]]]])
        return Data(("<html><meta property='og:image' content='https://example.com/social.jpg'><script type='application/json' id='serialized-server-data'>" + String(decoding: payload, as: UTF8.self) + "</script></html>").utf8)
    }

    private func commonsEntity(changes: [String: Any] = [:]) throws -> Data {
        var snak: [String: Any] = ["property": "P18", "snaktype": "value", "datatype": "commonsMedia", "datavalue": ["value": "Poster.jpg"]]
        for key in ["datatype", "snaktype"] { if let value = changes[key] { snak[key] = value } }
        var claim: [String: Any] = ["rank": changes["rank"] ?? "normal", "mainsnak": snak]
        if let qualifiers = changes["qualifiers"] { claim["qualifiers"] = qualifiers }
        return try json(["success": 1, "entities": ["Q100": ["id": "Q100", "type": "item", "sitelinks": [:], "claims": ["P18": [claim]]]]])
    }

    func testTelevisionSeriesUsesTheSameExactIdentityChain() async throws {
        var values = try plans()
        values[0] = .init(host: "www.wikidata.org", data: try entity(type: "Q5398426"))
        let h = ArtworkHarness(values); defer { h.close() }
        let response = try await h.service.fetch(qid: "Q100")
        XCTAssertNotNil(response.artwork)
    }

    func testInvalidUploadAndDescriptionHostsAreRejected() async throws {
        let cases: [(Data, Data)] = [
            (try article(thumbnailURL: "https://example.com/wikipedia/a/ab/Poster.jpg"), try file()),
            (try article(), try file(original: "https://upload.wikimedia.org.evil.example/wikipedia/a/ab/Poster.jpg")),
            (try article(), try file(description: "https://example.com/wiki/File:Poster.jpg")),
            (try article(), try file(description: "https://zh.wikipedia.org/wiki/File:Another.jpg"))
        ]
        for (page, image) in cases {
            let h = ArtworkHarness([.init(host: "www.wikidata.org", data: try entity()), .init(host: "zh.wikipedia.org", data: page), .init(host: "zh.wikipedia.org", data: image)]); defer { h.close() }
            do { _ = try await h.service.fetch(qid: "Q100"); XCTFail("Untrusted image or source URL accepted") }
            catch WorkArtworkError.invalidResponse { }
        }
    }

    func testCurrentWikimediaThumbnailHostWorksButLookalikeDomainIsRejected() async throws {
        for accepted in [true, false] {
            let host = accepted ? "thumb.wikimedia.org" : "thumb.wikimedia.org.evil.example"
            let thumbnail = "https://" + host + "/wikipedia/zh/thumb/a/ab/Poster.jpg/330px-Poster.jpg"
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: file()) as? [String: Any])
            var query = try XCTUnwrap(root["query"] as? [String: Any])
            var pages = try XCTUnwrap(query["pages"] as? [[String: Any]])
            var infos = try XCTUnwrap(pages[0]["imageinfo"] as? [[String: Any]])
            infos[0]["width"] = 530; infos[0]["height"] = 752
            infos[0]["thumburl"] = thumbnail; infos[0]["thumbwidth"] = 265; infos[0]["thumbheight"] = 376
            pages[0]["imageinfo"] = infos; query["pages"] = pages; root["query"] = query
            let h = ArtworkHarness([
                .init(host: "www.wikidata.org", data: try entity()),
                .init(host: "zh.wikipedia.org", data: try article(thumbnailURL: thumbnail)),
                .init(host: "zh.wikipedia.org", data: try json(root))
            ]); defer { h.close() }
            do {
                let response = try await h.service.fetch(qid: "Q100")
                XCTAssertTrue(accepted)
                XCTAssertEqual(response.artwork?.thumbnailURL, thumbnail)
            } catch WorkArtworkError.invalidResponse { XCTAssertFalse(accepted) }
        }
    }

    func testImageinfoUnscaledFallbackUsesOriginalDimensions() async throws {
        let h = ArtworkHarness([
            .init(host: "www.wikidata.org", data: try entity()),
            .init(host: "zh.wikipedia.org", data: try article(includeThumbnail: false)),
            .init(host: "zh.wikipedia.org", data: try file())
        ]); defer { h.close() }
        let response = try await h.service.fetch(qid: "Q100")
        XCTAssertEqual(response.artwork?.width, 265)
        XCTAssertEqual(response.artwork?.height, 376)
    }

    func testOnlyConfirmedNoImageReturnsNilAndNetworkFailuresThrow() async throws {
        let empty = ArtworkHarness([
            .init(host: "www.wikidata.org", data: try entity(en: "English Film")),
            .init(host: "zh.wikipedia.org", data: try article(hasImage: false)),
            .init(host: "en.wikipedia.org", data: try article(title: "English Film", hasImage: false))
        ]); defer { empty.close() }
        let noImage = try await empty.service.fetch(qid: "Q100")
        XCTAssertNil(noImage.artwork)
        let offline = ArtworkHarness([.init(host: "www.wikidata.org", data: Data(), failure: .notConnectedToInternet)]); defer { offline.close() }
        do { _ = try await offline.service.fetch(qid: "Q100"); XCTFail("Network error became nil artwork") }
        catch { XCTAssertEqual(offline.requests.count, 1) }
        let throttled = ArtworkHarness([.init(host: "www.wikidata.org", data: Data(), status: 429)]); defer { throttled.close() }
        do { _ = try await throttled.service.fetch(qid: "Q100"); XCTFail("HTTP 429 became nil artwork") }
        catch { XCTAssertEqual(throttled.requests.count, 1, "Honor source cooldown without retrying immediately") }
    }

    func testInvalidQIDDoesNotReachTransport() async throws {
        let h = ArtworkHarness([]); defer { h.close() }
        for qid in ["Q01", "Q100|Q200", "Q0", "q100"] {
            do { _ = try await h.service.fetch(qid: qid); XCTFail("Accepted invalid QID") }
            catch WorkArtworkError.invalidIdentity { }
        }
        XCTAssertTrue(h.requests.isEmpty)
    }

    private var upload: String { "https://upload.wikimedia.org/wikipedia/zh/a/ab/Poster.jpg" }
    private func realDriveMyCar(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "artwork-drive-my-car-" + name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
    private func plans(metadata: [String: String]? = nil) throws -> [ArtworkPlan] {
        [.init(host: "www.wikidata.org", data: try entity()), .init(host: "zh.wikipedia.org", data: try article()), .init(host: "zh.wikipedia.org", data: try file(metadata: metadata))]
    }
    private func entity(zh: String = "Exact Film", en: String? = nil, type: String = "Q11424") throws -> Data {
        var links = ["zhwiki": ["site": "zhwiki", "title": zh]]
        if let en { links["enwiki"] = ["site": "enwiki", "title": en] }
        let claim: [String: Any] = ["rank": "normal", "mainsnak": ["property": "P31", "snaktype": "value", "datatype": "wikibase-item", "datavalue": ["value": ["id": type]]]]
        return try json(["success": 1, "entities": ["Q100": ["id": "Q100", "type": "item", "sitelinks": links, "claims": ["P31": [claim]]]]])
    }
    private func article(title: String = "Exact Film", qid: String = "Q100", namespace: Int = 0, disambiguation: Bool = false,
                         hasImage: Bool = true, includeThumbnail: Bool = true, thumbnailURL: String? = nil, redirects: [[String: String]] = []) throws -> Data {
        var props = ["wikibase_item": qid]
        if disambiguation { props["disambiguation"] = "" }
        var page: [String: Any] = ["title": title, "pageid": 10, "ns": namespace, "pageprops": props]
        if hasImage {
            page["pageimage"] = "Poster.jpg"
            if includeThumbnail { page["thumbnail"] = ["source": thumbnailURL ?? upload, "width": 265, "height": 376] }
        }
        return try json(["query": ["pages": [page], "redirects": redirects]])
    }
    private func file(language: String = "zh", metadata: [String: String]? = nil, includeInfo: Bool = true,
                      description: String? = "default", original: String? = nil) throws -> Data {
        var page: [String: Any] = ["title": "File:Poster.jpg", "ns": 6, "pageid": 20, "imagerepository": "local"]
        if includeInfo {
            let values = metadata ?? ["Artist": "<b>A Studio</b>", "Credit": "<p>A source</p>", "LicenseShortName": "Fair use", "NonFree": "true"]
            var info: [String: Any] = ["url": original ?? upload, "width": 265, "height": 376, "mime": "image/jpeg", "thumburl": upload + "?utm_content=thumbnail_unscaled", "thumbwidth": 320, "thumbheight": 454, "extmetadata": values.mapValues { ["value": $0] }]
            if let description { info["descriptionurl"] = description == "default" ? "https://\(language).wikipedia.org/wiki/File:Poster.jpg" : description }
            page["imageinfo"] = [info]
        }
        return try json(["query": ["pages": [page]]])
    }
    private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
}

private struct ArtworkPlan: Sendable {
    let host: String
    let data: Data
    var status = 200
    var failure: URLError.Code? = nil
}
private final class ArtworkHarness: @unchecked Sendable {
    let service: WorkArtworkService
    private let token = UUID().uuidString
    private let state: ArtworkState
    private let session: URLSession
    init(_ plans: [ArtworkPlan]) {
        state = ArtworkState(plans); ArtworkRegistry.shared.put(token, state)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArtworkProtocol.self]
        config.httpAdditionalHeaders = ["X-Artwork-Test": token]
        config.urlCache = nil; config.urlCredentialStorage = nil
        session = URLSession(configuration: config)
        service = WorkArtworkService(session: session)
    }
    var requests: [URLRequest] { state.requests }
    func parameters(_ request: URLRequest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []).map { ($0.name, $0.value ?? "") })
    }
    func close(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(state.remaining, 0, file: file, line: line)
        session.invalidateAndCancel(); ArtworkRegistry.shared.remove(token)
    }
}
private final class ArtworkState: @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [ArtworkPlan]
    private var observed: [URLRequest] = []
    init(_ plans: [ArtworkPlan]) { self.plans = plans }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return observed }
    var remaining: Int { lock.lock(); defer { lock.unlock() }; return plans.count }
    func next(_ request: URLRequest) -> ArtworkPlan? {
        lock.lock(); defer { lock.unlock() }; observed.append(request)
        guard let first = plans.first, first.host == request.url?.host else { return nil }
        return plans.removeFirst()
    }
}
private final class ArtworkRegistry: @unchecked Sendable {
    static let shared = ArtworkRegistry()
    private let lock = NSLock()
    private var states: [String: ArtworkState] = [:]
    func put(_ key: String, _ value: ArtworkState) { lock.lock(); defer { lock.unlock() }; states[key] = value }
    func get(_ key: String?) -> ArtworkState? { lock.lock(); defer { lock.unlock() }; return key.flatMap { states[$0] } }
    func remove(_ key: String) { lock.lock(); defer { lock.unlock() }; states.removeValue(forKey: key) }
}
private final class ArtworkProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let state = ArtworkRegistry.shared.get(request.value(forHTTPHeaderField: "X-Artwork-Test")),
              let plan = state.next(request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        if let code = plan.failure { client?.urlProtocol(self, didFailWithError: URLError(code)); return }
        let response = HTTPURLResponse(url: url, statusCode: plan.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: plan.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
