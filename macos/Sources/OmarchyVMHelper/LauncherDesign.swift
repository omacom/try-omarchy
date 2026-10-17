import SwiftUI

/// The official Omarchy mark from omacom/omarchy-site, as drawn in
/// macos/OmarchyIcon.svg (a 1200-unit square, even-odd fill).
struct OmarchyMark: Shape {
    private static let outlines: [[CGPoint]] = [
        [
            CGPoint(x: 1200, y: 1200), CGPoint(x: 720, y: 1200), CGPoint(x: 720, y: 1120),
            CGPoint(x: 1120, y: 1120), CGPoint(x: 1120, y: 80), CGPoint(x: 640.004, y: 80),
            CGPoint(x: 640.004, y: 240), CGPoint(x: 240.004, y: 240), CGPoint(x: 240.004, y: 960),
            CGPoint(x: 960.004, y: 960), CGPoint(x: 960.004, y: 240), CGPoint(x: 880.004, y: 240),
            CGPoint(x: 880.004, y: 160), CGPoint(x: 1040, y: 160), CGPoint(x: 1040, y: 1040),
            CGPoint(x: 640, y: 1040), CGPoint(x: 640, y: 1200), CGPoint(x: 0, y: 1200),
            CGPoint(x: 0, y: 0), CGPoint(x: 1200, y: 0),
        ],
        [
            CGPoint(x: 80, y: 1120), CGPoint(x: 560, y: 1120), CGPoint(x: 560, y: 1040),
            CGPoint(x: 160, y: 1040), CGPoint(x: 160.004, y: 640), CGPoint(x: 80, y: 640),
        ],
        [
            CGPoint(x: 80, y: 560), CGPoint(x: 160.004, y: 560), CGPoint(x: 160.004, y: 160),
            CGPoint(x: 560.004, y: 160), CGPoint(x: 560.004, y: 80), CGPoint(x: 80, y: 80),
        ],
    ]

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / 1200
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        var path = Path()
        for outline in Self.outlines {
            path.addLines(outline.map { CGPoint(x: origin.x + $0.x * scale, y: origin.y + $0.y * scale) })
            path.closeSubpath()
        }
        return path
    }
}

enum OmarchyBrand {
    static let green = Color(red: 0x9E / 255, green: 0xCE / 255, blue: 0x6A / 255)
    static let tile = Color(red: 0x15 / 255, green: 0x19 / 255, blue: 0x12 / 255)
}

/// The app icon tile: the Omarchy mark on its dark rounded square.
struct OmarchyAppTile: View {
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.232, style: .continuous)
            .fill(OmarchyBrand.tile.gradient)
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.232, style: .continuous)
                    .strokeBorder(OmarchyBrand.green.opacity(0.28), lineWidth: max(0.5, size / 256))
            }
            .overlay {
                OmarchyMark()
                    .fill(OmarchyBrand.green, style: FillStyle(eoFill: true))
                    .padding(size * 0.136)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.18), radius: size / 24, y: size / 48)
    }
}

/// A System Settings–style icon: a white glyph on a small colored tile.
struct SettingIcon: View {
    enum Glyph {
        case symbol(String)
        case omarchy
    }

    let glyph: Glyph
    let color: Color

    init(_ symbol: String, _ color: Color) {
        glyph = .symbol(symbol)
        self.color = color
    }

    private init(glyph: Glyph, color: Color) {
        self.glyph = glyph
        self.color = color
    }

    static let omarchy = SettingIcon(glyph: .omarchy, color: OmarchyBrand.tile)

    @Environment(\.settingIconSize) private var size

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
            .fill(color.gradient)
            .overlay {
                switch glyph {
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: size * 0.5, weight: .semibold))
                        .foregroundStyle(.white)
                case .omarchy:
                    OmarchyMark()
                        .fill(OmarchyBrand.green, style: FillStyle(eoFill: true))
                        .padding(size * 0.19)
                }
            }
            .frame(width: size, height: size)
    }
}

extension EnvironmentValues {
    @Entry var settingIconSize: CGFloat = 26
}

/// One settings row: icon, title with an optional badge, secondary detail
/// lines, and trailing controls.
struct SettingRow<Trailing: View>: View {
    let icon: SettingIcon
    let title: String
    var badge: String?
    var detail: [String]
    var warning: String?
    var trailing: Trailing

    init(
        icon: SettingIcon,
        title: String,
        badge: String? = nil,
        detail: [String],
        warning: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.icon = icon
        self.title = title
        self.badge = badge
        self.detail = detail
        self.warning = warning
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    if let badge { Badge(text: badge) }
                }
                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .labelStyle(CompactLabelStyle())
                }
                ForEach(detail, id: \.self) { line in
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            HStack(spacing: 8) { trailing }
                .fixedSize()
        }
        .padding(.vertical, 2)
    }
}

struct Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(.quaternary))
    }
}

/// A trailing status such as "Allowed" or "Up to Date".
struct StatusLabel: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// Secondary text under a grouped section, aligned with the rows above it.
struct SectionNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
