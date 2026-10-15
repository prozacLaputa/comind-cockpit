import SwiftUI

/// Describes the current bridge and automatic AI work without starting either.
struct CodexRelationshipView: View {
    @ObservedObject var bridge: CodexBridge
    @Environment(\.cockpitTheme) private var theme

    private var accountDescription: String {
        if bridge.connected && bridge.subscription {
            return "使用本机已登录账号的 Codex 额度，与同账号的 Codex 客户端共用；驾驶舱没有独立额度池。剩余量和重置时间以侧栏读取结果为准。"
        }
        if bridge.connected && bridge.accountType == "apikey" {
            return "当前通过 API Key 登录，不使用 ChatGPT 订阅额度，也不提供订阅剩余额度。使用订阅前，请先在本机 Codex 切换登录方式。"
        }
        return "连接后以本机 Codex 的登录账号为准。使用 ChatGPT 登录时，与同账号的 Codex 客户端共用额度；驾驶舱没有独立额度池。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("驾驶舱是独立的本地应用，负责组织阵地和资料；AI 由本机 Codex 执行，不需要一直开着 Codex 客户端窗口。")
                .font(CockpitTypography.body).foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 16) {
                rule("登录与额度", symbol: "person.crop.circle", text: accountDescription) {
                    Label(bridge.connected ? bridge.accountLabel : "尚未连接", systemImage: "terminal")
                        .font(CockpitTypography.caption).foregroundStyle(theme.emphasis)
                }
                rule("哪些操作会调用 AI", symbol: "sparkles",
                     text: "发送消息、AI 拟定或重拟员工配置、总结进展和提炼记忆，都会调用模型，计入当前账号的用量。") {
                    Text("进入「进展」有更新时会自动总结；开启自动整理后，对话完成也会触发，可在员工配置中关闭。")
                        .font(CockpitTypography.caption).foregroundStyle(theme.emphasis)
                        .fixedSize(horizontal: false, vertical: true)
                }
                rule("哪些操作本身不调用 AI", symbol: "cursorarrow",
                     text: "查看历史、刷新额度、浏览或选择模型和 Skills、关联或改名、复制、保存资料、创建空会话。已经触发的后台整理仍可能继续。")
                rule("模型由谁决定", symbol: "slider.horizontal.3",
                     text: "输入框旁显示模型和推理强度。新会话默认读取本机配置，已有会话沿用原设置；手动切换从下一条消息生效，并由该会话继续沿用。不改全局默认，也不影响后台整理。")
                rule("Skills 如何使用", symbol: "sparkles.rectangle.stack",
                     text: "输入框旁可选择本机 Codex Skills，随下一条消息调用；发送后才计入用量。按当前会话目录读取，所需工具、登录与执行授权仍须可用，驾驶舱不会自动安装或启用技能。")
                rule("两边操作的是同一条会话", symbol: "link",
                     text: "关联是引用原 Codex 本机会话。续聊、改名、删除都作用于原会话；解除关联只移除当前阵地引用。外部更新需刷新，同一会话避免两边同时发送。")
                rule("不同会话如何接上背景", symbol: "text.bubble",
                     text: "不同会话不会自动合并。发送时携带的职责、记忆、进展和参考内容，可在输入框上方「给 AI 的背景」查看与调整。")
            }
        }.textSelection(.enabled)
    }

    private func rule(_ title: String, symbol: String, text: String) -> some View {
        rule(title, symbol: symbol, text: text) { EmptyView() }
    }

    private func rule<Detail: View>(_ title: String, symbol: String, text: String, @ViewBuilder detail: () -> Detail) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(CockpitTypography.font(size: 15)).foregroundStyle(theme.accent)
                .frame(width: 22, height: 20).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(CockpitTypography.font(size: 13, weight: .medium))
                Text(text).font(CockpitTypography.body).foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                detail()
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
