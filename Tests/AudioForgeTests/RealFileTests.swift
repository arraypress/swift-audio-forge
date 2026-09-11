//
//  RealFileTests.swift
//  AudioForgeTests
//
//  Created by David Sherlock on 2026.
//
//  A check against a REAL file, gated on an environment variable so it never runs in CI
//  and nothing copyrighted is ever committed here.
//
//      AUDIOFORGE_MP3=/path/to/file.mp3 swift test --filter RealFile
//
//  Synthesised fixtures prove the parser against headers this repository wrote itself,
//  which is exactly the weakness: a real encoder emits padding, VBR, ID3 tags and a
//  Xing frame, and agreeing with your own generator proves none of that. This closes it.
//

import XCTest
@testable import AudioForge

final class RealFileTests: XCTestCase {

    func testParsesAndTrimsARealEncodersOutput() async throws {
        guard let path = ProcessInfo.processInfo.environment["AUDIOFORGE_MP3"] else {
            throw XCTSkip("set AUDIOFORGE_MP3 to a real .mp3 to run this")
        }
        let src = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: src, options: .mappedIfSafe)

        let frames = MP3Frames.frames(in: data)
        XCTAssertGreaterThan(frames.count, 0, "a real file must parse into frames")
        let total = frames.reduce(0) { $0 + $1.duration }
        print("  audio starts at byte \(MP3Frames.audioStart(in: data))")
        print("  \(frames.count) frames, \(String(format: "%.2f", total))s")

        // Frames must tile the file exactly: each one starts where the last ended.
        for (a, b) in zip(frames, frames.dropFirst()) {
            XCTAssertEqual(a.offset + a.size, b.offset, "frames must be contiguous")
        }

        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("audioforge-real-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: out) }
        let r = try await Trimmer.trim(src, to: out, duration: 60, overwrite: true)
        print("  trimmed to \(String(format: "%.2f", r.duration))s, \(r.byteCount) bytes, lossless=\(r.lossless)")

        XCTAssertTrue(r.lossless)
        XCTAssertGreaterThanOrEqual(r.duration, 60.0)
        XCTAssertLessThan(r.duration - 60.0, 0.03, "at most one frame past the request")
        // The output must itself parse back, which a mis-sized copy would not.
        let reparsed = MP3Frames.frames(in: try Data(contentsOf: out))
        XCTAssertGreaterThan(reparsed.count, 0, "the written file must be a valid stream")
    }
}
