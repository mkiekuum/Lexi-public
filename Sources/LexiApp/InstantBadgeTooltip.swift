import SwiftUI

/// Preferences carry a badge's exact layout anchor to the window's SwiftUI overlay.
/// No panel, screen-coordinate conversion, or delayed system tooltip is involved.
struct BadgeTooltipAnchor {
    let text: String
    let bounds: Anchor<CGRect>
}

struct BadgeTooltipPreference: PreferenceKey {
    static var defaultValue: BadgeTooltipAnchor? { nil }
    static func reduce(value: inout BadgeTooltipAnchor?, nextValue: () -> BadgeTooltipAnchor?) {
        if let next = nextValue() { value = next }
    }
}

struct InstantBadgeTooltip: ViewModifier {
    let text: String
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onHover { inside in hovering = inside }
            .onDisappear { hovering = false }
            .anchorPreference(key: BadgeTooltipPreference.self, value: .bounds) {
                hovering ? BadgeTooltipAnchor(text: text, bounds: $0) : nil
            }
    }
}

/// Positions the measured tooltip within the same coordinate space as its anchor.
/// Try right, then left, then below/above if the window is unusually narrow.
struct BadgeTooltipLayout: Layout {
    let anchor: CGRect
    static func origin(anchor: CGRect, size: CGSize, bounds: CGRect) -> CGPoint {
        let gap: CGFloat = 8
        let margin: CGFloat = 8
        let minX = bounds.minX + margin
        let maxX = max(minX, bounds.maxX - margin - size.width)
        let minY = bounds.minY + margin
        let maxY = max(minY, bounds.maxY - margin - size.height)
        var x: CGFloat
        var y = anchor.midY - size.height / 2
        if anchor.maxX + gap <= maxX {
            x = anchor.maxX + gap
        } else if anchor.minX - gap - size.width >= minX {
            x = anchor.minX - gap - size.width
        } else {
            x = anchor.midX - size.width / 2
            y = anchor.maxY + gap <= maxY ? anchor.maxY + gap : anchor.minY - gap - size.height
        }
        return CGPoint(x: min(max(x, minX), maxX), y: min(max(y, minY), maxY))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        let constraint = ProposedViewSize(width: min(320, max(1, bounds.width - 16)), height: max(1, bounds.height - 16))
        let size = view.sizeThatFits(constraint)
        let point = Self.origin(anchor: anchor.offsetBy(dx: bounds.minX, dy: bounds.minY), size: size, bounds: bounds)
        view.place(at: point, anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}

struct BadgeTooltipOverlay: View {
    let tip: BadgeTooltipAnchor
    var body: some View {
        GeometryReader { proxy in
            let anchor = proxy[tip.bounds]
            if CGRect(origin: .zero, size: proxy.size).intersects(anchor) {
                BadgeTooltipLayout(anchor: anchor) {
                    Text(tip.text)
                        .lexiFont(LexiTypography.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.primary.opacity(0.14), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
                        .accessibilityIdentifier("instantBadgeTooltip")
                }
            }
        }
        .allowsHitTesting(false)
    }
}
