//
//  TestAudio.swift
//  AudioForgeTests
//
//  Created by David Sherlock on 2026.
//
//  Synthesised fixtures. The tests build their own audio rather than checking in a
//  file: a real MP3 cannot be committed to an MIT library, and a generated one is
//  the only kind whose exact frame layout the assertions can know in advance.
//

import AVFoundation
import Foundation
@testable import AudioForge

enum TestAudio {

    /// A scratch directory for one test, removed by the caller.
    static func scratch() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("audioforge-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes `seconds` of a quiet sine to a CAF file, which AVFoundation can always write.
    @discardableResult
    static func sine(seconds: Double, at url: URL, sampleRate: Double = 44100) throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            data[i] = 0.2 * sinf(2 * .pi * 440 * Float(i) / Float(sampleRate))
        }
        try file.write(from: buffer)
        return url
    }

    /// Builds a synthetic MPEG-1 Layer III stream: `count` CBR frames at 128 kbps, 44.1 kHz.
    ///
    /// The payload is zeroes. Nothing here decodes audio, so only the headers need to be
    /// real — and building them by hand is what lets a test assert an exact frame count and
    /// an exact byte length, which a checked-in file never could.
    static func mp3Stream(frames count: Int, id3: Bool = false, xingFirst: Bool = false) -> Data {
        // 144 × 128000 ÷ 44100 = 417 bytes, no padding.
        let frameSize = 417
        var out = Data()
        if id3 {
            out.append(contentsOf: Array("ID3".utf8))
            out.append(contentsOf: [0x04, 0x00, 0x00])          // version 2.4, no flags
            out.append(contentsOf: [0x00, 0x00, 0x01, 0x00])    // syncsafe 128
            out.append(Data(repeating: 0, count: 128))
        }
        func header() -> [UInt8] {
            // FF FB 90 00 — sync, MPEG-1, Layer III, no CRC, 128 kbps, 44.1 kHz, no padding.
            [0xFF, 0xFB, 0x90, 0x00]
        }
        if xingFirst {
            var f = Data(header())
            f.append(Data(repeating: 0, count: 32))
            f.append(contentsOf: Array("Xing".utf8))
            f.append(Data(repeating: 0, count: frameSize - f.count))
            out.append(f)
        }
        for _ in 0..<count {
            var f = Data(header())
            f.append(Data(repeating: 0, count: frameSize - 4))
            out.append(f)
        }
        return out
    }

    /// One MPEG-1 Layer III frame at 128 kbps / 44.1 kHz plays for this long.
    static let frameDuration = 1152.0 / 44100.0     // ≈ 0.026122 s
}
