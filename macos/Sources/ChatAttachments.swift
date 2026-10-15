import AppKit
import SwiftUI
import ImageIO
import CryptoKit
import UniformTypeIdentifiers

struct ChatAttachment: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var filename: String
    var byteCount: Int
    var digest: String
    func url(in root: URL) -> URL { root.appendingPathComponent("Chat Attachments").appendingPathComponent(filename) }
}
enum ChatAttachments {
    static let maximumCount = 4, byteLimit = 10_000_000, totalLimit = 20_000_000
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func importImage(_ input: Data, name: String, root: URL) throws -> ChatAttachment {
        guard input.count <= byteLimit, let source = CGImageSourceCreateWithData(input as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16000, height <= 16000, width * height <= 32_000_000 else {
            throw BridgeError(message: "请选择有效图片：单张不超过 10 MB、3200 万像素。")
        }
        let type = CGImageSourceGetType(source) as String?
        var data = input, ext = type == UTType.jpeg.identifier ? "jpg" : "png"
        if type != UTType.png.identifier && type != UTType.jpeg.identifier {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw BridgeError(message: "这张图片无法转换，请改用 PNG 或 JPEG。") }
            data = png; ext = "png"
        }
        guard data.count <= byteLimit else { throw BridgeError(message: "图片转换后超过 10 MB，请缩小后再添加。") }
        let id = UUID(), item = ChatAttachment(id: id, name: name, filename: id.uuidString + "." + ext, byteCount: data.count, digest: hash(data))
        let file = item.url(in: root)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return item
    }
    static func validate(_ items: [ChatAttachment], root: URL) throws -> [URL] {
        guard items.count <= maximumCount, items.reduce(0, { $0 + $1.byteCount }) <= totalLimit else { throw BridgeError(message: "每条消息最多 4 张图片，总计不超过 20 MB。") }
        return try items.map { item in
            guard [item.id.uuidString + ".png", item.id.uuidString + ".jpg"].contains(item.filename) else { throw BridgeError(message: "图片路径无效，请重新添加。") }
            let file = item.url(in: root)
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.fileSize == item.byteCount, item.byteCount <= byteLimit else { throw BridgeError(message: "图片已变化，请重新添加：" + item.name) }
            let data = try Data(contentsOf: file)
            guard hash(data) == item.digest else { throw BridgeError(message: "图片已变化，请重新添加：" + item.name) }
            return file
        }
    }
    static func thumbnail(_ item: ChatAttachment, root: URL, size: Int = 160) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(item.url(in: root) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: size, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
    static func hasImages(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.png, .tiff]) != nil || !imageURLs(pasteboard).isEmpty
    }
    static func imageURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).filter { url in
            url.isFileURL && UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        }
    }
}
extension AppStore {
    var attachmentRoot: URL { storageURL.deletingLastPathComponent() }
    func addImages(_ inputs: [(Data, String)], key: String, area: String) throws {
        let existing = conversationAttachments[key] ?? []
        guard composerWritable, existing.count + inputs.count <= ChatAttachments.maximumCount else { throw BridgeError(message: "每条消息最多添加 4 张图片。") }
        var added: [ChatAttachment] = []
        do {
            for (data, name) in inputs { added.append(try ChatAttachments.importImage(data, name: name, root: attachmentRoot)) }
            _ = try ChatAttachments.validate(existing + added, root: attachmentRoot)
            draftOwners[key] = area; conversationAttachments[key] = existing + added
            for item in added { attachmentLifecycle[item.id.uuidString] = .init(item: item) }
            guard saveComposerState() else { throw BridgeError(message: composerWarning ?? "附件未保存") }
        } catch {
            conversationAttachments[key] = existing
            for item in added { attachmentLifecycle[item.id.uuidString] = nil; try? FileManager.default.removeItem(at: item.url(in: attachmentRoot)) }
            throw error
        }
    }
    func imageInputs(_ urls: [URL]) throws -> [(Data, String)] {
        try urls.map { url in
            guard (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= ChatAttachments.byteLimit else { throw BridgeError(message: "图片超过 10 MB：" + url.lastPathComponent) }
            return (try Data(contentsOf: url), url.lastPathComponent)
        }
    }
    func removeImage(_ id: UUID, key: String) {
        // Keep owned files used by past messages. Removing the draft reference never alters the user's source image.
        let old = conversationAttachments[key]
        conversationAttachments[key]?.removeAll { $0.id == id }
        retireUnreferencedImages()
        if !saveComposerState() { conversationAttachments[key] = old; retireUnreferencedImages() }
    }
}

struct ChatAttachmentStrip: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.cockpitTheme) private var theme
    var items: [ChatAttachment]
    var remove: (UUID) -> Void
    @State private var preview: UUID?
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    HStack(spacing: 7) {
                        Button { preview = item.id } label: {
                            Group {
                                if let image = ChatAttachments.thumbnail(item, root: store.attachmentRoot) { Image(nsImage: image).resizable().scaledToFit() }
                                else { Image(systemName: "photo.badge.exclamationmark") }
                            }.frame(width: 52, height: 44)
                        }.buttonStyle(InteractiveButton()).accessibilityLabel("预览图片：" + item.name)
                            .popover(isPresented: Binding(get: { preview == item.id }, set: { if !$0 { preview = nil } })) {
                                if let image = ChatAttachments.thumbnail(item, root: store.attachmentRoot, size: 1000) { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 540, maxHeight: 420).padding(12) }
                            }
                        VStack(alignment: .leading, spacing: 3) { Text(item.name).lineLimit(1); Text(ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file)).foregroundStyle(theme.muted) }.font(CockpitTypography.caption).frame(maxWidth: 110)
                        Button { remove(item.id) } label: { Image(systemName: "xmark").frame(width: 26, height: 30) }.buttonStyle(InteractiveButton()).accessibilityLabel("移除图片：" + item.name)
                    }.padding(6).background(theme.surface, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }.frame(height: 58).scrollIndicators(.hidden)
    }
}
