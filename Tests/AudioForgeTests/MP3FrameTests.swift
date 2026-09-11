//
//  MP3FrameTests.swift
//  AudioForgeTests
//
//  Created by David Sherlock on 2026.
//
//  The frame parser, which is the only part of this library that reads a byte layout by
//  hand. Every case here exists because getting it wrong produces a file that is subtly
//  wrong rather than obviously broken: a stale ID3 length shifts every offset, a mis-read
//  syncsafe integer lands mid-frame, and a copied Xing header advertises a duration the
//  file no longer has.
//

import XCTest
@testable import AudioForge

final class MP3FrameTests: XCTestCase {

    func testParsesAKnownFrameHeaderExactly() {
        let data = TestAudio.mp3Stream(frames: 1)
        let frame = MP3Frames.frame(in: data, at: 0)
        XCTAssertNotNil(frame)
        // 144 × 128000 ÷ 44100 = 417, and MPEG-1 Layer III is 1152 samples a frame.
        XCTAssertEqual(frame?.size, 417)
        XCTAssertEqual(frame?.duration ?? 0, TestAudio.frameDuration, accuracy: 1e-9)
    }

    func testCountsEveryFrameInAStream() {
        XCTAssertEqual(MP3Frames.frames(in: TestAudio.mp3Stream(frames: 40)).count, 40)
    }

    func testStepsOverAnID3v2Tag() {
        let data = TestAudio.mp3Stream(frames: 10, id3: true)
        // 10 bytes of header plus the 128 the syncsafe length declares.
        XCTAssertEqual(MP3Frames.audioStart(in: data), 138)
        XCTAssertEqual(MP3Frames.frames(in: data).count, 10)
        XCTAssertEqual(MP3Frames.frames(in: data).first?.offset, 138)
    }

    func testSkipsAXingHeaderFrame() {
        let data = TestAudio.mp3Stream(frames: 10, xingFirst: true)
        // Eleven structurally valid frames; ten of them are audio.
        XCTAssertEqual(MP3Frames.frames(in: data).count, 10,
                       "the Xing frame carries seek data, not audio, and must not be copied")
    }

    func testRejectsHeadersThatAreNotLayerThree() {
        // FF FB is Layer III; FF FD sets the layer bits to Layer II.
        var data = TestAudio.mp3Stream(frames: 1)
        data[1] = 0xFD
        XCTAssertNil(MP3Frames.frame(in: data, at: 0))
    }

    func testRejectsFreeAndInvalidBitrates() {
        for nibble: UInt8 in [0x00, 0xF0] {          // index 0 = free, 15 = invalid
            var data = TestAudio.mp3Stream(frames: 1)
            data[2] = nibble | (data[2] & 0x0F)
            XCTAssertNil(MP3Frames.frame(in: data, at: 0), "bitrate nibble \(nibble) must not parse")
        }
    }

    func testResynchronisesAfterGarbage() {
        var data = Data([0x00, 0x11, 0x22, 0x33, 0x44])      // junk with no sync word
        data.append(TestAudio.mp3Stream(frames: 5))
        XCTAssertEqual(MP3Frames.frames(in: data).count, 5,
                       "a stray prefix must be skipped, not stop the scan")
    }

    func testATruncatedFinalFrameIsNotReported() {
        var data = TestAudio.mp3Stream(frames: 3)
        data.removeLast(200)                                  // cut the third frame in half
        XCTAssertEqual(MP3Frames.frames(in: data).count, 2,
                       "a frame that runs past the end of the file is not a frame")
    }

    func testEmptyAndTinyInputsAreSafe() {
        XCTAssertTrue(MP3Frames.frames(in: Data()).isEmpty)
        XCTAssertTrue(MP3Frames.frames(in: Data([0xFF])).isEmpty)
        XCTAssertNil(MP3Frames.frame(in: Data([0xFF, 0xFB]), at: 0))
    }
}
