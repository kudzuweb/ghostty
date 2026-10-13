import AppKit
import SwiftUI

enum TerminalTabColor: Int, CaseIterable, Codable {
    case none
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case teal
    case graphite
    case brightRed
    case brightGreen
    case brightYellow
    case brightBlue
    case brightTeal

    var localizedName: String {
        switch self {
        case .none:
            return "None"
        case .blue:
            return "Blue"
        case .purple:
            return "Purple"
        case .pink:
            return "Pink"
        case .red:
            return "Red"
        case .orange:
            return "Orange"
        case .yellow:
            return "Yellow"
        case .green:
            return "Green"
        case .teal:
            return "Teal"
        case .graphite:
            return "Graphite"
        case .brightRed:
            return "Bright Red"
        case .brightGreen:
            return "Bright Green"
        case .brightYellow:
            return "Bright Yellow"
        case .brightBlue:
            return "Bright Blue"
        case .brightTeal:
            return "Bright Teal"
        }
    }

    var displayColor: NSColor? {
        switch self {
        case .none:
            return nil
        case .blue:
            return .systemBlue
        case .purple:
            return .systemPurple
        case .pink:
            return .systemPink
        case .red:
            return .systemRed
        case .orange:
            return .systemOrange
        case .yellow:
            return .systemYellow
        case .green:
            return .systemGreen
        case .teal:
            if #available(macOS 13.0, *) {
                return .systemMint
            } else {
                return .systemTeal
            }
        case .graphite:
            return .systemGray
        case .brightRed:
            return Self.brightened(.systemRed)
        case .brightGreen:
            return Self.brightened(.systemGreen)
        case .brightYellow:
            return Self.brightened(.systemYellow)
        case .brightBlue:
            return Self.brightened(.systemBlue)
        case .brightTeal:
            return Self.brightened(.systemTeal)
        }
    }

    /// The system color blended 35% toward white, the fallback for the bright colors
    /// when no theme palette is in play.
    private static func brightened(_ color: NSColor) -> NSColor {
        color.blended(withFraction: 0.35, of: .white) ?? color
    }

    func swatchImage(selected: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        return NSImage(size: size, flipped: false) { rect in
            let circleRect = rect.insetBy(dx: 1, dy: 1)
            let circlePath = NSBezierPath(ovalIn: circleRect)

            if let fillColor = self.displayColor {
                fillColor.setFill()
                circlePath.fill()
            } else {
                NSColor.clear.setFill()
                circlePath.fill()
                NSColor.quaternaryLabelColor.setStroke()
                circlePath.lineWidth = 1
                circlePath.stroke()
            }

            if self == .none {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: circleRect.minX + 2, y: circleRect.minY + 2))
                slash.line(to: NSPoint(x: circleRect.maxX - 2, y: circleRect.maxY - 2))
                slash.lineWidth = 1.5
                NSColor.secondaryLabelColor.setStroke()
                slash.stroke()
            }

            if selected {
                let highlight = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
                highlight.lineWidth = 2
                NSColor.controlAccentColor.setStroke()
                highlight.stroke()
            }

            return true
        }
    }
}

// MARK: - Menu View

/// A SwiftUI view displaying a color palette for tab color selection.
/// Used as a custom view inside an NSMenuItem in the tab context menu.
struct TabColorMenuView: View {
    @State private var currentSelection: TerminalTabColor
    let title: String
    let onSelect: (TerminalTabColor) -> Void

    init(
        selectedColor: TerminalTabColor,
        title: String = "Tab Color",
        onSelect: @escaping (TerminalTabColor) -> Void
    ) {
        self._currentSelection = State(initialValue: selectedColor)
        self.title = title
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .padding(.bottom, 2)

            ForEach(Self.paletteRows, id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(row, id: \.self) { color in
                        TabColorSwatch(
                            color: color,
                            isSelected: color == currentSelection
                        ) {
                            currentSelection = color
                            onSelect(color)
                        }
                    }
                }
            }
        }
        .padding(.leading, Self.leadingPadding)
        .padding(.trailing, 12)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    static let paletteRows: [[TerminalTabColor]] = [
        [.none, .blue, .purple, .pink, .red],
        [.orange, .yellow, .green, .teal, .graphite],
        [.brightRed, .brightYellow, .brightGreen, .brightTeal, .brightBlue],
    ]

    /// Leading padding to align with the menu's icon gutter.
    /// macOS 26 introduced icons in menus, requiring additional padding.
    private static var leadingPadding: CGFloat {
        if #available(macOS 26.0, *) {
            return 40
        } else {
            return 12
        }
    }
}

/// A single color swatch button in the tab color palette.
private struct TabColorSwatch: View {
    let color: TerminalTabColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if color == .none {
                    Image(systemName: isSelected ? "circle.slash" : "circle")
                        .foregroundStyle(.secondary)
                } else if let displayColor = color.displayColor {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle.fill")
                        .foregroundStyle(Color(nsColor: displayColor))
                }
            }
            .font(.system(size: 16))
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(color.localizedName)
    }
}
