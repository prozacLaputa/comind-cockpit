import Foundation

@main struct SendSafetySmoke {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cockpit-send-safety-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storageURL: root.appendingPathComponent("state.json"))
        let input = try ConversationContext.message(request: "仅这句话", area: nil, progress: nil, references: [])
        precondition(input == "本次需求：\n仅这句话")
        let context = try ConversationContext.message(request: "继续", area: nil, progress: nil, references: [], actions: "用户明确反馈的事项状态（背景资料）：已完成")
        precondition(context.contains("事项状态"))
        precondition(ConversationContext.visibleUserText(context) == "继续")
        let file = root.appendingPathComponent("source.md"), output = root.appendingPathComponent("export.md")
        try "真实内容 👋".write(to: file, atomically: true, encoding: .utf8)
        let doc = DocumentRecord(name: "source.md", areaID: "", source: "本地文件", path: file.path, body: "", localURL: file)
        store.documents = [doc]
        try store.exportDocument(doc, to: output)
        precondition((try? String(contentsOf: output, encoding: .utf8)) == "真实内容 👋")
        try FileManager.default.removeItem(at: file)
        do { try store.exportDocument(doc, to: output); fatalError("读取失败不应导出成功") }
        catch let error as DocumentReadFailure { precondition(error.id == doc.id) }
        precondition((try? String(contentsOf: output, encoding: .utf8)) == "真实内容 👋", "失败不能覆盖原导出文件")
        let moved = root.appendingPathComponent("moved.md")
        try "新位置内容".write(to: moved, atomically: true, encoding: .utf8)
        try store.relocateDocument(doc.id, to: moved)
        precondition((try? store.documentText(store.documents[0])) == "新位置内容")
        precondition(store.documents[0].id == doc.id)
        try Data(repeating: 65, count: 2_000_001).write(to: moved)
        do { _ = try store.documentText(store.documents[0]); fatalError("超限不应被当成正文") } catch is DocumentReadFailure {}
        try Data([0xff, 0xfe]).write(to: moved)
        do { _ = try store.documentText(store.documents[0]); fatalError("非文本不应被当成正文") } catch is DocumentReadFailure {}
        print("PASS: 背景可省略，资料读取失败阻断，导出不覆盖，重新定位保留身份，大小及编码校验")
    }
}
