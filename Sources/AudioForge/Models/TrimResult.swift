//
//  TrimResult.swift
//  AudioForge
//
//  Created by David Sherlock on 2026.
//
//  What a trim actually produced, which is not always what was asked for. An MP3
//  cut lands on a frame boundary and a decoded export lands on a sample, so the
//  caller is told the real duration rather than being left to assume.
//

import Foundation

/// What a completed trim produced.
public struct TrimResult: Equatable, Sendable {

    /// Where the file was written.
    public let url: URL

    /// The duration actually written, in seconds.
    ///
    /// For a frame-copied MP3 this is the nearest frame boundary at or past the
    /// requested end, so it can exceed the request by up to one frame — about 26 ms
    /// at 44.1 kHz, 24 ms at 48 kHz. For every other format it is sample-exact.
    public let duration: Double

    /// Whether the audio was copied rather than decoded and re-encoded.
    ///
    /// True means the output is bit-identical to that stretch of the source, so a
    /// trim can be repeated forever without generation loss.
    public let lossless: Bool

    /// Bytes written.
    public let byteCount: Int

    /// Creates a result.
    public init(url: URL, duration: Double, lossless: Bool, byteCount: Int) {
        self.url = url
        self.duration = duration
        self.lossless = lossless
        self.byteCount = byteCount
    }
}
