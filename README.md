# Swift Audio Forge

Trim, convert and cut up audio — offline, on-device, no vendored codecs and no `ffmpeg`.
Pure AVFoundation and Accelerate, so nothing ships alongside your binary and nothing
phones home.

The audio sibling of [swift-video-forge](https://github.com/arraypress/swift-video-forge).

```swift
import AudioForge

// Trim an MP3. Stays MP3, copies frames, loses nothing.
let cut = try await Trimmer.trim(song, to: clip, start: 30, duration: 60)
cut.lossless        // true
cut.duration        // 60.01 — the nearest frame boundary

// Make a ringtone. AAC in an MPEG-4 container, which is all a .m4r is.
try await Trimmer.trim(song, to: ring, duration: 30)
```

## Two roads

**The copy road.** MP3 in, MP3 out: whole frames are copied through, nothing is decoded,
and the output is byte-identical to that stretch of the source. Trim the same file a
hundred times and it is still the original audio. A cut can only land on a frame boundary,
so a result may run up to one frame long — about 26 ms at 44.1 kHz.

**The decode road.** Everything else: a time-ranged `AVAssetExportSession`, sample-exact
and re-encoded. Used for format changes and for sample-accurate cuts of non-MP3 sources.

`TrimResult.lossless` says which one ran, because a caller building a pipeline needs to
know whether it just spent a generation.

## Measured

**Apple decodes MP3 and does not encode it.** `AVAudioFile` opened a 220-second MP3 as
10,569,910 frames at 48 kHz without complaint. `AVAssetWriter` accepts AIFF, AIFC, WAV,
CAF, M4A, MPEG-4, QuickTime, 3GPP and AMR — and raises `NSInvalidArgumentException`, rather
than returning nil, when asked for MP3.

That asymmetry is the whole design. Trimming an MP3 by the obvious route — decode, cut,
re-encode — cannot produce an MP3 at the other end, only AAC. So trimming does not decode
at all: an MP3 is a flat sequence of self-contained frames, each header carrying the
bitrate and sample rate from which its exact byte length follows, and cutting is finding
the boundaries and copying whole frames.

Two details the format makes you handle, both covered by tests:

- An ID3v2 tag may precede the audio, and its length is stored **syncsafe** — seven bits
  per byte, so the length can never contain a frame sync pattern. Read four sevens, not
  four eights, or every offset after it is wrong.
- The first frame is often a **Xing/Info or VBRI header**: structurally a valid frame, but
  it holds duration and seek data rather than audio. It is skipped, because copying it into
  a cut file would advertise a length the file no longer has.

## What it does not do

- **Write MP3.** Not a missing feature, a platform fact. Converting *to* MP3 is refused
  with an error that says why, rather than silently written as AAC. If you need it, link
  LAME yourself and keep that licence question in one place.
- **Decode anything by hand.** The frame parser reads headers and never touches a sample.
- **Replace ffmpeg.** ffmpeg covers hundreds of formats and carries a licence question
  depending on build flags. This covers what Apple platforms actually produce, with nothing
  to ship and nothing to install.

## Requirements

- macOS 14+, iOS 17+
- Swift 6.2+ (Swift 6 language mode)

## License

MIT
