import CoreGraphics
import Darwin
import Foundation

/// Isolates Silver's only private macOS dependency. Every mutation is followed
/// by read-back and the original state is retained for restoration.
final class PrivateHDRController {
    private typealias Query = @convention(c) (CGDirectDisplayID) -> UInt8
    private typealias Set = @convention(c) (CGDirectDisplayID, UInt8) -> Void

    private let library: UnsafeMutableRawPointer?
    private let supports: Query?
    private let isEnabled: Query?
    private let setEnabled: Set?
    private var original: (displayID: CGDirectDisplayID, enabled: Bool)?

    init() {
        let path = "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay"
        library = dlopen(path, RTLD_NOW | RTLD_LOCAL)
        if let library {
            supports = Self.load("CoreDisplay_Display_SupportsHDRMode", from: library)
            isEnabled = Self.load("CoreDisplay_Display_IsHDRModeEnabled", from: library)
            setEnabled = Self.load("CoreDisplay_Display_SetHDRModeEnabled", from: library)
        } else {
            supports = nil
            isEnabled = nil
            setEnabled = nil
        }
    }

    func apply(displayID: CGDirectDisplayID, enabled: Bool) throws {
        guard let supports, let isEnabled, let setEnabled else {
            throw DisplayModeError.privateHDRUnavailable
        }
        let supported = supports(displayID) != 0
        let before = isEnabled(displayID) != 0
        SilverLog.info("Private HDR capability displayID=\(displayID) supported=\(supported) enabledBefore=\(before) requested=\(enabled)")
        if enabled && !supported { throw DisplayModeError.hdrUnsupported }
        if original == nil { original = (displayID, before) }
        guard before != enabled else {
            SilverLog.info("Private HDR state already matches request enabled=\(enabled)")
            return
        }
        setEnabled(displayID, enabled ? 1 : 0)
        for _ in 0..<30 {
            if (isEnabled(displayID) != 0) == enabled {
                SilverLog.info("Private HDR state verified enabled=\(enabled)")
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        SilverLog.error("Private HDR read-back did not reach requested state enabled=\(enabled)")
        throw DisplayModeError.hdrToggleVerificationFailed
    }

    /// Recovers the projector to an SDR idle state after an abnormal exit. This
    /// deliberately does not record the inherited HDR state for later restore.
    func ensureDisabled(displayID: CGDirectDisplayID) throws {
        guard let supports, let isEnabled, let setEnabled else {
            throw DisplayModeError.privateHDRUnavailable
        }
        let supported = supports(displayID) != 0
        let before = isEnabled(displayID) != 0
        SilverLog.info("Idle SDR recovery displayID=\(displayID) supported=\(supported) enabledBefore=\(before)")
        guard before else {
            SilverLog.info("Idle SDR state verified enabled=false")
            return
        }
        setEnabled(displayID, 0)
        for _ in 0..<30 {
            if isEnabled(displayID) == 0 {
                SilverLog.info("Idle SDR state recovered enabled=false")
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        SilverLog.error("Idle SDR recovery failed")
        throw DisplayModeError.hdrToggleVerificationFailed
    }

    func restore() {
        guard let original else { return }
        defer { self.original = nil }
        guard let isEnabled, let setEnabled else {
            SilverLog.error("Cannot restore original HDR state because CoreDisplay symbols disappeared")
            return
        }
        if (isEnabled(original.displayID) != 0) != original.enabled {
            setEnabled(original.displayID, original.enabled ? 1 : 0)
        }
        for _ in 0..<30 {
            if (isEnabled(original.displayID) != 0) == original.enabled {
                SilverLog.info("Restored original private HDR state enabled=\(original.enabled)")
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        SilverLog.error("Failed to restore original private HDR state enabled=\(original.enabled)")
    }

    deinit { if let library { dlclose(library) } }

    private static func load<T>(_ name: String, from library: UnsafeMutableRawPointer) -> T? {
        guard let symbol = dlsym(library, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}
