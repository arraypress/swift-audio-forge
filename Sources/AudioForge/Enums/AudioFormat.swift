//
//  AudioFormat.swift
//  AudioForge
//
//  Created by David Sherlock on 2026.
//
//  What this library can read and what it can write, which are not the same list.
//
//  MEASURED: `AVAssetWriter` on macOS 27 accepts exactly these output types —
//  public.aiff-audio, public.aifc-audio, com.microsoft.waveform-audio,
//  com.apple.coreaudio-format, com.apple.m4a-audio, public.mpeg-4,
//  com.apple.quicktime-movie/audio, public.3gpp, public.3gpp2 and AMR. MP3 is not
//  among them, and asking for it raises NSInvalidArgumentException rather than
//  returning nil. Reading MP3 works everywhere: a 220s file opened as 10,569,910
//  frames at 48 kHz without complaint. So `canEncode` is a real distinction, not
//  defensive coding.
//

import Foundation

/// An audio container this library understands.
public enum AudioFormat: String, CaseIterable, Sendable {

    /// MPEG-1/2 Audio Layer III. Readable everywhere, writable nowhere — see ``canEncode``.
    case mp3
    /// MPEG-4 audio, the `.m4a` container. The default output.
    case m4a
    /// An iOS/macOS ringtone: AAC in an MPEG-4 container with a different extension.
    case m4r
    /// Uncompressed WAVE.
    case wav
    /// Uncompressed AIFF.
    case aiff
    /// Core Audio Format.
    case caf

    /// The file extension, without the dot.
    public var fileExtension: String { rawValue }

    /// The name to print at a person.
    public var displayName: String {
        switch self {
        case .mp3:  return "MP3"
        case .m4a:  return "M4A"
        case .m4r:  return "Ringtone (M4R)"
        case .wav:  return "WAV"
        case .aiff: return "AIFF"
        case .caf:  return "CAF"
        }
    }

    /// Whether this library can WRITE the format.
    ///
    /// False only for MP3, and that is a platform fact rather than a missing feature:
    /// Apple ships no MP3 encoder. Trimming an MP3 still yields an MP3, because
    /// ``MP3Frames`` copies frames rather than re-encoding them; it is *converting* to
    /// MP3 that cannot be done without an external encoder such as LAME.
    public var canEncode: Bool { self != .mp3 }

    /// The format of a file, from its extension.
    ///
    /// - Parameter url: Any file URL; only the extension is read.
    public static func of(_ url: URL) -> AudioFormat? {
        AudioFormat(rawValue: url.pathExtension.lowercased())
    }
}
