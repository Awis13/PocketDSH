import SwiftUI
import Observation
import UniformTypeIdentifiers

enum HarnessTheme: String, CaseIterable, Identifiable {
    case system, light, dark, dracula, nord, pixel, glass, hacker, custom
    var id: String { rawValue }
    var title: String {
        switch self { case .system: "System"; case .light: "Light"; case .dark: "Dark"; case .dracula: "Dracula"; case .nord: "Nord"; case .pixel: "Pixel Quest"; case .glass: "Liquid Glass"; case .hacker: "Ghost Protocol"; case .custom: ThemeStudio.shared.palette.name }
    }
    var scheme: ColorScheme? {
        switch self { case .system, .glass: nil; case .light: .light; case .custom: ThemeStudio.shared.palette.dark ? .dark : .light; default: .dark }
    }
    var canvas: Color {
        switch self {
        case .dracula: Color(hex: 0x282A36)
        case .nord: Color(hex: 0x2E3440)
        case .pixel: Color(hex: 0x19152F)
        case .glass: Color(uiColor: .systemBackground)
        case .custom: Color(hex: ThemeStudio.shared.palette.canvas)
        case .hacker: Color(hex: 0x070E13)
        default: Color(uiColor: .systemBackground)
        }
    }
    var surface: Color {
        switch self {
        case .dracula: Color(hex: 0x343746)
        case .nord: Color(hex: 0x3B4252)
        case .pixel: Color(hex: 0x30254C)
        case .glass: Color(uiColor: .secondarySystemBackground)
        case .custom: Color(hex: ThemeStudio.shared.palette.surface)
        case .hacker: Color(hex: 0x0D1D25)
        default: Color(uiColor: .secondarySystemBackground)
        }
    }
    var accent: Color {
        switch self {
        case .dracula: Color(hex: 0xBD93F9)
        case .nord: Color(hex: 0x88C0D0)
        case .pixel: Color(hex: 0xE6F68A)
        case .glass: Color.blue
        case .custom: Color(hex: ThemeStudio.shared.palette.accent)
        case .hacker: Color(hex: 0x66FFB2)
        default: Color(hex: 0xD45D3D)
        }
    }
    var ink: Color {
        switch self { case .dracula: Color(hex: 0xF8F8F2); case .nord: Color(hex: 0xECEFF4); case .pixel: Color(hex: 0xFFF1D4); case .glass: .primary; case .custom: Color(hex: ThemeStudio.shared.palette.ink); case .hacker: Color(hex: 0xD2F7ED); default: .primary }
    }
    var glassSettings: StudioGlass {
        if self == .glass { return StudioGlass(style: "regular") }
        return self == .custom ? (ThemeStudio.shared.palette.glass ?? StudioGlass()) : StudioGlass()
    }
    var usesGlass: Bool { glassSettings.style != "off" }
    var messageSize: CGFloat { self == .custom ? glassSettings.fontSize : 16 }
    var digital: Bool { self == .pixel || self == .hacker }
    var design: Font.Design {
        if self == .custom { switch ThemeStudio.shared.palette.font { case "mono": return .monospaced; case "rounded": return .rounded; case "serif": return .serif; default: return .default } }
        return digital ? .monospaced : .default
    }
    var subtitle: String {
        switch self {
        case .system: "Follow your iPhone settings"
        case .light: "Clean canvas · classic Harness"
        case .dark: "Deep black · soft contrast"
        case .dracula: "Purple accents · warm text"
        case .nord: "Arctic palette · icy blue"
        case .pixel: "8-bit edges · moonlit arcade"
        case .glass: "Liquid controls · luminous layers"
        case .hacker: "Neon terminals · ASCII signals"
        case .custom: "Your colors · your rules"
        }
    }

}
extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255) }
}
private struct HarnessThemeKey: EnvironmentKey { static let defaultValue = HarnessTheme.system }
extension EnvironmentValues {
    var harnessTheme: HarnessTheme {
        get { self[HarnessThemeKey.self] }
        set { self[HarnessThemeKey.self] = newValue }
    }
}
struct AppearanceView: View {
    @AppStorage("harness.theme") private var selection = HarnessTheme.system.rawValue
    @Environment(\.dismiss) private var dismiss
    @Environment(\.harnessTheme) private var theme
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Your Harness.\nYour style.").font(.system(size: 30, weight: .bold)).padding(.vertical, 16)
                    NavigationLink { ThemeStudioView() } label: {
                        HStack {
                            Image(systemName: "slider.horizontal.3").font(.title2)
                            VStack(alignment: .leading, spacing: 4) { Text("Theme Studio").font(.headline); Text("Mix colors. Save a mood. Make it yours.").font(.caption) }
                            Spacer(); Image(systemName: "chevron.right")
                        }.padding(18).background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                    }.buttonStyle(.plain).accessibilityIdentifier("themeStudio")
                    ForEach(HarnessTheme.allCases) { option in
                        Button { selection = option.rawValue } label: {
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Capsule().fill(option.accent).frame(width: 24, height: 4)
                                    Capsule().fill(option.ink.opacity(0.75)).frame(width: 38, height: 4)
                                    Capsule().fill(option.ink.opacity(0.25)).frame(width: 30, height: 4)
                                }.padding(14).background(option.canvas, in: RoundedRectangle(cornerRadius: 12)).environment(\.colorScheme, option.scheme ?? .light)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(option.title).font(.headline)
                                    Text(option.subtitle)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: selection == option.rawValue ? "checkmark.circle.fill" : "circle").foregroundStyle(selection == option.rawValue ? theme.accent : .secondary)
                            }.padding(14).harnessSurface(radius: 18)
                        }.buttonStyle(.plain).accessibilityIdentifier("theme-" + option.rawValue).accessibilityAddTraits(selection == option.rawValue ? .isSelected : [])
                    }
                }.padding(.horizontal, 22).padding(.bottom, 25)
            }.background { ThemeBackdrop() }.foregroundStyle(theme.ink)
                .navigationTitle("Appearance").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.tint(theme.accent)
    }
}

// Decorative layers never intercept gestures or enter the accessibility tree.
struct ThemeBackdrop: View {
    @Environment(\.harnessTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                theme.canvas
                if theme == .custom {
                    let palette = ThemeStudio.shared.palette
                    if palette.pattern == "glow" {
                        LinearGradient(colors: [Color(hex: palette.glow).opacity(palette.intensity), .clear, theme.accent.opacity(palette.intensity * 0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    } else if palette.pattern != "none" {
                        Canvas { context, size in
                            var lines = Path()
                            let step: CGFloat = palette.pattern == "scanlines" ? 5 : 28
                            for y in stride(from: CGFloat(0), to: size.height, by: step) { lines.move(to: CGPoint(x: 0, y: y)); lines.addLine(to: CGPoint(x: size.width, y: y)) }
                            if palette.pattern == "grid" { for x in stride(from: CGFloat(0), to: size.width, by: step) { lines.move(to: CGPoint(x: x, y: 0)); lines.addLine(to: CGPoint(x: x, y: size.height)) } }
                            context.stroke(lines, with: .color(Color(hex: palette.glow).opacity(palette.intensity)), lineWidth: 0.5)
                        }
                    }
                } else if theme.digital {
                    Canvas { context, size in
                        if theme == .pixel {
                            for i in 0..<60 {
                                let x = CGFloat((i * 73 + 17) % max(1, Int(size.width)))
                                let y = CGFloat((i * 127 + 29) % max(1, Int(size.height)))
                                context.fill(Path(CGRect(x: x, y: y, width: i % 3 == 0 ? 4 : 2, height: i % 3 == 0 ? 4 : 2)), with: .color(theme.accent.opacity(0.13)))
                            }
                        } else {
                            var grid = Path()
                            for x in stride(from: CGFloat(0), to: size.width, by: 28) { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)) }
                            for y in stride(from: CGFloat(0), to: size.height, by: 28) { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)) }
                            context.stroke(grid, with: .color(theme.accent.opacity(0.035)), lineWidth: 0.5)
                        }
                    }
                }
            }
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}
struct PixelFrame: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(6.0, min(rect.width, rect.height) / 4)
        return Path { p in
            p.move(to: CGPoint(x: s * 2, y: 0))
            for point in [CGPoint(x: rect.width-s*2,y: 0), CGPoint(x: rect.width-s*2,y:s), CGPoint(x:rect.width-s,y:s), CGPoint(x:rect.width-s,y:s*2), CGPoint(x:rect.width,y:s*2), CGPoint(x:rect.width,y:rect.height-s*2), CGPoint(x:rect.width-s,y:rect.height-s*2), CGPoint(x:rect.width-s,y:rect.height-s), CGPoint(x:rect.width-s*2,y:rect.height-s), CGPoint(x:rect.width-s*2,y:rect.height), CGPoint(x:s*2,y:rect.height), CGPoint(x:s*2,y:rect.height-s), CGPoint(x:s,y:rect.height-s), CGPoint(x:s,y:rect.height-s*2), CGPoint(x:0,y:rect.height-s*2), CGPoint(x:0,y:s*2), CGPoint(x:s,y:s*2), CGPoint(x:s,y:s), CGPoint(x:s*2,y:s)] { p.addLine(to: point) }
            p.closeSubpath()
        }
    }
}
private struct HarnessSurface: ViewModifier {
    @Environment(\.harnessTheme) var theme
    @Environment(\.accessibilityReduceTransparency) var opaque
    var radius: CGFloat
    var control: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if theme == .pixel {
            content.background(theme.surface, in: PixelFrame())
                .overlay { PixelFrame().strokeBorderless(theme.accent.opacity(0.38)) }
        } else if theme == .hacker {
            content.background(theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 3))
                .overlay { RoundedRectangle(cornerRadius: 3).stroke(theme.accent.opacity(0.28), lineWidth: 1).allowsHitTesting(false) }
        } else if control && theme.usesGlass {
            content.modifier(ConfiguredGlassSurface(radius: radius))
        } else if theme == .glass {
            content.background(theme.surface, in: RoundedRectangle(cornerRadius: radius))
        } else if theme == .custom {
            content.background(theme.surface, in: RoundedRectangle(cornerRadius: ThemeStudio.shared.palette.radius))
                .overlay { RoundedRectangle(cornerRadius: ThemeStudio.shared.palette.radius).stroke(Color(hex: ThemeStudio.shared.palette.border).opacity(0.45), lineWidth: 1).allowsHitTesting(false) }
        } else {
            content.background(theme.surface, in: RoundedRectangle(cornerRadius: radius))
        }
    }
}
private extension Shape {
    func strokeBorderless(_ color: Color) -> some View { stroke(color, lineWidth: 2).allowsHitTesting(false) }
}
extension View {
    func harnessSurface(radius: CGFloat = 18, control: Bool = false) -> some View { modifier(HarnessSurface(radius: radius, control: control)) }
}
struct ThemeSignature: View {
    @Environment(\.harnessTheme) private var theme
    var body: some View {
        if theme.digital {
            HStack {
                Text(theme == .pixel ? "✦  P O C K E T   Q U E S T" : "[ DSH ]  // GHOST PROTOCOL")
                Spacer()
                Text(theme == .pixel ? "▰ ▰ ▰" : ">_ ").foregroundStyle(theme == .hacker ? Color(hex: 0xF27EFF) : theme.accent)
            }.font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(theme.accent)
                .padding(.horizontal, 22).padding(.bottom, 12).accessibilityHidden(true)
        }
    }
}

struct StudioPalette: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "Midnight Workshop"
    var canvas: UInt32 = 0x10141F
    var surface: UInt32 = 0x1B2436
    var ink: UInt32 = 0xE6EDF8
    var accent: UInt32 = 0x91A7FF
    var border: UInt32 = 0x52658F
    var glow: UInt32 = 0x8055D9
    var dark = true
    var font = "mono"
    var pattern = "glow"
    var intensity = 0.12
    var radius = 16.0
    var glass: StudioGlass?
    func validated() throws -> Self {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              [canvas, surface, ink, accent, border, glow].allSatisfy({ $0 <= 0xFFFFFF }),
              ["system", "mono", "rounded", "serif"].contains(font),
              ["none", "glow", "grid", "scanlines"].contains(pattern),
              intensity.isFinite, (0...0.5).contains(intensity), radius.isFinite, (0...32).contains(radius) else {
            throw HarnessError(message: "This file contains unsupported theme settings.")
        }
        if let glass { try glass.validate() }
        return self
    }
}

@Observable final class ThemeStudio {
    static let shared = ThemeStudio()
    var palette: StudioPalette { didSet { persist() } }
    var saved: [StudioPalette] { didSet { persist() } }
    private init() {
        palette = (UserDefaults.standard.data(forKey: "harness.studio.palette").flatMap { try? JSONDecoder().decode(StudioPalette.self, from: $0).validated() }) ?? StudioPalette()
        saved = (UserDefaults.standard.data(forKey: "harness.studio.saved").flatMap { try? JSONDecoder().decode([StudioPalette].self, from: $0) })?.compactMap { try? $0.validated() } ?? []
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(palette) { UserDefaults.standard.set(data, forKey: "harness.studio.palette") }
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: "harness.studio.saved") }
    }
    func save() {
        guard let valid = try? palette.validated() else { return }
        if let index = saved.firstIndex(where: { $0.id == valid.id }) { saved[index] = valid }
        else { saved.append(valid) }
    }
    func remix() {
        let hue = Double.random(in: 0...1)
        func rgb(_ brightness: Double, _ saturation: Double, offset: Double = 0) -> UInt32 {
            UIColor(hue: (hue + offset).truncatingRemainder(dividingBy: 1), saturation: saturation, brightness: brightness, alpha: 1).studioRGB
        }
        var next = palette
        next.id = UUID(); next.name = "Remix " + String(Int.random(in: 100...999))
        next.canvas = rgb(next.dark ? 0.10 : 0.98, next.dark ? 0.4 : 0.04)
        next.surface = rgb(next.dark ? 0.18 : 0.93, next.dark ? 0.35 : 0.07)
        next.ink = next.dark ? 0xEEF1FA : 0x162033
        next.accent = rgb(next.dark ? 0.95 : 0.65, 0.5, offset: 0.12)
        next.border = rgb(0.55, 0.3); next.glow = rgb(0.8, 0.6, offset: 0.45)
        palette = next
    }
    func copy(_ theme: HarnessTheme) {
        let traits = UITraitCollection(userInterfaceStyle: theme.scheme == .light ? .light : .dark)
        func rgb(_ color: Color) -> UInt32 { UIColor(color).resolvedColor(with: traits).studioRGB }
        var next = StudioPalette()
        next.name = theme.title + " Remix"; next.canvas = rgb(theme.canvas); next.surface = rgb(theme.surface)
        next.ink = rgb(theme.ink); next.accent = rgb(theme.accent); next.border = next.accent; next.glow = next.accent
        next.dark = theme.scheme != .light; next.font = theme.digital ? "mono" : "system"
        next.pattern = theme == .glass ? "none" : theme == .hacker ? "grid" : "glow"
        next.glass = theme.glassSettings
        palette = next
    }
}
private extension UIColor {
    var studioRGB: UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ x: CGFloat) -> UInt32 { UInt32((min(1, max(0, x)) * 255).rounded()) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }
}
struct ThemeFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var palette: StudioPalette
    init(_ palette: StudioPalette) { self.palette = palette }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, data.count < 64_000 else { throw HarnessError(message: "Choose a Pocket DSH theme JSON file smaller than 64 KB.") }
        palette = try JSONDecoder().decode(StudioPalette.self, from: data).validated()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(palette.validated()))
    }
}
struct ThemeStudioView: View {
    @Bindable private var studio = ThemeStudio.shared
    @AppStorage("harness.theme") private var selection = HarnessTheme.system.rawValue
    @State private var importing = false
    @State private var exporting = false
    @State private var problem: String?
    @State private var savedNotice = false
    private func glassBinding<T>(_ key: WritableKeyPath<StudioGlass, T>) -> Binding<T> {
        Binding(get: { (studio.palette.glass ?? StudioGlass())[keyPath: key] }, set: { value in
            var settings = studio.palette.glass ?? StudioGlass(); settings[keyPath: key] = value
            studio.palette.glass = settings; activate()
        })
    }
    private func activate() { selection = HarnessTheme.custom.rawValue }
    private func color(_ key: WritableKeyPath<StudioPalette, UInt32>) -> Binding<Color> {
        Binding(get: { Color(hex: studio.palette[keyPath: key]) }, set: { studio.palette[keyPath: key] = UIColor($0).studioRGB; activate() })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Your own little universe.").font(.title.bold())
                    Text("Changes are saved automatically. Save named versions to keep a collection.").font(.callout).foregroundStyle(.secondary)
                    TextField("Theme name", text: $studio.palette.name).textFieldStyle(.roundedBorder).accessibilityIdentifier("studioName")
                    preview
                    HStack {
                        Button("Apply", systemImage: "checkmark") { activate() }.buttonStyle(.borderedProminent)
                        Button("Remix", systemImage: "dice") { studio.remix(); activate() }.buttonStyle(.bordered).accessibilityIdentifier("studioRemix")
                        Menu("Start from…") {
                            ForEach(HarnessTheme.allCases.filter { $0 != .custom }) { theme in Button(theme.title) { studio.copy(theme); activate() } }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Palette").font(.headline)
                    colorRow("Canvas", key: \.canvas)
                    colorRow("Surfaces", key: \.surface)
                    colorRow("Text", key: \.ink)
                    colorRow("Accent", key: \.accent)
                    colorRow("Borders", key: \.border)
                    colorRow("Atmosphere", key: \.glow)
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text("Glass & legibility").font(.headline)
                    Picker("Control material", selection: glassBinding(\.style)) {
                        Text("Solid").tag("off"); Text("Regular").tag("regular"); Text("Clear").tag("clear"); Text("Frosted").tag("frosted")
                    }.pickerStyle(.segmented).accessibilityIdentifier("studioGlassMaterial")
                    Text("Regular and Clear use native Liquid Glass on iOS 26+. Frosted uses a standard system material. Effects reveal app content beneath controls, not other apps behind the window.").font(.caption).foregroundStyle(.secondary)
                    HStack { Text("Backplate"); Slider(value: glassBinding(\.backplate), in: 0...0.8); Text("\(Int((studio.palette.glass ?? StudioGlass()).backplate * 100))%").monospacedDigit().frame(width: 44) }
                    HStack { Text("Text shadow"); Slider(value: glassBinding(\.shadow), in: 0...1); Text("\(Int((studio.palette.glass ?? StudioGlass()).shadow * 100))%").monospacedDigit().frame(width: 44) }
                    HStack { Text("Text size"); Slider(value: glassBinding(\.fontSize), in: 12...24, step: 1); Text("\(Int((studio.palette.glass ?? StudioGlass()).fontSize))").monospacedDigit().frame(width: 44) }
                    Text("Character").font(.headline)
                    Toggle("Dark interface controls", isOn: $studio.palette.dark)
                    Picker("Typeface", selection: $studio.palette.font) {
                        Text("System").tag("system"); Text("Mono").tag("mono"); Text("Rounded").tag("rounded"); Text("Serif").tag("serif")
                    }.pickerStyle(.segmented)
                    Picker("Background", selection: $studio.palette.pattern) {
                        Text("Plain").tag("none"); Text("Glow").tag("glow"); Text("Grid").tag("grid"); Text("Scanlines").tag("scanlines")
                    }.pickerStyle(.segmented)
                    HStack { Text("Atmosphere"); Slider(value: $studio.palette.intensity, in: 0...0.5); Text("\(Int(studio.palette.intensity * 100))%").monospacedDigit().frame(width: 44) }
                    HStack { Text("Corners"); Slider(value: $studio.palette.radius, in: 0...32, step: 1); Text("\(Int(studio.palette.radius))").monospacedDigit().frame(width: 44) }
                    Text("Terminal messages keep their monospace typeface.").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Collection").font(.headline)
                    HStack {
                        Button(savedNotice ? "Saved" : "Save version", systemImage: "square.and.arrow.down") { studio.save(); savedNotice = true }
                            .disabled((try? studio.palette.validated()) == nil).accessibilityIdentifier("studioSave")
                        Spacer()
                        Button("Import") { importing = true }
                        Button("Export") { exporting = true }.disabled((try? studio.palette.validated()) == nil)
                    }.buttonStyle(.bordered)
                    ForEach(studio.saved) { palette in
                        HStack {
                            Button { studio.palette = palette; activate() } label: {
                                HStack { Circle().fill(Color(hex: palette.accent)).frame(width: 14, height: 14); Text(palette.name); Spacer() }
                            }.buttonStyle(.plain)
                            Button("Duplicate", systemImage: "doc.on.doc") { studio.palette = palette; studio.palette.id = UUID(); studio.palette.name = String(palette.name.prefix(70)) + " Copy"; activate() }.labelStyle(.iconOnly)
                            Button("Delete saved version", systemImage: "trash", role: .destructive) { studio.saved.removeAll { $0.id == palette.id } }.labelStyle(.iconOnly)
                        }.padding(.vertical, 6)
                    }
                }
                Button("Reset editor to Midnight Workshop") { studio.palette = StudioPalette(); activate() }.font(.caption)
            }.padding(24).frame(maxWidth: 650).frame(maxWidth: .infinity)
        }.navigationTitle("Theme Studio").navigationBarTitleDisplayMode(.inline)
            .onChange(of: studio.palette) { _, _ in savedNotice = false }
            .fileExporter(isPresented: $exporting, document: ThemeFile(studio.palette), contentType: .json, defaultFilename: "PocketDSH-Theme") { result in if case .failure(let error) = result { problem = error.localizedDescription } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size < 64_000 else { throw HarnessError(message: "Theme files must be smaller than 64 KB.") }
                    let palette = try JSONDecoder().decode(StudioPalette.self, from: Data(contentsOf: url)).validated()
                    studio.palette = palette; studio.palette.id = UUID(); activate()
                } catch { problem = error.localizedDescription }
            }
            .alert("Theme file", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) { Button("OK") { problem = nil } } message: { Text(problem ?? "") }
    }
    private func colorRow(_ title: String, key: WritableKeyPath<StudioPalette, UInt32>) -> some View {
        HStack {
            ColorPicker(title, selection: color(key), supportsOpacity: false)
            StudioHexField(value: Binding(get: { studio.palette[keyPath: key] }, set: { studio.palette[keyPath: key] = $0; activate() }))
        }
    }
    private var preview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("❯ YOU").foregroundStyle(Color(hex: studio.palette.accent)); Spacer(); Text("LIVE PREVIEW").foregroundStyle(.secondary) }.font(.caption.monospaced())
            Text("Build something that feels like home.").modifier(HarnessTextLegibility())
            Text("◆ DSH").font(.caption.monospaced()).foregroundStyle(Color(hex: studio.palette.accent))
            Text("A place for your ideas, tools, and late-night experiments.").lineSpacing(4).modifier(HarnessTextLegibility())
            HStack { Image(systemName: "terminal"); Text("Ready when you are"); Spacer(); Image(systemName: "arrow.up") }.padding(12).harnessSurface(radius: 16, control: true)
        }.padding(20).foregroundStyle(Color(hex: studio.palette.ink)).font(.system(size: HarnessTheme.custom.messageSize, design: HarnessTheme.custom.design))
            .background { ThemeBackdrop() }.clipShape(RoundedRectangle(cornerRadius: 18))
            .environment(\.harnessTheme, .custom).environment(\.colorScheme, studio.palette.dark ? .dark : .light)
    }
}
private struct StudioHexField: View {
    @Binding var value: UInt32
    @State private var draft = ""
    @FocusState private var focused: Bool
    private var parsed: UInt32? {
        let hex = draft.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        return hex.count == 6 ? UInt32(hex, radix: 16) : nil
    }
    var body: some View {
        TextField("#RRGGBB", text: $draft).font(.system(size: 12, design: .monospaced)).textInputAutocapitalization(.characters).autocorrectionDisabled()
            .textFieldStyle(.roundedBorder).frame(width: 104).focused($focused)
            .foregroundStyle(parsed == nil ? Color.orange : Color.primary)
            .onAppear { draft = String(format: "#%06X", value) }
            .onChange(of: value) { _, new in if !focused { draft = String(format: "#%06X", new) } }
            .onChange(of: draft) { _, _ in if let parsed, parsed != value { value = parsed } }
            .onChange(of: focused) { _, new in if !new { draft = String(format: "#%06X", value) } }
    }
}

struct HarnessGlassGroup: ViewModifier {
    @Environment(\.harnessTheme) private var theme
    func body(content: Content) -> some View {
        content
    }
}
struct HarnessNavigationSurface: ViewModifier {
    @Environment(\.harnessTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var opaque
    var radius: CGFloat = 18
    func body(content: Content) -> some View {
        if theme.usesGlass { content.modifier(ConfiguredGlassSurface(radius: radius)) }
        else { content }
    }
}
struct HarnessComposerSurface: ViewModifier {
    var enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.harnessSurface(radius: 25, control: true) }
        else { content }
    }
}

struct StudioGlass: Codable, Equatable {
    var style = "off"
    var backplate = 0.0
    var shadow = 0.0
    var fontSize = 16.0
    func validate() throws {
        guard ["off", "regular", "clear", "frosted"].contains(style),
              backplate.isFinite, (0...0.8).contains(backplate),
              shadow.isFinite, (0...1).contains(shadow),
              fontSize.isFinite, (12...24).contains(fontSize) else {
            throw HarnessError(message: "Unsupported glass or typography settings.")
        }
    }
}
private struct ConfiguredGlassSurface: ViewModifier {
    @Environment(\.harnessTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var opaque
    let radius: CGFloat
    func body(content: Content) -> some View {
        let settings = theme.glassSettings
        if opaque {
            content.background(theme.surface, in: RoundedRectangle(cornerRadius: radius))
        } else if #available(iOS 26.0, *), settings.style == "regular" || settings.style == "clear" {
            content
                .background(theme.surface.opacity(settings.backplate), in: RoundedRectangle(cornerRadius: radius))
                .glassEffect(settings.style == "clear" ? .clear : .regular, in: .rect(cornerRadius: radius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius))
                .background(theme.surface.opacity(settings.backplate), in: RoundedRectangle(cornerRadius: radius))
        }
    }
}
struct HarnessTextLegibility: ViewModifier {
    @Environment(\.harnessTheme) private var theme
    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(theme.glassSettings.shadow), radius: theme.glassSettings.shadow > 0 ? 2 : 0, x: 0, y: theme.glassSettings.shadow > 0 ? 1 : 0)
    }
}
