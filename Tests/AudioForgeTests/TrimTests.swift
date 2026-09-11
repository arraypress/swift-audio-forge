//
//  TrimTests.swift
//  AudioForgeTests
//
//  Created by David Sherlock on 2026.
//
//  The two roads, and the promise each makes. The copy road must produce bytes identical
//  to the source's, because that is the whole reason it exists; the decode road must be
//  sample-accurate. The refusals matter as much: writing AAC into a file named .mp3 would
//  be worse than failing, because nothing downstream would notice.
//

import AVFoundation
import XCTest
@testable import AudioForge

final class TrimTests: XCTestCase {

    private var dir = URL(fileURLWithPath: "/tmp")

    override func setUp() { super.setUp(); dir = TestAudio.scratch() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir); super.tearDown() }

    // MARK: - The copy road

    func testTrimmingAnMP3KeepsMP3AndCopiesBytesExactly() async throws {
        let src = dir.appendingPathComponent("in.mp3")
        try TestAudio.mp3Stream(frames: 100).write(to: src)      // ≈ 2.61 s
        let out = dir.appendingPathComponent("out.mp3")

        let r = try await Trimmer.trim(src, to: out, start: 0, duration: 1.0)
        XCTAssertTrue(r.lossless, "mp3 → mp3 must never decode")

        // 1.0 s at 1152 samples / 44100 Hz is 38.3 frames, so 39 are kept.
        XCTAssertEqual(r.byteCount, 39 * 417)
        XCTAssertEqual(r.duration, 39 * TestAudio.frameDuration, accuracy: 1e-9)

        // Bit-identical to that stretch of the source: the point of the copy road.
        let source = try Data(contentsOf: src), written = try Data(contentsOf: out)
        XCTAssertEqual(written, source.prefix(39 * 417))
    }

    func testTheCutLandsOnAFrameBoundaryAtOrPastTheRequest() async throws {
        let src = dir.appendingPathComponent("in.mp3")
        try TestAudio.mp3Stream(frames: 100).write(to: src)
        let out = dir.appendingPathComponent("out.mp3")
        let r = try await Trimmer.trim(src, to: out, duration: 1.0)
        XCTAssertGreaterThanOrEqual(r.duration, 1.0, "never short of the request")
        XCTAssertLessThan(r.duration - 1.0, TestAudio.frameDuration, "never more than one frame over")
    }

    func testTrimmingFromAStartOffsetDropsTheLeadingFrames() async throws {
        let src = dir.appendingPathComponent("in.mp3")
        try TestAudio.mp3Stream(frames: 100).write(to: src)
        let out = dir.appendingPathComponent("out.mp3")
        let r = try await Trimmer.trim(src, to: out, start: 1.0, duration: 1.0)
        XCTAssertTrue(r.lossless)
        XCTAssertGreaterThan(r.byteCount, 0)
        XCTAssertLessThan(r.byteCount, 100 * 417, "the whole file is not the answer")
    }

    // MARK: - Refusals

    func testConvertingToMP3IsRefusedRatherThanWrittenAsAAC() async throws {
        let src = dir.appendingPathComponent("in.caf")
        try TestAudio.sine(seconds: 2, at: src)
        do {
            _ = try await Trimmer.trim(src, to: dir.appendingPathComponent("out.mp3"), duration: 1)
            XCTFail("expected a refusal")
        } catch let error as AudioForgeError {
            XCTAssertEqual(error, .unsupportedOutput(.mp3))
            XCTAssertTrue("\(error)".contains("do not encode it"), "the message must say why")
        }
    }

    func testAnExistingDestinationIsNotClobberedByDefault() async throws {
        let src = dir.appendingPathComponent("in.mp3")
        try TestAudio.mp3Stream(frames: 10).write(to: src)
        let out = dir.appendingPathComponent("out.mp3")
        try Data("existing".utf8).write(to: out)
        do {
            _ = try await Trimmer.trim(src, to: out, duration: 0.1)
            XCTFail("expected a refusal")
        } catch let error as AudioForgeError {
            XCTAssertEqual(error, .destinationExists(out))
        }
        _ = try await Trimmer.trim(src, to: out, duration: 0.1, overwrite: true)
        XCTAssertNotEqual(try Data(contentsOf: out), Data("existing".utf8))
    }

    func testARangeBeyondTheFileIsRefused() async throws {
        let src = dir.appendingPathComponent("in.mp3")
        try TestAudio.mp3Stream(frames: 10).write(to: src)     // ≈ 0.26 s
        do {
            _ = try await Trimmer.trim(src, to: dir.appendingPathComponent("o.mp3"), start: 60)
            XCTFail("expected a refusal")
        } catch let error as AudioForgeError {
            guard case .rangeOutOfBounds = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testAnUnreadableSourceIsRefused() async throws {
        do {
            _ = try await Trimmer.trim(dir.appendingPathComponent("nope.mp3"),
                                       to: dir.appendingPathComponent("o.mp3"))
            XCTFail("expected a refusal")
        } catch let error as AudioForgeError {
            guard case .unreadable = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    // MARK: - The decode road

    func testTrimmingToM4AReEncodesAndIsSampleAccurate() async throws {
        let src = dir.appendingPathComponent("in.caf")
        try TestAudio.sine(seconds: 3, at: src)
        let out = dir.appendingPathComponent("out.m4a")
        let r = try await Trimmer.trim(src, to: out, start: 0.5, duration: 1.0)
        XCTAssertFalse(r.lossless, "a format change cannot be lossless")
        XCTAssertEqual(r.duration, 1.0, accuracy: 0.05)
        XCTAssertGreaterThan(r.byteCount, 0)
    }

    func testARingtoneIsAACInAnMPEG4ContainerNamedM4R() async throws {
        let src = dir.appendingPathComponent("in.caf")
        try TestAudio.sine(seconds: 5, at: src)
        let out = dir.appendingPathComponent("ring.m4r")
        let r = try await Trimmer.trim(src, to: out, duration: 3)
        XCTAssertEqual(out.pathExtension, "m4r")
        XCTAssertEqual(r.duration, 3.0, accuracy: 0.05)
        // It must be a real MPEG-4 file, not merely renamed.
        let written = AVURLAsset(url: out)
        let tracks = try await written.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
    }
}

// MARK: - Uncompressed output

/// The formats that must NOT go through an export session.
///
/// `AVAssetExportPresetAppleM4A` supports only `com.apple.m4a-audio` and
/// `com.apple.quicktime-audio`; handing `setOutputFileType:` a WAV type raises
/// an Objective-C exception, which in Swift is not a thrown error but a dead
/// process. These cases would have caught that, and did not exist when it
/// shipped — the crash was found by pointing a CLI at a real MP3.
final class PCMExportTests: XCTestCase {

    /// A real two-second sine in a WAV, written through AVAudioFile.
    ///
    /// Not ``TestAudio/mp3Stream(frames:)``: those frames carry valid MPEG
    /// headers over an empty payload, which is exactly right for testing the
    /// frame parser and gives a decoder nothing to produce. Measuring what
    /// comes out the far end of a decode needs audio that actually decodes.
    private func sineSource() throws -> URL {
        let rate = 44_100.0
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-pcm-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ])
        let frames = AVAudioFrameCount(rate * 2)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let step = 2 * Double.pi * 440 / rate
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = Float(sin(step * Double(i)))
        }
        try file.write(from: buffer)
        return url
    }

    private func trim(to ext: String) async throws -> TrimResult {
        let source = try sineSource()
        defer { try? FileManager.default.removeItem(at: source) }
        // A distinct base name: the source is itself a .wav, so reusing it
        // would ask the trimmer to overwrite the file it is reading.
        let destination = source.deletingLastPathComponent()
            .appendingPathComponent("out-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        return try await Trimmer.trim(source, to: destination, start: 0, duration: 1, overwrite: true)
    }

    func testWritesWavWithoutCrashing() async throws {
        let result = try await trim(to: "wav")
        defer { try? FileManager.default.removeItem(at: result.url) }
        XCTAssertGreaterThan(result.byteCount, 0)
        XCTAssertFalse(result.lossless, "PCM output is decoded and re-encoded")
        XCTAssertGreaterThan(result.duration, 0)
    }

    func testWritesAiffAndCaf() async throws {
        for ext in ["aiff", "caf"] {
            let result = try await trim(to: ext)
            defer { try? FileManager.default.removeItem(at: result.url) }
            XCTAssertGreaterThan(result.byteCount, 0, "\(ext) produced an empty file")
        }
    }

    func testTheWrittenFileIsReadableAudio() async throws {
        // A file that exists and cannot be opened is the failure this misses if
        // it only checks the byte count.
        let result = try await trim(to: "wav")
        defer { try? FileManager.default.removeItem(at: result.url) }
        let file = try AVAudioFile(forReading: result.url)
        XCTAssertGreaterThan(file.length, 0)
        XCTAssertEqual(file.processingFormat.sampleRate, 44_100, accuracy: 1)
    }
}
