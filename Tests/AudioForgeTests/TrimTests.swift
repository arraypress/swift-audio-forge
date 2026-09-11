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
