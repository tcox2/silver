import AppKit
import CoreGraphics
import Foundation

@main
struct DisplayProbe {
    static func main() {
        _ = NSApplication.shared
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = number.uint32Value
            let current = CGDisplayCopyDisplayMode(id)
            print("DISPLAY \(screen.localizedName)")
            print("CURRENT \(current?.pixelWidth ?? 0)x\(current?.pixelHeight ?? 0) @ \(format(current?.refreshRate ?? 0)) Hz")
            print("EDR_CURRENT \(format(screen.maximumExtendedDynamicRangeColorComponentValue))")
            print("EDR_POTENTIAL \(format(screen.maximumPotentialExtendedDynamicRangeColorComponentValue))")
            let modes = (CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] ?? [])
                .filter { $0.isUsableForDesktopGUI() && $0.refreshRate > 0 }
            let unique = Dictionary(grouping: modes) { "\($0.pixelWidth)x\($0.pixelHeight)" }
            for key in unique.keys.sorted(by: resolutionOrder) {
                let rates = Set(unique[key, default: []].map { format($0.refreshRate) }).sorted { Double($0)! < Double($1)! }
                print("MODE \(key) @ \(rates.joined(separator: ", ")) Hz")
            }
        }
    }

    static func format(_ value: Double) -> String { String(format: "%.6f", value) }
    static func format(_ value: CGFloat) -> String { String(format: "%.6f", Double(value)) }
    static func resolutionOrder(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: "x").compactMap { Int($0) }
        let right = rhs.split(separator: "x").compactMap { Int($0) }
        return (left.first ?? 0) * (left.last ?? 0) < (right.first ?? 0) * (right.last ?? 0)
    }
}
