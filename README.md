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
An optional YouTube tab reads Zorg's authenticated download catalogue and sends
selected videos directly to the same strict full-screen playback path. Zorg's
byte-range endpoint supports seeking without downloading the entire file first.
The Control tab can operate one explicitly configured Loxone `Switch`. In the
house configuration this is the existing `Projector Power` control; the browser
can send only its fixed `on` and `off` commands.

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

The post-start synchronization check derives its expected speed correction from
mpv's decoded frame rate rather than rounded catalogue metadata. Thus 24000/1001
material reported as 24 fps correctly expects the approximately 1.001x correction
needed by a nominal 24 Hz HDMI mode. While media is playing, the Status tab shows
the declared and decoded source frame rates alongside the expected and actual
mpv speed corrections, each at nine-decimal precision.

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

Every commit pushed to `main` is also built on GitHub's Apple-silicon macOS Tahoe
runner. The `Silver-macos-arm64` Actions artifact contains an ad-hoc signed
`Silver.app` and its SHA-256 checksum. The CI bundle loads the media runtime from
an installed Jellyfin Desktop 2.0.0, as described above; local builds additionally
embed that installation's runtime dylibs in the bundle.

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

Loxone control is optional. Set `loxoneURL`, `loxoneUsername`, `loxonePassword`,
and `projectorPowerUUID` together to enable it. Set `amplifierVolumeUUID` to show
the current Lounge/Zone 1 amplifier volume and provide fixed 2-point Volume Down
and Volume Up controls. Silver accepts only an HTTPS Miniserver URL and sends
credentials only in its TLS-protected request. Keep the configuration mode
`0600`; a dedicated Loxone user restricted to these controls is preferable to an
administrator account.

On first use, macOS may ask whether Silver can access devices on the local
network. Allow this access so Silver can reach the Loxone Miniserver.

Then run:

```sh
.build/direct/Silver
```

The web controller listens on all interfaces on TCP port 8099. It is intended for
a trusted home network; do not expose this port directly to the internet.
The YouTube tab displays each downloaded video's source channel from Zorg's
stored yt-dlp metadata.

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

At startup Silver authenticates with Jellyfin but does not download or retain its
catalogue. The idle projector screen shows only the `home cinema` title and web
controller URL; it does not enumerate output modes or catalogue-derived counts.

Library requests are proxied directly from the web controller to Jellyfin using
Jellyfin's `StartIndex`, `Limit`, and `SearchTerm` parameters. The browser requests
at most 100 summary records per page and loads additional pages only on demand.
Selecting an item makes a separate Jellyfin request for its full media details.
Neither Silver nor the browser downloads the complete catalogue. **Reload now**
simply fetches the current search page from Jellyfin again.

The controller's Now Playing panel reports the live mpv time and duration,
play state, resolution, frame rate, HDR/SDR mode, video and audio codecs, and SRT
status. An always-visible Current Output panel reports the active HDMI pixel
resolution, refresh rate, HDR/SDR state, display name, and HDR capability. Its
timeline seeks the direct-play stream without requesting a transcode.

Silver holds playback paused after every HDMI mode change and exact seek until
mpv has configured video output, decoded a frame at the requested timestamp, and
buffered at least three seconds of demuxed input. Audio and video are then
released together. A prebuffer that cannot satisfy those conditions within 15
seconds fails closed instead of starting with an uncontrolled lip-sync offset.
Every start and seek receives a monotonically increasing generation token; stop,
replacement, or a newer seek invalidates older waits so stale asynchronous work
can never release audio for the current playback.

The compressed demux cache permits 1 GiB forward and 256 MiB backward. The
asynchronous decoded-video queue permits 48 frames, two seconds, or 1536 MiB,
whichever limit is reached first. At 23.976 fps this provides approximately two
seconds of decoded-video headroom while leaving ample memory on the dedicated
64 GiB cinema endpoint.
