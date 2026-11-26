import AVFoundation
import Foundation
import Testing
@testable import FileQueueCore

/// Builds small but structurally real video container files.
enum TestContainers {
    static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    static func le64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    static func chunk(_ id: String, _ body: Data) -> Data {
        var d = Data(id.utf8) + le32(UInt32(body.count)) + body
        if body.count % 2 == 1 { d.append(0) }
        return d
    }
    static func list(_ type: String, _ chunks: [Data]) -> Data { chunk("LIST", Data(type.utf8) + chunks.reduce(Data(), +)) }

    /// An AVI with hdrl (1280x720, 30 fps, 129586 frames, XVID), a movi block, and INFO **after** the video data.
    static func avi(title: String?, truncateAt: Int? = nil) -> Data {
        var avih = Data(count: 56)
        avih.replaceSubrange(0..<4, with: le32(33_333))      // µs per frame → 30 fps
        avih.replaceSubrange(16..<20, with: le32(129_586))   // total frames
        avih.replaceSubrange(32..<36, with: le32(1280))
        avih.replaceSubrange(36..<40, with: le32(720))
        var strh = Data("vids".utf8) + Data("XVID".utf8)
        strh.append(Data(count: 48))
        let hdrl = list("hdrl", [chunk("avih", avih), list("strl", [chunk("strh", strh)])])
        let movi = list("movi", [chunk("00dc", Data(repeating: 7, count: 5000))])
        var body = Data("AVI ".utf8) + hdrl + movi + chunk("idx1", Data(count: 16))
        if let title {
            body += list("INFO", [chunk("INAM", Data((title + "\0").utf8)), chunk("ICMT", Data("comment\0".utf8))])
        }
        var file = Data("RIFF".utf8) + le32(UInt32(body.count)) + body
        if let truncateAt { file = file.prefix(truncateAt) }
        return file
    }

    // EBML element: ID bytes + size (8-byte vint) + payload.
    static func ebml(_ id: [UInt8], _ payload: Data) -> Data {
        var size = Data([0x01]) + Data(count: 7)
        let n = UInt64(payload.count)
        for k in 0..<7 { size[7 - k] = UInt8((n >> (8 * UInt64(k))) & 0xFF) }
        return Data(id) + size + payload
    }
    static func uint(_ v: UInt64, bytes: Int = 4) -> Data { Data((0..<bytes).reversed().map { UInt8((v >> (8 * UInt64($0))) & 0xFF) }) }

    /// A Matroska file: Info (title, 1 ms scale, 5400 s duration, date) and a 1920x1080 H.264 track.
    /// The Segment has "unknown size", as live-written and recovered files often do.
    static func mkv(title: String) -> Data {
        let header = ebml([0x1A, 0x45, 0xDF, 0xA3], ebml([0x42, 0x82], Data("matroska".utf8)))
        var durationBits = Data(count: 8)
        let bits = Double(5_400_000).bitPattern
        for k in 0..<8 { durationBits[7 - k] = UInt8((bits >> (8 * UInt64(k))) & 0xFF) }
        let info = ebml([0x15, 0x49, 0xA9, 0x66],
                        ebml([0x2A, 0xD7, 0xB1], uint(1_000_000)) + ebml([0x44, 0x89], durationBits)
                        + ebml([0x7B, 0xA9], Data(title.utf8))
                        + ebml([0x44, 0x61], uint(UInt64(463_000_000) * 1_000_000_000, bytes: 8)))
        let video = ebml([0xE0], ebml([0xB0], uint(1920, bytes: 2)) + ebml([0xBA], uint(1080, bytes: 2)))
        let track = ebml([0xAE], ebml([0x86], Data("V_MPEG4/ISO/AVC".utf8)) + video)
        let tracks = ebml([0x16, 0x54, 0xAE, 0x6B], track)
        let segmentUnknownSize = Data([0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        return header + segmentUnknownSize + info + tracks + ebml([0x1F, 0x43, 0xB6, 0x75], Data(count: 100))
    }

    /// A Windows Media file with a Content Description (title) and File Properties (duration 95 s).
    static func asf(title: String) -> Data {
        func object(_ guid: String, _ body: Data) -> Data { ContainerReaders.guid(guid) + le64(UInt64(24 + body.count)) + body }
        let titleBytes = Data(title.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }) + Data([0, 0])
        let description = le16(UInt16(titleBytes.count)) + le16(0) + le16(0) + le16(0) + le16(0) + titleBytes
        var props = Data(count: 80)
        props.replaceSubrange(40..<48, with: le64(950_000_000 + 30_000_000)) // play duration (100 ns) incl. 3000 ms preroll
        props.replaceSubrange(56..<64, with: le64(3000))
        let objects = object("8CABDCA1-A947-11CF-8EE4-00C00C205365", props)
            + object("75B22633-668E-11CF-A6D9-00AA0062CE6C", description)
        let headerBody = le32(2) + Data([1, 2]) + objects
        return ContainerReaders.guid("75B22630-668E-11CF-A6D9-00AA0062CE6C") + le64(UInt64(24 + headerBody.count)) + headerBody
    }
}

@Suite("Titles inside video files", .serialized)
struct VideoTitleTests {
    @Test("AVI: title at the end of the file, size, fps, duration, codec")
    func avi() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        let url = s.path("file000196.avi")
        try TestContainers.avi(title: "The.Intern.2015.720p.WEBRip.XviD.MP3-FGT").write(to: url)
        let m = await MetadataReader.read(url)
        #expect(m.kind == .video)
        #expect(m.title == "The.Intern.2015.720p.WEBRip.XviD.MP3-FGT")
        #expect(m.width == 1280 && m.height == 720)
        #expect(m.fps.map { abs($0 - 30) < 0.01 } == true)
        #expect(m.duration.map { abs($0 / 60 - 72) < 0.5 } == true)
        #expect(m.codec == "Xvid")
        // Every INFO tag is reached, not just the first: a date tag after the title is read too.
        var withDate = TestContainers.avi(title: nil)
        let info = TestContainers.list("INFO", [TestContainers.chunk("INAM", Data("A\0".utf8)), TestContainers.chunk("ICRD", Data("2015-05-28\0".utf8))])
        withDate.append(info)
        withDate.replaceSubrange(4..<8, with: TestContainers.le32(UInt32(withDate.count - 8)))
        try withDate.write(to: s.path("dated.avi"))
        let dated = await MetadataReader.read(s.path("dated.avi"))
        #expect(dated.title == "A")
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        #expect(dated.taken.map(f.string) == "2015-05-28")
    }

    @Test("AVI cut short (as recovered files often are): header details still read, no crash")
    func aviTruncated() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        let url = s.path("cut.avi")
        try TestContainers.avi(title: "Lost", truncateAt: 2000).write(to: url)
        let m = await MetadataReader.read(url)
        #expect(m.width == 1280)
        #expect(m.title == nil) // the tags were in the missing part
        try Data("RIFF garbage".utf8).write(to: s.path("bad.avi"))
        #expect(await MetadataReader.read(s.path("bad.avi")).title == nil)
    }

    @Test("MKV: title, date, duration, size, codec — with an unknown-size segment")
    func mkv() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        let url = s.path("file000196.mkv")
        try TestContainers.mkv(title: "[YTS.AG] Arrival.2016.1080p.BluRay.x264").write(to: url)
        let m = await MetadataReader.read(url)
        #expect(m.kind == .video)
        #expect(m.title == "[YTS.AG] Arrival.2016.1080p.BluRay.x264")
        #expect(m.width == 1920 && m.height == 1080)
        #expect(m.codec == "H.264")
        #expect(m.duration.map { abs($0 - 5400) < 1 } == true)
        #expect(m.taken == Date(timeIntervalSinceReferenceDate: 463_000_000))
    }

    @Test("WMV: title and duration")
    func wmv() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        let url = s.path("clip.wmv")
        try TestContainers.asf(title: "Family Holiday 2009").write(to: url)
        let m = await MetadataReader.read(url)
        #expect(m.kind == .video)
        #expect(m.title == "Family Holiday 2009")
        #expect(m.duration.map { abs($0 - 95) < 0.5 } == true)
    }

    @Test("MP4/MOV: title through macOS's own reader")
    func mp4() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        let src = s.path("in.mov")
        try await TestMedia.movie(at: src, created: Date(timeIntervalSince1970: 1_465_000_000))
        // Re-export with a title tag.
        let asset = AVURLAsset(url: src)
        let export = try #require(AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough))
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = "Edge.of.Tomorrow.2014.1080p.WEBRip" as NSString
        export.metadata = [title]
        let out = s.path("titled.mp4")
        try await export.export(to: out, as: .mp4)
        #expect(await MetadataReader.read(out).title == "Edge.of.Tomorrow.2014.1080p.WEBRip")
    }

    @Test("Formats macOS doesn't know still count as videos")
    func kinds() {
        for ext in ["mkv", "avi", "wmv", "webm", "m2ts", "divx", "flv", "vob"] {
            #expect(MetadataReader.kind(of: URL(fileURLWithPath: "/x/a.\(ext)")) == .video, "\(ext)")
        }
    }

    @Test("Release-style titles become readable names", arguments: [
        ("RARBG.COM - Edge.of.Tomorrow.2014.1080p.WEBRip.HC.XviD.MP3-RARBG", "Edge of Tomorrow (2014)"),
        ("The.Intern.2015.720p.WEBRip.XviD.MP3-FGT", "The Intern (2015)"),
        ("[YTS.AG] Arrival.2016.1080p.BluRay.x264", "Arrival (2016)"),
        ("2001.A.Space.Odyssey.1968.1080p.BluRay", "2001 A Space Odyssey (1968)"),
        ("Breaking.Bad.S01E02.720p.HDTV.x264-CTU", "Breaking Bad S01E02"),
        ("www.Torrenting.com - Inception 2010 BRRip", "Inception (2010)"),
        ("Some_Movie_Name_DVDRip_XviD", "Some Movie Name"),
        ("Family Holiday 2009", "Family Holiday (2009)"),
        ("Birthday Party", "Birthday Party"),
        ("IMG_1234", "IMG_1234"),
    ])
    func cleanTitles(raw: String, expected: String) {
        #expect(ReleaseTitle.clean(raw) == expected)
    }

    @Test("Not really titles: blank, site names only, timestamps")
    func junkTitles() async throws {
        #expect(ReleaseTitle.cleanOrNil("JAVSHARING.COM") == nil)
        #expect(ReleaseTitle.cleanOrNil("   ") == nil)
        #expect(ReleaseTitle.cleanOrNil("[YTS.AG]") == nil)
        #expect(ReleaseTitle.cleanOrNil("> VISIT - MICROMKV.COM <") == nil)
        #expect(ReleaseTitle.cleanOrNil("Downloaded from www.example.com") == nil)
        #expect(ReleaseTitle.cleanOrNil("Jupiter.Ascending.2015.720p.BluRay.x264-MICROMKV.COM") == "Jupiter Ascending (2015)")
        let ctx = NameTemplate.Context(metadata: { var m = FileMetadata(); m.title = "EXAMPLE.COM"; return m }(), name: "f", ext: "wmv")
        #expect(NameTemplate.render("{title:clean}", ctx).missing == ["Title"])
        #expect(NameTemplate.render("{title}", ctx).text == "EXAMPLE.COM") // "as is" really is as is

        // A timestamp written as the title becomes the date taken.
        let s = try Sandbox(); defer { s.cleanup() }
        try TestContainers.mkv(title: "2012-11-21T19:32:44").write(to: s.path("phone.mkv"))
        let m = await MetadataReader.read(s.path("phone.mkv"))
        #expect(m.title == nil)
        try TestContainers.asf(title: "                              ").write(to: s.path("blank.wmv"))
        #expect(await MetadataReader.read(s.path("blank.wmv")).title == nil)
    }

    @Test("Title fields in names and suggestions")
    func fieldsAndSuggestions() {
        var m = FileMetadata(); m.kind = .video
        m.title = "RARBG.COM - Edge.of.Tomorrow.2014.1080p.WEBRip.HC.XviD.MP3-RARBG"
        let ctx = NameTemplate.Context(metadata: m, name: "file000196", ext: "avi")
        #expect(NameTemplate.render("{title:clean}", ctx).text == "Edge of Tomorrow (2014)")
        #expect(NameTemplate.render("{title}", ctx).text == "RARBG.COM - Edge.of.Tomorrow.2014.1080p.WEBRip.HC.XviD.MP3-RARBG")
        #expect(NameTemplate.render("{title}", .init(metadata: FileMetadata(), name: "x", ext: "avi")).missing == ["Title"])
        #expect(NameTemplate.needsDetails("{title:clean}"))

        // Even a few titled videos get the title suggestion (others keep their names).
        let few = [m] + Array(repeating: { var v = FileMetadata(); v.kind = .video; return v }(), count: 99)
        #expect(MetadataSuggestions.renameSuggestions(few).first?.template == "{title:clean}")
        // A quarter of the videos have titles: the title suggestion comes first.
        let none = FileMetadata()
        var noneVideo = none; noneVideo.kind = .video
        let metas = [m] + Array(repeating: noneVideo, count: 3)
        #expect(MetadataSuggestions.renameSuggestions(metas).first?.template == "{title:clean}")
        #expect(MetadataSuggestions.coverage(metas).contains { $0.label == "Title" && $0.example == "Edge of Tomorrow (2014)" })
    }
}

@Suite("Organize: title as the file name", .serialized)
struct OrganizeTitleNameTests {
    func meta(_ title: String?) -> FileMetadata {
        var m = FileMetadata(); m.kind = .video; m.title = title; return m
    }

    @Test("Titled files are renamed (extension kept); others keep their names; same titles numbered")
    func plan() {
        let root = URL(fileURLWithPath: "/rec")
        let files = ["/rec/avi/file000070.avi", "/rec/avi/file000196.avi", "/rec/avi/file000001.avi", "/rec/mkv/file000186.mkv",
                     "/rec/mkv/file000187.mkv"].map(url)
        let md = [files[0]: meta("RARBG.COM - Edge.of.Tomorrow.2014.1080p.WEBRip.HC.XviD.MP3-RARBG"),
                  files[1]: meta("The.Intern.2015.720p.WEBRip.XviD.MP3-FGT"),
                  files[2]: meta(nil),
                  files[3]: meta("Hot Shots Part Deux 1993 1080p BluRay X264-AMIABLE (1)"),
                  files[4]: meta("Hot.Shots.Part.Deux.1993.720p")]
        let plan = OrganizePlanner.plan(files: files, root: root,
                                        options: .init(template: "{type}", nameTemplate: "{title:clean}"), metadata: md, lister: { _ in [] })
        #expect(plan.items.map { OrganizePlanner.relativePath($0.destination, root) } == [
            "Videos/Edge of Tomorrow (2014).avi",
            "Videos/The Intern (2015).avi",
            "Videos/file000001.avi",                  // no title: keeps its name
            "Videos/Hot Shots Part Deux (1993).mkv",
            "Videos/Hot Shots Part Deux (1993) 2.mkv", // same title: numbered
        ])
        #expect(NameTemplate.needsDetails("{title:clean}"))
    }

    @Test("Renaming in place: the file stays in its folder with its new name")
    func renameInPlace() {
        let root = URL(fileURLWithPath: "/rec/avi")
        let f = url("/rec/avi/file000196.avi")
        let plan = OrganizePlanner.plan(files: [f], root: root, options: .init(template: ".", nameTemplate: "{title:clean}"),
                                        metadata: [f: meta("The.Intern.2015.720p.WEBRip.XviD.MP3-FGT")], lister: { _ in ["file000196.avi"] })
        #expect(plan.items[0].destination.path == "/rec/avi/The Intern (2015).avi")
        #expect(plan.items[0].status == .ok)
        // Without a name template nothing changes.
        let keep = OrganizePlanner.plan(files: [f], root: root, options: .init(template: "."), metadata: [:], lister: { _ in ["file000196.avi"] })
        #expect(keep.items[0].status == .unchanged)
    }

    @Test("End to end with real AVI files")
    func endToEnd() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.dir("rec")
        try TestContainers.avi(title: "The.Intern.2015.720p.WEBRip.XviD.MP3-FGT").write(to: s.path("rec/file000196.avi"))
        try TestContainers.avi(title: nil).write(to: s.path("rec/file000001.avi"))
        let root = s.path("rec")
        let files = FileExpander.expand([root], recursive: true)
        let md = await MetadataReader.readAll(files)
        let plan = OrganizePlanner.plan(files: files, root: root, options: .init(template: ".", nameTemplate: "{title:clean}"), metadata: md)
        let engine = await s.engine()
        let id = try await engine.enqueue(.organize(items: plan.items, move: true, cleanUpIn: root))
        await engine.waitUntilIdle()
        #expect(try #require(await engine.job(id)).state == .completed)
        #expect(s.names("rec") == ["The Intern (2015).avi", "file000001.avi"])
        try await engine.undo(id)
        await engine.waitUntilIdle()
        #expect(s.names("rec") == ["file000001.avi", "file000196.avi"])
    }
}
