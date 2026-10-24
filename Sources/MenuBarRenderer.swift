import AppKit

enum MenuBarRenderer {
    @MainActor
    static func image(model: UsageViewModel) -> NSImage {
        let barHeight = NSStatusBar.system.thickness
        let iconSide: CGFloat = 16
        let gap: CGFloat = 5
        let clusterGap: CGFloat = 10
        let font = NSFont.menuBarFont(ofSize: 0)
        let color = menuBarTextColor()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]

        struct Cluster {
            var icon: NSImage?
            var primary: NSAttributedString
            var extra: [NSAttributedString]
        }

        var clusters: [Cluster] = []

        // One item: the shared X Subscription pool from the Grok session.
        let text: String
        switch model.state {
        case .loaded(let snap):
            text = barText(percent: snap.usedPercent, resetsIn: snap.resetsIn, showDaysLeft: model.showDaysLeft)
        case .unavailable:
            text = model.hasActiveOutage ? "⚠" : "—"
        case .failed:
            text = model.hasActiveOutage ? "⚠" : "!"
        case .idle, .loading:
            text = model.hasActiveOutage ? "⚠" : "…"
        }
        clusters.append(Cluster(icon: ProviderIcons.grok, primary: NSAttributedString(string: text, attributes: attrs), extra: []))

        var width: CGFloat = 0
        for (i, cluster) in clusters.enumerated() {
            if i > 0 { width += clusterGap }
            if cluster.icon != nil { width += iconSide + gap }
            width += cluster.primary.size().width
            for extra in cluster.extra {
                width += gap + extra.size().width
            }
        }
        width += 2

        let size = NSSize(width: ceil(width), height: barHeight)
        let image = NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = 0
            for (i, cluster) in clusters.enumerated() {
                if i > 0 { x += clusterGap }
                if let icon = cluster.icon {
                    let iconY = (barHeight - iconSide) / 2
                    tinted(icon, color: color).draw(
                        in: NSRect(x: x, y: iconY, width: iconSide, height: iconSide),
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1,
                        respectFlipped: true,
                        hints: [.interpolation: NSImageInterpolation.high]
                    )
                    x += iconSide + gap
                }
                let primarySize = cluster.primary.size()
                cluster.primary.draw(at: NSPoint(x: x, y: (barHeight - primarySize.height) / 2))
                x += primarySize.width
                for extra in cluster.extra {
                    x += gap
                    let extraSize = extra.size()
                    extra.draw(at: NSPoint(x: x, y: (barHeight - extraSize.height) / 2))
                    x += extraSize.width
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// "42%" when "Show days left" is off; "42% · 3d" when on and a reset date is known.
    static func barText(percent: Double, resetsIn: TimeInterval?, showDaysLeft: Bool) -> String {
        let pct = "\(Int(percent.rounded()))%"
        if showDaysLeft, let days = daysLeftLabel(resetsIn) {
            return "\(pct) · \(days)"
        }
        return pct
    }

    private static func menuBarTextColor() -> NSColor {
        .labelColor
    }

    private static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        let size = image.size
        let out = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            image.draw(in: rect)
            ctx.setBlendMode(.sourceIn)
            color.setFill()
            ctx.fill(rect)
            return true
        }
        return out
    }
}
