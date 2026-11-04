import AppKit
import RofiCore

extension MarkupText {
    /// The text drawn in `font` and `color`, with each run's markup on top, so
    /// markup colors win over `color` (upstream's Pango attributes override the
    /// theme's text color). With `overridingColors`, markup foregrounds yield
    /// to `color` instead, which keeps the emphasized cursor row readable on
    /// the accent fill; markup backgrounds stay.
    func attributedString(
        font: NSFont,
        color: NSColor,
        lineBreakMode: NSLineBreakMode,
        overridingColors: Bool = false
    ) -> NSAttributedString {
        // An attributed string ignores the field's lineBreakMode.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreakMode
        let string = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        )
        for run in runs {
            let style = run.attributes
            let range = NSRange(run.range, in: text)
            string.addAttribute(.font, value: style.font(base: font), range: range)
            if style.underline {
                string.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            if style.strikethrough {
                string.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            if let script = style.script {
                string.addAttribute(
                    .baselineOffset, value: (script == .sup ? 1 : -1) * font.pointSize / 3, range: range)
            }
            if let foreground = style.foreground, !overridingColors {
                string.addAttribute(.foregroundColor, value: NSColor(foreground), range: range)
            }
            if let background = style.background {
                string.addAttribute(.backgroundColor, value: NSColor(background), range: range)
            }
        }
        return string
    }
}

extension MarkupAttributes {
    /// `base`, or the system monospaced font or `fontFamily` when set, at the
    /// markup's size with its bold and italic traits.
    fileprivate func font(base: NSFont) -> NSFont {
        let size = CGFloat((pointSize ?? Double(base.pointSize)) * scale)
        let font =
            monospace
            ? .monospacedSystemFont(ofSize: size, weight: .regular)
            : fontFamily.flatMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: size) }
                ?? NSFont(descriptor: base.fontDescriptor, size: size) ?? base
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: size) ?? font
    }
}

extension NSColor {
    fileprivate convenience init(_ color: MarkupColor) {
        self.init(
            srgbRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: CGFloat(color.alpha) / 255
        )
    }
}
