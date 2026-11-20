import Foundation
@testable import Pianwai

/// Transcodes historical iTunes recordings only for regression coverage.
/// These are deliberately not described as recorded MusicKit responses.
enum MusicKitTestFixture {
    static func transcode(_ data: Data, url: URL? = nil) -> Data {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["results"] as? [[String: Any]] else { return data }
        var songs: [[String: Any]] = [], albums: [String: [String: Any]] = [:], artists: [String: [String: Any]] = [:]
        var songAlbum: [String: String] = [:], songArtist: [String: String] = [:], albumArtist: [String: String] = [:]
        for row in rows {
            func string(_ key: String) -> String? { row[key].map { String(describing: $0) } }
            if let id = string("artistId"), let name = string("artistName"), artists[id] == nil || string("wrapperType") == "artist" {
                artists[id] = ["id":id, "type":"artists", "attributes":["name":name]]
            }
            if let id = string("collectionId"), let name = string("collectionName"), albums[id] == nil || string("wrapperType") == "collection" {
                var attrs: [String: Any] = ["name":name]
                if string("wrapperType") == "collection" { attrs["artistName"] = row["artistName"]; albumArtist[id] = string("artistId") }
                albums[id] = ["id":id, "type":"albums", "attributes":attrs]
            }
            guard let id = string("trackId"), let name = string("trackName") else { continue }
            var attributes: [String: Any] = ["name": name]
            for (old, new) in [("artistName","artistName"), ("releaseDate","releaseDate"), ("trackViewUrl","url"), ("trackTimeMillis","durationInMillis")] { attributes[new] = row[old] }
            if let art = row["artworkUrl100"] { attributes["artwork"] = ["url": art] }
            songs.append(["id":id, "type":"songs", "attributes":attributes])
            songAlbum[id] = string("collectionId"); songArtist[id] = string("artistId")
        }
        songs = songs.map { song in
            var song = song, relationships: [String: Any] = [:]
            let id = song["id"] as! String
            if let artist = songArtist[id].flatMap({ artists[$0] }) { relationships["artists"] = ["data":[artist]] }
            if let album = songAlbum[id].flatMap({ albums[$0] }) { relationships["albums"] = ["data":[album]] }
            song["relationships"] = relationships; return song
        }
        for id in Array(albums.keys) {
            var relationships: [String: Any] = ["tracks":["data":songs.filter { songAlbum[$0["id"] as! String] == id }]]
            if let artist = albumArtist[id].flatMap({ artists[$0] }) { relationships["artists"] = ["data":[artist]] }
            albums[id]?["relationships"] = relationships
        }
        for id in Array(artists.keys) {
            artists[id]?["relationships"] = ["albums":["data":albums.keys.sorted().filter { albumArtist[$0] == id }.compactMap { albums[$0] }]]
        }
        let groups: [String: [[String: Any]]] = ["songs":songs, "albums":albums.keys.sorted().compactMap { albums[$0] }, "artists":artists.keys.sorted().compactMap { artists[$0] }]
        let path = url?.pathComponents ?? []
        if path.count >= 5, let resources = groups[path[4]] {
            let selected = path.count > 5 ? resources.filter { ($0["id"] as? String) == path[5] } : resources
            return (try? JSONSerialization.data(withJSONObject: ["data":selected])) ?? data
        }
        return (try? JSONSerialization.data(withJSONObject: ["results":groups.mapValues { ["data":$0] }])) ?? data
    }
}
