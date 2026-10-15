import SwiftUI

struct QuestionCard: View {
    @ObservedObject var bridge: CodexBridge
    let request: CodexBridge.InputRequest
    @Environment(\.cockpitTheme) private var theme
    @State private var answers: [String: String] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("需要你的决定", systemImage: "questionmark.bubble").font(CockpitTypography.section)
            ForEach(request.items) { question in
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.title).font(CockpitTypography.body).textSelection(.enabled)
                    ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                        Button { answers[question.id] = option.label } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: answers[question.id] == option.label ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(option.label)
                                    if !option.detail.isEmpty { Text(option.detail).font(CockpitTypography.caption).foregroundStyle(theme.muted) }
                                }
                                Spacer()
                            }.padding(10)
                        }.buttonStyle(InteractiveButton(selected: answers[question.id] == option.label))
                    }
                    CockpitField(title: "你的回答", text: Binding(get: { answers[question.id] ?? "" }, set: { answers[question.id] = $0 }), placeholder: "选择一项，或输入自己的回答", showsLabel: false)
                }
            }
            HStack {
                Caption(text: "确认后继续当前任务，不会另开会话。")
                Spacer()
                Button("提交回答") { bridge.answerQuestions(request, answers: answers) }.buttonStyle(PrimaryButton())
                    .disabled(!request.items.allSatisfy { !(answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }
        }.padding(16).background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}
