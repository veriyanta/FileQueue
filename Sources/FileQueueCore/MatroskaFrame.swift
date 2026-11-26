import CoreGraphics
import CoreMedia
import Foundation
import VideoToolbox

/// Grabs one picture from an MKV/WebM file without any extra software: the Matroska container is read
/// here, and the H.264 / HEVC frame inside it is decoded by macOS's own VideoToolbox.
/// Only the header and a few MB around one keyframe are read, so even huge files are quick.
public enum MatroskaFrame {
    struct VideoTrack {
        var number: UInt64 = 0
        var codecID = ""
        var codecPrivate = Data()
        var width = 0
        var height = 0
        /// ContentCompAlgo: 3 = header stripping (bytes to put back in front of every frame), 0 = zlib.
        var compression: UInt64?
        var strippedHeader = Data()
        var isMPEG2: Bool { codecID == "V_MPEG2" || codecID == "V_MPEG1" }
        var isAVC: Bool { codecID == "V_MPEG4/ISO/AVC" }
    }

    /// A frame from about `position` (0…1) into the video, or nil if it can't be decoded here.
    public static func image(at url: URL, position: Double = 0.1) -> CGImage? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        guard fileSize > 64, (try? handle.seek(toOffset: 0)) != nil,
              let head = try? handle.read(upToCount: 4 << 20), head.prefix(4) == Data([0x1A, 0x45, 0xDF, 0xA3]),
              let track = videoTrack(in: head), track.compression == nil || track.compression == 3 else { return nil }
        let headerFormat = formatDescription(for: track)

        // Look for a keyframe around `position`, then nearer the start, then right after the headers.
        let starts = [position, position / 3, 0].map { UInt64(Double(fileSize) * $0) }
        for start in starts {
            guard (try? handle.seek(toOffset: start)) != nil, let window = try? handle.read(upToCount: 6 << 20) else { continue }
            guard let raw = keyframe(in: window, track: track.number) else { continue }
            var frame = prepare(raw, track: track)
            var format = headerFormat
            if format == nil, track.isAVC, let inBand = inBandH264(frame) {
                // No setup in the header (some ffmpeg-made files): it travels inside the keyframe instead.
                (frame, format) = inBand
            }
            if let format, let image = decode(frame, format: format) { return image }
        }
        return nil
    }

    // MARK: Container

    static func videoTrack(in head: Data) -> VideoTrack? {
        let reader = EBMLReader(data: head)
        var tracks: [VideoTrack] = []
        var current: VideoTrack?
        // Segment, Tracks, TrackEntry, Video, ContentEncodings, ContentEncoding, ContentCompression
        for (id, payload) in reader.elements(descendingInto: [0x1853_8067, 0x1654_AE6B, 0xAE, 0xE0, 0x6D80, 0x6240, 0x5034]) {
            switch id {
            case 0xAE:
                if let c = current { tracks.append(c) }
                current = VideoTrack()
            case 0xD7: current?.number = payload.uintValue
            case 0x83: if payload.uintValue != 1 { current?.codecID = "-" } // not a video track
            case 0x86: if current?.codecID != "-" { current?.codecID = payload.stringValue }
            case 0x63A2: current?.codecPrivate = Data(payload.bytes)
            case 0xB0: current?.width = Int(payload.uintValue)
            case 0xBA: current?.height = Int(payload.uintValue)
            case 0x5034: current?.compression = 0 // ContentCompression present; algorithm defaults to zlib
            case 0x4254: current?.compression = payload.uintValue
            case 0x4255: current?.strippedHeader = Data(payload.bytes)
            case 0x1F43_B675: break // first Cluster: tracks are done
            default: break
            }
        }
        if let c = current { tracks.append(c) }
        return tracks.first {
            $0.isAVC || ($0.codecID == "V_MPEGH/ISO/HEVC" && !$0.codecPrivate.isEmpty) || $0.isMPEG2
        }
    }

    /// Puts back stripped header bytes, and for MPEG-2 makes sure the sequence header comes first.
    static func prepare(_ frame: Data, track: VideoTrack) -> Data {
        var frame = track.compression == 3 ? track.strippedHeader + frame : frame
        if track.isMPEG2, !track.codecPrivate.isEmpty, !frame.starts(with: [0, 0, 1, 0xB3]) {
            frame = track.codecPrivate + frame
        }
        return frame
    }

    /// Finds the first keyframe of `track` in a chunk of the file that starts at an arbitrary position.
    static func keyframe(in data: Data, track: UInt64) -> Data? {
        let clusterID: [UInt8] = [0x1F, 0x43, 0xB6, 0x75]
        var search = data.startIndex
        var clusters = 0
        while clusters < 40, let r = data.range(of: Data(clusterID), in: search..<data.endIndex) {
            clusters += 1
            search = r.upperBound
            // A real cluster: a size, then its Timecode element first.
            let body = data[r.upperBound...]
            guard let (size, sizeLen) = vintSize(body), size > 0 else { continue }
            let start = r.upperBound + sizeLen
            guard start < data.endIndex, data[start] == 0xE7 else { continue }
            let end = min(data.endIndex, start + Int(min(size, UInt64(Int.max / 2))))
            if let frame = keyframe(inCluster: data[start..<end], track: track) { return frame }
        }
        return nil
    }

    static func keyframe(inCluster cluster: Data, track: UInt64) -> Data? {
        var i = cluster.startIndex
        while i < cluster.endIndex {
            guard let (id, idLen) = vintID(cluster[i...]), let (size, sizeLen) = vintSize(cluster[(i + idLen)...]) else { return nil }
            let start = i + idLen + sizeLen
            let end = start + Int(min(size, UInt64(cluster.endIndex - start)))
            guard start <= cluster.endIndex else { return nil }
            let payload = cluster[start..<end]
            if id == 0xA3, let frame = blockFrame(payload, track: track, requireKeyFlag: true) {
                return frame // SimpleBlock flagged as a keyframe
            }
            if id == 0xA0 {
                // BlockGroup: a keyframe when it has no ReferenceBlock (0xFB).
                var block: Data?
                var references = false
                var j = payload.startIndex
                while j < payload.endIndex, let (cid, cidLen) = vintID(payload[j...]), let (csize, csizeLen) = vintSize(payload[(j + cidLen)...]) {
                    let cs = j + cidLen + csizeLen
                    let ce = min(payload.endIndex, cs + Int(min(csize, UInt64(payload.endIndex - cs))))
                    if cid == 0xA1 { block = Data(payload[cs..<ce]) }
                    if cid == 0xFB { references = true }
                    j = ce
                }
                if !references, let block, let frame = blockFrame(block, track: track, requireKeyFlag: false) { return frame }
            }
            if end >= cluster.endIndex, start + Int(min(size, UInt64(Int.max / 2))) > cluster.endIndex { return nil }
            i = end
        }
        return nil
    }

    /// Block layout: track number (vint), 2-byte timecode, flags, then the frame (no lacing).
    static func blockFrame(_ block: Data, track: UInt64, requireKeyFlag: Bool) -> Data? {
        guard let (number, len) = vintSize(block), number == track, block.count > len + 3 else { return nil }
        let flags = block[block.startIndex + len + 2]
        if requireKeyFlag && flags & 0x80 == 0 { return nil }
        if flags & 0x06 != 0 { return nil } // laced: not used for video in practice
        return Data(block[(block.startIndex + len + 3)...])
    }

    static func vintID(_ d: Data.SubSequence) -> (UInt64, Int)? {
        guard let first = d.first, first != 0 else { return nil }
        let length = first.leadingZeroBitCount + 1
        guard length <= 4, d.count >= length else { return nil }
        return (d.prefix(length).reduce(0) { ($0 << 8) | UInt64($1) }, length)
    }

    static func vintSize(_ d: Data.SubSequence) -> (UInt64, Int)? {
        guard let first = d.first, first != 0 else { return nil }
        let length = first.leadingZeroBitCount + 1
        guard length <= 8, d.count >= length else { return nil }
        var value = UInt64(first & (0xFF >> length))
        for byte in d.dropFirst().prefix(length - 1) { value = (value << 8) | UInt64(byte) }
        return (value, length)
    }

    // MARK: Decoding

    /// Splits an H.264 frame into NAL units, whether it uses start codes (00 00 01) or 4-byte lengths.
    static func nalUnits(_ frame: Data) -> [Data] {
        let bytes = [UInt8](frame)
        // 4-byte length prefixes that add up exactly to the frame.
        var units: [Data] = []
        var i = 0
        while i + 4 <= bytes.count {
            let n = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            guard n > 0, i + 4 + n <= bytes.count else { units = []; break }
            units.append(Data(bytes[(i + 4)..<(i + 4 + n)]))
            i += 4 + n
        }
        if !units.isEmpty, i == bytes.count { return units }
        // Annex B start codes.
        units = []
        var starts: [(Int, Int)] = [] // (start code position, payload position)
        var j = 0
        while j + 3 <= bytes.count {
            if bytes[j] == 0, bytes[j + 1] == 0, bytes[j + 2] == 1 {
                let at = j > 0 && bytes[j - 1] == 0 ? j - 1 : j
                starts.append((at, j + 3))
                j += 3
            } else { j += 1 }
        }
        for (k, s) in starts.enumerated() {
            let end = k + 1 < starts.count ? starts[k + 1].0 : bytes.count
            if end > s.1 { units.append(Data(bytes[s.1..<end])) }
        }
        return units
    }

    /// Builds the decoder setup from SPS/PPS found in the frame, and repacks the frame with 4-byte lengths.
    static func inBandH264(_ frame: Data) -> (Data, CMVideoFormatDescription)? {
        let units = nalUnits(frame)
        guard let sps = units.first(where: { ($0.first ?? 0) & 0x1F == 7 }),
              let pps = units.first(where: { ($0.first ?? 0) & 0x1F == 8 }) else { return nil }
        var format: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2,
                                                                           parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                           nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        guard status == noErr, let format else { return nil }
        var packed = Data()
        for unit in units {
            var length = UInt32(unit.count).bigEndian
            packed.append(Data(bytes: &length, count: 4))
            packed.append(unit)
        }
        return (packed, format)
    }

    static func formatDescription(for track: VideoTrack) -> CMVideoFormatDescription? {
        if track.isAVC && track.codecPrivate.isEmpty { return nil }
        if track.isMPEG2 {
            var format: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_MPEG2Video,
                                                        width: Int32(max(16, track.width)), height: Int32(max(16, track.height)),
                                                        extensions: nil, formatDescriptionOut: &format)
            return status == noErr ? format : nil
        }
        let isHEVC = track.codecID == "V_MPEGH/ISO/HEVC"
        let atoms: [String: Any] = [isHEVC ? "hvcC" : "avcC": track.codecPrivate]
        let extensions: [CFString: Any] = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms]
        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: isHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            width: Int32(max(16, track.width)), height: Int32(max(16, track.height)),
            extensions: extensions as CFDictionary, formatDescriptionOut: &format)
        return status == noErr ? format : nil
    }

    static func decode(_ frame: Data, format: CMVideoFormatDescription) -> CGImage? {
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: frame.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: frame.count, flags: 0, blockBufferOut: &blockBuffer) == noErr,
              let blockBuffer,
              frame.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blockBuffer,
                                                                   offsetIntoDestination: 0, dataLength: frame.count) }) == noErr
        else { return nil }
        var sample: CMSampleBuffer?
        var sizes = [frame.count]
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }

        var session: VTDecompressionSession?
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
                                           imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                                           decompressionSessionOut: &session) == noErr, let session else { return nil }
        defer { VTDecompressionSessionInvalidate(session) }

        final class Box: @unchecked Sendable { var image: CGImage? }
        let box = Box()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, buffer, _, _ in
            guard status == noErr, let buffer else { return }
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
            box.image = image
        }
        guard status == noErr else { return nil }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return box.image
    }
}
