import Foundation

@main
enum PlaybackPrebufferTests {
    static func main() {
        var generations = PlaybackOperationGeneration()
        let first = generations.advance()
        check(generations.isCurrent(first), "new generation should be current")
        let second = generations.advance()
        check(!generations.isCurrent(first), "older generation should be superseded")
        check(generations.isCurrent(second), "latest generation should remain current")
        check(
            PlaybackPrebufferSample(
                videoOutputConfigured: true,
                videoFormatAvailable: true,
                decodedFrameRate: 23.976,
                position: 120.2,
                demuxedSeconds: 8,
                reachedEndOfFile: false
            ).isReady(expectedPosition: 120, minimumDemuxedSeconds: 3),
            "ready decoded video should be accepted"
        )
        check(
            !PlaybackPrebufferSample(
                videoOutputConfigured: true,
                videoFormatAvailable: true,
                decodedFrameRate: nil,
                position: 0,
                demuxedSeconds: 30,
                reachedEndOfFile: false
            ).isReady(expectedPosition: nil, minimumDemuxedSeconds: 3),
            "output without a decoded frame should be rejected"
        )
        check(
            !PlaybackPrebufferSample(
                videoOutputConfigured: true,
                videoFormatAvailable: true,
                decodedFrameRate: 23.976,
                position: 118,
                demuxedSeconds: 8,
                reachedEndOfFile: false
            ).isReady(expectedPosition: 120, minimumDemuxedSeconds: 3),
            "seek should reach the requested timestamp"
        )
        check(
            PlaybackPrebufferSample(
                videoOutputConfigured: true,
                videoFormatAvailable: true,
                decodedFrameRate: 23.976,
                position: 0,
                demuxedSeconds: 0.5,
                reachedEndOfFile: true
            ).isReady(expectedPosition: nil, minimumDemuxedSeconds: 3),
            "a short file at EOF should not require three cached seconds"
        )
        let cinemaRate = 24_000.0 / 1_001.0
        check(
            abs(DisplaySynchronization.expectedCorrection(
                declaredFrameRate: 24,
                decodedFrameRate: cinemaRate,
                outputRefreshRate: 24
            ) - 1.001) < 0.000_000_1,
            "decoded 24000/1001 fps should expect mpv's 1.001 correction on 24 Hz"
        )
        check(
            DisplaySynchronization.expectedCorrection(
                declaredFrameRate: 25,
                decodedFrameRate: 25,
                outputRefreshRate: 25
            ) == 1,
            "integer cadence should retain unity correction"
        )
        check(
            DisplaySynchronization.effectiveSourceFrameRate(
                declaredFrameRate: 24,
                decodedFrameRate: nil
            ) == 24,
            "declared frame rate should remain the fallback before mpv reports decoding"
        )
        print("Playback prebuffer tests passed")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
}
