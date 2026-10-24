import AppKit

enum ProviderIcons {
    static let grok = GrokMenuIcon.image

    /// Menu bar + popover mark. Upstream `Resources/GrokBotIcon.svg`, unmodified, loaded as a
    /// 16 pt template image (`isTemplate = true`) so it follows light/dark menu bars.
    static let grokBot: NSImage = templateIcon(
        names: ["GrokBotIcon", "GrokBotIcon@2x", "GrokBotIcon@3x"],
        svgName: "GrokBotIcon",
        symbol: "face.smiling",
        accessibility: "Grok Bot"
    )

    static let cursor: NSImage = templateIcon(
        names: ["CursorIcon", "CursorIcon@2x"],
        svgName: "CursorIcon",
        symbol: "chevron.right.2",
        accessibility: "Cursor"
    )

    private static func templateIcon(
        names: [String],
        svgName: String,
        symbol: String,
        accessibility: String
    ) -> NSImage {
        let pointSize = NSSize(width: 16, height: 16)
        let img = NSImage(size: pointSize)
        img.isTemplate = true

        for name in names {
            let url = Bundle.main.url(forResource: name, withExtension: "png")
                ?? Bundle.main.resourceURL?.appendingPathComponent("\(name).png")
            guard let url,
                  FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data)
            else { continue }
            rep.size = pointSize
            img.addRepresentation(rep)
        }

        if img.representations.isEmpty,
           let svg = Bundle.main.url(forResource: svgName, withExtension: "svg"),
           let svgImage = NSImage(contentsOf: svg)
        {
            svgImage.size = pointSize
            svgImage.isTemplate = true
            return svgImage
        }

        if img.representations.isEmpty {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            if let symbol = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)?
                .withSymbolConfiguration(config)
            {
                symbol.isTemplate = true
                return symbol
            }
        }

        img.isTemplate = true
        return img
    }
}
