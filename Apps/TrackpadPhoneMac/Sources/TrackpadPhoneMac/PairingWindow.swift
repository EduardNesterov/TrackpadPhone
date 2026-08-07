import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import TrackpadProtocol

/// Shows the pairing code as a QR for the phone's camera.
///
/// A window rather than a menu image: the code has to stay on screen while the phone is
/// picked up, aimed and focused, and a menu closes the moment attention leaves it.
///
/// Not actor-annotated, like the rest of this app: it is only ever reached from a menu
/// action, and those already arrive on the main thread.
final class PairingWindow {
    private var window: NSWindow?

    func show(_ code: PairingCode) {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)

        let image = NSImageView(image: Self.qr(code.url, side: 320))
        image.setFrameSize(NSSize(width: 320, height: 320))
        content.addArrangedSubview(image)

        content.addArrangedSubview(label(code.serviceName, size: 15, weight: .semibold))
        content.addArrangedSubview(label(
            "На телефоні: «Сканувати код». Далі він знаходить цей Mac сам.",
            size: 12, weight: .regular, secondary: true
        ))
        // The addresses are in the code anyway; showing them is for the moment when
        // pairing does not work and somebody needs to know what the phone was told.
        if let first = code.addresses.first {
            content.addArrangedSubview(label(
                "\(first) · порт \(code.port)", size: 11, weight: .regular, secondary: true
            ))
        }

        let window = self.window ?? NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Код для телефона"
        window.contentView = content
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        // A menu-bar app is an accessory and its windows do not come forward on their own.
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func close() {
        window?.close()
    }

    private func label(
        _ text: String, size: CGFloat, weight: NSFont.Weight, secondary: Bool = false
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.alignment = .center
        if secondary { field.textColor = .secondaryLabelColor }
        return field
    }

    /// - Parameter side: points. Generated at the code's natural size and scaled up with
    ///   nearest-neighbour, because interpolating a QR blurs the very edges a camera reads.
    private static func qr(_ text: String, side: CGFloat) -> NSImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        // Medium correction: the code is read off a bright screen from ten centimetres,
        // not off a crumpled label, and more correction means a denser code.
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return NSImage(size: .zero) }
        let scale = side / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
