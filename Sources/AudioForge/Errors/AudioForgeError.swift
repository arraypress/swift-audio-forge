//
//  AudioForgeError.swift
//  AudioForge
//
//  Created by David Sherlock on 2026.
//
//  Every way a job can refuse, said in terms the caller can act on. A CLI prints
//  these straight to the user, so each one names the file or the value that was
//  wrong rather than the function that noticed.
//

import Foundation

/// Why a job could not be done.
public enum AudioForgeError: Error, Equatable, CustomStringConvertible {

    /// The file could not be read at all.
    case unreadable(URL)

    /// The file is not audio this library can open.
    case unsupportedInput(URL)

    /// The requested output format cannot be written on this platform.
    ///
    /// The common case is MP3: Apple's frameworks decode it everywhere and encode it
    /// nowhere, so an MP3 output is refused rather than silently written as AAC.
    case unsupportedOutput(AudioFormat)

    /// The time range asked for does not exist in the source.
    case rangeOutOfBounds(requested: ClosedRange<Double>, duration: Double)

    /// The source has no audio track.
    case noAudioTrack(URL)

    /// The export failed. Carries the underlying reason, which is usually AVFoundation's.
    case exportFailed(String)

    /// A file already exists at the destination and overwriting was not allowed.
    case destinationExists(URL)

    public var description: String {
        switch self {
        case .unreadable(let url):
            return "Cannot read \(url.lastPathComponent)."
        case .unsupportedInput(let url):
            return "\(url.lastPathComponent) is not an audio file this can open."
        case .unsupportedOutput(let format):
            return format == .mp3
                ? "MP3 cannot be written: Apple's frameworks decode MP3 but do not encode it. "
                  + "Trimming an MP3 keeps MP3 (frames are copied); converting to MP3 needs an external encoder."
                : "\(format.displayName) cannot be written on this platform."
        case .rangeOutOfBounds(let requested, let duration):
            return String(format: "Range %.2fs–%.2fs is outside the file's %.2fs.",
                          requested.lowerBound, requested.upperBound, duration)
        case .noAudioTrack(let url):
            return "\(url.lastPathComponent) has no audio track."
        case .exportFailed(let reason):
            return "Export failed: \(reason)"
        case .destinationExists(let url):
            return "\(url.lastPathComponent) already exists."
        }
    }
}
