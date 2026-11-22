// No SwiftUI in this file: MWDATDisplay has its own Text, Button and Image.
import Foundation
import MWDATDisplay
import UIKit

/// Test cards that answer what only the glasses can: how much text fits, and
/// whether a drawn picture is quick and readable. See docs/device-findings.md.
extension Glasses {
    /// A card with numbered lines of each text style above a row of buttons.
    /// Count what is readable on the lens.
    func probeCapacity(headings: Int, bodies: Int, metas: Int, buttons: Int,
                       onPick: @escaping @Sendable (String) -> Void) async -> Bool {
        var parts: [any ViewComponent] = []
        for i in 0..<max(0, headings) { parts.append(Text("Heading \(i + 1): the quick brown fox", style: .heading, color: .primary)) }
        for i in 0..<max(0, bodies) { parts.append(Text("Body \(i + 1): jumps over the lazy dog, twice a day", style: .body, color: .secondary)) }
        for i in 0..<max(0, metas) { parts.append(Text("Meta \(i + 1) · Ann Lee · 2h · Atlas", style: .meta, color: .secondary)) }
        var made: [Button] = []
        for i in 0..<max(1, buttons) {
            let label = i == 0 ? "Close" : "Button \(i + 1)"
            made.append(Button(label: label, style: i == 0 ? .primary : .secondary, onClick: { onPick(label) }))
        }
        let all = parts
        let row = made
        let view = FlexBox(direction: .column, spacing: 14, alignment: .start, crossAlignment: .start) {
            for part in all { part }
            ButtonGroup(alignment: .start) {
                for button in row { button }
            }
        }
        return await show(view: view, reopen: false)
    }

    /// A card that is one drawn picture (a day as a timeline) and a button.
    /// The log has how long it took to send.
    func probeImage(onPick: @escaping @Sendable (String) -> Void) async -> Bool {
        let picture = Self.timelinePicture()
        let view = FlexBox(direction: .column, spacing: 12, alignment: .start, crossAlignment: .stretch) {
            Image(image: picture, sizePreset: .fill, cornerRadius: .medium)
            ButtonGroup(alignment: .start) {
                Button(label: "Close", style: .primary, onClick: { onPick("Close") })
            }
        }
        return await show(view: view, reopen: false)
    }

    /// A made-up day, drawn the way a plan card could be: white on black,
    /// meetings solid, time boxes outlined, a line for now.
    private static func timelinePicture() -> UIImage {
        let size = CGSize(width: 600, height: 420)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let blocks: [(String, String, CGFloat, CGFloat, Bool)] = [
            ("09:00", "Stand-up", 0.00, 0.08, true),
            ("10:00", "Quote for Ann", 0.14, 0.20, false),
            ("13:00", "Review with Tom", 0.52, 0.16, true),
            ("15:30", "Invoices", 0.82, 0.12, false),
        ]
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let label: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: UIColor.white]
            let small: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 20, weight: .regular), .foregroundColor: UIColor(white: 0.7, alpha: 1)]
            let top: CGFloat = 20
            let height = size.height - 40
            for (start, title, at, length, solid) in blocks {
                let box = CGRect(x: 110, y: top + at * height, width: 470, height: max(44, length * height))
                let path = UIBezierPath(roundedRect: box, cornerRadius: 12)
                if solid {
                    UIColor(white: 0.28, alpha: 1).setFill()
                    path.fill()
                } else {
                    UIColor(white: 0.75, alpha: 1).setStroke()
                    path.lineWidth = 3
                    path.stroke()
                }
                (start as NSString).draw(at: CGPoint(x: 14, y: box.minY + 8), withAttributes: small)
                (title as NSString).draw(at: CGPoint(x: box.minX + 16, y: box.minY + 7), withAttributes: label)
            }
            // Now.
            let now = top + 0.44 * height
            UIColor.white.setFill()
            context.fill(CGRect(x: 96, y: now, width: 490, height: 3))
            UIBezierPath(ovalIn: CGRect(x: 90, y: now - 6, width: 14, height: 14)).fill()
        }
    }
}
