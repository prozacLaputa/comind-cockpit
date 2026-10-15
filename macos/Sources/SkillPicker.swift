import SwiftUI

struct SkillPicker: View {
    @ObservedObject var bridge: CodexBridge
    let cwd: String
    @Binding var selection: [CodexSkill]
    let dismiss: () -> Void
    @Environment(\.cockpitTheme) private var theme
    @State private var query = ""
    @State private var catalog: CodexSkillCatalog?
    @State private var loading = false
    @State private var error: String?
    @State private var requestID = UUID()
    private var results: [CodexSkill] { catalog?.skills.filter { $0.matches(query) } ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(theme.accent)
                Text("选择 Skills").font(CockpitTypography.section)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(InteractiveButton()).accessibilityLabel("关闭 Skills")
            }
            Caption(text: "复用本机 Codex 已安装的 Skills，随下一条消息使用。")
            HStack(spacing: 8) {
                CockpitField(title: "搜索 Skills", text: $query, placeholder: "搜索名称或用途", symbol: "magnifyingglass", showsLabel: false)
                Button { Task { await load(force: true) } } label: { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24) }
                    .buttonStyle(QuietButton()).disabled(loading || !bridge.connected).help("重新读取本机 Skills").accessibilityLabel("刷新 Skills")
            }
            Group {
                if loading {
                    VStack(spacing: 12) { ProgressView().progressViewStyle(CockpitProgressStyle()); Caption(text: "正在读取本机 Skills…") }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    VStack(spacing: 12) {
                        Text(error).font(CockpitTypography.body).multilineTextAlignment(.center)
                        Button("重试") { Task { await load(force: true) } }.buttonStyle(QuietButton()).disabled(!bridge.connected)
                    }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "sparkle.magnifyingglass").font(.system(size: 22)).foregroundStyle(theme.muted)
                        Text(query.isEmpty ? "当前目录没有可用的 Skills" : "没有匹配的 Skill").font(CockpitTypography.body)
                        Caption(text: query.isEmpty ? "在 Codex 中安装后，点击刷新即可。" : "试试技能名称或用途关键词。")
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(results) { skill in
                                let chosen = selection.contains { $0.id == skill.id }
                                Button {
                                    if chosen { selection.removeAll { $0.id == skill.id } }
                                    else { selection.append(skill) }
                                } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: chosen ? "checkmark.circle.fill" : "circle").foregroundStyle(chosen ? theme.accent : theme.muted).padding(.top, 2)
                                        VStack(alignment: .leading, spacing: 5) {
                                            HStack {
                                                Text(skill.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                                Spacer(minLength: 6)
                                                Text(skill.enabled ? skill.sourceLabel : "已停用").font(CockpitTypography.caption).foregroundStyle(theme.muted)
                                            }
                                            if skill.title != skill.name { Text(skill.name).font(CockpitTypography.caption).foregroundStyle(theme.muted).lineLimit(1) }
                                            Text(skill.description.isEmpty ? "暂无说明" : skill.description).font(CockpitTypography.caption).foregroundStyle(theme.muted).lineLimit(2).multilineTextAlignment(.leading)
                                        }
                                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(InteractiveButton(selected: chosen)).disabled(!skill.enabled)
                                    .accessibilityLabel("选择 Skill：" + skill.name).accessibilityValue(chosen ? "已选择" : skill.enabled ? "未选择" : "已停用")
                                    .help(skill.path)
                            }
                        }.padding(4)
                    }
                }
            }.frame(height: 280).background(theme.surface, in: RoundedRectangle(cornerRadius: 9))
            if let catalog, !catalog.warnings.isEmpty {
                Text("\(catalog.warnings.count) 项加载提示，其余 Skills 仍可选择。")
                    .font(CockpitTypography.caption).foregroundStyle(theme.emphasis).help(catalog.warnings.joined(separator: "\n"))
            }
            HStack {
                Caption(text: selection.isEmpty ? "查看和选择不消耗模型额度" : "已选 \(selection.count) 项 · 发送后使用 Codex 额度")
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(QuietButton())
            }
        }.padding(16).frame(width: 410).background(theme.canvas).foregroundStyle(theme.text)
            .preferredColorScheme(theme.dark ? .dark : .light)
            .task(id: cwd + String(bridge.connected)) { await load(force: false) }
            .onDisappear { requestID = UUID() }
            .onExitCommand { dismiss() }
    }
    private func load(force: Bool) async {
        let token = UUID(); requestID = token
        loading = true; error = nil; catalog = nil
        defer { if requestID == token { loading = false } }
        do {
            let value = try await bridge.listSkills(cwd: cwd, forceReload: force)
            guard !Task.isCancelled, requestID == token else { return }
            catalog = value
        } catch {
            guard !Task.isCancelled, requestID == token else { return }
            self.error = error.localizedDescription
        }
    }
}
