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
        print("Playback prebuffer tests passed")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
}
