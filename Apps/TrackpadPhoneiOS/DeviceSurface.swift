import UIKit

/// Physical size of the touch surface, in millimetres.
///
/// The Mac tunes acceleration in mm/s so its numbers hold across devices and
/// orientations — which means somebody has to convert points to millimetres, and iOS
/// will not tell us the screen's physical size. So: model identifier → pixel density.
///
/// The table is short on purpose, and it can afford to be. Every iPhone that runs a current
/// iOS falls into one of three densities, so the whole lineup is three numbers and a
/// default — not a row per model, which would go stale the week Apple ships another one.
///
/// Being a few per cent out on an unlisted phone shifts perceived sensitivity by the same
/// few per cent, and the sensitivity slider on the Mac absorbs it. That is why an unknown
/// phone is a shrug rather than a failure.
enum DeviceSurface {
    /// The big middle of the lineup — 12, 13, 14, 15, 16 and their Pro and Max variants are
    /// all 458 to 461. Also the right guess for a model this table has never heard of.
    private static let defaultPPI: Double = 460

    /// Longest prefix wins, so `iPhone14,6` (SE 3) is found before the `iPhone14,` family.
    private static let ppiByPrefix: [(prefix: String, ppi: Double)] = [
        // The 326 family: the ones with the older, larger pixels.
        ("iPhone8,4", 326),   // SE 1
        ("iPhone9,", 326),    // 7 / 7 Plus is 401, close enough at this altitude
        ("iPhone10,4", 326),  // 8
        ("iPhone10,5", 401),  // 8 Plus
        ("iPhone11,8", 326),  // XR
        ("iPhone12,1", 326),  // 11
        ("iPhone12,8", 326),  // SE 2
        ("iPhone14,6", 326),  // SE 3
        // The minis are denser than everything else, and the only models that are.
        ("iPhone13,1", 476),  // 12 mini
        ("iPhone14,4", 476),  // 13 mini
        ("iPad", 264),
    ]

    static var pixelsPerInch: Double {
        // Longest prefix first: `iPhone14,6` and `iPhone14,` both match an SE 3, and only
        // one of them is right.
        let matches = ppiByPrefix
            .filter { modelIdentifier.hasPrefix($0.prefix) }
            .sorted { $0.prefix.count > $1.prefix.count }
        return matches.first?.ppi ?? defaultPPI
    }

    /// Hand-tuning for a phone the table gets wrong.
    ///
    /// One number, not two. Pixels on every iPhone are square, so a surface that reads too
    /// large reads too large in both directions by the same amount — separate horizontal and
    /// vertical figures would be encoding an error that does not exist, and would quietly
    /// break every threshold that compares one axis against the other, from pinch-versus-
    /// scroll to which border a drag is running out of room at.
    ///
    /// If the pointer feels differently geared sideways than up and down, that is not this:
    /// it is the desktop being wider than it is tall, and it belongs to the Mac's gain.
    static var calibration: Double {
        let stored = UserDefaults.standard.double(forKey: "surfaceCalibration")
        return stored > 0.2 && stored < 5 ? stored : 1
    }

    static var modelIdentifier: String {
        // On a simulator `uname` reports the Mac's architecture, not the device being
        // simulated, so every lookup would silently fall through to the default.
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    /// Converts a view's size in points to millimetres.
    static func millimetres(forPoints size: CGSize, scale: CGFloat) -> CGSize {
        let pixelsPerMM = pixelsPerInch / 25.4 / calibration
        return CGSize(
            width: Double(size.width * scale) / pixelsPerMM,
            height: Double(size.height * scale) / pixelsPerMM
        )
    }
}
