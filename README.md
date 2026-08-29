# Silver

A strict macOS Tahoe cinema endpoint controlled from a web browser.

Silver uses one deliberately isolated private Tahoe interface from
`CoreDisplay.framework` to switch the system HDMI HDR mode for playback. It is
therefore not Mac App Store compatible and may require maintenance after macOS
updates. Resolution, refresh-rate, windowing, rendering, and media operation use
standard macOS APIs.

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
media additionally requires macOS to report an HDR-capable active display after
the switch. Tahoe high dynamic range is used only for HDR; SDR explicitly uses
standard dynamic range. Silver re-verifies exclusive fullscreen after each mode
change and terminates if another app takes the display. If any requirement cannot
be met, playback is blocked rather than shown incorrectly. The previous display
mode is restored when playback stops.

`outputModes` in `config.json` can provide explicit trusted mappings for HDMI
timings that Core Graphics reports nominally. A forced mapping may select a timing
that discovery does not identify correctly, but it never bypasses post-switch
resolution, refresh-rate, HDR/SDR, or fullscreen verification.

The output whitelist is limited to progressive HDMI presets in Sony's official
VPL-VW790ES signal table. Core Graphics reports the projector's 23.976 and 29.970
presets nominally as 24 and 30 Hz; other resolution/rate combinations are rejected
even if added to `config.json`.

## Build

```sh
Scripts/build.sh
```

The executable is written to `.build/direct/Silver`. A signed application bundle,
including the required media-runtime libraries, is written to
`.build/Silver-build.app.disabled`; rename it to `Silver.app` when installing it.

This wrapper targets the installed Tahoe SDK explicitly. It also works around a
partial Command Line Tools installation where the default `swift` compiler and
default SDK symlink have different patch versions.

To start Silver automatically at login after installing `/Applications/Silver.app`:

```sh
./Scripts/install-launch-agent.sh
```

Silver is a display-owning GUI application, so login is the earliest safe startup
point; it cannot control the projector before the macOS graphical session exists.

## Run

Copy `config.example.json` to Silver's Application Support directory, enter the
Jellyfin URL and credentials, and restrict the file to the current user:

```sh
mkdir -p "$HOME/Library/Application Support/Silver"
cp config.example.json "$HOME/Library/Application Support/Silver/config.json"
chmod 600 "$HOME/Library/Application Support/Silver/config.json"
```

Then run:

```sh
.build/direct/Silver
```

The web controller listens on all interfaces on TCP port 8099. It is intended for
a trusted home network; do not expose this port directly to the internet.

For development, Silver falls back to `config.json` in the working directory.
Set `HOME_CINEMA_CONFIG` to an absolute path to override both locations.
Configuration changes take effect on the next launch.

## Diagnostics

Silver writes timestamped logs to `~/Library/Logs/Silver/silver.log` and rotates
the previous file to `silver.old.log` at 5 MB. Display changes record the requested
media format, configured and discovered modes, selected Core Graphics mode, active
resolution and refresh rate, macOS current/potential/reference EDR values,
fullscreen verification, and fail-closed reasons. Credentials, API keys, and
complete direct-play URLs are never logged.

For HDR playback Silver dynamically resolves CoreDisplay's undocumented
`SupportsHDRMode`, `IsHDRModeEnabled`, and `SetHDRModeEnabled` functions. It saves
the original system HDR state, positively verifies every requested transition,
and restores the original state before revealing the desktop. Missing symbols,
unsupported output, failed read-back, or incorrect EDR values block playback.

Jellyfin access is mandatory. The app terminates if the configuration is missing
or invalid, authentication is rejected, the server cannot be reached, or the
initial library request fails.

The controller's Now Playing panel reports the live mpv time and duration,
play state, resolution, frame rate, HDR/SDR mode, video and audio codecs, and SRT
status. An always-visible Current Output panel reports the active HDMI pixel
resolution, refresh rate, HDR/SDR state, display name, and HDR capability. Its
timeline seeks the direct-play stream without requesting a transcode.
