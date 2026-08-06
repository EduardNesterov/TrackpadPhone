import UIKit

/// Physical size of the touch surface, in millimetres.
///
/// The Mac tunes acceleration in mm/s so its numbers hold across devices and
/// orientations — which means somebody has to convert points to millimetres, and iOS
/// will not tell us the screen's physical size. So: model identifier → pixel density.
///
/// The table is deliberately short. Being 5% off on an unlisted phone shifts perceived
/// sensitivity by 5%, which the sensitivity slider absorbs; it is not worth enumerating
/// every model Apple has shipped.
enum DeviceSurface {
    /// Most iPhones since the X are 458–460 ppi. Reasonable when the model is unknown.
    private static let defaultPPI: Double = 460

    private static let ppiByPrefix: [(prefix: String, ppi: Double)] = [
        ("iPhone8,4", 326),   // SE 1
        ("iPhone9,", 326),    // 7 / 7 Plus is 401, close enough at this altitude
        ("iPhone10,4", 326),  // 8
        ("iPhone10,5", 401),  // 8 Plus
        ("iPhone11,8", 326),  // XR
        ("iPhone12,1", 326),  // 11
        ("iPhone12,8", 326),  // SE 2
        ("iPhone14,6", 326),  // SE 3
        ("iPad", 264),
    ]

    static var pixelsPerInch: Double {
        for entry in ppiByPrefix where modelIdentifier.hasPrefix(entry.prefix) {
            return entry.ppi
        }
        return defaultPPI
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
        let pixelsPerMM = pixelsPerInch / 25.4
        return CGSize(
            width: Double(size.width * scale) / pixelsPerMM,
            height: Double(size.height * scale) / pixelsPerMM
        )
    }
}
