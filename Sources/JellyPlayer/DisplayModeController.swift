import AppKit
import CoreGraphics

@MainActor
final class DisplayModeController {
    private var originalMode: CGDisplayMode?

    func apply(
        width: Int?,
        height: Int?,
        frameRate: Double?,
        hdr: Bool,
        configuredModes: [ConfiguredOutputMode]
    ) throws -> String {
        guard let width, let height else { throw DisplayModeError.missingResolution }
        guard let frameRate, frameRate > 0 else { throw DisplayModeError.missingFrameRate }
        guard let screen = NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let modes = CGDisplayCopyAllDisplayModes(number.uint32Value, nil) as? [CGDisplayMode] else {
            throw DisplayModeError.noDisplay
        }
        let displayID = number.uint32Value
        if originalMode == nil { originalMode = CGDisplayCopyDisplayMode(displayID) }
        let override = configuredModes.first { $0.matches(width: width, height: height, frameRate: frameRate, hdr: hdr) }
        if let override, !SonyVW790ES.supports(
            width: override.displayWidth,
            height: override.displayHeight,
            nominalRefreshRate: override.displayRefreshRate,
            hdr: hdr
        ) {
            throw DisplayModeError.unsupportedByProjector(override.label)
        }
        let outputWidth = override?.displayWidth ?? width
        let outputHeight = override?.displayHeight ?? height
        let matching = modes.filter { mode in
            mode.isUsableForDesktopGUI() && mode.pixelWidth == outputWidth && mode.pixelHeight == outputHeight
                && SonyVW790ES.supports(
                    width: mode.pixelWidth,
                    height: mode.pixelHeight,
                    nominalRefreshRate: mode.refreshRate,
                    hdr: hdr
                )
                && (override.map { abs(mode.refreshRate - $0.displayRefreshRate) < 0.01 }
                    ?? exactCadence(mode.refreshRate, frameRate: frameRate))
        }
        guard let best = matching.max(by: { $0.refreshRate < $1.refreshRate }) else {
            throw DisplayModeError.noExactMode(outputWidth, outputHeight, override?.displayRefreshRate ?? frameRate)
        }
        var result = CGDisplaySetDisplayMode(displayID, best, nil)
        if result != .success {
            var configuration: CGDisplayConfigRef?
            result = CGBeginDisplayConfiguration(&configuration)
            if result == .success {
                result = CGConfigureDisplayWithDisplayMode(configuration, displayID, best, nil)
            }
            if result == .success {
                result = CGCompleteDisplayConfiguration(configuration, .forSession)
            } else if configuration != nil {
                CGCancelDisplayConfiguration(configuration)
            }
        }
        guard result == .success else {
            restore()
            throw DisplayModeError.applyFailed(result.rawValue)
        }
        Thread.sleep(forTimeInterval: 1.5)
        guard let active = CGDisplayCopyDisplayMode(displayID),
              active.pixelWidth == outputWidth, active.pixelHeight == outputHeight,
              (override.map { abs(active.refreshRate - $0.displayRefreshRate) < 0.01 }
                ?? exactCadence(active.refreshRate, frameRate: frameRate)) else {
            restore()
            throw DisplayModeError.verificationFailed
        }
        if hdr && screen.maximumPotentialExtendedDynamicRangeColorComponentValue <= 1 && override?.force != true {
            restore()
            throw DisplayModeError.hdrUnavailable
        }
        return override?.label ?? "Automatic exact cadence"
    }

    func restore() {
        guard let originalMode, let screen = NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        CGDisplaySetDisplayMode(number.uint32Value, originalMode, nil)
        self.originalMode = nil
    }

    private func exactCadence(_ refreshRate: Double, frameRate: Double) -> Bool {
        guard refreshRate > 0 else { return false }
        let ratio = refreshRate / frameRate
        let multiplier = ratio.rounded()
        guard multiplier >= 1 else { return false }
        return abs(ratio - multiplier) <= 0.0005
    }
}

enum DisplayModeError: LocalizedError {
    case noDisplay
    case missingResolution
    case missingFrameRate
    case noExactMode(Int, Int, Double)
    case unsupportedByProjector(String)
    case applyFailed(Int32)
    case verificationFailed
    case hdrUnavailable

    var errorDescription: String? {
        switch self {
        case .noDisplay: "No controllable cinema display is available."
        case .missingResolution: "Playback blocked: the media has no declared resolution."
        case .missingFrameRate: "Playback blocked: the media has no declared frame rate."
        case let .noExactMode(width, height, rate):
            "Playback blocked: no exact \(width)×\(height) display mode matches \(String(format: "%.3f", rate)) fps."
        case let .unsupportedByProjector(label):
            "Playback blocked: configured mode \(label) is not supported by the Sony VPL-VW790ES."
        case let .applyFailed(code): "Playback blocked: macOS rejected the required display mode (CGError \(code))."
        case .verificationFailed: "Playback blocked: macOS did not apply the required display mode exactly."
        case .hdrUnavailable: "Playback blocked: the active display is not currently HDR-capable."
        }
    }
}

private enum SonyVW790ES {
    // Core Graphics rounds the Sony 23.976 and 29.970 presets to nominal 24 and 30 Hz.
    private static let presets: [(Int, Int, Double)] = [
        (720, 480, 60), (720, 576, 50),
        (1280, 720, 50), (1280, 720, 60),
        (1920, 1080, 24), (1920, 1080, 50), (1920, 1080, 60),
        (3840, 2160, 24), (3840, 2160, 25), (3840, 2160, 30),
        (3840, 2160, 50), (3840, 2160, 60),
        (4096, 2160, 24), (4096, 2160, 25), (4096, 2160, 30),
        (4096, 2160, 50), (4096, 2160, 60)
    ]

    static func supports(width: Int, height: Int, nominalRefreshRate: Double, hdr: Bool) -> Bool {
        // The projector exposes HDR only for its UHD/DCI 4K preset memories.
        guard !hdr || (height == 2160 && width >= 3840) else { return false }
        return presets.contains {
            $0.0 == width && $0.1 == height && abs($0.2 - nominalRefreshRate) < 0.01
        }
    }
}
