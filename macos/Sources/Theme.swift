import SwiftUI

/// UI consumes semantic tokens, never branches on a theme's identifier.
struct CockpitTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let dark: Bool
    let palette: Palette
    var metrics = Metrics()
    var binary = false
    var collection: Collection = .original
    var detail = ""
    enum Collection: String, CaseIterable { case client = "AI 客户端", editor = "编辑器经典", original = "CoMind 原有主题" }
    func opacity(_ value: Double) -> Double { binary ? 1 : value }
    struct Palette: Equatable {
        var canvas, sidebar, surface, soft, text, muted, border, accent, emphasis, accentSoft: String
        var onAccent = "FFFFFF"
        // Some clients keep primary actions neutral while using a brand accent elsewhere.
        var primary: String? = nil
        var primaryHover: String? = nil
        var primaryDisabled: String? = nil
        var onPrimaryDisabled: String? = nil
    }
    struct Metrics: Equatable {
        var radius: CGFloat = 10
        var spacing: CGFloat = 20
        var body: CGFloat = 13
        var title: CGFloat = 22
    }
    var canvas: Color { Color(hex: palette.canvas) }
    var sidebar: Color { Color(hex: palette.sidebar) }
    var surface: Color { Color(hex: palette.surface) }
    var soft: Color { Color(hex: palette.soft) }
    var text: Color { Color(hex: palette.text) }
    var muted: Color { Color(hex: palette.muted) }
    var border: Color { Color(hex: palette.border) }
    var accent: Color { Color(hex: palette.accent) }
    var emphasis: Color { Color(hex: palette.emphasis) }
    var accentSoft: Color { Color(hex: palette.accentSoft) }
    var onAccent: Color { Color(hex: palette.onAccent) }
    var primary: Color { Color(hex: palette.primary ?? palette.accent) }
    var primaryHover: Color { Color(hex: palette.primaryHover ?? palette.emphasis) }
    var primaryDisabled: Color { Color(hex: palette.primaryDisabled ?? palette.primary ?? palette.accent) }
    var onPrimaryDisabled: Color { Color(hex: palette.onPrimaryDisabled ?? palette.onAccent) }
}

enum ThemeRegistry {
    static let version = 5
    static let all: [CockpitTheme] = [
        .init(id: "terracotta", name: "暖陶", dark: false, palette: .init(canvas: "FCFBF9", sidebar: "F1EEE8", surface: "FFFFFF", soft: "FDF3ED", text: "37352F", muted: "817A72", border: "E8E2D9", accent: "AF5035", emphasis: "8E3B26", accentSoft: "F6E7DF")),
        .init(id: "sage", name: "青苔", dark: false, palette: .init(canvas: "FAFBF8", sidebar: "EEF0E7", surface: "FFFFFF", soft: "F2F5EB", text: "2C3227", muted: "707968", border: "DFE5D7", accent: "52643C", emphasis: "354625", accentSoft: "E7EEDB")),
        .init(id: "mist", name: "雾蓝", dark: false, palette: .init(canvas: "F8FAFB", sidebar: "EAF0F3", surface: "FFFFFF", soft: "F0F4F7", text: "303A42", muted: "64737E", border: "DCE4E9", accent: "526F83", emphasis: "3D5669", accentSoft: "E1EAF0")),
        .init(id: "lilac", name: "灰紫", dark: false, palette: .init(canvas: "FAF9FC", sidebar: "EFECF3", surface: "FFFFFF", soft: "F4F1F7", text: "3C3743", muted: "766C80", border: "E3DEE9", accent: "786586", emphasis: "5E4B6D", accentSoft: "EBE4F0")),
        .init(id: "oat", name: "燕麦", dark: false, palette: .init(canvas: "FBFAF7", sidebar: "F0EDE5", surface: "FFFEFC", soft: "F5F1E9", text: "3D3932", muted: "787165", border: "E5DFD4", accent: "7D6C50", emphasis: "61513A", accentSoft: "EDE5D8")),
        .init(id: "rose", name: "浅玫瑰", dark: false, palette: .init(canvas: "FCF9F9", sidebar: "F3EBEC", surface: "FFFFFF", soft: "F8F0F1", text: "443638", muted: "806C70", border: "EADFE1", accent: "936970", emphasis: "764E55", accentSoft: "F1E2E5")),
        .init(id: "monochrome", name: "柔灰", dark: false, palette: .init(canvas: "FAFAF8", sidebar: "F0F0ED", surface: "FFFFFF", soft: "F5F5F2", text: "383936", muted: "72736E", border: "E3E4DF", accent: "696C65", emphasis: "4D504A", accentSoft: "E9EBE5")),
        .init(id: "dusk", name: "暮色", dark: true, palette: .init(canvas: "20211F", sidebar: "1B1C1A", surface: "292A27", soft: "302923", text: "F0ECE4", muted: "B0AFA3", border: "42443B", accent: "E6A18A", emphasis: "FFD1C0", accentSoft: "46332B", onAccent: "282622")),
        // Client light palettes; source tokens and native mappings are in theme-sources.md.
        .init(id: "claude", name: "Claude", dark: false, palette: .init(canvas: "FAF9F5", sidebar: "F5F4ED", surface: "FFFFFF", soft: "F0EEE6", text: "141413", muted: "73726C", border: "E8E6DC", accent: "D97757", emphasis: "3D3D3A", accentSoft: "E8E6DC", onAccent: "FFFFFF", primary: "141413", primaryHover: "3D3D3A"), collection: .client, detail: "默认浅色 · 暖白陶土"),
        .init(id: "codex", name: "Codex", dark: false, palette: .init(canvas: "FFFFFF", sidebar: "F9F9F9", surface: "FFFFFF", soft: "F8F8F8", text: "282828", muted: "6B6B6B", border: "EBEBEB", accent: "5D5D5D", emphasis: "282828", accentSoft: "EEEEEE", primary: "181818", primaryHover: "303030", primaryDisabled: "E8E8E8", onPrimaryDisabled: "9B9B9B"), collection: .client, detail: "默认浅色 · 轻柔中性灰"),
        // Official palette references and cockpit adaptations: ../theme-sources.md.
        .init(id: "dracula", name: "Dracula", dark: true, palette: .init(canvas: "282A36", sidebar: "21222C", surface: "30323F", soft: "343746", text: "F8F8F2", muted: "A4AAC7", border: "44475A", accent: "BD93F9", emphasis: "D6ACFF", accentSoft: "3D3455", onAccent: "282A36"), collection: .editor, detail: "经典紫 · 深色"),
        .init(id: "github-dark", name: "GitHub Dark", dark: true, palette: .init(canvas: "0D1117", sidebar: "010409", surface: "161B22", soft: "21262D", text: "E6EDF3", muted: "8B949E", border: "30363D", accent: "58A6FF", emphasis: "A5D6FF", accentSoft: "172F46", onAccent: "0D1117"), collection: .editor, detail: "石墨黑 · 蓝色点缀"),
        .init(id: "one-dark-pro", name: "One Dark Pro", dark: true, palette: .init(canvas: "282C34", sidebar: "21252B", surface: "2C313A", soft: "333842", text: "ABB2BF", muted: "9DA5B4", border: "434A56", accent: "61AFEF", emphasis: "8AC7F3", accentSoft: "2C4055", onAccent: "21252B"), collection: .editor, detail: "经典蓝灰 · 深色"),
        .init(id: "catppuccin-mocha", name: "Catppuccin Mocha", dark: true, palette: .init(canvas: "1E1E2E", sidebar: "181825", surface: "242436", soft: "313244", text: "CDD6F4", muted: "BAC2DE", border: "45475A", accent: "CBA6F7", emphasis: "DCC0FF", accentSoft: "3B304F", onAccent: "1E1E2E"), collection: .editor, detail: "柔和淡紫 · 深色"),
        .init(id: "tokyo-night", name: "Tokyo Night", dark: true, palette: .init(canvas: "1A1B26", sidebar: "16161E", surface: "202230", soft: "24283B", text: "A9B1D6", muted: "9AA5CE", border: "3B4261", accent: "7AA2F7", emphasis: "ADC8FF", accentSoft: "283457", onAccent: "1A1B26"), collection: .editor, detail: "夜幕蓝 · 深色"),
        .init(id: "solarized-dark", name: "Solarized Dark", dark: true, palette: .init(canvas: "002B36", sidebar: "00252F", surface: "073642", soft: "083945", text: "93A1A1", muted: "93A1A1", border: "315661", accent: "2AA198", emphasis: "6CC6BE", accentSoft: "0B474C", onAccent: "002B36"), collection: .editor, detail: "经典青墨 · 深色"),
        .init(id: "github-light", name: "GitHub Light", dark: false, palette: .init(canvas: "FFFFFF", sidebar: "F6F8FA", surface: "FFFFFF", soft: "F3F5F7", text: "1F2328", muted: "656D76", border: "D0D7DE", accent: "0969DA", emphasis: "0550AE", accentSoft: "DDF4FF"), collection: .editor, detail: "干净白 · 蓝色点缀"),
        .init(id: "catppuccin-latte", name: "Catppuccin Latte", dark: false, palette: .init(canvas: "EFF1F5", sidebar: "E6E9EF", surface: "FFFFFF", soft: "E6E9EF", text: "4C4F69", muted: "5C5F77", border: "BCC0CC", accent: "8839EF", emphasis: "6E2DCE", accentSoft: "E9DEF8"), collection: .editor, detail: "奶白淡紫 · 浅色"),
        .init(id: "solarized-light", name: "Solarized Light", dark: false, palette: .init(canvas: "FDF6E3", sidebar: "EEE8D5", surface: "FFFBF0", soft: "F4ECD6", text: "52666D", muted: "576B72", border: "D8D1BA", accent: "216F91", emphasis: "18536D", accentSoft: "E4ECE3"), collection: .editor, detail: "暖纸色 · 浅色")
    ]
    static func resolve(_ id: String) -> CockpitTheme { all.first { $0.id == id } ?? all[0] }
}
private struct ThemeKey: EnvironmentKey { static let defaultValue = ThemeRegistry.all[0] }
extension EnvironmentValues { var cockpitTheme: CockpitTheme { get { self[ThemeKey.self] } set { self[ThemeKey.self] = newValue } } }
extension Color {
    init(hex: String) {
        let n = UInt64(hex, radix: 16) ?? 0
        self.init(.sRGB, red: Double((n >> 16) & 255)/255, green: Double((n >> 8) & 255)/255, blue: Double(n & 255)/255, opacity: 1)
    }
}

/// Native system typography uses SF for Latin and the system Chinese fallback.
/// Keep roles independent from the selected color palette.
enum CockpitTypography {
    static var increment: CGFloat { UserDefaults.standard.string(forKey: "cockpit.density") == "舒适" ? 2 : 0 }
    static func font(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font { .system(size: size + increment, weight: weight, design: design) }
    static var section: Font { font(size: 15, weight: .medium) }
    static var body: Font { font(size: 13) }
    static var caption: Font { font(size: 11) }
    static func title(_ size: CGFloat) -> Font { font(size: size, weight: .medium) }
}

/// Reading preferences are independent of color themes and application chrome.
struct ChatTypography: Equatable {
    static let preferenceKey = "cockpit.chatFontSize"
    static let defaultSize = 15
    static let range = 12...22
    let size: Int
    init(size: Int = Self.defaultSize) { self.size = min(Self.range.upperBound, max(Self.range.lowerBound, size)) }
    var body: CGFloat { CGFloat(size) }
    var code: CGFloat { body - 1 }
    var lineSpacing: CGFloat { body * 0.3 }
    var codeLineSpacing: CGFloat { code * 0.25 }
    var codeLineHeight: CGFloat { ceil(NSLayoutManager().defaultLineHeight(for: .monospacedSystemFont(ofSize: code, weight: .regular)) + codeLineSpacing) }
    var cacheKey: String { String(size) }
}
private struct ChatTypographyKey: EnvironmentKey { static let defaultValue = ChatTypography() }
extension EnvironmentValues {
    var chatTypography: ChatTypography {
        get { self[ChatTypographyKey.self] }
        set { self[ChatTypographyKey.self] = newValue }
    }
}
