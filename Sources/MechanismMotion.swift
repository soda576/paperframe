import Foundation

enum MechanismMotion {
    static let lampRise: Double = 0.18
    static let holdTime: Double = 0.28

    static func lampEase(_ progress: CGFloat) -> CGFloat {
        1 - pow(1 - progress, 3)
    }

    static func returnEase(_ progress: CGFloat) -> CGFloat {
        1 - pow(1 - progress, 2)
    }

    static func settleDuration(distance: CGFloat) -> Double {
        min(0.65, 0.22 + Double(abs(distance)) * 0.004)
    }
}
