import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FileQueueCore

// MARK: - Test media

enum TestMedia {
    /// Writes a small JPEG with EXIF date, camera and lens.
    static func jpeg(at url: URL, taken: String?, make: String? = "Canon", model: String? = "Canon EOS 100D",
                     lens: String? = "EF-S18-55mm", width: Int = 64, height: Int = 48) throws {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = ctx.makeImage()!
        var exif: [CFString: Any] = [kCGImagePropertyExifISOSpeedRatings: [200], kCGImagePropertyExifFNumber: 2.8,
                                     kCGImagePropertyExifFocalLength: 24.0]
        if let taken { exif[kCGImagePropertyExifDateTimeOriginal] = taken }
        if let lens { exif[kCGImagePropertyExifLensModel] = lens }
        var tiff: [CFString: Any] = [:]
        if let make { tiff[kCGImagePropertyTIFFMake] = make }
        if let model { tiff[kCGImagePropertyTIFFModel] = model }
        let props: [CFString: Any] = [kCGImagePropertyExifDictionary: exif, kCGImagePropertyTIFFDictionary: tiff]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Writes a short H.264 .mov (64x48, 10 frames at 25 fps) with a creation date and camera model.
    static func movie(at url: URL, created: Date, model: String = "HERO4") async throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let creation = AVMutableMetadataItem()
        creation.identifier = .quickTimeMetadataCreationDate
        creation.value = ISO8601DateFormatter().string(from: created) as NSString
        let modelItem = AVMutableMetadataItem()
        modelItem.identifier = .quickTimeMetadataModel
        modelItem.value = model as NSString
        writer.metadata = [creation, modelItem]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer)
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 25))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}

// MARK: - Reading

@Suite("Reading photo and video details", .serialized)
struct MetadataReaderTests {
    @Test("JPEG: date taken, camera, lens, size, ISO, aperture, focal length")
    func photo() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        let url = s.path("IMG_0001.jpg")
        try TestMedia.jpeg(at: url, taken: "2016:05:28 16:08:43")
        let m = await MetadataReader.read(url)
        #expect(m.kind == .image)
        #expect(m.camera == "Canon EOS 100D") // not "Canon Canon EOS 100D"
        #expect(m.lens == "EF-S18-55mm")
        #expect(m.width == 64 && m.height == 48)
        #expect(m.iso == 200)
        #expect(m.fNumber == 2.8)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        #expect(m.taken.map(f.string) == "2016-05-28 16:08:43")
    }

    @Test("Video: creation date, camera, size, duration, frame rate, codec")
    func video() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        let url = s.path("GOPR0001.mov")
        let created = Date(timeIntervalSince1970: 1_465_000_000)
        try await TestMedia.movie(at: url, created: created)
        let m = await MetadataReader.read(url)
        #expect(m.kind == .video)
        #expect(m.taken.map { abs($0.timeIntervalSince(created)) < 1 } == true)
        #expect(m.model == "HERO4")
        #expect(m.width == 64 && m.height == 48)
        #expect(m.codec == "H.264")
        #expect(m.fps.map { abs($0 - 25) < 0.5 } == true)
        #expect(m.duration.map { $0 > 0.3 && $0 < 0.5 } == true)
    }

    @Test("Many files are read concurrently")
    func readAll() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        let urls = try (1...20).map { i -> URL in
            let u = s.path("p\(i).jpg"); try TestMedia.jpeg(at: u, taken: "2020:01:0\(i % 9 + 1) 10:00:00"); return u
        }
        let done = Counter()
        let all = await MetadataReader.readAll(urls) { _ in done.increment() }
        #expect(all.count == 20)
        #expect(done.value == 20)
        #expect(all.values.allSatisfy { $0.taken != nil })
    }
}

// MARK: - Templates & suggestions

@Suite("Name templates and suggestions")
struct NameTemplateTests {
    func meta(taken: Date? = Date(timeIntervalSince1970: 1_464_426_523), camera: String? = "Canon EOS 100D",
              kind: FileMetadata.Kind = .image) -> FileMetadata {
        var m = FileMetadata()
        m.kind = kind; m.taken = taken; m.model = camera
        m.width = 4000; m.height = 3000; m.duration = kind == .video ? 65 : nil; m.fps = kind == .video ? 29.97 : nil
        return m
    }

    func render(_ t: String, _ m: FileMetadata?, name: String = "IMG_1", n: Int = 1) -> NameTemplate.Result {
        NameTemplate.render(t, .init(metadata: m, name: name, ext: "JPG", number: n))
    }

    @Test func fields() {
        let m = meta(kind: .video)
        #expect(render("{camera} {resolution} {fps}fps {duration}", m).text == "Canon EOS 100D 4000x3000 29.97fps 1m05s")
        #expect(render("{type}/{ext}", m).text == "Videos/jpg") // "/" typed in the template stays (Organize: subfolders)
        var slashy = m; slashy.model = "AF/S 18:55"
        #expect(render("{camera}", slashy).text == "AF-S 18-55") // but "/" and ":" inside a value are replaced
        #expect(render("{name} {n:3}", m, n: 7).text == "IMG_1 007")
        #expect(render("{prefix:3}", m).text == "IMG")
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        #expect(render("{taken}", m).text == f.string(from: m.taken!))
    }

    @Test func missingFields() {
        let r = render("{taken:yyyy} {camera}", meta(taken: nil, camera: nil))
        #expect(r.missing == ["Date taken", "Camera"])
        #expect(render("{date:yyyy}", { var m = meta(taken: nil); m.created = Date(timeIntervalSince1970: 0); return m }()).missing.isEmpty)
        #expect(render("{nonsense}", meta()).missing.count == 1)
    }

    @Test("Coverage counts how many files have each detail")
    func coverage() {
        let metas = [meta(), meta(), meta(camera: nil), meta(taken: nil)]
        let c = Dictionary(uniqueKeysWithValues: MetadataSuggestions.coverage(metas).map { ($0.label, $0) })
        #expect(c["Date taken"]?.count == 3)
        #expect(c["Camera"]?.count == 3)
        #expect(c["Camera"]?.example == "Canon EOS 100D")
        #expect(c["Resolution"]?.fraction == 1)
        #expect(c["Duration"] == nil)
    }

    @Test("Suggestions only offer names most files can use")
    func suggestions() {
        let photos = Array(repeating: meta(), count: 9) + [meta(taken: nil)]
        let rename = MetadataSuggestions.renameSuggestions(photos)
        #expect(rename.first?.template == "{taken:yyyy-MM-dd HH.mm.ss}")
        #expect(rename.first.map { abs($0.fraction - 0.9) < 0.001 } == true)
        #expect(!rename.contains { $0.template.contains("{fps}") }) // photos have no frame rate

        let videos = Array(repeating: meta(kind: .video), count: 4)
        #expect(MetadataSuggestions.renameSuggestions(videos).contains { $0.template.contains("{fps}") })

        let noDates = Array(repeating: meta(taken: nil, camera: nil), count: 5)
        #expect(!MetadataSuggestions.renameSuggestions(noDates).contains { $0.template.contains("taken") })
        #expect(MetadataSuggestions.organizeSuggestions(photos).first?.template == "{taken:yyyy}/{taken:MM}")
    }
}

// MARK: - Rename with metadata

@Suite("Batch rename with metadata", .serialized)
struct MetadataRenameTests {
    struct NoDisk: FileMetadataProviding {
        var existing: [String] = []
        func isPlainFolder(_ url: URL) -> Bool { false }
        func date(_ source: RenameRule.DateSource, of url: URL) -> Date? { nil }
        func existingNames(in directory: URL) -> [String] { existing }
        func isCaseSensitive(_ directory: URL) -> Bool { false }
    }

    func meta(_ seconds: TimeInterval?) -> FileMetadata {
        var m = FileMetadata(); m.kind = .image
        m.taken = seconds.map { Date(timeIntervalSince1970: $0) }; m.model = "Canon EOS 100D"
        return m
    }

    @Test("Names from metadata; files without the detail are left alone")
    func renameAndMissing() {
        let files = ["/d/IMG_1.JPG", "/d/IMG_2.JPG", "/d/IMG_3.JPG"].map(url)
        let md = [files[0]: meta(1_464_426_523), files[1]: meta(1_464_426_600), files[2]: meta(nil)]
        let plan = RenameEngine.makePlan(files: files, rules: [.metadata("{taken:yyyy-MM-dd} {camera}")],
                                         metadata: NoDisk(existing: files.map(\.lastPathComponent)), fileMetadata: md)
        #expect(plan[0].status == .collidesWithinBatch) // same day, same camera
        #expect(plan[2].status == .missingMetadata("Date taken"))
        #expect(!plan[2].status.isError)
    }

    @Test("Number duplicates: same-second photos get ' 2', ' 3'")
    func numberDuplicates() {
        let files = ["/d/a.JPG", "/d/b.JPG", "/d/c.JPG"].map(url)
        let md = Dictionary(uniqueKeysWithValues: files.map { ($0, meta(1_464_426_523)) })
        let plan = RenameEngine.makePlan(files: files, rules: [.metadata("{taken:yyyy-MM-dd} {camera}")],
                                         metadata: NoDisk(existing: ["a.JPG", "b.JPG", "c.JPG", "2016-05-28 Canon EOS 100D 2.JPG"]),
                                         fileMetadata: md, options: .init(numberDuplicates: true))
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let day = f.string(from: Date(timeIntervalSince1970: 1_464_426_523))
        // " 2" is already taken by an unrelated file in the folder, so it's skipped.
        #expect(plan.map(\.proposedName) == ["\(day) Canon EOS 100D.JPG", "\(day) Canon EOS 100D 3.JPG", "\(day) Canon EOS 100D 4.JPG"])
        #expect(plan.allSatisfy { $0.status == .ok })
    }

    @Test("Counters can restart in each folder")
    func perFolderCounter() {
        let files = ["/a/x.jpg", "/a/y.jpg", "/b/z.jpg"].map(url)
        var seq = RenameRule.sequence(start: 1, padding: 2, placement: .replace)
        seq.perFolder = true
        #expect(RenameEngine.makePlan(files: files, rules: [seq], metadata: NoDisk()).map(\.proposedName) == ["01.jpg", "02.jpg", "01.jpg"])
        seq.perFolder = false
        #expect(RenameEngine.makePlan(files: files, rules: [seq], metadata: NoDisk()).map(\.proposedName) == ["01.jpg", "02.jpg", "03.jpg"])
        // The same applies to {n} inside a Metadata rule.
        var meta = RenameRule.metadata("{name} {n:2}")
        #expect(RenameEngine.makePlan(files: files, rules: [meta], metadata: NoDisk()).map(\.proposedName) == ["x 01.jpg", "y 02.jpg", "z 03.jpg"])
        meta.perFolder = true
        #expect(RenameEngine.makePlan(files: files, rules: [meta], metadata: NoDisk()).map(\.proposedName) == ["x 01.jpg", "y 02.jpg", "z 01.jpg"])
    }

    @Test("Recursive: every file in a folder tree, hidden files and package insides left out")
    func expandRecursive() throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try s.file("trip/a.jpg"); try s.file("trip/day2/b.jpg"); try s.file("trip/day2/deep/c.jpg")
        try s.file("trip/.hidden"); try s.file("trip/Tool.app/Contents/x"); try s.file("single.txt")
        let all = FileExpander.expand([s.path("trip"), s.path("single.txt")], recursive: true).map { OrganizePlanner.relativePath($0, s.root) }
        #expect(all == ["trip/a.jpg", "trip/day2/b.jpg", "trip/day2/deep/c.jpg", "trip/Tool.app", "single.txt"])
        #expect(FileExpander.expand([s.path("trip")], recursive: false).count == 1)
    }

    @Test("Recursive metadata rename runs as one job across folders")
    func recursiveRenameJob() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try TestMedia.jpeg(at: s.path("trip/IMG_1.jpg"), taken: "2016:05:28 16:08:43")
        try TestMedia.jpeg(at: s.path("trip/day2/IMG_2.jpg"), taken: "2016:05:29 09:00:00")
        try TestMedia.jpeg(at: s.path("trip/day2/IMG_3.jpg"), taken: nil)
        let files = FileExpander.expand([s.path("trip")], recursive: true)
        let md = await MetadataReader.readAll(files)
        let plan = RenameEngine.makePlan(files: files, rules: [.metadata("{taken:yyyy-MM-dd HH.mm.ss}")], fileMetadata: md)
        let engine = await s.engine()
        let id = try await engine.enqueue(.batchRename(items: plan))
        await engine.waitUntilIdle()
        #expect(try #require(await engine.job(id)).state == .completed)
        #expect(s.names("trip") == ["2016-05-28 16.08.43.jpg", "day2"])
        #expect(s.names("trip/day2") == ["2016-05-29 09.00.00.jpg", "IMG_3.jpg"])
    }

    @Test("Older rename presets still load")
    func oldPreset() throws {
        let json = #"[{"kind":"addPrefix","text":"x","isEnabled":true}]"#
        let rules = try JSONDecoder().decode([RenameRule].self, from: Data(json.utf8))
        #expect(rules.first?.text == "x")
        #expect(rules.first?.perFolder == false)
    }
}

// MARK: - Organize

@Suite("Organize into folders", .serialized)
struct OrganizeTests {
    func meta(_ y: Int, _ mo: Int, camera: String? = "Canon EOS 100D") -> FileMetadata {
        var m = FileMetadata(); m.kind = .image; m.model = camera
        var c = DateComponents(); c.year = y; c.month = mo; c.day = 10; c.hour = 12
        m.taken = Calendar.current.date(from: c)
        return m
    }

    @Test("Plan: subfolders from the layout, fallback folder for missing details, numbered clashes")
    func plan() {
        let root = URL(fileURLWithPath: "/pics")
        let files = ["/pics/a.jpg", "/pics/b.jpg", "/pics/sub/a.jpg", "/pics/c.jpg"].map(url)
        var noDate = FileMetadata(); noDate.kind = .image
        let md = [files[0]: meta(2016, 5), files[1]: meta(2017, 1), files[2]: meta(2016, 5), files[3]: noDate]
        let plan = OrganizePlanner.plan(files: files, root: root, options: .init(template: "{taken:yyyy}/{taken:MM}"), metadata: md)
        #expect(plan.error == nil)
        let rel = plan.items.map { OrganizePlanner.relativePath($0.destination, root) }
        #expect(rel == ["2016/05/a.jpg", "2017/01/b.jpg", "2016/05/a 2.jpg", "Unsorted/c.jpg"])
        #expect(plan.items[3].status == .fallback("Date taken"))
        #expect(plan.folders(relativeTo: root).map(\.path) == ["2016/05", "2017/01", "Unsorted"])
    }

    @Test("Plan from parts of the file name")
    func byName() {
        let root = URL(fileURLWithPath: "/docs")
        let files = ["/docs/INV-2015-001.pdf", "/docs/INV-2016-007.pdf", "/docs/notes.txt"].map(url)
        let plan = OrganizePlanner.plan(files: files, root: root,
                                        options: .init(template: "{1}/{2}", namePattern: #"^(\w+)-(\d{4})"#), metadata: [:])
        #expect(plan.items.map { OrganizePlanner.relativePath($0.destination, root) } == ["INV/2015/INV-2015-001.pdf", "INV/2016/INV-2016-007.pdf", "Unsorted/notes.txt"])
        #expect(OrganizePlanner.plan(files: files, root: root, options: .init(template: "{1}", namePattern: "("), metadata: [:]).error != nil)
    }

    @Test("Organize in place (move): files sorted, empty old folders removed, undo restores everything")
    func moveInPlaceAndUndo() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try TestMedia.jpeg(at: s.path("pics/old/a.jpg"), taken: "2016:05:28 16:08:43")
        try TestMedia.jpeg(at: s.path("pics/b.jpg"), taken: "2017:01:02 10:00:00")
        try TestMedia.jpeg(at: s.path("pics/c.jpg"), taken: nil)
        let root = s.path("pics")
        let files = FileExpander.expand([root], recursive: true)
        let md = await MetadataReader.readAll(files)
        let plan = OrganizePlanner.plan(files: files, root: root, options: .init(template: "{taken:yyyy}/{taken:MM}"), metadata: md)
        let engine = await s.engine()
        let id = try await engine.enqueue(.organize(items: plan.items, move: true, cleanUpIn: root))
        await engine.waitUntilIdle()
        let job = try #require(await engine.job(id))
        #expect(job.state == .completed)
        #expect(s.names("pics") == ["2016", "2017", "Unsorted"]) // "old" was emptied and removed
        #expect(s.exists("pics/2016/05/a.jpg") && s.exists("pics/2017/01/b.jpg") && s.exists("pics/Unsorted/c.jpg"))

        try await engine.undo(id)
        await engine.waitUntilIdle()
        #expect(s.names("pics") == ["b.jpg", "c.jpg", "old"])
        #expect(s.exists("pics/old/a.jpg"))
    }

    @Test("Copy into folders elsewhere; files already there are skipped")
    func copyElsewhere() async throws {
        let s = try Sandbox(); defer { s.cleanup() }
        try TestMedia.jpeg(at: s.path("pics/a.jpg"), taken: "2016:05:28 16:08:43")
        try TestMedia.jpeg(at: s.path("pics/b.jpg"), taken: "2016:05:29 16:08:43")
        let files = FileExpander.expand([s.path("pics")], recursive: true)
        let md = await MetadataReader.readAll(files)
        let dest = try s.dir("library")
        let plan = OrganizePlanner.plan(files: files, root: dest, options: .init(template: "{taken:yyyy}"), metadata: md)
        let engine = await s.engine()
        try await engine.enqueue(.organize(items: plan.items, move: false, cleanUpIn: nil))
        await engine.waitUntilIdle()
        #expect(s.names("library/2016") == ["a.jpg", "b.jpg"])
        #expect(s.names("pics") == ["a.jpg", "b.jpg"]) // originals kept
        let again = try await engine.enqueue(.organize(items: plan.items, move: false, cleanUpIn: nil))
        await engine.waitUntilIdle()
        #expect(try #require(await engine.job(again)).notes.contains("2 already in place"))
    }
}
