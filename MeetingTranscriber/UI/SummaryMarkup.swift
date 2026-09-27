import Foundation

/// Small, deliberately forgiving parser for the Markdown contract emitted by
/// the summary pass. Older summaries may not follow this contract, so the UI
/// falls back to normal Markdown whenever there are no section headings and
/// bullets to render.
enum SummaryMarkup {
    struct Document {
        let sections: [Section]
    }

    struct Section: Identifiable {
        let id: Int
        let title: String
        let body: String
        let bullets: [Bullet]
    }

    struct Bullet: Identifiable {
        let id: Int
        let text: String
        let timestamp: TimeInterval?
    }

    static func parse(_ raw: String, duration: TimeInterval) -> Document? {
        var drafts: [SectionDraft] = []
        var current: SectionDraft?
        var bulletID = 0
        var continuationAllowed = false

        func finishCurrent() {
            if let current, !current.title.isEmpty {
                drafts.append(current)
            }
        }

        for rawLine in raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)

            if let title = headingTitle(from: line) {
                finishCurrent()
                current = SectionDraft(title: title)
                continuationAllowed = false
                continue
            }

            guard current != nil else { continue }

            if line.isEmpty {
                continuationAllowed = false
                continue
            }

            if let payload = bulletPayload(from: line) {
                let parsed = parseTimestamp(from: payload, duration: duration)
                current?.bullets.append(
                    BulletDraft(
                        id: bulletID,
                        text: parsed.text,
                        timestamp: parsed.timestamp
                    )
                )
                bulletID += 1
                continuationAllowed = true
            } else if continuationAllowed, !current!.bullets.isEmpty {
                let index = current!.bullets.index(before: current!.bullets.endIndex)
                current!.bullets[index].text += " " + line
            } else {
                current?.bodyLines.append(line)
                continuationAllowed = false
            }
        }
        finishCurrent()

        let sections = drafts.enumerated().map { index, draft in
            Section(
                id: index,
                title: draft.title,
                body: draft.bodyLines.joined(separator: "\n"),
                bullets: draft.bullets.map {
                    Bullet(id: $0.id, text: $0.text, timestamp: $0.timestamp)
                }
            )
        }

        // A single Markdown heading in an old free-form summary is not enough
        // to justify changing its rendering. Structured summaries have at
        // least two sections and at least one list.
        guard sections.count >= 2, sections.contains(where: { !$0.bullets.isEmpty }) else {
            return nil
        }
        return Document(sections: sections)
    }

    private struct SectionDraft {
        var title: String
        var bodyLines: [String] = []
        var bullets: [BulletDraft] = []
    }

    private struct BulletDraft {
        let id: Int
        var text: String
        let timestamp: TimeInterval?
    }

    private static func headingTitle(from line: String) -> String? {
        guard line.first == "#" else { return nil }
        let title = line.drop(while: { $0 == "#" || $0 == " " || $0 == "\t" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private static func bulletPayload(from line: String) -> String? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
            return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }

        var index = line.startIndex
        while index < line.endIndex, line[index].isNumber {
            index = line.index(after: index)
        }
        guard index > line.startIndex, index < line.endIndex,
              line[index] == "." || line[index] == ")"
        else { return nil }
        let next = line.index(after: index)
        guard next < line.endIndex, line[next] == " " else { return nil }
        return String(line[line.index(after: next)...])
            .trimmingCharacters(in: .whitespaces)
    }

    private static func parseTimestamp(
        from text: String,
        duration: TimeInterval
    ) -> (text: String, timestamp: TimeInterval?) {
        let pattern = #"\[\[([0-9:]+)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(
                  in: text,
                  range: NSRange(text.startIndex..., in: text)
              ).last,
              let tokenRange = Range(match.range(at: 1), in: text)
        else {
            return (text, nil)
        }

        let parts = tokenRange.isEmpty
            ? []
            : text[tokenRange].split(separator: ":").compactMap { Int($0) }
        let seconds: TimeInterval?
        switch parts.count {
        case 2 where parts[1] < 60:
            seconds = TimeInterval(parts[0] * 60 + parts[1])
        case 3 where parts[1] < 60 && parts[2] < 60:
            seconds = TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
        default:
            seconds = nil
        }

        guard let seconds,
              duration <= 0 || seconds <= duration + 1
        else {
            return (text, nil)
        }

        let fullRange = Range(match.range, in: text)!
        var cleaned = text
        cleaned.removeSubrange(fullRange)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasSuffix("."), cleaned.dropLast().last == " " {
            cleaned.removeLast()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (cleaned, seconds)
    }
}
