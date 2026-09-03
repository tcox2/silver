import Foundation

enum DisplaySynchronization {
    static func effectiveSourceFrameRate(
        declaredFrameRate: Double,
        decodedFrameRate: Double?
    ) -> Double {
        if let decodedFrameRate,
           decodedFrameRate.isFinite,
           decodedFrameRate > 0 {
            return decodedFrameRate
        }
        return declaredFrameRate
    }

    static func expectedCorrection(
        declaredFrameRate: Double,
        decodedFrameRate: Double?,
        outputRefreshRate: Double
    ) -> Double {
        outputRefreshRate / effectiveSourceFrameRate(
            declaredFrameRate: declaredFrameRate,
            decodedFrameRate: decodedFrameRate
        )
    }
}
