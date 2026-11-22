// No SwiftUI and no toolkit in this file: only drawing, so both the lens
// (CardRenderer) and the phone's own copy of the card (CardView) can use it.
import UIKit

/// Pictures for the lens, where a drawing says more at a glance than lines of
/// text. White on black: black is see-through on the glasses.
///
/// Whether the glasses show a drawn picture quickly and sharply is one of the
/// things only the device can tell (docs/device-findings.md, question 2), so a
/// picture is always optional: every card that has one also draws as text.
enum CardImages {
    /// The picture that stands for a card's body, when it has one. Today that
    /// is the day plan: its blocks as a timeline.
    static func picture(for card: LensCard) -> UIImage? {
        guard card.template == "plan", let blocks = card.blocks, blocks.contains(where: { $0.kind != "now" }) else { return nil }
        return day(Array(blocks.prefix(7)))
    }

    /// A day from now on, top to bottom: the time down the side, a bar per
    /// meeting (filled) or planned task (outlined) that is taller when it takes
    /// longer, and a line where "now" is.
    static func day(_ blocks: [LensBlock]) -> UIImage {
        let width: CGFloat = 600
        let gap: CGFloat = 8
        let heights: [CGFloat] = blocks.map { block in
            if block.kind == "now" { return 22 }
            let minutes = CGFloat(block.minutes ?? 30)
            return min(84, max(48, 34 + minutes * 0.35))
        }
        let total = heights.reduce(0, +) + gap * CGFloat(max(0, blocks.count - 1))
        let size = CGSize(width: width, height: max(60, total))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            var top: CGFloat = 0
            for (index, block) in blocks.enumerated() {
                let row = CGRect(x: 0, y: top, width: width, height: heights[index])
                if block.kind == "now" {
                    drawNow(block, in: row)
                } else {
                    drawBlock(block, in: row)
                }
                top += heights[index] + gap
            }
        }
    }

    // MARK: Pieces

    /// Where the bars start: left of it is the time.
    private static let barLeft: CGFloat = 104

    private static func drawNow(_ block: LensBlock, in row: CGRect) {
        let time = text(size: 20, weight: .semibold, white: 1)
        draw(block.start, in: CGRect(x: 8, y: row.midY - 13, width: barLeft - 22, height: 26), time)
        UIColor.white.setFill()
        UIBezierPath(rect: CGRect(x: barLeft, y: row.midY - 1.5, width: row.width - barLeft, height: 3)).fill()
        UIBezierPath(ovalIn: CGRect(x: barLeft - 7, y: row.midY - 7, width: 14, height: 14)).fill()
    }

    private static func drawBlock(_ block: LensBlock, in row: CGRect) {
        let done = block.done == true
        let meeting = block.kind == "meeting"
        let box = CGRect(x: barLeft, y: row.minY, width: row.width - barLeft, height: row.height)

        // A meeting is solid, a task you planned is an outline: one is fixed, the other is yours to move.
        if meeting {
            UIColor(white: done ? 0.16 : 0.27, alpha: 1).setFill()
            UIBezierPath(roundedRect: box, cornerRadius: 12).fill()
        } else {
            let outline = UIBezierPath(roundedRect: box.insetBy(dx: 1.5, dy: 1.5), cornerRadius: 12)
            outline.lineWidth = 3
            UIColor(white: done ? 0.35 : 0.8, alpha: 1).setStroke()
            outline.stroke()
        }

        let time = text(size: 20, weight: .regular, white: 0.7)
        draw(block.start, in: CGRect(x: 8, y: row.minY + 11, width: barLeft - 22, height: 26), time)

        var right = box.maxX - 16
        if let minutes = block.minutes, minutes > 0 {
            let label = length(minutes)
            let small = text(size: 20, weight: .regular, white: 0.7)
            let needed = ceil((label as NSString).size(withAttributes: small).width)
            draw(label, in: CGRect(x: right - needed, y: box.midY - 13, width: needed, height: 26), small)
            right -= needed + 12
        }

        let title = text(size: 26, weight: .semibold, white: done ? 0.5 : 1)
        let shown = done ? "✓ " + block.title : block.title
        draw(shown, in: CGRect(x: box.minX + 16, y: box.midY - 17, width: max(40, right - box.minX - 16), height: 34), title)
    }

    private static func length(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest)"
    }

    private static func text(size: CGFloat, weight: UIFont.Weight, white: CGFloat) -> [NSAttributedString.Key: Any] {
        let cut = NSMutableParagraphStyle()
        cut.lineBreakMode = .byTruncatingTail
        return [
            .font: UIFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: UIColor(white: white, alpha: 1),
            .paragraphStyle: cut,
        ]
    }

    /// One line, cut with an ellipsis where it doesn't fit.
    private static func draw(_ words: String, in rect: CGRect, _ look: [NSAttributedString.Key: Any]) {
        (words as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: look, context: nil)
    }
}
