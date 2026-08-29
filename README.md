# Silver

A strict macOS Tahoe cinema endpoint controlled from a web browser.

The Mac has no local library UI. It opens full-screen on a black screen showing
`home cinema`, and exposes its controller on port **8099**. Jellyfin connection
details come from `config.json`; the browser contains no credential form.

## Supported playback profile

- macOS Tahoe 26 or newer
- Apple M2 Ultra (the target Mac Studio) or newer
- AV1 video
- FLAC audio
- SRT subtitles
- MP4/M4V/MOV and MKV direct delivery
- Jellyfin Direct Play only

There is no H.264, HEVC/H.265, server remux, video transcoding, or audio conversion.
On this M2 Ultra, the app uses Jellyfin Desktop's installed libmpv/libavformat and
libdav1d runtime for MKV demuxing and software AV1 decoding. Jellyfin's `SUBRIP`
codec name is accepted as SRT. Other incompatible items remain
visible in the web library with their incompatibility reason.

The M2 Ultra has no dedicated AV1 hardware decoder. Tahoe's AVFoundation decoder
therefore performs AV1 decoding in software while Jellyfin still Direct Plays the
original, unchanged stream. The target machine's 24-core M2 Ultra is the baseline.

Playback is gated on exact output matching. The app requires a display mode with
the media's exact pixel dimensions and a refresh rate that is an integer multiple
of its declared frame rate, then verifies the active mode after switching. HDR
media additionally requires an HDR-capable active display. Tahoe high dynamic
range is used only for HDR; SDR explicitly uses standard dynamic range. If any
requirement cannot be met, playback is blocked rather than shown incorrectly. The
previous display mode is restored when playback stops.

`outputModes` in `config.json` can provide explicit trusted mappings for HDMI
timings that Core Graphics reports nominally. A forced mapping bypasses cadence
and HDR-capability discovery only for an exact media resolution, frame rate, and
dynamic range tuple; macOS must still successfully apply and report the configured
output resolution and nominal refresh rate.

The output whitelist is limited to progressive HDMI presets in Sony's official
VPL-VW790ES signal table. Core Graphics reports the projector's 23.976 and 29.970
presets nominally as 24 and 30 Hz; other resolution/rate combinations are rejected
even if added to `config.json`.

## Build

```sh
Scripts/build.sh
```

The executable is written to `.build/direct/Silver`.

This wrapper targets the installed Tahoe SDK explicitly. It also works around a
partial Command Line Tools installation where the default `swift` compiler and
default SDK symlink have different patch versions.

## Run

Copy `config.example.json` to `config.json`, enter the Jellyfin URL and credentials,
and restrict the file to the current user:

```sh
cp config.example.json config.json
chmod 600 config.json
```

Then run:

```sh
.build/direct/Silver
```

The web controller listens on all interfaces on TCP port 8099. It is intended for
a trusted home network; do not expose this port directly to the internet.

Set `HOME_CINEMA_CONFIG` to an absolute path to use a configuration file outside
the working directory. Configuration changes take effect on the next launch.

Jellyfin access is mandatory. The app terminates if the configuration is missing
or invalid, authentication is rejected, the server cannot be reached, or the
initial library request fails.

The controller's Now Playing panel reports the live AVPlayer time and duration,
play state, resolution, frame rate, HDR/SDR mode, video and audio codecs, and SRT
status. Its timeline seeks the direct-play stream without requesting a transcode.
