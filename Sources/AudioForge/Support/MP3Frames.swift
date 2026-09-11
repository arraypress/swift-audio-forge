//
//  MP3Frames.swift
//  AudioForge
//
//  Created by David Sherlock on 2026.
//
//  The road that never decodes a sample, and the reason this library exists at all.
//
//  Apple's frameworks decode MP3 and do not encode it, so the obvious way to trim one —
//  decode, cut, re-encode — cannot produce an MP3 at the other end. It can only produce
//  AAC, which means "trim my MP3" silently changes the format and loses a generation of
//  quality every time.
//
//  But an MP3 does not need decoding to be cut. It is a flat sequence of self-contained
//  frames, each announced by a four-byte header carrying its own bitrate and sample rate,
//  from which its exact byte length follows. Cutting is therefore finding the frame
//  boundaries and copying whole frames through. The result is bit-identical to that stretch
//  of the source, so the same file can be trimmed a hundred times without degrading.
//
//  Two details the format makes you handle:
//
//  • An ID3v2 tag may sit in front of the audio, and its length is stored as a "syncsafe"
//    integer — seven bits per byte, the top bit always clear, so the length can never
//    accidentally contain a frame sync pattern. Read it as four sevens, not four eights.
//  • The first frame is often a Xing/Info or VBRI header: a structurally valid frame that
//    holds duration and seek data instead of audio. It is skipped, because copying it into
//    a cut file would describe a length the file no longer has.
//

import Foundation

/// Reads the frame layout of an MPEG audio file without decoding it.
public enum MP3Frames {

    /// One frame's position, size and duration in the source.
    public struct Frame: Equatable, Sendable {
        /// Byte offset of the frame header in the file.
        public let offset: Int
        /// Total bytes in the frame, header included.
        public let size: Int
        /// How long the frame plays, in seconds.
        public let duration: Double
    }

    /// Layer III bitrates in kbps, indexed by the header's four-bit field.
    /// Index 0 is "free" and 15 is invalid; both are treated as unparseable.
    private static let bitratesV1: [Int] = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0]
    private static let bitratesV2: [Int] = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0]

    /// Sample rates by version, indexed by the header's two-bit field.
    private static let ratesV1: [Int]   = [44100, 48000, 32000]
    private static let ratesV2: [Int]   = [22050, 24000, 16000]
    private static let ratesV25: [Int]  = [11025, 12000, 8000]

    /// Byte offset where the audio starts, stepping over an ID3v2 tag if present.
    ///
    /// - Parameter data: The whole file.
    /// - Returns: The offset of the first candidate frame.
    public static func audioStart(in data: Data) -> Int {
        guard data.count >= 10,
              data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 else { return 0 }   // "ID3"
        // Syncsafe: four bytes, seven significant bits each, high bit always clear.
        let size = (Int(data[6]) << 21) | (Int(data[7]) << 14) | (Int(data[8]) << 7) | Int(data[9])
        let footer = (data[5] & 0x10) != 0 ? 10 : 0     // flags bit 4 means a footer is present
        return min(10 + size + footer, data.count)
    }

    /// Parses the frame at `offset`, or nil when there is no valid frame header there.
    ///
    /// - Parameters:
    ///   - data: The whole file.
    ///   - offset: Where to look.
    public static func frame(in data: Data, at offset: Int) -> Frame? {
        guard offset + 4 <= data.count else { return nil }
        let b0 = data[offset], b1 = data[offset + 1], b2 = data[offset + 2]

        // Sync is eleven set bits: all of b0, then the top three of b1.
        guard b0 == 0xFF, (b1 & 0xE0) == 0xE0 else { return nil }

        let versionBits = (b1 >> 3) & 0x03      // 0=MPEG2.5, 1=reserved, 2=MPEG2, 3=MPEG1
        let layerBits   = (b1 >> 1) & 0x03      // 1 = Layer III
        guard versionBits != 1, layerBits == 1 else { return nil }

        let bitrateIndex = Int((b2 >> 4) & 0x0F)
        let rateIndex    = Int((b2 >> 2) & 0x03)
        let padding      = Int((b2 >> 1) & 0x01)
        guard bitrateIndex > 0, bitrateIndex < 15, rateIndex < 3 else { return nil }

        let isV1 = versionBits == 3
        let bitrate = (isV1 ? bitratesV1 : bitratesV2)[bitrateIndex] * 1000
        let sampleRate = (versionBits == 3 ? ratesV1 : versionBits == 2 ? ratesV2 : ratesV25)[rateIndex]
        guard bitrate > 0, sampleRate > 0 else { return nil }

        // Layer III packs 1152 samples per frame under MPEG-1 and 576 under MPEG-2/2.5,
        // and the byte length follows from that: samples/8 × bitrate ÷ sampleRate.
        let samples = isV1 ? 1152 : 576
        let size = (samples / 8 * bitrate) / sampleRate + padding
        guard size > 4, offset + size <= data.count else { return nil }

        return Frame(offset: offset, size: size, duration: Double(samples) / Double(sampleRate))
    }

    /// Whether the frame at `offset` is a Xing/Info or VBRI header rather than audio.
    ///
    /// These sit in the first frame and hold duration and seek tables. Copying one into a
    /// trimmed file would advertise a length the file no longer has, so they are skipped.
    static func isMetadataFrame(_ data: Data, _ frame: Frame) -> Bool {
        let end = min(frame.offset + frame.size, data.count)
        // The tag sits after the side information, whose size varies; scanning the frame
        // is simpler than deriving the offset and cannot miss a layout variant.
        let window = data[frame.offset..<end]
        for marker in ["Xing", "Info", "VBRI"] {
            let bytes = Array(marker.utf8)
            if window.indices.dropLast(3).contains(where: { i in
                data[i] == bytes[0] && data[i+1] == bytes[1] && data[i+2] == bytes[2] && data[i+3] == bytes[3]
            }) { return true }
        }
        return false
    }

    /// Every audio frame in the file, in order, metadata frames excluded.
    ///
    /// Resynchronises on garbage: a byte that does not start a valid frame is skipped and
    /// the scan continues, which is how a file with a stray tag or a truncated tail still
    /// parses rather than stopping at the first surprise.
    ///
    /// - Parameter data: The whole file.
    public static func frames(in data: Data) -> [Frame] {
        var out: [Frame] = []
        var i = audioStart(in: data)
        var seenFirst = false
        while i < data.count {
            guard let f = frame(in: data, at: i) else { i += 1; continue }
            if !seenFirst, isMetadataFrame(data, f) { seenFirst = true; i += f.size; continue }
            seenFirst = true
            out.append(f)
            i += f.size
        }
        return out
    }
}
