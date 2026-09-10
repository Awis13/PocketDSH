import SwiftUI
import UIKit
import SwiftTerm
import CoreText

/// One palette and font for the live PTY, retained blocks and Find results.
/// Explicit 256-color/RGB output is left as supplied by the command.
struct TerminalAppearance: Equatable {
    var palette: [Int]
    var foreground: Int
    var background: Int
    var size: CGFloat

    init(theme: HarnessTheme, scheme: ColorScheme) {
        let dark = scheme == .dark
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        func rgb(_ color: SwiftUI.Color) -> Int {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            return Int(r * 255) << 16 | Int(g * 255) << 8 | Int(b * 255)
        }
        foreground = rgb(theme.ink); background = rgb(theme.canvas); size = theme.messageSize
        switch theme {
        case .dracula:
            palette = [0x282a36, 0xff5555, 0x50fa7b, 0xf1fa8c, 0xbd93f9, 0xff79c6, 0x8be9fd, 0xf8f8f2,
                       0x6272a4, 0xff6e6e, 0x69ff94, 0xffffa5, 0xd6acff, 0xff92df, 0xa4ffff, 0xffffff]
        case .nord:
            palette = [0x3b4252, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x88c0d0, 0xe5e9f0,
                       0x65738b, 0xd57780, 0xb5d09e, 0xf5d99e, 0x91b1d1, 0xc49ebd, 0x9ad2e2, 0xeceff4]
        default:
            // Theme accent colors the navigation/directory slot; semantic ANSI
            // red/green/yellow remain distinguishable, including in light themes.
            palette = dark
                ? [0x242936, 0xf47067, 0x77cc9e, 0xe8c56e, rgb(theme.accent), 0xd59fe8, 0x80cbd3, foreground,
                   0x7b849a, 0xff8e85, 0x99e4b9, 0xf9de92, rgb(theme.accent), 0xe4b5f4, 0xa0e3e9, 0xffffff]
                : [0x252a34, 0xb42328, 0x217a43, 0x876300, rgb(theme.accent), 0x8e3aa6, 0x067582, foreground,
                   0x646d7b, 0xc22d33, 0x248247, 0x906700, rgb(theme.accent), 0x943fab, 0x087b86, 0x6c7480]
        }
    }

    static func color(_ rgb: Int) -> SwiftUI.Color { SwiftUI.Color(hex: UInt32(rgb)) }

    private static let symbols: UIFont? = {
        // UIAppFonts normally loads it; explicitly register the bundled face if
        // the terminal is constructed before automatic font registration.
        if let font = UIFont(name: "SymbolsNFM", size: 16) { return font }
        if let url = Bundle.main.url(forResource: "SymbolsNerdFontMono-Regular", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        let font = UIFont(name: "SymbolsNFM", size: 16)
        #if DEBUG
        if font == nil { NSLog("PocketDSH: bundled terminal symbol font is unavailable") }
        #endif
        return font
    }()

    static func font(size: CGFloat, bold: Bool = false, italic: Bool = false) -> UIFont {
        let base = UIFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
        var descriptor = base.fontDescriptor
        if italic, let slanted = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) { descriptor = slanted }
        // The small bundled symbol font also works on iPad; letters retain SF Mono.
        // Keep the system cascade for emoji, CJK, Cyrillic and other scripts.
        if let symbols = symbols?.withSize(size) {
            let fallback = (descriptor.object(forKey: .cascadeList) as? [UIFontDescriptor]) ?? []
            descriptor = descriptor.addingAttributes([.cascadeList: [symbols.fontDescriptor] + fallback])
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    static func symbolFont(size: CGFloat) -> Font {
        Font(symbolUIFont(size: size) ?? font(size: size))
    }

    private static func symbolUIFont(size: CGFloat) -> UIFont? {
        // SymbolsOnly uses a square em. Fit it to the body's one-column advance.
        let body = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let advance = ("W" as NSString).size(withAttributes: [.font: body]).width
        return symbols?.withSize(advance)
    }

    func apply(to terminal: NativeTerminalSurface) {
        guard terminal.appearance != self else { return }
        terminal.appearance = self
        let iconFont = Self.symbolUIFont(size: size)
        terminal.characterFont = { character in
            character.unicodeScalars.contains { (0xE000...0xF8FF).contains($0.value) || (0xF0000...0x10FFFD).contains($0.value) } ? iconFont : nil
        }
        terminal.nativeBackgroundColor = UIColor(Self.color(background))
        terminal.nativeForegroundColor = UIColor(Self.color(foreground))
        if terminal.font.pointSize != size || terminal.font.fontDescriptor.object(forKey: .cascadeList) == nil {
            terminal.font = Self.font(size: size)
        }
        terminal.installColors(palette.map { rgb in
            SwiftTerm.Color(red: UInt16((rgb >> 16) & 255) * 257, green: UInt16((rgb >> 8) & 255) * 257, blue: UInt16(rgb & 255) * 257)
        })
    }
}

extension NativeBlock {
    func attributedOutput(appearance: TerminalAppearance) -> AttributedString {
        let fonts = [false, true].flatMap { bold in
            [false, true].map { Font(TerminalAppearance.font(size: appearance.size, bold: bold, italic: $0)) }
        }
        func color(_ rgb: Int?, _ index: Int?, fallback: Int) -> Int {
            if let index, appearance.palette.indices.contains(index) { return appearance.palette[index] }
            return rgb ?? fallback
        }
        var output = AttributedString()
        for run in styledOutput.isEmpty ? [NativeStyledRun(text: preview)] : styledOutput {
            var text = AttributedString(run.text)
            let fg = color(run.foreground, run.foregroundIndex, fallback: appearance.foreground)
            let bg = color(run.background, run.backgroundIndex, fallback: appearance.background)
            text.foregroundColor = TerminalAppearance.color(run.inverse ? bg : fg).opacity(run.dim ? 0.6 : 1)
            if run.inverse || run.background != nil || run.backgroundIndex != nil {
                text.backgroundColor = TerminalAppearance.color(run.inverse ? fg : bg)
            }
            text.font = fonts[(run.bold ? 2 : 0) + (run.italic ? 1 : 0)]
            // SwiftUI can rebuild a UIFont without its custom cascade. Give Nerd
            // Font's private-use glyphs an explicit face in retained text too.
            for index in text.characters.indices {
                let character = text.characters[index]
                if character.unicodeScalars.contains(where: { (0xE000...0xF8FF).contains($0.value) || (0xF0000...0x10FFFD).contains($0.value) }) {
                    let end = text.characters.index(after: index)
                    text[index..<end].font = TerminalAppearance.symbolFont(size: appearance.size)
                }
            }
            if run.underline { text.underlineStyle = .single }
            if run.crossedOut { text.strikethroughStyle = .single }
            output += text
        }
        return output
    }
}
