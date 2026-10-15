import SwiftUI
import AppKit

struct CockpitView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var pageKey: String { store.areaID ?? store.page.rawValue }
    private var isOverview: Bool { store.areaID == nil && store.page == .overview }
    @State private var columns: NavigationSplitViewVisibility = .all
    private var sourceWatchKey: String {
        guard let connection = store.coMind else { return "" }
        return connection.repository.path + connection.sources.map { source in
            source.id.uuidString + source.path + source.areas.sorted().joined()
        }.joined()
    }
    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar().navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 280)
        } detail: {
            Group {
            if let id = store.areaID, let area = store.areas.first(where: { $0.id == id }), store.areaTab == "开始工作" {
                VStack(alignment: .leading, spacing: 10) {
                    WorkActivity(bridge: store.codex)
                    StorageWarningBanner()
                    AreaDetail(area: area)
                }.padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    WorkActivity(bridge: store.codex)
                    StorageWarningBanner()
                    ZStack(alignment: .topLeading) { Group {
                    if let id = store.areaID, let area = store.areas.first(where: { $0.id == id }) { AreaDetail(area: area) }
                    else { switch store.page {
                    case .overview: OverviewDashboard()
                    case .areas: Overview()
                    case .files: FilesPage()
                    case .codex: CodexPage(bridge: store.codex)
                    } }
                    }.id(pageKey).transition(.opacity)
                    }.animation((reduceMotion || theme.binary) ? nil : CockpitMotion.navigation, value: pageKey)
                    if (store.areaID != nil && store.areaTab == "随手记") || (store.areaID == nil && (store.page == .overview || store.page == .areas)) { CaptureBar().padding(.top, 8) }
                }.padding(.horizontal, 24).padding(.vertical, 20)
                    .frame(maxWidth: isOverview ? 1240 : 1040, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: isOverview ? .center : .leading)
            }
            }
            }.background {
                ZStack {
                    theme.canvas
                    if isOverview { theme.soft.opacity(theme.opacity(theme.dark ? 0.16 : 0.65)) }
                }
            }
            .navigationTitle(" ")
            .toolbarBackground(theme.canvas, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
        }.navigationSplitViewStyle(.balanced)
        .overlay(alignment: .top) { theme.border.frame(height: 1).allowsHitTesting(false) }
        .foregroundStyle(theme.text).font(CockpitTypography.body).tint(theme.accent)
        .overlay(alignment: .bottom) { if let message = store.message { Text(message).font(CockpitTypography.font(size: 12)).padding(14).foregroundStyle(theme.canvas).background(theme.text, in: Capsule()).padding(20).transition(.opacity.combined(with: reduceMotion ? .identity : .move(edge: .bottom))) } }
        .animation((reduceMotion || theme.binary) ? nil : CockpitMotion.presentation, value: store.message)
        .allowsHitTesting(store.sheet == nil && store.filePreview == nil)
        .disabled(store.sheet != nil || store.filePreview != nil)
        .accessibilityHidden(store.sheet != nil || store.filePreview != nil)
        .overlay {
            if let document = store.filePreview {
                CockpitModal(width: 740, dismiss: { store.filePreview = nil }) {
                    FilePreview(document: document)
                }.id(document.id).transition(.opacity)
            } else if let sheet = store.sheet {
                CockpitModal(width: sheet.modalWidth, dismiss: { store.sheet = nil }) {
                    SheetHost(sheet: sheet)
                }.id(sheet.id).transition(.opacity)
            }
        }
        .animation((reduceMotion || theme.binary) ? nil : CockpitMotion.presentation, value: store.sheet?.id)
        .animation((reduceMotion || theme.binary) ? nil : CockpitMotion.presentation, value: store.filePreview?.id)
        .task {
            await store.codex.connect()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) } catch { break }
                await store.codex.refreshAccount()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                if store.codex.connected {
                    if store.codex.refreshedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true { await store.codex.refreshAccount() }
                } else { await store.codex.connect() }
            }
        }
        .task(id: sourceWatchKey) { store.refreshOriginalActivity() }
        .background { AreaActivityObserver(bridge: store.codex) }
        .onChange(of: store.focusCapture) { _, requested in
            guard requested else { return }
            if store.areaID != nil { store.areaTab = "随手记" }
            else if store.page != .overview && store.page != .areas { store.navigate(.overview) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store.codex.disconnect(); store.reviewTasks.values.forEach { $0.cancel() }; store.employeeBatchTask?.cancel(); store.employeeSetupTasks.values.forEach { $0.cancel() } }
    }
}
struct Sidebar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 9) {
                        Image(systemName: "leaf.fill").foregroundStyle(theme.accent)
                        Text("CoMind").font(CockpitTypography.font(size: 14, weight: .semibold))
                    }.padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 20)
                    groupLabel("工作空间")
                    Button { store.sheet = .search } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").frame(width: 18)
                            Text("搜索"); Spacer()
                            Text("⇧⌘F").font(CockpitTypography.caption).foregroundStyle(theme.muted)
                        }.padding(.horizontal, 11).frame(height: 34).contentShape(Rectangle())
                    }.buttonStyle(InteractiveButton(treatment: .sidebar))
                    ForEach(Page.allCases) { page in
                        Button { store.navigate(page) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: page.symbol).font(CockpitTypography.font(size: 14)).frame(width: 18)
                                Text(page.rawValue); Spacer()
                            }.padding(.horizontal, 11).frame(height: 34).contentShape(Rectangle())
                        }.buttonStyle(InteractiveButton(treatment: .sidebar, selected: store.page == page && store.areaID == nil))
                            .accessibilityAddTraits(store.page == page && store.areaID == nil ? .isSelected : [])
                    }
                    HStack {
                        groupLabel("长期阵地")
                        Spacer()
                        Button { store.sheet = .area } label: {
                            Image(systemName: "plus").font(CockpitTypography.font(size: 11)).frame(width: 26, height: 26)
                        }.buttonStyle(InteractiveButton()).help("新建阵地")
                    }.padding(.top, 22)
                    if store.areas.isEmpty {
                        Text("创建一个持续关注的主题").font(CockpitTypography.font(size: 11)).foregroundStyle(theme.muted)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                    } else {
                        ForEach(store.areas) { area in
                            Button { store.openArea(area.id) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: area.symbol).frame(width: 18)
                                    Text(area.name).lineLimit(1); Spacer(minLength: 28)
                                }.padding(.horizontal, 11).frame(maxWidth: .infinity).frame(height: 34).contentShape(Rectangle())
                                    .modifier(AreaReorder(id: area.id))
                            }.buttonStyle(InteractiveButton(treatment: .sidebar, selected: store.areaID == area.id))
                                .contextMenu {
                                    Button { store.manageArea(area.id) } label: {
                                        Label("重命名与编辑…", systemImage: "square.and.pencil")
                                    }
                                    Divider()
                                    Button(role: .destructive) { store.confirmAreaDeletion(area.id) } label: {
                                        Label("归档阵地…", systemImage: "trash")
                                    }
                                }
                                .accessibilityAddTraits(store.areaID == area.id ? .isSelected : [])
                                .overlay(alignment: .trailing) { AreaStatusMark(bridge: store.codex, area: area.id).padding(.trailing, 6) }
                        }
                        .animation((reduceMotion || theme.binary) ? nil : CockpitMotion.selection, value: store.areas.map(\.id))
                    }
                }.padding(.horizontal, 10)
            }
            VStack(spacing: 10) {
                theme.border.frame(height: 0.5)
                Button { store.revealStorage() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: store.usesICloud ? "icloud" : "internaldrive")
                        Text(store.storageLabel); Spacer()
                        Image(systemName: "arrow.up.right").font(CockpitTypography.font(size: 9))
                    }.font(CockpitTypography.font(size: 11)).padding(.horizontal, 10).padding(.vertical, 6)
                }.buttonStyle(InteractiveButton()).help("打开数据位置；iCloud 上传进度由系统管理")
                CodexQuotaView(bridge: store.codex)
                Button { store.sheet = .theme } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "paintpalette")
                        Text("设置"); Spacer()
                        Text(theme.name).foregroundStyle(theme.muted)
                    }.font(CockpitTypography.font(size: 11)).padding(.horizontal, 10).frame(height: 30)
                }.buttonStyle(InteractiveButton())
            }.padding(10)
        }.background(theme.sidebar)
    }
    private func groupLabel(_ text: String) -> some View {
        Text(text).font(CockpitTypography.font(size: 10, weight: .medium)).foregroundStyle(theme.muted)
            .padding(.horizontal, 10).padding(.bottom, 5)
    }
}
struct EmptyPanel: View {
    @Environment(\.cockpitTheme) var theme
    var icon: String; var title: String; var detail: String
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: icon).font(CockpitTypography.font(size: 24, weight: .light))
                .foregroundStyle(theme.accent).frame(width: 44, height: 44)
                .background(theme.accentSoft.opacity(theme.opacity(0.55)), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(CockpitTypography.section)
                Text(detail).font(CockpitTypography.font(size: 12)).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 24)
    }
}
struct Overview: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("我的阵地").font(CockpitTypography.title(20))
                    Caption(text: "接着上次的进展，开始今天的工作。")
                }
                Spacer()
                Button("新建阵地") { store.sheet = .area }.buttonStyle(QuietButton())
            }
            EmployeeSetupOverview()
            if store.areas.isEmpty { EmptyPanel(icon: "square.stack.3d.up", title: "从第一个阵地开始", detail: "创建一个持续关注的主题，再关联资料和真实会话。") }
            else {
                VStack(spacing: 12) {
                    ForEach(store.areas) { area in AreaCard(area: area) }
                }.animation((reduceMotion || theme.binary) ? nil : CockpitMotion.selection, value: store.areas.map(\.id))
            }
        }
    }
}
struct AreaDetail: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) var theme
    var area: Area
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: area.symbol).font(CockpitTypography.font(size: 17))
                    .foregroundStyle(theme.accent).frame(width: 36, height: 36)
                    .background(theme.accentSoft.opacity(theme.opacity(0.65)), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(area.name).font(CockpitTypography.title(19))
                    if !area.purpose.isEmpty {
                        Text(area.purpose).font(CockpitTypography.caption).foregroundStyle(theme.muted)
                            .lineLimit(2).help(area.purpose)
                    }
                }
                Spacer(minLength: 16)
                EmployeeSetupStatus(areaID: area.id)
                CockpitActionMenu(title: "阵地设置", symbol: "slider.horizontal.3", showsTitle: true, actions: [
                    .init(title: "员工配置", symbol: "person.crop.rectangle") { store.editingAreaID = area.id; store.sheet = .employee },
                    .init(title: "管理阵地", symbol: "square.and.pencil") { store.manageArea(area.id) }
                ])
            }
            CockpitTabs(selection: Binding(get: { WorkspacePosition.resolvedAreaTab(store.areaTab) }, set: { store.areaTab = $0 }), options: [
                .init(id: "开始工作", label: "工作"), .init(id: "进展", label: "进展"),
                .init(id: "资料", label: "资料"), .init(id: "随手记", label: "随手记")
            ])
            switch WorkspacePosition.resolvedAreaTab(store.areaTab) {
            case "资料": AreaMaterialsView(area: area)
            case "开始工作": AreaChatView(bridge: store.codex, area: area)
            case "会话", "Codex 会话": CodexPage(bridge: store.codex, areaFilter: area.id)
            case "进展": AreaProgressView(area: area)
            case "随手记": records
            default:
                HStack(spacing: 28) { metric("资料", store.documents(for: area.id).count); metric("会话", store.threadLinks.filter { $0.areaID == area.id }.count) }.padding(22).background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
                HStack { Button("开始工作") { store.areaTab = "开始工作" }.buttonStyle(PrimaryButton()); Button("添加资料") { store.areaTab = "资料" }.buttonStyle(QuietButton()) }
                records
            }
        }
    }
    func metric(_ label: String, _ count: Int) -> some View { VStack(alignment: .leading, spacing: 8) { Caption(text: label); Text("\(count)").font(CockpitTypography.font(size: 20)).monospacedDigit() }.frame(maxWidth: .infinity, alignment: .leading) }
    @ViewBuilder var records: some View {
        SectionHeading(title: "随手记录")
        let notes = store.captures.filter { $0.areaID == area.id }
        if notes.isEmpty { Caption(text: "还没有记录。你可以在下方留下第一条想法。") }
        ForEach(notes) { note in
            VStack(alignment: .leading, spacing: 10) {
                Text(note.text).textSelection(.enabled)
                HStack {
                    Text(note.date, style: .date).font(CockpitTypography.caption).foregroundStyle(theme.muted)
                    Spacer()
                    Button("编辑") { store.editingCaptureID = note.id; store.sheet = .editCapture }.buttonStyle(QuietButton())
                    Button("继续讨论") { store.discussCapture(note) }.buttonStyle(QuietButton())
                }
            }.padding(16).background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
struct FilesPage: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.cockpitTheme) var theme
    @State private var originalURLs: Set<URL> = []
    private var remainingDocuments: [DocumentRecord] {
        store.filteredDocuments.filter { doc in
            guard let url = doc.localURL else { return true }
            return !originalURLs.contains(url.standardizedFileURL.resolvingSymlinksInPath())
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("文件").font(CockpitTypography.title(theme.metrics.title)); Spacer(); Button("CoMind 来源") { store.settingsTab = "数据"; store.sheet = .theme }.buttonStyle(QuietButton()); Button("记录到原笔记") { store.openOriginalCapture() }.buttonStyle(QuietButton()); Button("打开本地文件") { store.chooseLocalFile() }.buttonStyle(PrimaryButton()) }
            CockpitField(title: "搜索名称或路径", text: $store.search, symbol: "magnifyingglass", showsLabel: false)
            OriginalFilesSection(query: store.search) { originalURLs = Set($0) }
            if !remainingDocuments.isEmpty {
                Text("其他资料").font(CockpitTypography.section)
                DocumentList(documents: remainingDocuments)
            } else if store.coMind?.sources.isEmpty != false { DocumentList(documents: []) }
        }
    }
}
