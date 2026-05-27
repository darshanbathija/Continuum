import Foundation
import Markdown

public struct MarkdownDocumentContent: Equatable, Sendable {
    public let blocks: [MarkdownDocumentBlock]

    public init(blocks: [MarkdownDocumentBlock]) {
        self.blocks = blocks
    }

    public static func parse(_ raw: String) -> MarkdownDocumentContent {
        let document = Document(parsing: raw, options: [.parseBlockDirectives])
        var blocks: [MarkdownDocumentBlock] = []
        for child in document.children {
            blocks.append(contentsOf: parseBlock(child))
        }
        if blocks.isEmpty, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks = [.unsupported("Unsupported Markdown content")]
        }
        return MarkdownDocumentContent(blocks: blocks)
    }

    private static func parseBlock(_ markup: Markup) -> [MarkdownDocumentBlock] {
        if let heading = markup as? Heading {
            return [.heading(level: heading.level, text: plainText(of: heading))]
        }
        if let paragraph = markup as? Paragraph {
            let text = plainText(of: paragraph)
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [.paragraph(text)]
        }
        if let code = markup as? CodeBlock {
            return [.codeBlock(language: code.language, code: code.code)]
        }
        if let unordered = markup as? UnorderedList {
            return [.list(ordered: false, items: unordered.children.compactMap(parseListItem))]
        }
        if let ordered = markup as? OrderedList {
            return [.list(ordered: true, items: ordered.children.compactMap(parseListItem))]
        }
        if let quote = markup as? BlockQuote {
            var children: [MarkdownDocumentBlock] = []
            for child in quote.children {
                children.append(contentsOf: parseBlock(child))
            }
            return children.isEmpty ? [] : [.blockQuote(children)]
        }
        if markup is ThematicBreak {
            return [.thematicBreak]
        }

        var nested: [MarkdownDocumentBlock] = []
        for child in markup.children {
            nested.append(contentsOf: parseBlock(child))
        }
        if !nested.isEmpty { return nested }

        let fallback = plainText(of: markup).trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? [.unsupported(String(describing: type(of: markup)))] : [.paragraph(fallback)]
    }

    private static func parseListItem(_ markup: Markup) -> MarkdownDocumentListItem? {
        guard let item = markup as? ListItem else { return nil }
        var text = ""
        var children: [MarkdownDocumentBlock] = []
        for child in item.children {
            if text.isEmpty, let paragraph = child as? Paragraph {
                text = plainText(of: paragraph)
            } else {
                children.append(contentsOf: parseBlock(child))
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !children.isEmpty else { return nil }
        return MarkdownDocumentListItem(
            text: text,
            isTask: item.checkbox != nil,
            isComplete: item.checkbox == .checked,
            children: children
        )
    }

    private static func plainText(of markup: Markup) -> String {
        var out = ""
        for child in markup.children {
            if let text = child as? Text {
                out += text.string
            } else if let code = child as? InlineCode {
                out += code.code
            } else if child is SoftBreak || child is LineBreak {
                out += "\n"
            } else if let link = child as? Link {
                out += plainText(of: link)
            } else {
                out += plainText(of: child)
            }
        }
        return out
    }
}

public enum MarkdownDocumentBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(ordered: Bool, items: [MarkdownDocumentListItem])
    case codeBlock(language: String?, code: String)
    case blockQuote([MarkdownDocumentBlock])
    case thematicBreak
    case unsupported(String)
}

public struct MarkdownDocumentListItem: Equatable, Sendable, Identifiable {
    public let id: String
    public let text: String
    public let isTask: Bool
    public let isComplete: Bool
    public let children: [MarkdownDocumentBlock]

    public init(
        id: String = UUID().uuidString,
        text: String,
        isTask: Bool,
        isComplete: Bool,
        children: [MarkdownDocumentBlock]
    ) {
        self.id = id
        self.text = text
        self.isTask = isTask
        self.isComplete = isComplete
        self.children = children
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text
            && lhs.isTask == rhs.isTask
            && lhs.isComplete == rhs.isComplete
            && lhs.children == rhs.children
    }
}
