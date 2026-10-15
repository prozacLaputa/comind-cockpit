import SwiftUI

struct OriginalLibraryEntry: Identifiable {
    var source: CoMindSource
    var title: String
    var file: URL?
    var location: String
    var areas: Set<String>
    var id: UUID { source.id }
}
enum OriginalLibrary {
    static func entries(_ connection: CoMindConnection?, allowed: Set<String>) -> [OriginalLibraryEntry] {
        guard let connection else { return [] }
        var entries: [OriginalLibraryEntry] = [], positions: [String: Int] = [:]
        for source in connection.sources where !source.areas.intersection(allowed).isEmpty {
            let url = try? CoMindFiles.url(source.path, in: connection.repository).standardizedFileURL.resolvingSymlinksInPath()
            let identity = url?.path ?? source.path
            if let index = positions[identity] { entries[index].areas.formUnion(source.areas.intersection(allowed)); continue }
            positions[identity] = entries.count
            entries.append(.init(source: source, title: CoMindFiles.title(source, connection: connection), file: url, location: source.path, areas: source.areas.intersection(allowed)))
        }
        return entries.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
struct OriginalFilesSection: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.cockpitTheme) private var theme
    var query: String
    var resolved: ([URL]) -> Void = { _ in }
    @State private var entries: [OriginalLibraryEntry] = []
    private var visible: [OriginalLibraryEntry] { entries.filter { query.isEmpty || $0.title.localizedStandardContains(query) || $0.location.localizedStandardContains(query) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("已关联原文件").font(CockpitTypography.section); Text("\(entries.count)").foregroundStyle(theme.muted); Spacer(); Button("搜索正文") { store.sheet = .search }.buttonStyle(QuietButton()) }
            Caption(text: "打开和编辑的是原文件；用于聊天的范围在各阵地「资料」中设置。")
            ForEach(visible) { entry in
                Button {
                    guard let source = store.coMind?.sources.first(where: { $0.id == entry.id }), !source.areas.isDisjoint(with: Set(store.areas.map(\.id) + [""])) else { return }
                    store.openCoMindSource(source)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: entry.source.path.hasPrefix("context/") ? "slider.horizontal.3" : "book.closed").foregroundStyle(theme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title).font(CockpitTypography.body)
                            Text(entry.location).font(CockpitTypography.caption).foregroundStyle(theme.muted).lineLimit(1)
                        }
                        Spacer()
                        Text(entry.areas.sorted().map { store.areaName($0) }.joined(separator: " · ")).font(CockpitTypography.caption).foregroundStyle(theme.muted).lineLimit(1)
                        Image(systemName: "arrow.up.right").foregroundStyle(theme.muted)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(InteractiveButton())
            }
            if entries.isEmpty { Caption(text: "在阵地的资料页关联原笔记后，会统一显示在这里。") }
        }.task(id: String(describing: store.coMind) + store.areas.map(\.id).joined()) {
            let connection = store.coMind, allowed = Set(store.areas.map(\.id) + [""])
            let result = await Task.detached { OriginalLibrary.entries(connection, allowed: allowed) }.value
            guard !Task.isCancelled else { return }; entries = result; resolved(result.compactMap(\.file))
        }
    }
}
