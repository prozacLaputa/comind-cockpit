import Foundation

/// A turn's process occupies one quiet row. Expanded details remain individual List
/// rows, so opening a long process does not defeat native row virtualization.
struct TranscriptEntry: Identifiable {
    let id: String
    let message: CodexMessage
    var tools: [CodexMessage] = []
    var toolGroupID: String? = nil
    var isProcess: Bool { !tools.isEmpty }

    static func index(_ messages: [CodexMessage], expanded: Set<String>) -> [TranscriptEntry] {
        var result: [TranscriptEntry] = []
        var turn: [CodexMessage] = []
        func appendTurn() {
            let tools = turn.filter(\.isTool)
            let first = tools.first?.id
            for message in turn {
                if !message.isTool { result.append(.init(id: message.id, message: message)); continue }
                guard message.id == first else { continue }
                let groupID = "process:" + message.id
                result.append(.init(id: groupID, message: message, tools: tools))
                if expanded.contains(groupID) {
                    result += tools.map { .init(id: $0.id, message: $0, toolGroupID: groupID) }
                }
            }
            turn = []
        }
        for message in messages {
            if message.role == "你" { appendTurn() }
            turn.append(message)
        }
        appendTurn()
        return result
    }
    static func groupID(containing messageID: String, in messages: [CodexMessage]) -> String? {
        index(messages, expanded: []).first { $0.tools.contains { $0.id == messageID } }?.id
    }
}
