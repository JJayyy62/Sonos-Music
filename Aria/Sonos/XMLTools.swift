import Foundation

// MARK: - Escaping

enum XMLEscape {
    static func escape(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        for character in string {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default: result.append(character)
            }
        }
        return result
    }
}

// MARK: - Minimal DOM

/// 名前空間プレフィックスを取り除いたローカル名で要素を扱う、軽量なXMLツリー。
final class XMLElementNode {
    let name: String
    var attributes: [String: String]
    var children: [XMLElementNode] = []
    var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    func first(_ name: String) -> XMLElementNode? {
        children.first { $0.name == name }
    }

    func all(_ name: String) -> [XMLElementNode] {
        children.filter { $0.name == name }
    }

    /// 幅優先で最初に見つかった子孫要素
    func firstDescendant(_ name: String) -> XMLElementNode? {
        var queue = children
        var index = 0
        while index < queue.count {
            let node = queue[index]
            if node.name == name { return node }
            queue.append(contentsOf: node.children)
            index += 1
        }
        return nil
    }

    func descendants(named name: String) -> [XMLElementNode] {
        var result: [XMLElementNode] = []
        for child in children {
            if child.name == name { result.append(child) }
            result.append(contentsOf: child.descendants(named: name))
        }
        return result
    }
}

final class XMLTreeParser: NSObject, XMLParserDelegate {
    private var stack: [XMLElementNode] = []
    private var root: XMLElementNode?

    static func parse(data: Data) -> XMLElementNode? {
        let parser = XMLParser(data: data)
        let delegate = XMLTreeParser()
        parser.delegate = delegate
        // Sonosのメタデータは未宣言プレフィックスを含むことがあるため、名前空間処理は自前で行う
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        return delegate.root
    }

    static func parse(string: String) -> XMLElementNode? {
        guard !string.isEmpty else { return nil }
        return parse(data: Data(string.utf8))
    }

    static func localName(_ qualifiedName: String) -> String {
        guard let index = qualifiedName.lastIndex(of: ":") else { return qualifiedName }
        return String(qualifiedName[qualifiedName.index(after: index)...])
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        var attributes: [String: String] = [:]
        for (key, value) in attributeDict where !key.hasPrefix("xmlns") {
            attributes[Self.localName(key)] = value
        }
        stack.append(XMLElementNode(name: Self.localName(elementName), attributes: attributes))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) {
            stack.last?.text += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        guard let node = stack.popLast() else { return }
        if let parent = stack.last {
            parent.children.append(node)
        } else {
            root = node
        }
    }
}

// MARK: - Small helpers

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }

    /// 最初のキャプチャグループを返す（大文字小文字は区別しない）
    func firstMatch(_ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = self as NSString
        guard let match = regex.firstMatch(in: self, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let range = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
        guard range.location != NSNotFound else { return nil }
        return ns.substring(with: range)
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

enum TimeFormat {
    /// "H:MM:SS" / "HH:MM:SS.mmm" → 秒
    static func parse(_ string: String) -> Double? {
        let parts = string.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.reduce(0.0) { $0 * 60 + ($1 ?? 0) }
    }

    /// 秒 → Sonosが受け付ける "H:MM:SS"
    static func sonos(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    /// 画面表示用 "m:ss" / "h:mm:ss"
    static func display(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let s = max(0, Int(seconds.rounded(.down)))
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
