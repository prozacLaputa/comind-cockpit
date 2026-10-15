import Foundation

struct MessageTable: Equatable {
    enum Alignment: Equatable { case left, center, right }
    let source: String
    let rows: [[String]] // Header first; retain extra cells rather than silently dropping content.
    let alignments: [Alignment]
    var columns: Int { rows.map(\.count).max() ?? 1 }
}

enum MessageBlock: Equatable {
    case text(String), code(String), table(MessageTable)
}

/// Block structure only. Inline formatting and selection still use the native text renderer.
enum MessageMarkdown {
    private final class Cached: NSObject {
        let blocks: [MessageBlock]
        init(_ blocks: [MessageBlock]) { self.blocks = blocks }
    }
    private static let cache: NSCache<NSString, Cached> = {
        let result = NSCache<NSString, Cached>()
        result.countLimit = 256; result.totalCostLimit = 2 * 1024 * 1024
        return result
    }()

    static func blocks(_ text: String) -> [MessageBlock] {
        let key = text as NSString
        if let cached = cache.object(forKey: key) { return cached.blocks }
        let result = parse(text)
        cache.setObject(Cached(result), forKey: key, cost: key.length * 4)
        return result
    }

    private static func parse(_ text: String) -> [MessageBlock] {
        let lines = text.components(separatedBy: "\n")
        var result: [MessageBlock] = [], prose: [String] = []
        var index = 0
        func flush() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.isEmpty { result.append(.text(text)) }
            prose.removeAll(keepingCapacity: true)
        }
        while index < lines.count {
            if let opening = fence(lines[index]) {
                flush(); index += 1
                var code: [String] = []
                while index < lines.count {
                    if let closing = fence(lines[index]), closing.mark == opening.mark,
                       closing.count >= opening.count, closing.suffix.isEmpty { break }
                    code.append(lines[index]); index += 1
                }
                result.append(.code(code.joined(separator: "\n").trimmingCharacters(in: .newlines)))
                if index < lines.count { index += 1 }
            } else if index + 1 < lines.count, let header = cells(lines[index]),
                      let separator = cells(lines[index + 1]), header.count == separator.count,
                      let alignment = alignments(separator) {
                flush()
                let start = index
                var rows = [header]
                index += 2
                while index < lines.count, fence(lines[index]) == nil, let row = cells(lines[index]) {
                    rows.append(row); index += 1
                }
                result.append(.table(.init(source: lines[start..<index].joined(separator: "\n"), rows: rows, alignments: alignment)))
            } else {
                prose.append(lines[index]); index += 1
            }
        }
        flush()
        return result
    }

    private static func fence(_ line: String) -> (mark: Character, count: Int, suffix: String)? {
        let trimmed = line.drop(while: { $0 == " " })
        guard line.count - trimmed.count <= 3, let mark = trimmed.first, mark == "`" || mark == "~" else { return nil }
        let count = trimmed.prefix(while: { $0 == mark }).count
        guard count >= 3 else { return nil }
        let suffix = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if mark == "`" && suffix.contains("`") { return nil }
        return (mark, count, suffix)
    }

    private static func alignments(_ cells: [String]) -> [MessageTable.Alignment]? {
        var result: [MessageTable.Alignment] = []
        for cell in cells {
            var marker = cell[...]
            if marker.first == ":" { marker = marker.dropFirst() }
            if marker.last == ":" { marker = marker.dropLast() }
            guard marker.count >= 3, marker.allSatisfy({ $0 == "-" }) else { return nil }
            result.append(cell.hasSuffix(":") ? (cell.hasPrefix(":") ? .center : .right) : .left)
        }
        return result
    }

    /// Escaped pipes and pipes inside complete inline-code spans are cell content.
    static func cells(_ line: String) -> [String]? {
        let chars = Array(line.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !chars.isEmpty else { return nil }
        var parts: [String] = [], cell = "", index = 0, codeTicks = 0, delimiters = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\\", index + 1 < chars.count {
                cell.append(char); cell.append(chars[index + 1]); index += 2; continue
            }
            if char == "`" {
                var end = index
                while end < chars.count && chars[end] == "`" { end += 1 }
                let run = end - index
                if codeTicks == run { codeTicks = 0 }
                else if codeTicks == 0 {
                    // An unmatched backtick is literal text, not an open code span.
                    var cursor = end
                    while cursor < chars.count {
                        if chars[cursor] != "`" { cursor += 1; continue }
                        let start = cursor
                        while cursor < chars.count && chars[cursor] == "`" { cursor += 1 }
                        if cursor - start == run { codeTicks = run; break }
                    }
                }
                cell += String(repeating: "`", count: run); index = end; continue
            }
            if char == "|" && codeTicks == 0 {
                parts.append(cell.trimmingCharacters(in: .whitespaces)); cell = ""; delimiters += 1
            } else { cell.append(char) }
            index += 1
        }
        guard delimiters > 0 else { return nil }
        parts.append(cell.trimmingCharacters(in: .whitespaces))
        if chars.first == "|" { parts.removeFirst() }
        if parts.last == "", chars.last == "|" { parts.removeLast() }
        return parts.isEmpty ? nil : parts
    }
}
