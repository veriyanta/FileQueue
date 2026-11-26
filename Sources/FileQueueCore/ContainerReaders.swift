import Foundation

/// Small readers for video containers macOS can't open itself (AVI, Matroska/WebM).
/// They only read headers — seeking past the video data — so even multi-GB files take milliseconds.
enum ContainerReaders {

    // MARK: - AVI (RIFF)

    /// Reads title, size, frame rate, duration and codec from an AVI file. Handles files whose
    /// INFO tags come after the video data, and files that were cut short (e.g. recovered files).
    static func readAVI(_ url: URL, into meta: inout FileMetadata) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        guard fileSize >= 12, (try? handle.seek(toOffset: 0)) != nil,
              let head = try? handle.read(upToCount: 12), head.count == 12,
              head.prefix(4) == Data("RIFF".utf8), head[8..<12] == Data("AVI ".utf8) else { return }

        var pos: UInt64 = 12
        var steps = 0
        // Walk top-level chunks; also step into following "RIFF AVIX" extension chunks (files > 1 GB).
        while pos + 8 <= fileSize, steps < 10_000 {
            steps += 1
            guard (try? handle.seek(toOffset: pos)) != nil, let header = try? handle.read(upToCount: 12), header.count >= 8 else { break }
            let id = String(decoding: header.prefix(4), as: UTF8.self)
            let size = UInt64(header.le32(4))
            if id == "RIFF" {
                pos += 12 // a following RIFF-AVIX: its chunks start after its form type
                continue
            }
            if id == "LIST", header.count >= 12 {
                let listType = String(decoding: header[8..<12], as: UTF8.self)
                if listType == "hdrl" || listType == "INFO" {
                    let bodySize = Int(min(size, 1 << 20)) - 4
                    if bodySize > 0, let body = try? handle.read(upToCount: bodySize) {
                        if listType == "hdrl" { parseAVIHeader(body, into: &meta) } else { parseInfo(body, into: &meta) }
                    }
                }
            }
            pos += 8 + size + (size % 2)
        }
    }

    /// `hdrl` list body: avih (size, frame rate, frame count) and the video stream's codec.
    static func parseAVIHeader(_ body: Data, into meta: inout FileMetadata) {
        forEachChunk(in: body) { id, data in
            if id == "avih", data.count >= 40 {
                let usPerFrame = Double(data.le32(0))
                let frames = Double(data.le32(16))
                let width = Int(data.le32(32)), height = Int(data.le32(36))
                if width > 0, height > 0 { meta.width = width; meta.height = height }
                if usPerFrame > 0 {
                    meta.fps = (1_000_000 / usPerFrame * 1000).rounded() / 1000
                    if frames > 0 { meta.duration = frames * usPerFrame / 1_000_000 }
                }
            } else if id == "LIST", data.count >= 4, String(decoding: data.prefix(4), as: UTF8.self) == "strl" {
                forEachChunk(in: data.dropFirst(4)) { sid, sdata in
                    guard sid == "strh", sdata.count >= 8, meta.codec == nil,
                          String(decoding: sdata.prefix(4), as: UTF8.self) == "vids" else { return }
                    meta.codec = aviCodecName(String(decoding: sdata[sdata.startIndex + 4..<sdata.startIndex + 8], as: UTF8.self))
                }
            }
        }
    }

    /// `INFO` list body: INAM (title), ICRD (date), IART (artist)…
    static func parseInfo(_ body: Data, into meta: inout FileMetadata) {
        forEachChunk(in: body) { id, data in
            let text = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            switch id {
            case "INAM": meta.title = text
            case "ICRD": if meta.taken == nil { meta.taken = looseDate(text) }
            default: break
            }
        }
    }

    static func forEachChunk(in data: Data, _ body: (String, Data) -> Void) {
        var i = data.startIndex
        while i + 8 <= data.endIndex {
            let id = String(decoding: data[i..<i + 4], as: UTF8.self)
            let size = Int(data.le32(i - data.startIndex + 4)) // the size follows the 4-byte ID
            let start = i + 8
            let end = min(data.endIndex, start + size)
            body(id, data[start..<end])
            i = start + size + (size % 2)
        }
    }

    static func aviCodecName(_ fourCC: String) -> String {
        switch fourCC.trimmingCharacters(in: .whitespaces).uppercased() {
        case "XVID": "Xvid"
        case "DIVX", "DX50", "DIV3", "DIV4": "DivX"
        case "H264", "X264", "AVC1": "H.264"
        case "HEVC", "H265", "X265", "HVC1": "HEVC"
        case "MJPG": "Motion JPEG"
        case "MP42", "MP43", "MP4V", "FMP4": "MPEG-4"
        case "": "Uncompressed"
        default: fourCC.trimmingCharacters(in: .whitespaces).uppercased()
        }
    }

    // MARK: - Matroska / WebM (EBML)

    /// Reads title, date, duration, size and codec from the start of an MKV/WebM file.
    static func readMatroska(_ url: URL, into meta: inout FileMetadata) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512 << 10), data.count > 4,
              data.prefix(4) == Data([0x1A, 0x45, 0xDF, 0xA3]) else { return }
        let reader = EBMLReader(data: data)
        var timecodeScale = 1_000_000.0
        var rawDuration: Double?
        // Segment, Info, Tracks, TrackEntry, Video hold the elements we read.
        for (id, payload) in reader.elements(descendingInto: [0x1853_8067, 0x1549_A966, 0x1654_AE6B, 0xAE, 0xE0]) {
            switch id {
            case 0x2AD7B1: timecodeScale = Double(payload.uintValue)
            case 0x4489: rawDuration = payload.floatValue
            case 0x7BA9:
                let title = payload.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { meta.title = title }
            case 0x4461:
                // DateUTC: nanoseconds since 2001-01-01.
                let ns = Double(Int64(bitPattern: payload.uintValue))
                if ns != 0 { meta.taken = Date(timeIntervalSinceReferenceDate: ns / 1_000_000_000) }
            case 0x86:
                if meta.codec == nil, payload.stringValue.hasPrefix("V_") { meta.codec = matroskaCodecName(payload.stringValue) }
            case 0xB0: if meta.width == nil { meta.width = Int(payload.uintValue) }
            case 0xBA: if meta.height == nil { meta.height = Int(payload.uintValue) }
            default: break
            }
        }
        if let rawDuration, rawDuration > 0 { meta.duration = rawDuration * timecodeScale / 1_000_000_000 }
    }

    static func matroskaCodecName(_ id: String) -> String {
        switch id {
        case "V_MPEG4/ISO/AVC": "H.264"
        case "V_MPEGH/ISO/HEVC": "HEVC"
        case "V_AV1": "AV1"
        case "V_VP9": "VP9"
        case "V_VP8": "VP8"
        case "V_MPEG4/ISO/ASP", "V_MPEG4/ISO/SP": "MPEG-4"
        case "V_MPEG2": "MPEG-2"
        default: String(id.dropFirst(2))
        }
    }

    /// "2015-05-28", "2015/05/28 10:00", "2015" → a date (dates in tags are written many ways).
    static func looseDate(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "yyyy/MM/dd HH:mm", "yyyy/MM/dd", "yyyy:MM:dd HH:mm:ss", "EEE MMM dd HH:mm:ss yyyy", "yyyy"] {
            f.dateFormat = format
            if let d = f.date(from: text) { return d }
        }
        return nil
    }
}

/// Minimal EBML walker over an in-memory prefix of a Matroska file.
struct EBMLReader {
    let data: Data

    struct Payload {
        let bytes: Data
        var uintValue: UInt64 { bytes.prefix(8).reduce(0) { ($0 << 8) | UInt64($1) } }
        var floatValue: Double? {
            switch bytes.count {
            case 4: Double(Float(bitPattern: UInt32(truncatingIfNeeded: uintValue)))
            case 8: Double(bitPattern: uintValue)
            default: nil
            }
        }
        var stringValue: String { String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// Every element, in order; the children of elements whose ID is in `containers` are included too.
    func elements(descendingInto containers: Set<UInt64>) -> [(UInt64, Payload)] {
        var result: [(UInt64, Payload)] = []
        collect(range: data.startIndex..<data.endIndex, depth: 0, containers: containers, into: &result)
        return result
    }

    private func collect(range: Range<Data.Index>, depth: Int, containers: Set<UInt64>, into result: inout [(UInt64, Payload)]) {
        guard depth < 8 else { return }
        var i = range.lowerBound
        var count = 0
        while i < range.upperBound, count < 5000 {
            count += 1
            guard let (id, idLen) = vint(at: i, keepMarker: true), let (size, sizeLen, unknown) = sizeVint(at: i + idLen) else { return }
            let start = i + idLen + sizeLen
            guard start <= range.upperBound else { return }
            let declaredEnd = start.addingReportingOverflow(Int(clamping: size))
            let end = unknown || declaredEnd.overflow ? range.upperBound : min(range.upperBound, declaredEnd.partialValue)
            result.append((id, Payload(bytes: data[start..<end])))
            if containers.contains(id) { collect(range: start..<end, depth: depth + 1, containers: containers, into: &result) }
            if unknown || declaredEnd.overflow || declaredEnd.partialValue > range.upperBound { return } // runs to the end / cut short
            i = end
        }
    }

    /// Element IDs keep their length marker bits.
    private func vint(at i: Data.Index, keepMarker: Bool) -> (UInt64, Int)? {
        guard i < data.endIndex else { return nil }
        let first = data[i]
        guard first != 0 else { return nil }
        let length = first.leadingZeroBitCount + 1
        guard length <= 4, i + length <= data.endIndex else { return nil }
        var value: UInt64 = 0
        for k in 0..<length { value = (value << 8) | UInt64(data[i + k]) }
        return (value, length)
    }

    /// Sizes drop the marker bit; all-ones means "unknown size".
    private func sizeVint(at i: Data.Index) -> (UInt64, Int, Bool)? {
        guard i < data.endIndex else { return nil }
        let first = data[i]
        guard first != 0 else { return nil }
        let length = first.leadingZeroBitCount + 1
        guard length <= 8, i + length <= data.endIndex else { return nil }
        var value = UInt64(first & (0xFF >> length))
        var allOnes = value == UInt64(0xFF >> length)
        for k in 1..<length {
            value = (value << 8) | UInt64(data[i + k])
            if data[i + k] != 0xFF { allOnes = false }
        }
        return (value, length, allOnes)
    }
}

extension Data {
    /// Little-endian UInt32 at `offset` from the start (0 if out of range).
    func le32(_ offset: Int) -> UInt32 {
        let i = startIndex + offset
        guard i >= startIndex, i + 4 <= endIndex else { return 0 }
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}

// MARK: - Windows Media (ASF: .wmv, .wma, .asf)

extension ContainerReaders {
    /// Reads the title (Content Description object) and duration (File Properties object) of an ASF file.
    static func readASF(_ url: URL, into meta: inout FileMetadata) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 << 10), data.count >= 30,
              data.prefix(16) == guid("75B22630-668E-11CF-A6D9-00AA0062CE6C") else { return }
        let headerCount = Int(data.le32(24))
        var i = data.startIndex + 30
        for _ in 0..<min(headerCount, 200) {
            guard i + 24 <= data.endIndex else { return }
            let objectID = data[i..<i + 16]
            let size = Int(data.le64(i - data.startIndex + 16))
            guard size >= 24 else { return }
            let body = data[(i + 24)..<min(data.endIndex, i + size)]
            if objectID == guid("75B22633-668E-11CF-A6D9-00AA0062CE6C"), body.count >= 10 {
                // Content Description: five lengths, then UTF-16 strings; the first is the title.
                let titleLength = Int(body.le16(0))
                let start = body.startIndex + 10
                if titleLength > 0, start + titleLength <= body.endIndex {
                    let title = String(decoding: utf16(body[start..<start + titleLength]), as: UTF16.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
                    if !title.isEmpty { meta.title = title }
                }
            } else if objectID == guid("8CABDCA1-A947-11CF-8EE4-00C00C205365"), body.count >= 80 {
                // File Properties: play duration (100 ns units) minus preroll (ms).
                let play = Double(body.le64(40)), preroll = Double(body.le64(56))
                let seconds = play / 10_000_000 - preroll / 1000
                if seconds > 0 { meta.duration = seconds }
            }
            i += size
        }
    }

    /// ASF GUIDs are stored with the first three groups little-endian.
    static func guid(_ text: String) -> Data {
        let hex = text.replacingOccurrences(of: "-", with: "")
        var bytes = stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
            let s = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[s..<hex.index(s, offsetBy: 2)], radix: 16) ?? 0
        }
        bytes[0..<4].reverse(); bytes[4..<6].reverse(); bytes[6..<8].reverse()
        return Data(bytes)
    }

    static func utf16(_ data: Data) -> [UInt16] {
        stride(from: data.startIndex, to: data.endIndex - 1, by: 2).map { UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8 }
    }
}

extension Data {
    func le16(_ offset: Int) -> UInt16 {
        let i = startIndex + offset
        guard i >= startIndex, i + 2 <= endIndex else { return 0 }
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func le64(_ offset: Int) -> UInt64 {
        UInt64(le32(offset)) | UInt64(le32(offset + 4)) << 32
    }
}
