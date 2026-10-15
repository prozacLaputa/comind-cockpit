import Foundation

struct CodexModelSelection: Equatable, Codable {
    let model: String
    let effort: String?
    var label: String { model + (effort.map { " · " + Self.effortName($0) } ?? "") }
    static func effortName(_ raw: String) -> String {
        ["none": "None", "minimal": "Minimal", "low": "Low", "medium": "Medium", "high": "High", "xhigh": "XHigh", "max": "Max", "ultra": "Ultra"][raw] ?? raw
    }
}
struct CodexModelOption: Identifiable {
    let id: String
    let title: String
    let detail: String
    let efforts: [String]
    let defaultEffort: String?
    let isDefault: Bool
    init?(_ raw: [String: Any]) {
        guard raw["hidden"] as? Bool != true, let model = raw["model"] as? String, !model.isEmpty else { return nil }
        id = model; title = raw["displayName"] as? String ?? model
        detail = raw["description"] as? String ?? ""
        let supported = (raw["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { $0["reasoningEffort"] as? String }
        efforts = supported
        defaultEffort = (raw["defaultReasoningEffort"] as? String).flatMap { supported.contains($0) ? $0 : nil }
        isDefault = raw["isDefault"] as? Bool == true
    }
    var selection: CodexModelSelection { .init(model: id, effort: defaultEffort) }
}
struct CodexModelContext {
    let models: [CodexModelOption]
    let inherited: CodexModelSelection?
    static func defaultSelection(config: [String: Any], models: [CodexModelOption]) -> CodexModelSelection? {
        guard let model = config["model"] as? String ?? models.first(where: \.isDefault)?.id else { return nil }
        return .init(model: model, effort: config["model_reasoning_effort"] as? String ?? models.first(where: { $0.id == model })?.defaultEffort)
    }
    static func validate(_ selection: CodexModelSelection, models: [CodexModelOption]) throws {
        guard let model = models.first(where: { $0.id == selection.model }) else {
            throw BridgeError(message: "所选模型当前不可用，请重新选择；没有自动换用其他模型。")
        }
        if let effort = selection.effort, !model.efforts.contains(effort) {
            throw BridgeError(message: "所选模型不支持这个推理强度，请重新选择。")
        }
    }
}

extension CodexBridge {
    func listModels() async throws -> [CodexModelOption] {
        guard connected else { throw BridgeError(message: "连接本机 Codex 后即可查看模型。") }
        var models: [CodexModelOption] = [], cursor: String?, seen: Set<String> = []
        repeat {
            var params: [String: Any] = ["includeHidden": false, "limit": 100]
            if let cursor { params["cursor"] = cursor }
            let response = try await call("model/list", params)
            guard let data = response["data"] as? [[String: Any]] else { throw BridgeError(message: "Codex 未返回有效模型列表，请刷新或更新本机 Codex。") }
            for option in data.compactMap(CodexModelOption.init) where !models.contains(where: { $0.id == option.id }) { models.append(option) }
            cursor = response["nextCursor"] as? String
            if let cursor, !seen.insert(cursor).inserted { throw BridgeError(message: "模型列表分页异常，请刷新重试。") }
            if seen.count > 20 { throw BridgeError(message: "模型列表过长，请更新本机 Codex 后重试。") }
        } while cursor != nil
        return models
    }
    func inspectModels(cwd: String, threadID: String?) async throws -> CodexModelContext {
        let models = try await listModels()
        let inherited: CodexModelSelection?
        if let threadID {
            let result = try await call("thread/read", ["threadId": threadID, "includeTurns": false])
            guard let raw = result["thread"] as? [String: Any], let thread = CodexThread(raw), thread.id == threadID else { throw BridgeError(message: "无法读取会话模型，请刷新。") }
            inherited = thread.modelSettings
        } else {
            var params: [String: Any] = ["includeLayers": false]
            if cwd.hasPrefix("/") { params["cwd"] = cwd }
            let result = try await call("config/read", params)
            guard let config = result["config"] as? [String: Any] else { throw BridgeError(message: "无法读取本机默认模型，请刷新或手动选择。") }
            inherited = CodexModelContext.defaultSelection(config: config, models: models)
        }
        return .init(models: models, inherited: inherited)
    }
}
