//
//  Trimmer.swift
//  AudioForge
//
//  Created by David Sherlock on 2026.
//
//  Cutting a section out of an audio file, by whichever of two roads keeps the most.
//
//  THE COPY ROAD. Source and destination both MP3: whole frames are copied through by
//  `MP3Frames`, nothing is decoded, and the output is bit-identical to that stretch of the
//  input. A file can be trimmed repeatedly with no generation loss. The cost is that a cut
//  can only land on a frame boundary, so the result may run up to one frame long — about
//  26 ms at 44.1 kHz, 24 ms at 48 kHz.
//
//  THE DECODE ROAD. Everything else: `AVAssetExportSession` over a time range, which is
//  sample-exact and re-encodes. Used for every format conversion and for sample-accurate
//  cuts of non-MP3 sources.
//
//  The roads are chosen, never mixed, and `TrimResult.lossless` says which one ran, because
//  a caller building a pipeline needs to know whether it just spent a generation.
//

import AVFoundation
import Foundation

/// Cuts a section out of an audio file.
public enum Trimmer {

    /// Trims `source` into `destination`.
    ///
    /// The road is chosen from the two extensions: MP3 in and MP3 out copies frames,
    /// anything else decodes and re-encodes. Converting *to* MP3 is refused rather than
    /// silently written as AAC — see ``AudioFormat/canEncode``.
    ///
    /// - Parameters:
    ///   - source: The file to read.
    ///   - destination: Where to write. Its extension chooses the output format.
    ///   - start: Seconds from the beginning of the source. Defaults to 0.
    ///   - duration: How many seconds to keep, or nil for "to the end".
    ///   - overwrite: Whether an existing destination may be replaced. Defaults to false.
    /// - Returns: What was actually written, including the real duration.
    @discardableResult
    public static func trim(_ source: URL,
                            to destination: URL,
                            start: Double = 0,
                            duration: Double? = nil,
                            overwrite: Bool = false) async throws -> TrimResult {
        guard FileManager.default.isReadableFile(atPath: source.path) else {
            throw AudioForgeError.unreadable(source)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            guard overwrite else { throw AudioForgeError.destinationExists(destination) }
            try FileManager.default.removeItem(at: destination)
        }
        guard let outFormat = AudioFormat.of(destination) else {
            throw AudioForgeError.unsupportedInput(destination)
        }
        let inFormat = AudioFormat.of(source)

        if inFormat == .mp3 && outFormat == .mp3 {
            return try copyFrames(source, to: destination, start: start, duration: duration)
        }
        guard outFormat.canEncode else { throw AudioForgeError.unsupportedOutput(outFormat) }

        // Two different writers, because one API cannot do both. PCM containers
        // go through AVAudioFile; an export session refuses them at runtime with
        // an uncatchable exception — see ``exportPCM``.
        switch outFormat {
        case .wav, .caf:
            return try exportPCM(source, to: destination, start: start, duration: duration,
                                 bigEndian: false)
        case .aiff:
            return try exportPCM(source, to: destination, start: start, duration: duration,
                                 bigEndian: true)
        case .m4a, .m4r:
            return try await export(source, to: destination, start: start, duration: duration,
                                    format: outFormat)
        case .mp3:
            // Unreachable: mp3→mp3 took the copy road above, and canEncode is
            // false for mp3, so the guard has already thrown.
            throw AudioForgeError.unsupportedOutput(outFormat)
        }
    }

    // MARK: - The copy road

    /// MP3 to MP3: copies whole frames, decoding nothing.
    private static func copyFrames(_ source: URL,
                                   to destination: URL,
                                   start: Double,
                                   duration: Double?) throws -> TrimResult {
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        let frames = MP3Frames.frames(in: data)
        guard !frames.isEmpty else { throw AudioForgeError.unsupportedInput(source) }

        let total = frames.reduce(0) { $0 + $1.duration }
        let end = duration.map { start + $0 } ?? total
        guard start >= 0, start < total else {
            // `end` is below `start` whenever the start is past the file, and a ClosedRange
            // traps on that rather than reporting it — the bug this guard is here to report.
            throw AudioForgeError.rangeOutOfBounds(requested: start...max(start, end), duration: total)
        }

        // Walk the frames accumulating time. A frame is kept when any part of it falls
        // inside the window, so the cut lands on the boundary at or past the request
        // rather than clipping the last frame short.
        var out = Data()
        var elapsed = 0.0, kept = 0.0
        for f in frames {
            let frameEnd = elapsed + f.duration
            if frameEnd > start && elapsed < end {
                out.append(data[f.offset..<(f.offset + f.size)])
                kept += f.duration
            }
            elapsed = frameEnd
            if elapsed >= end { break }
        }
        try out.write(to: destination, options: .atomic)
        return TrimResult(url: destination, duration: kept, lossless: true, byteCount: out.count)
    }

    // MARK: - The decode road

    /// Uncompressed output: read the samples and write them straight out.
    ///
    /// `AVAssetExportSession` CANNOT do this, and finding that out at runtime is
    /// ugly: `AVAssetExportPresetAppleM4A` supports exactly two output types —
    /// `com.apple.m4a-audio` and `com.apple.quicktime-audio` — and handing
    /// `setOutputFileType:` anything else raises an Objective-C exception that
    /// `try`/`catch` cannot see, so the process dies rather than throwing. (The
    /// full list in ``AudioFormat`` was measured against `AVAssetWriter`, which
    /// is a different class; the code used an export session.) PCM belongs to
    /// `AVAudioFile` anyway, which writes the container the extension names.
    ///
    /// Output is 16-bit: universal, what every DAW and sampler expects, and a
    /// truthful ceiling for a source that was lossy to begin with.
    private static func exportPCM(_ source: URL,
                                  to destination: URL,
                                  start: Double,
                                  duration: Double?,
                                  bigEndian: Bool) throws -> TrimResult {
        let input = try AVAudioFile(forReading: source)
        let processing = input.processingFormat
        let rate = processing.sampleRate
        guard rate > 0, input.length > 0 else { throw AudioForgeError.noAudioTrack(source) }

        let total = Double(input.length) / rate
        let end = duration.map { min(start + $0, total) } ?? total
        guard start >= 0, start < total, end > start else {
            throw AudioForgeError.rangeOutOfBounds(requested: start...max(start, end), duration: total)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: processing.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: bigEndian,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // The writer lives in its own scope so it is released — and the file
        // finalised — before anything measures the result. AVAudioFile flushes
        // its header on deinit, so reading the destination while the writer is
        // still alive reports a file of zero frames, which reads exactly like a
        // silent export and is not one.
        var writtenFrames: AVAudioFramePosition = 0
        do {
            let output = try AVAudioFile(forWriting: destination, settings: settings)
            input.framePosition = AVAudioFramePosition(start * rate)
            var remaining = AVAudioFrameCount(((end - start) * rate).rounded())
            let chunk: AVAudioFrameCount = 8192
            guard let buffer = AVAudioPCMBuffer(pcmFormat: processing, frameCapacity: chunk) else {
                throw AudioForgeError.exportFailed("could not allocate a \(chunk)-frame buffer")
            }
            while remaining > 0 {
                try input.read(into: buffer, frameCount: min(chunk, remaining))
                guard buffer.frameLength > 0 else { break }   // short file; take what is there
                try output.write(from: buffer)
                remaining -= buffer.frameLength
            }
            writtenFrames = output.length
        }

        let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
        return TrimResult(url: destination,
                          duration: Double(writtenFrames) / rate,
                          lossless: false,
                          byteCount: bytes)
    }

    /// Compressed output: a time-ranged export, sample-exact and re-encoded.
    private static func export(_ source: URL,
                               to destination: URL,
                               start: Double,
                               duration: Double?,
                               format: AudioFormat) async throws -> TrimResult {
        let asset = AVURLAsset(url: source)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw AudioForgeError.noAudioTrack(source)
        }
        let total = try await CMTimeGetSeconds(asset.load(.duration))
        let end = duration.map { min(start + $0, total) } ?? total
        guard start >= 0, start < total, end > start else {
            throw AudioForgeError.rangeOutOfBounds(requested: start...max(start, end), duration: total)
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioForgeError.exportFailed("no export session for \(source.lastPathComponent)")
        }
        let scale: CMTimeScale = 600
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: scale),
                                        duration: CMTime(seconds: end - start, preferredTimescale: scale))
        // A ringtone is AAC in an MPEG-4 container; only the extension differs, so the
        // writer is told m4a and the file is simply named .m4r.
        // Always .m4a: this path only ever handles m4a and m4r, and an m4r IS an
        // m4a with a different extension. Handing this preset any other type
        // raises an Objective-C exception rather than throwing.
        do {
            try await session.export(to: destination, as: .m4a)
        } catch {
            throw AudioForgeError.exportFailed(error.localizedDescription)
        }
        let written = AVURLAsset(url: destination)
        let realDuration = try await CMTimeGetSeconds(written.load(.duration))
        let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
        return TrimResult(url: destination, duration: realDuration, lossless: false, byteCount: bytes)
    }
}
