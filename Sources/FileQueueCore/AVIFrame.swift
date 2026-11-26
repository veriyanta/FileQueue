import CoreGraphics
import CoreMedia
import Foundation
import ImageIO

/// Grabs one picture from an AVI that macOS can't preview: XviD/DivX (decoded by macOS's own MPEG-4 decoder)
/// and uncompressed or RLE bitmaps (turned into a BMP for ImageIO). MJPEG AVIs are left to Quick Look.
public enum AVIFrame {
    struct VideoStream {
        var index = 0
        var format = Data() // strf: BITMAPINFOHEADER (+ palette or codec extra data)
        var width: Int { format.count >= 40 ? Int(Int32(bitPattern: format.le32(4))) : 0 }
        var height: Int { format.count >= 40 ? abs(Int(Int32(bitPattern: format.le32(8)))) : 0 }
        var compression: UInt32 { format.count >= 40 ? format.le32(16) : 0xFFFF_FFFF }
        var fourCC: String { String(decoding: withUnsafeBytes(of: compression.littleEndian) { Array($0) }, as: UTF8.self) }
        var isBitmap: Bool { compression <= 2 } // BI_RGB, BI_RLE8, BI_RLE4
        var isMPEG4: Bool { MPEG4Part2.fourCCs.contains(fourCC.uppercased()) }
    }

    public static func image(at url: URL, position: Double = 0.1) -> CGImage? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        guard fileSize > 64, (try? handle.seek(toOffset: 0)) != nil, let riff = try? handle.read(upToCount: 12),
              riff.count == 12, riff.prefix(4) == Data("RIFF".utf8), riff[8..<12] == Data("AVI ".utf8) else { return nil }

        // Top-level chunks: hdrl (stream formats) and movi (the frames).
        var stream: VideoStream?
        var movi: Range<UInt64>?
        var offset: UInt64 = 12
        for _ in 0..<64 where offset + 12 <= fileSize {
            guard (try? handle.seek(toOffset: offset)) != nil, let h = try? handle.read(upToCount: 12), h.count == 12 else { break }
            let id = String(decoding: h.prefix(4), as: UTF8.self), size = UInt64(h.le32(4))
            let listType = String(decoding: h[8..<12], as: UTF8.self)
            if id == "LIST", listType == "hdrl", let body = try? handle.read(upToCount: Int(min(size, 2 << 20)) - 4) {
                stream = videoStream(inHeaderList: body)
            } else if id == "LIST", listType == "movi" {
                movi = (offset + 12)..<min(fileSize, offset + 8 + size)
                break
            }
            guard size > 0 else { break }
            offset += 8 + size + (size & 1)
        }
        guard let stream, let movi, stream.width > 0, stream.height > 0 else { return nil }
        let tags = [String(format: "%02ddc", stream.index), String(format: "%02ddb", stream.index)].map { Data($0.utf8) }

        func window(at fraction: Double) -> Data? {
            let start = movi.lowerBound + UInt64(Double(movi.upperBound - movi.lowerBound) * fraction)
            guard (try? handle.seek(toOffset: start)) != nil else { return nil }
            return try? handle.read(upToCount: 4 << 20)
        }
        guard let opening = window(at: 0), let first = frames(in: opening, tags: tags).first(where: { !$0.isEmpty }) else { return nil }

        if stream.isBitmap { return bitmap(first, format: stream.format) }
        guard stream.isMPEG4 else { return nil }
        let config = MPEG4Part2.config(in: Data(stream.format.dropFirst(40))) ?? MPEG4Part2.config(in: first)
        guard let config, let format = MPEG4Part2.formatDescription(config: config, width: stream.width, height: stream.height) else { return nil }
        // An intra frame a little way in (the very first one is often black), else the first frame.
        for fraction in [position, position / 3] {
            guard let data = window(at: fraction) else { continue }
            if let intra = frames(in: data, tags: tags).first(where: MPEG4Part2.isIntra),
               let image = MatroskaFrame.decode(intra, format: format) { return image }
        }
        return MatroskaFrame.decode(first, format: format)
    }

    static func videoStream(inHeaderList body: Data) -> VideoStream? {
        var streamIndex = 0
        var i = body.startIndex
        while i + 12 <= body.endIndex {
            let id = String(decoding: body[i..<(i + 4)], as: UTF8.self), size = Int(body.le32(i - body.startIndex + 4))
            let end = min(body.endIndex, i + 8 + size)
            if id == "LIST", String(decoding: body[(i + 8)..<(i + 12)], as: UTF8.self) == "strl" {
                var stream = VideoStream(index: streamIndex)
                var isVideo = false
                var j = i + 12
                while j + 8 <= end {
                    let cid = String(decoding: body[j..<(j + 4)], as: UTF8.self), csize = Int(body.le32(j - body.startIndex + 4))
                    let cend = min(end, j + 8 + csize)
                    if cid == "strh", cend - j >= 12 { isVideo = body[(j + 8)..<(j + 12)] == Data("vids".utf8) }
                    if cid == "strf" { stream.format = Data(body[(j + 8)..<cend]) }
                    j = cend + (csize & 1)
                }
                if isVideo { return stream }
                streamIndex += 1
            }
            guard size >= 0, end > i else { break }
            i = end + (size & 1)
        }
        return nil
    }

    /// Video chunks (`00dc` / `00db`) found in a stretch of the movi list, in order.
    static func frames(in data: Data, tags: [Data]) -> [Data] {
        var found: [(Int, Data)] = []
        for tag in tags {
            var search = data.startIndex
            var count = 0
            while count < 400, let r = data.range(of: tag, in: search..<data.endIndex) {
                count += 1
                search = r.upperBound
                guard r.upperBound + 4 <= data.endIndex else { break }
                let size = Int(data.le32(r.upperBound - data.startIndex))
                let start = r.upperBound + 4
                guard size >= 0, size < 32 << 20, start + size <= data.endIndex else { continue }
                found.append((r.lowerBound, Data(data[start..<(start + size)])))
                search = start + size
            }
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Uncompressed / RLE frames are bitmaps already: wrap them as a .bmp file and let ImageIO draw them.
    static func bitmap(_ frame: Data, format: Data) -> CGImage? {
        guard format.count >= 40 else { return nil }
        var info = format
        withUnsafeBytes(of: UInt32(frame.count).littleEndian) { info.replaceSubrange(info.startIndex + 20..<info.startIndex + 24, with: $0) }
        var bmp = Data("BM".utf8)
        for value in [UInt32(14 + info.count + frame.count), 0, UInt32(14 + info.count)] {
            withUnsafeBytes(of: value.littleEndian) { bmp.append(contentsOf: $0) }
        }
        bmp += info + frame
        guard let source = CGImageSourceCreateWithData(bmp as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// MPEG-4 Part 2 (XviD, DivX 4/5, FFmpeg MPEG-4): macOS decodes it once it's given the stream's VOL header.
enum MPEG4Part2 {
    static let fourCCs: Set<String> = ["XVID", "DIVX", "DX50", "FMP4", "MP4V", "M4S2", "3IV2", "DXGM", "XVIX", "MP4S"]

    /// The configuration headers (VOS / VO / VOL) that come before the first picture.
    static func config(in data: Data) -> Data? {
        let bytes = [UInt8](data)
        var start: Int?
        var i = 0
        while i + 4 <= bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                let code = bytes[i + 3]
                if start == nil, code == 0xB0 || code <= 0x2F { start = i }
                if code == 0xB6 || code == 0xB3 { break } // first picture / group
                if code >= 0x20 && code <= 0x2F, let s = start {
                    // VOL found: keep going to the next start code to include all of it.
                    var e = i + 4
                    while e + 3 <= bytes.count, !(bytes[e] == 0 && bytes[e + 1] == 0 && bytes[e + 2] == 1) { e += 1 }
                    return Data(bytes[s..<min(e, bytes.count)])
                }
            }
            i += 1
        }
        return nil
    }

    /// An I-VOP: the picture can be decoded on its own.
    static func isIntra(_ frame: Data) -> Bool {
        guard let r = frame.range(of: Data([0, 0, 1, 0xB6])), r.upperBound < frame.endIndex else { return false }
        return frame[r.upperBound] >> 6 == 0
    }

    static func formatDescription(config: Data, width: Int, height: Int) -> CMVideoFormatDescription? {
        func descriptor(_ tag: UInt8, _ body: Data) -> Data {
            let n = body.count
            return Data([tag, 0x80 | UInt8((n >> 21) & 0x7F), 0x80 | UInt8((n >> 14) & 0x7F), 0x80 | UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)]) + body
        }
        let decoderConfig = descriptor(0x04, Data([0x20, 0x11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]) + descriptor(0x05, config))
        let es = descriptor(0x03, Data([0, 1, 0]) + decoderConfig + descriptor(0x06, Data([0x02])))
        let esds = Data([0, 0, 0, 0]) + es
        let extensions: [CFString: Any] = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["esds": esds]]
        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_MPEG4Video,
                                                    width: Int32(width), height: Int32(height),
                                                    extensions: extensions as CFDictionary, formatDescriptionOut: &format)
        return status == noErr ? format : nil
    }
}
