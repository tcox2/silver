import AppKit
import CoreGraphics

@MainActor
final class DisplayModeController {
    private var originalMode: CGDisplayMode?
    private let privateHDR = PrivateHDRController()

    func ensureIdleSDR() throws {
        guard let screen = NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw DisplayModeError.noDisplay
        }
        try privateHDR.ensureDisabled(displayID: number.uint32Value)
    }

    func apply(
        width: Int?,
        height: Int?,
        frameRate: Double?,
        hdr: Bool,
        configuredModes: [ConfiguredOutputMode]
    ) throws -> String {
        SilverLog.info("Display request media=\(width.map(String.init) ?? "unknown")x\(height.map(String.init) ?? "unknown") fps=\(frameRate.map { String(format: "%.6f", $0) } ?? "unknown") range=\(hdr ? "HDR" : "SDR")")
        guard let width, let height else { throw DisplayModeError.missingResolution }
        guard let frameRate, frameRate > 0 else { throw DisplayModeError.missingFrameRate }
        guard let screen = NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let modes = CGDisplayCopyAllDisplayModes(number.uint32Value, nil) as? [CGDisplayMode] else {
            throw DisplayModeError.noDisplay
        }
        let displayID = number.uint32Value
        SilverLog.info("Display target id=\(displayID) name=\(screen.localizedName) currentEDR=\(screen.maximumExtendedDynamicRangeColorComponentValue) potentialEDR=\(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)")
        if originalMode == nil { originalMode = CGDisplayCopyDisplayMode(displayID) }
        let override = configuredModes.first { $0.matches(width: width, height: height, frameRate: frameRate, hdr: hdr) }
        if let override {
            SilverLog.info("Configured mode label=\(override.label) output=\(override.displayWidth)x\(override.displayHeight) nominalHz=\(String(format: "%.6f", override.displayRefreshRate)) force=\(override.force)")
        } else {
            SilverLog.info("No configured override matched; selecting an exact-cadence discovered mode")
        }
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
        let available = modes.filter { $0.pixelWidth == outputWidth && $0.pixelHeight == outputHeight }
            .map { String(format: "%.6f", $0.refreshRate) }.joined(separator: ",")
        SilverLog.info("Discovered output modes resolution=\(outputWidth)x\(outputHeight) refreshRates=[\(available)] matchingCount=\(matching.count)")
        guard let best = matching.max(by: { $0.refreshRate < $1.refreshRate }) else {
            SilverLog.error("No eligible display mode for \(outputWidth)x\(outputHeight) at requested cadence")
            throw DisplayModeError.noExactMode(outputWidth, outputHeight, override?.displayRefreshRate ?? frameRate)
        }
        SilverLog.info("Selected mode pixels=\(best.pixelWidth)x\(best.pixelHeight) points=\(best.width)x\(best.height) nominalHz=\(String(format: "%.6f", best.refreshRate)) modeID=\(best.ioDisplayModeID) flags=0x\(String(best.ioFlags, radix: 16))")
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
            SilverLog.error("Core Graphics rejected display mode CGError=\(result.rawValue)")
            restore()
            throw DisplayModeError.applyFailed(result.rawValue)
        }
        Thread.sleep(forTimeInterval: 1.5)
        guard let active = CGDisplayCopyDisplayMode(displayID),
              active.pixelWidth == outputWidth, active.pixelHeight == outputHeight,
              (override.map { abs(active.refreshRate - $0.displayRefreshRate) < 0.01 }
                ?? exactCadence(active.refreshRate, frameRate: frameRate)) else {
            SilverLog.error("Active display mode failed resolution/refresh verification")
            restore()
            throw DisplayModeError.verificationFailed
        }
        do {
            try privateHDR.apply(displayID: displayID, enabled: hdr)
        } catch {
            privateHDR.restore()
            restoreDisplayModeOnly()
            throw error
        }
        Thread.sleep(forTimeInterval: 0.5)
        guard let activeScreen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else {
            SilverLog.error("NSScreen disappeared after display mode switch")
            restore()
            throw DisplayModeError.noDisplay
        }
        SilverLog.info("Active mode pixels=\(active.pixelWidth)x\(active.pixelHeight) nominalHz=\(String(format: "%.6f", active.refreshRate)) currentEDR=\(activeScreen.maximumExtendedDynamicRangeColorComponentValue) potentialEDR=\(activeScreen.maximumPotentialExtendedDynamicRangeColorComponentValue) referenceEDR=\(activeScreen.maximumReferenceExtendedDynamicRangeColorComponentValue)")
        if hdr && activeScreen.maximumPotentialExtendedDynamicRangeColorComponentValue <= 1 {
            SilverLog.error("HDR verification failed: potentialEDR is not greater than 1")
            restore()
            throw DisplayModeError.dynamicRangeMismatch("HDR")
        }
        if !hdr && activeScreen.maximumExtendedDynamicRangeColorComponentValue > 1 {
            SilverLog.error("SDR verification failed: currentEDR is greater than 1")
            restore()
            throw DisplayModeError.dynamicRangeMismatch("SDR")
        }
        SilverLog.info("Display mode and \(hdr ? "HDR" : "SDR") state verified")
        return override?.label ?? "Automatic exact cadence"
    }

    func restore() {
        privateHDR.restore()
        restoreDisplayModeOnly()
    }

    private func restoreDisplayModeOnly() {
        guard let originalMode, let screen = NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        CGDisplaySetDisplayMode(number.uint32Value, originalMode, nil)
        SilverLog.info("Restored original display mode \(originalMode.pixelWidth)x\(originalMode.pixelHeight) nominalHz=\(String(format: "%.6f", originalMode.refreshRate))")
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
    case dynamicRangeMismatch(String)
    case displayGrabLost
    case privateHDRUnavailable
    case hdrUnsupported
    case hdrToggleVerificationFailed

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
        case let .dynamicRangeMismatch(range):
            "Playback blocked: macOS did not activate the required \(range) output state."
        case .displayGrabLost: "Playback blocked: Silver lost exclusive full-screen control during the mode change."
        case .privateHDRUnavailable: "Playback blocked: Tahoe's private HDR controls are unavailable."
        case .hdrUnsupported: "Playback blocked: CoreDisplay reports that the HDMI output does not support HDR mode."
        case .hdrToggleVerificationFailed: "Playback blocked: CoreDisplay did not confirm the requested HDR setting."
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
