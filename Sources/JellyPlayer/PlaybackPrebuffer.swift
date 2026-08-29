import Foundation

struct PlaybackOperationGeneration: Equatable {
    private(set) var current: UInt64 = 0

    mutating func advance() -> UInt64 {
        current &+= 1
        return current
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        generation == current
    }
}

struct PlaybackPrebufferSample: Equatable {
    let videoOutputConfigured: Bool
    let videoFormatAvailable: Bool
    let decodedFrameRate: Double?
    let position: Double?
    let demuxedSeconds: Double?
    let reachedEndOfFile: Bool

    func isReady(expectedPosition: Double?, minimumDemuxedSeconds: Double) -> Bool {
        guard videoOutputConfigured,
              videoFormatAvailable,
              let decodedFrameRate,
              decodedFrameRate.isFinite,
              decodedFrameRate > 0,
              let position,
              position.isFinite else { return false }

        if let expectedPosition {
            guard abs(position - expectedPosition) <= 0.75 else { return false }
        }

        if reachedEndOfFile { return true }
        guard let demuxedSeconds, demuxedSeconds.isFinite else { return false }
        return demuxedSeconds >= minimumDemuxedSeconds
    }
}
