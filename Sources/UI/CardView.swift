import SwiftUI

/// The phone's copy of the card on the lens, drawn from the same data. Its
/// buttons work: the phone alone is enough to decide.
struct CardView: View {
    let card: LensCard
    let footer: String?
    let onAction: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            head
            if let title = card.title, !title.isEmpty {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array((card.lines ?? []).prefix(3).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let tiles = card.tiles, !tiles.isEmpty { tileRow(tiles) }
            ForEach(Array((card.rows ?? []).prefix(5).enumerated()), id: \.offset) { _, row in rowLine(row) }
            ForEach(Array((card.blocks ?? []).prefix(6).enumerated()), id: \.offset) { _, block in blockLine(block) }
            if let chips = card.chips, !chips.isEmpty { chipRow(chips) }
            if let hint = card.hint, !hint.isEmpty {
                Text(hint).font(.footnote).foregroundStyle(.secondary)
            }
            if let footer, !footer.isEmpty {
                Text(footer).font(.footnote).foregroundStyle(.secondary)
            }
            buttons
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(card.danger == true ? Color.red.opacity(0.7) : Color(white: 0.2)))
    }

    private var head: some View {
        HStack(spacing: 8) {
            if card.danger == true {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
            } else if let name = Symbols.name(card.icon) {
                Image(systemName: name).foregroundStyle(.secondary)
            }
            if let meta = card.meta, !meta.isEmpty {
                Text(meta).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let position = card.position, !position.isEmpty {
                Text(position).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let page = card.page, !page.isEmpty {
                Text("p \(page)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func tileRow(_ tiles: [LensTile]) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(tiles.prefix(3).enumerated()), id: \.offset) { _, tile in
                VStack(spacing: 2) {
                    Text(tile.value).font(.title.weight(.semibold).monospacedDigit())
                    Text(tile.label).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private func rowLine(_ row: LensRow) -> some View {
        let line = HStack(spacing: 8) {
            Image(systemName: row.done == true ? "checkmark.circle" : (Symbols.name(row.icon) ?? "chevron.right"))
                .foregroundStyle(.secondary)
            Text(row.title).lineLimit(1)
            if let meta = row.meta, !meta.isEmpty {
                Text(meta).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        if let id = row.id, !id.isEmpty {
            Button { onAction(id) } label: { line }
                .buttonStyle(.plain)
        } else {
            line
        }
    }

    private func blockLine(_ block: LensBlock) -> some View {
        HStack(spacing: 8) {
            Text(block.start).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            Text(block.title).lineLimit(1).foregroundStyle(block.done == true ? .secondary : .primary)
            Spacer(minLength: 0)
            if let minutes = block.minutes {
                Text("\(minutes) min").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func chipRow(_ chips: [LensChip]) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(chips.prefix(2).enumerated()), id: \.offset) { _, chip in
                HStack(spacing: 5) {
                    if let name = Symbols.name(chip.icon) { Image(systemName: name) }
                    Text(chip.text).lineLimit(1)
                }
                .font(.footnote)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(Symbols.tone(chip.tone))
                .background(Color(white: 0.15), in: Capsule())
            }
        }
    }

    private var buttons: some View {
        let actions = Array((card.actions ?? []).prefix(4))
        return HStack(spacing: 8) {
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                Button { onAction(action.id) } label: {
                    Text(action.label)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .foregroundStyle(index == 0 && action.style != "danger" ? Color.black : (action.style == "danger" ? Color.red : Color.white))
                .background(index == 0 && action.style != "danger" ? Color.white : Color(white: 0.17), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
        }
    }
}

/// MailPilot's icon names as SF Symbols, and its tones as colours.
enum Symbols {
    static func name(_ icon: String?) -> String? {
        switch icon {
        case "mail": return "envelope"
        case "person": return "person"
        case "calendar": return "calendar"
        case "cart": return "cart"
        case "code": return "chevron.left.forwardslash.chevron.right"
        case "ticket": return "number"
        case "news": return "megaphone"
        case "lock": return "lock"
        case "bell": return "bell"
        case "sun": return "sun.max"
        case "pencil": return "pencil"
        case "reply": return "arrowshape.turn.up.left"
        case "folder": return "folder"
        case "check": return "checkmark"
        case "clip": return "paperclip"
        case "battery": return "battery.25"
        case "question": return "questionmark.circle"
        case "spark": return "sparkles"
        case "list": return "list.bullet"
        case "star": return "star"
        case "clock": return "clock"
        case "mic": return "mic"
        case "agent": return "wand.and.stars"
        case "task": return "checkmark.circle"
        default: return nil
        }
    }

    static func tone(_ tone: String?) -> Color {
        switch tone {
        case "accent": return Color(red: 0.55, green: 0.75, blue: 1.0)
        case "good": return Color(red: 0.45, green: 0.85, blue: 0.55)
        case "warn": return Color(red: 1.0, green: 0.75, blue: 0.3)
        case "bad": return Color(red: 1.0, green: 0.45, blue: 0.4)
        default: return Color.white
        }
    }
}
