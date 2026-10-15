import SwiftUI

struct ThemeSettings: View {
    @AppStorage("cockpit.theme") private var selected = "terracotta"
    @AppStorage(ChatTypography.preferenceKey) private var chatFontSize = ChatTypography.defaultSize
    @Environment(\.cockpitTheme) private var theme
    @EnvironmentObject private var store: AppStore
    @AppStorage("cockpit.density") private var density = "紧凑"
    @State private var filter = "全部"
    private let filters = ["全部", "浅色", "深色"]
    private func options(in collection: CockpitTheme.Collection) -> [CockpitTheme] {
        ThemeRegistry.all.filter {
            $0.collection == collection && (filter == "全部" || $0.dark == (filter == "深色"))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CockpitTabs(selection: $density, options: ["紧凑", "舒适"].map { .init(id: $0, label: $0 + "布局") })
                .onChange(of: density) { _, _ in store.objectWillChange.send() }
            Caption(text: "调整导航、资料、进展与辅助文字；聊天正文仍使用下方独立字号。")
            readingSettings
            Divider().overlay(theme.border)
            HStack {
                Label("当前 · \(theme.name)", systemImage: theme.dark ? "moon" : "sun.max")
                    .font(CockpitTypography.caption).foregroundStyle(theme.muted)
                Spacer()
                Text("点击即切换").font(CockpitTypography.caption).foregroundStyle(theme.muted)
            }
            CockpitTabs(selection: $filter, options: filters.map { SelectOption(id: $0, label: $0) })
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(CockpitTheme.Collection.allCases, id: \.self) { collection in
                            let themes = options(in: collection)
                            if !themes.isEmpty {
                                VStack(alignment: .leading, spacing: 9) {
                                    HStack {
                                        Text(collection.rawValue).font(.system(size: 12, weight: .medium))
                                        Text("\(themes.count)").font(CockpitTypography.caption).foregroundStyle(theme.muted)
                                    }
                                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                                        ForEach(themes) { option in
                                            ThemeOptionCard(option: option, selected: selected == option.id) { selected = option.id }
                                        }
                                    }
                                }
                            }
                        }
                    }.padding(2).id("theme-list-top")
                }.frame(height: 250)
                    .onChange(of: filter) { _, _ in proxy.scrollTo("theme-list-top", anchor: .top) }
            }
            Caption(text: "自动记住你的选择 · 保留内容和工作状态")
        }
    }
    private var readingSettings: some View {
        let typography = ChatTypography(size: chatFontSize)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("聊天字号").font(CockpitTypography.section)
                    Text("正文、表格、代码与输入框同步调整")
                        .font(CockpitTypography.caption).foregroundStyle(theme.muted)
                }
                Spacer()
                HStack(spacing: 0) {
                    Button { chatFontSize = typography.size - 1 } label: {
                        Image(systemName: "minus").frame(width: 32, height: 32)
                    }.buttonStyle(QuietButton()).disabled(typography.size <= ChatTypography.range.lowerBound)
                        .accessibilityLabel("减小聊天字号").help("减小字号")
                    Text("\(typography.size) pt").font(.system(size: 13, weight: .regular)).monospacedDigit()
                        .frame(width: 48).accessibilityLabel("当前聊天字号 \(typography.size) pt")
                    Button { chatFontSize = typography.size + 1 } label: {
                        Image(systemName: "plus").frame(width: 32, height: 32)
                    }.buttonStyle(QuietButton()).disabled(typography.size >= ChatTypography.range.upperBound)
                        .accessibilityLabel("增大聊天字号").help("增大字号")
                }.background(theme.surface, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.border, lineWidth: 1).allowsHitTesting(false))
                Button("恢复默认") { chatFontSize = ChatTypography.defaultSize }
                    .buttonStyle(QuietButton()).disabled(typography.size == ChatTypography.defaultSize)
                    .help("恢复为 15 pt")
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("阅读预览")
                    Spacer()
                    Text("12–22 pt · 实时生效")
                }.font(CockpitTypography.caption).foregroundStyle(theme.muted)
                SelectableMessageText(text: "把文字调到舒服的大小，再慢慢接着聊。", copySelection: { _ in })
                    .environment(\.chatTypography, typography)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(12).background(theme.soft, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct ThemeOptionCard: View {
    var option: CockpitTheme
    var selected: Bool
    var action: () -> Void
    @Environment(\.cockpitTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                preview
                HStack(spacing: 4) {
                    Text(option.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : option.dark ? "moon" : "sun.max")
                        .font(.system(size: 10)).foregroundStyle(selected ? theme.accent : theme.muted)
                }.foregroundStyle(theme.text)
                Text(option.detail.isEmpty ? (option.dark ? "CoMind · 深色" : "CoMind · 浅色") : option.detail)
                    .font(.system(size: 10)).foregroundStyle(theme.muted).lineLimit(1)
            }.padding(10)
                .background(selected ? theme.accentSoft : theme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected || hovered ? theme.accent : theme.border, lineWidth: selected ? 1.5 : 0.5))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(InteractiveButton())
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : CockpitMotion.feedback, value: hovered)
            .accessibilityLabel("切换到\(option.name)主题")
            .accessibilityValue(option.dark ? "深色" : "浅色")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(option.name + " · " + (option.detail.isEmpty ? "CoMind" : option.detail))
    }
    private var preview: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(option.accent).frame(width: 10, height: 3)
                RoundedRectangle(cornerRadius: 2).fill(option.accentSoft).frame(width: 24, height: 8)
                    .overlay(alignment: .leading) { Capsule().fill(option.accent).frame(width: 2, height: 5) }
                Capsule().fill(option.muted.opacity(0.45)).frame(width: 18, height: 3)
            }.frame(width: 38, height: 54).background(option.sidebar)
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(option.text).frame(width: 33, height: 3)
                Capsule().fill(option.muted.opacity(0.5)).frame(width: 48, height: 2)
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(option.primary).frame(width: 21, height: 9)
                        .overlay(Capsule().fill(option.onAccent).frame(width: 9, height: 2))
                    RoundedRectangle(cornerRadius: 2).fill(option.surface).frame(width: 26, height: 9)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(option.border, lineWidth: 0.5))
                }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }.background(option.canvas).clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(option.border, lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}
