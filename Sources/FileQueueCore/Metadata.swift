import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Details read from a photo, video or other file, used for naming and organizing.
public struct FileMetadata: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable {
        case image, video, audio, other
        public var folderName: String {
            switch self {
            case .image: "Photos"
            case .video: "Videos"
            case .audio: "Audio"
            case .other: "Other"
            }
        }
    }

    public var kind: Kind = .other
    /// When the photo/video was taken (EXIF DateTimeOriginal, QuickTime creation date).
    public var taken: Date?
    public var created: Date?
    public var modified: Date?
    public var make: String?
    public var model: String?
    public var lens: String?
    public var width: Int?
    public var height: Int?
    /// Seconds.
    public var duration: Double?
    public var fps: Double?
    public var codec: String?
    public var iso: Int?
    public var fNumber: Double?
    public var focalLength: Double?
    public var latitude: Double?
    public var longitude: Double?
    /// File size in bytes (files only).
    public var size: Int64?
    /// A title stored inside the file (video title tags; e.g. "The.Intern.2015.720p.WEBRip…").
    public var title: String?

    public init() {}

    /// "Canon EOS 100D" (not "Canon Canon EOS 100D").
    public var camera: String? {
        switch (clean(make), clean(model)) {
        case let (make?, model?):
            return model.lowercased().hasPrefix(make.lowercased().split(separator: " ").first.map(String.init) ?? make.lowercased())
                ? model : "\(make) \(model)"
        case let (nil, model?): return model
        case let (make?, nil): return make
        default: return nil
        }
    }

    private func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)), !t.isEmpty else { return nil }
        // Some cameras write e.g. "NIKON CORPORATION"; keep the useful part.
        return t.replacingOccurrences(of: " CORPORATION", with: "").replacingOccurrences(of: " Corporation", with: "")
    }
}

public enum MetadataReader {
    /// Only what the file system knows (kind from the extension, created/modified dates). Very fast:
    /// the file itself isn't opened.
    public static func readBasic(_ url: URL) -> FileMetadata {
        var meta = FileMetadata()
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isDirectoryKey])
        meta.created = values?.creationDate
        meta.modified = values?.contentModificationDate
        if values?.isDirectory != true { meta.size = values?.fileSize.map(Int64.init) }
        meta.kind = kind(of: url)
        return meta
    }

    /// Video formats macOS may not recognise (no system type for them).
    static let videoExtensions: Set<String> = ["avi", "mkv", "webm", "wmv", "asf", "flv", "f4v", "m2ts", "mts", "ts",
                                               "mpg", "mpeg", "m2v", "vob", "3gp", "3g2", "divx", "xvid", "ogv", "rm", "rmvb"]

    public static func kind(of url: URL) -> FileMetadata.Kind {
        if videoExtensions.contains(url.pathExtension.lowercased()) { return .video }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return .other
    }

    /// Reads the details of one file. Fast: only file headers are read, never whole images or videos.
    public static func read(_ url: URL) async -> FileMetadata {
        var meta = readBasic(url)
        switch meta.kind {
        case .image: readImage(url, into: &meta)
        case .video, .audio: await readMedia(url, into: &meta)
        case .other: break
        }
        tidyTitle(&meta)
        return meta
    }

    /// Reads many files, a few at a time. `progress` gets the number done so far.
    public static func readAll(
        _ urls: [URL], concurrency: Int = 8, progress: (@Sendable (Int) -> Void)? = nil
    ) async -> [URL: FileMetadata] {
        var result: [URL: FileMetadata] = [:]
        await withTaskGroup(of: (URL, FileMetadata).self) { group in
            var iterator = urls.makeIterator()
            for _ in 0..<max(1, concurrency) {
                guard let url = iterator.next() else { break }
                group.addTask { (url, await read(url)) }
            }
            while let (url, meta) = await group.next() {
                if Task.isCancelled { group.cancelAll(); break }
                result[url] = meta
                progress?(result.count)
                if let next = iterator.next() { group.addTask { (next, await read(next)) } }
            }
        }
        return result
    }

    /// Drops titles that aren't titles: blank ones, and timestamps (used as the date taken instead).
    static func tidyTitle(_ meta: inout FileMetadata) {
        guard let raw = meta.title else { return }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        if t.isEmpty { meta.title = nil; return }
        if let date = ReleaseTitle.dateIfTimestamp(t) {
            if meta.taken == nil { meta.taken = date }
            meta.title = nil
            return
        }
        meta.title = t
    }

    // MARK: Images (EXIF via ImageIO)

    static func readImage(_ url: URL, into meta: inout FileMetadata) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any]
        else { return }
        meta.width = props[kCGImagePropertyPixelWidth] as? Int
        meta.height = props[kCGImagePropertyPixelHeight] as? Int
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String
            ?? exif[kCGImagePropertyExifDateTimeDigitized] as? String
            ?? tiff[kCGImagePropertyTIFFDateTime] as? String
        let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
        meta.taken = original.flatMap { exifDate($0, offset: offset) }

        meta.make = tiff[kCGImagePropertyTIFFMake] as? String
        meta.model = tiff[kCGImagePropertyTIFFModel] as? String
        meta.lens = exif[kCGImagePropertyExifLensModel] as? String
        meta.iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
        meta.fNumber = exif[kCGImagePropertyExifFNumber] as? Double
        meta.focalLength = exif[kCGImagePropertyExifFocalLength] as? Double
        if let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            meta.latitude = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
            meta.longitude = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
        }
    }

    /// "2016:05:28 16:08:43" (+ optional "+07:00"). Without an offset, EXIF times are local to this Mac.
    static func exifDate(_ text: String, offset: String?) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if let offset, !offset.isEmpty {
            f.dateFormat = "yyyy:MM:dd HH:mm:ssXXX"
            if let d = f.date(from: text + offset) { return d }
        }
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.timeZone = .current
        return f.date(from: text)
    }

    // MARK: Videos and audio (AVFoundation)

    static func readMedia(_ url: URL, into meta: inout FileMetadata) async {
        // Containers macOS can't open: read their headers directly.
        switch url.pathExtension.lowercased() {
        case "avi", "divx", "xvid":
            ContainerReaders.readAVI(url, into: &meta)
            return
        case "mkv", "webm", "mka", "mk3d":
            ContainerReaders.readMatroska(url, into: &meta)
            return
        case "wmv", "wma", "asf":
            ContainerReaders.readASF(url, into: &meta)
            return
        default:
            break
        }
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 {
            meta.duration = duration.seconds
        }
        if let item = try? await asset.load(.creationDate), let date = try? await item.load(.dateValue) {
            meta.taken = date
        }
        if let items = try? await asset.load(.metadata) {
            func string(_ ids: [AVMetadataIdentifier]) async -> String? {
                for id in ids {
                    if let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first,
                       let value = try? await item.load(.stringValue), !value.isEmpty { return value }
                }
                return nil
            }
            meta.title = await string([.commonIdentifierTitle, .quickTimeMetadataTitle, .iTunesMetadataSongName, .id3MetadataTitleDescription])
            meta.make = await string([.quickTimeMetadataMake, .commonIdentifierMake])
            meta.model = await string([.quickTimeMetadataModel, .commonIdentifierModel])
            if meta.taken == nil, let text = await string([.quickTimeMetadataCreationDate, .commonIdentifierCreationDate]) {
                meta.taken = ISO8601DateFormatter().date(from: text)
            }
            if let iso6709 = await string([.quickTimeMetadataLocationISO6709, .commonIdentifierLocation]) {
                (meta.latitude, meta.longitude) = parseISO6709(iso6709)
            }
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                let rotated = size.applying(transform)
                meta.width = Int(abs(rotated.width).rounded())
                meta.height = Int(abs(rotated.height).rounded())
            }
            if let fps = try? await track.load(.nominalFrameRate), fps > 0 { meta.fps = Double(fps) }
            if let formats = try? await track.load(.formatDescriptions), let format = formats.first {
                meta.codec = codecName(CMFormatDescriptionGetMediaSubType(format))
            }
        } else if meta.kind == .video {
            meta.kind = .video
        }
    }

    static func codecName(_ code: FourCharCode) -> String {
        let names: [String: String] = [
            "avc1": "H.264", "avc3": "H.264", "hvc1": "HEVC", "hev1": "HEVC", "av01": "AV1",
            "apcn": "ProRes", "apch": "ProRes HQ", "apcs": "ProRes LT", "apco": "ProRes Proxy", "ap4h": "ProRes 4444",
            "mp4v": "MPEG-4", "jpeg": "Motion JPEG", "vp09": "VP9",
        ]
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((code >> $0) & 0xFF))) }
        let fourCC = String(chars).trimmingCharacters(in: .whitespaces)
        return names[fourCC] ?? fourCC.uppercased()
    }

    /// "+37.7858-122.4064+010.000/" → (37.7858, -122.4064)
    static func parseISO6709(_ s: String) -> (Double?, Double?) {
        let scanner = Scanner(string: s)
        let lat = scanner.scanDouble()
        let lon = scanner.scanDouble()
        return (lat, lon)
    }
}

/// Picks a few files from every folder, so suggestions can be made without reading everything.
public enum MediaSampler {
    /// Up to `perFolder` files from each folder (spread evenly through it, photos/videos first),
    /// and at most `maxTotal` overall — every folder gets a turn before any gets more.
    public static func sample(_ files: [URL], perFolder: Int = 3, maxTotal: Int = 400) -> [URL] {
        let byFolder = Dictionary(grouping: files) { $0.deletingLastPathComponent() }
        let folders = byFolder.keys.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        var picks: [URL: [URL]] = [:]
        for folder in folders {
            let all = byFolder[folder]!
            let media = all.filter { MetadataReader.kind(of: $0) == .image || MetadataReader.kind(of: $0) == .video }
            let pool = media.isEmpty ? all : media
            picks[folder] = spread(pool, count: perFolder)
        }
        // Round-robin so a cap still covers as many folders as possible.
        var result: [URL] = []
        var round = 0
        while result.count < maxTotal {
            var added = false
            for folder in folders {
                guard let list = picks[folder], round < list.count else { continue }
                result.append(list[round])
                added = true
                if result.count >= maxTotal { break }
            }
            if !added { break }
            round += 1
        }
        return result
    }

    /// `count` items evenly spaced through `items` (first, middle, last…).
    static func spread(_ items: [URL], count: Int) -> [URL] {
        guard items.count > count, count > 0 else { return items }
        if count == 1 { return [items[items.count / 2]] }
        return (0..<count).map { i in items[Int((Double(i) * Double(items.count - 1) / Double(count - 1)).rounded())] }
    }
}
