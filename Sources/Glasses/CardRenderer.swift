// No SwiftUI in this file: MWDATDisplay has its own Text, Button and Image.
import Foundation
import MWDATDisplay
import UIKit

/// What the lens shows: MailPilot's card, and one small line under it (what it
/// did last, or what it heard).
struct LensFace: Equatable {
    var card: LensCard
    var footer: String?
}

/// Buttons the phone answers itself, without MailPilot.
enum LocalAction {
    static let prefix = "local:"
    /// Takes the card off the lens.
    static let close = "local:close"
}

/// Turns a card into the toolkit's layout. The lens is 600×600, so a card is:
/// a small head line, one headline, at most three short lines, then whatever
/// the template adds (tiles, rows, a day's blocks, chips), and one row of
/// buttons. MailPilot clamps every field; this only draws.
///
/// The toolkit has two text colours and no accent colour, so tone is carried
/// by icons and by the order of the buttons: the first one is the suggested
/// one, and it is the one in focus.
enum CardRenderer {
    /// - Parameter picture: the card's body as a drawing (`CardImages.picture`),
    ///   for a card that has one. It takes the place of the headline and the
    ///   day's blocks: its first bar is what the headline would say.
    static func view(_ face: LensFace, picture: UIImage? = nil, onAction: @escaping @Sendable (String) -> Void) -> FlexBox {
        let card = face.card
        var parts: [any ViewComponent] = []

        if let head = head(card) { parts.append(head) }
        if picture == nil, let title = clean(card.title) {
            parts.append(Text(title, style: .heading, color: .primary))
        }
        for line in (card.lines ?? []).prefix(3) {
            if let text = clean(line) { parts.append(Text(text, style: .body, color: .secondary)) }
        }
        if let tiles = card.tiles, !tiles.isEmpty { parts.append(tileRow(Array(tiles.prefix(3)))) }
        for row in (card.rows ?? []).prefix(5) { parts.append(rowLine(row, onAction)) }
        if let picture {
            parts.append(Image(image: picture, sizePreset: .fill, cornerRadius: .medium))
        } else {
            for block in (card.blocks ?? []).prefix(7) { parts.append(blockLine(block)) }
        }
        if let chips = card.chips, !chips.isEmpty { parts.append(chipRow(Array(chips.prefix(2)))) }
        if let hint = clean(card.hint) { parts.append(Text(hint, style: .meta, color: .secondary)) }
        if let footer = clean(face.footer) { parts.append(Text(footer, style: .meta, color: .secondary)) }
        parts.append(buttons(card, onAction))

        let all = parts
        // A picture fills the width of the lens; text stays at the left.
        return FlexBox(direction: .column, spacing: 14, alignment: .start, crossAlignment: picture == nil ? .start : .stretch) {
            for part in all { part }
        }
    }

    // MARK: Pieces

    /// Icon, who and when, and where in the deck: "✉ Ann Lee · 2h      2/7".
    private static func head(_ card: LensCard) -> FlexBox? {
        let symbol = card.danger == true ? IconName.exclamationTriangle : icon(card.icon)
        let meta = clean(card.meta)
        var place = clean(card.position)
        if let page = clean(card.page) { place = place.map { "\($0) · p \(page)" } ?? "p \(page)" }
        guard symbol != nil || meta != nil || place != nil else { return nil }
        return FlexBox(direction: .row, spacing: 10, alignment: .start, crossAlignment: .center) {
            if let symbol { Icon(name: symbol, style: .outline) }
            if let meta { Text(meta, style: .meta, color: .secondary) }
            if let place { Text(place, style: .meta, color: .secondary) }
        }
    }

    /// The home card's numbers, side by side.
    private static func tileRow(_ tiles: [LensTile]) -> FlexBox {
        FlexBox(direction: .row, spacing: 12, alignment: .start, crossAlignment: .stretch) {
            for tile in tiles {
                FlexBox(direction: .column, spacing: 2, alignment: .center, crossAlignment: .center, padding: EdgeInsets(all: 14)) {
                    Text(tile.value, style: .heading, color: .primary)
                    Text(tile.label, style: .meta, color: .secondary)
                }
                .background(.card)
                .flexGrow(1)
            }
        }
    }

    /// A row of a list (it can be picked) or a step of "how it did it" (ticked).
    private static func rowLine(_ row: LensRow, _ onAction: @escaping @Sendable (String) -> Void) -> FlexBox {
        let symbol: IconName = row.done == true ? .checkmarkCircle : (icon(row.icon) ?? .caretRight)
        let meta = clean(row.meta)
        let line = FlexBox(direction: .row, spacing: 10, alignment: .start, crossAlignment: .center) {
            Icon(name: symbol, style: .outline)
            Text(row.title, style: .body, color: .primary)
            if let meta { Text(meta, style: .meta, color: .secondary) }
        }
        guard let id = row.id, !id.isEmpty else { return line }
        return line.onTap { onAction(id) }
    }

    /// A piece of the day as text, when it isn't drawn: "14:30  Send quote  30 min",
    /// with a line of its own for where "now" is.
    private static func blockLine(_ block: LensBlock) -> FlexBox {
        if block.kind == "now" {
            return FlexBox(direction: .row, spacing: 10, alignment: .start, crossAlignment: .center) {
                Icon(name: .clock, style: .outline)
                Text("\(block.start) · now", style: .meta, color: .primary)
            }
        }
        let minutes = block.minutes ?? 0
        let length: String? = minutes <= 0 ? nil : (minutes >= 60 && minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes) min")
        let symbol: IconName = block.done == true ? .checkmark : (block.kind == "meeting" ? .calendar : .caretRight)
        return FlexBox(direction: .row, spacing: 10, alignment: .start, crossAlignment: .center) {
            Icon(name: symbol, style: .outline)
            Text(block.start, style: .meta, color: .secondary)
            Text(block.title, style: .body, color: block.done == true ? .secondary : .primary)
            if let length { Text(length, style: .meta, color: .secondary) }
        }
    }

    /// Small labels: the suggestion, "Files", a warning.
    private static func chipRow(_ chips: [LensChip]) -> FlexBox {
        FlexBox(direction: .row, spacing: 10, alignment: .start, crossAlignment: .center, wrap: true) {
            for chip in chips {
                let symbol = icon(chip.icon) ?? toneIcon(chip.tone)
                FlexBox(direction: .row, spacing: 6, alignment: .start, crossAlignment: .center, padding: EdgeInsets(top: 6, bottom: 6, leading: 12, trailing: 12)) {
                    if let symbol { Icon(name: symbol, style: .outline) }
                    Text(chip.text, style: .meta, color: .primary)
                }
                .background(.card)
            }
        }
    }

    /// At most four buttons; the first is the suggested one and gets the focus.
    private static func buttons(_ card: LensCard, _ onAction: @escaping @Sendable (String) -> Void) -> ButtonGroup {
        var made: [Button] = []
        for (index, action) in (card.actions ?? []).prefix(4).enumerated() {
            let id = action.id
            let look: ButtonStyle
            switch action.style {
            case "danger": look = .outline
            case "secondary": look = index == 0 ? .primary : .secondary
            default: look = index == 0 ? .primary : .secondary
            }
            let button = Button(label: action.label, style: look, iconName: icon(action.icon), onClick: { onAction(id) })
            made.append(index == 0 ? button.actionRole(.primary) : button)
        }
        if made.isEmpty {
            // Every card has a way out other than the back gesture, which closes the app on the glasses.
            made.append(Button(label: "Close", style: .outline, iconName: .x, onClick: { onAction(LocalAction.close) }))
        }
        let all = made
        return ButtonGroup(alignment: .start) {
            for button in all { button }
        }
    }

    // MARK: Icons

    /// MailPilot's icon names, as the toolkit's fixed set has them.
    static func icon(_ name: String?) -> IconName? {
        switch name {
        case "mail": return .envelopeOpen
        case "person": return .person
        case "calendar": return .calendar
        case "cart": return .cart
        case "code": return .code
        case "ticket": return .hashtag
        case "news": return .bullhorn
        case "lock": return .padlockClosed
        case "bell": return .bell
        case "sun": return .circle8RaysLarge
        case "pencil": return .pencil
        case "reply": return .arrowULeft
        case "folder": return .containerWithLid
        case "check": return .checkmark
        case "battery", "warn": return .exclamationTriangle
        case "question": return .iCircle
        case "spark": return .starCircleTriangleAi
        case "list": return .threeHorizontalLines
        case "star": return .star
        case "clock": return .clock
        case "mic": return .speechBubble
        case "agent": return .magicWand
        case "task": return .checkmarkCircle
        // The toolkit's set has no paperclip: stacked sheets stand for "files".
        case "clip": return .twoSquaresStackedRightDown
        default: return nil
        }
    }

    private static func toneIcon(_ tone: String?) -> IconName? {
        switch tone {
        case "good": return .checkmarkCircle
        case "warn": return .exclamationTriangle
        case "bad": return .exclamationCircle
        default: return nil
        }
    }

    private static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
