import Foundation

enum TranscriptPolishing {
    struct Item: Codable, Equatable {
        let index: Int
        let text: String
    }

    static func batches(for segments: [TranscriptSegment]) -> [[Int]] {
        var result: [[Int]] = []
        var current: [Int] = []
        var characters = 0
        for index in segments.indices {
            let count = segments[index].text.count
            // Smaller batches make strict JSON materially more reliable on
            // local models while retaining enough neighbouring context.
            if !current.isEmpty && (current.count >= 24 || characters + count > 4_000) {
                result.append(current)
                current = []
                characters = 0
            }
            current.append(index)
            characters += count
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func prompt(for language: TranscriptionLanguage,
                       segments: [TranscriptSegment],
                       indices: [Int]) throws -> String {
        let items = indices.map { Item(index: $0, text: segments[$0].text) }
        let payload = String(decoding: try JSONEncoder().encode(items), as: UTF8.self)
        let instruction: String
        switch language {
        case .russian:
            instruction = """
                Причеши фрагменты транскрипции как части одного связного разговора: восстанови регистр и пунктуацию с учётом соседних фрагментов, исправь только очевидные ошибки распознавания имён, названий и технических терминов по контексту и глоссарию. Не ставь точку в конце каждого элемента автоматически: граница элемента не обязательно является границей мысли. Не сокращай, не пересказывай, не цензурируй и не добавляй новых фактов. Сохрани каждый index ровно один раз и не объединяй элементы. Верни только JSON-массив объектов {\"index\": Int, \"text\": String}, без Markdown и пояснений.
                """
        case .polish:
            instruction = """
                Wygładź fragmenty transkrypcji: popraw interpunkcję i spójność oraz tylko oczywiste błędy rozpoznawania imion, nazw i terminów technicznych na podstawie kontekstu i słownika. Nie skracaj, nie streszczaj, nie cenzuruj i nie dodawaj faktów. Zachowaj każdy index dokładnie raz i nie łącz elementów. Zwróć wyłącznie tablicę JSON obiektów {\"index\": Int, \"text\": String}, bez Markdownu i objaśnień.
                """
        case .english:
            instruction = """
                Polish these transcript fragments: restore punctuation and coherence, and correct only obvious recognition errors in names, product names, and technical terms using context and the glossary. Do not shorten, summarize, censor, or add facts. Preserve every index exactly once and do not merge items. Return only a JSON array of {\"index\": Int, \"text\": String} objects, with no Markdown or explanation.
                """
        }
        return instruction + "\n\n" + payload
    }

    static func apply(_ raw: String,
                      to segments: [TranscriptSegment],
                      expectedIndices: [Int]) -> [TranscriptSegment]? {
        let cleaned = SummaryPrompts.stripThinking(raw)
        guard let first = cleaned.firstIndex(of: "["),
              let last = cleaned.lastIndex(of: "]"), first <= last,
              let data = String(cleaned[first...last]).data(using: .utf8),
              let items = try? JSONDecoder().decode([Item].self, from: data),
              items.map(\.index).sorted() == expectedIndices.sorted(),
              Set(items.map(\.index)).count == expectedIndices.count,
              items.allSatisfy({ !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { return nil }

        var result = segments
        for item in items {
            guard result.indices.contains(item.index) else { return nil }
            result[item.index].text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}

/// Per-language prompt templates. Two passes per summarization (summary then
/// title) keep streaming UX simple and robust — no JSON parsing, each block
/// lands in its own UI card as it generates.
enum SummaryPrompts {

    // MARK: - System instructions (user-editable via Settings).

    static let defaultSystemEnglish =
        "You are a meeting-notes assistant. Be concise, factual, and faithful to the transcript. " +
        "Use the same language as the transcript. Preserve names, technical terms, and numbers exactly as they appear."

    static let defaultSystemPolish =
        "Jesteś asystentem do notowania spotkań. Bądź zwięzły, rzeczowy i wierny transkrypcji. " +
        "Odpowiadaj w języku transkrypcji. Zachowaj nazwy, terminy techniczne i liczby dokładnie tak, jak się pojawiają."

    static let defaultSystemRussian =
        "Ты помощник для заметок встреч. Будь кратким, точным и верным транскрипции. " +
        "Отвечай на языке транскрипции. Сохраняй имена, технические термины и числа точно так, как они встречаются в тексте."

    /// Stable guidance for names that are meaningful identifiers, not prose.
    /// It is appended even when the user has an older saved system prompt.
    static func technicalTermsBlock(for language: TranscriptionLanguage) -> String {
        switch language {
        case .english:
            return "Technical terminology rules: preserve the exact spelling, case, punctuation, and underscores of table, schema, database, service, API, queue, repository, and metric names. Do not translate or normalize identifiers. In the summary, put such names in backticks when appropriate. Never invent technical names that are absent from the transcript."
        case .polish:
            return "Zasady terminologii technicznej: zachowuj dokładną pisownię, wielkość liter, znaki interpunkcyjne i podkreślenia w nazwach tabel, schematów, baz danych, usług, API, kolejek, repozytoriów i metryk. Nie tłumacz ani nie normalizuj identyfikatorów. W streszczeniu używaj backticków dla takich nazw, gdy poprawia to czytelność. Nie wymyślaj nazw technicznych, których nie ma w transkrypcji."
        case .russian:
            return "Правила технической терминологии: сохраняй точное написание, регистр, знаки препинания и подчёркивания в названиях таблиц, схем, баз данных, сервисов, API, очередей, репозиториев и метрик. Не переводи и не нормализуй идентификаторы. В резюме оформляй такие названия в обратных кавычках, если это улучшает читаемость. Не придумывай технические названия, которых нет в транскрипции."
        }
    }

    /// Prompt asking the LLM to map placeholder speaker labels ("Remote",
    /// "Remote 1", …) to real names mentioned in the conversation. Strict
    /// output format so `parseInferredNames` can read it back deterministically.
    static func identifyInstruction(for language: TranscriptionLanguage,
                                    labels: [String]) -> String {
        let intro: String
        let unknown: String
        switch language {
        case .english:
            intro = "Below is a meeting transcript with placeholder speaker labels. For each label, infer the speaker's real name only if the conversation clearly indicates it (e.g. they are addressed by name). Reply with one line per label in the exact format:"
            unknown = "If no name is clearly indicated for a label, write 'unknown'. Do not invent names. Do not add any other commentary."
        case .polish:
            intro = "Poniżej znajduje się transkrypcja spotkania z zastępczymi etykietami mówców. Dla każdej etykiety podaj prawdziwe imię, tylko jeśli rozmowa jasno to wskazuje (np. ktoś zwraca się po imieniu). Odpowiedz dokładnie jedną linią na etykietę w formacie:"
            unknown = "Jeśli żadne imię nie jest jasno wskazane dla danej etykiety, napisz 'unknown'. Nie wymyślaj imion. Nie dodawaj żadnego komentarza."
        case .russian:
            intro = "Ниже приведена расшифровка встречи с условными именами участников. Для каждого имени укажи настоящее имя только если разговор явно это подтверждает, например к человеку обращаются по имени. Ответь ровно одной строкой для каждого имени в формате:"
            unknown = "Если настоящее имя явно не указано, напиши 'unknown'. Не выдумывай имена и не добавляй комментариев."
        }
        let format = "<label>: <name or unknown>"
        let bullets = labels.map { "- \($0)" }.joined(separator: "\n")
        return "\(intro)\n\(format)\n\(unknown)\n\nLabels to identify:\n\(bullets)"
    }

    /// Parses lines like "Remote 1: Romek" / "Remote 2: unknown" produced by
    /// the identification pass. Tolerates leading bullets, surrounding
    /// whitespace, and extra commentary lines (skipped).
    static func parseInferredNames(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in raw.split(whereSeparator: \.isNewline) {
            let trimmed = String(line)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-*•"))
                .trimmingCharacters(in: .whitespaces)
            guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
            let label = String(trimmed[..<colonIdx])
                .trimmingCharacters(in: .whitespaces)
            let name = String(trimmed[trimmed.index(after: colonIdx)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !label.isEmpty, !name.isEmpty else { continue }
            out[label] = name
        }
        return out
    }

    /// Formats enabled glossary entries into a system-prompt appendix. Returns
    /// nil when nothing is enabled / both fields blank, so the caller can skip
    /// the appendix entirely. Header language matches the transcript.
    static func glossaryBlock(for language: TranscriptionLanguage,
                              terms: [GlossaryTerm]) -> String? {
        let enabled = terms.filter {
            $0.isEnabled
                && !$0.term.trimmingCharacters(in: .whitespaces).isEmpty
                && !$0.definition.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !enabled.isEmpty else { return nil }
        let header: String
        switch language {
        case .polish:
            header = "Słownik pojęć (użyj tych definicji do interpretacji transkrypcji):"
        case .russian:
            header = "Глоссарий терминов (используй эти определения для интерпретации транскрипции):"
        case .english:
            header = "Glossary of domain terms (use these definitions to interpret the transcript):"
        }
        let lines = enabled
            .map { "- \($0.term): \($0.definition)" }
            .joined(separator: "\n")
        return header + "\n" + lines
    }

    // MARK: - Per-call user prompts.

    static func summaryInstruction(for language: TranscriptionLanguage) -> String {
        switch language {
        case .english:
            return """
                Write concise meeting notes from the transcript below in the transcript's language.

                Use exactly these Markdown sections:
                # Overall Summary
                One short paragraph.

                # Key Points
                - One factual point [[M:SS]]

                # Action Items
                - One assigned or agreed action [[M:SS]]

                # Open Questions
                - One unresolved question [[M:SS]]

                Rules:
                - Keep the summary factual and concise. Use 2–6 bullets in each list only when supported by the transcript.
                - Every substantive bullet in Key Points, Action Items, and Open Questions must end with one timestamp copied from the transcript in the form [[M:SS]] or [[H:MM:SS]].
                - Use the timestamp of the transcript line that supports the bullet. Never invent a timestamp. Omit a bullet when there is no clear evidence.
                - If a section has no supported items, write a single bullet without a timestamp saying that there are no supported items.
                - Preserve names, technical identifiers, decisions, and numbers exactly as spoken. Do not add commentary outside these sections.
                """
        case .polish:
            return """
                Napisz zwięzłe notatki ze spotkania na podstawie poniższej transkrypcji, w jej języku.

                Użyj dokładnie tych sekcji Markdown:
                # Ogólne podsumowanie
                Jeden krótki akapit.

                # Najważniejsze punkty
                - Jeden rzeczowy punkt [[M:SS]]

                # Zadania
                - Jedno uzgodnione lub przypisane zadanie [[M:SS]]

                # Otwarte pytania
                - Jedno nierozstrzygnięte pytanie [[M:SS]]

                Zasady:
                - Pisz rzeczowo i zwięźle. Użyj 2–6 punktów w każdej liście tylko wtedy, gdy wynika to z transkrypcji.
                - Każdy merytoryczny punkt w trzech listach musi kończyć się jednym znacznikiem czasu skopiowanym z transkrypcji: [[M:SS]] lub [[H:MM:SS]].
                - Użyj czasu linii transkrypcji, która potwierdza dany punkt. Nie wymyślaj czasu. Pomiń punkt bez wyraźnego potwierdzenia.
                - Jeśli sekcja nie ma potwierdzonych elementów, wpisz jeden punkt bez znacznika czasu, że brak potwierdzonych elementów.
                - Zachowaj dokładnie imiona, identyfikatory techniczne, decyzje i liczby. Nie dodawaj komentarzy poza tymi sekcjami.
                """
        case .russian:
            return """
                Составь краткие заметки по приведённой транскрипции встречи на языке транскрипции.

                Используй ровно эти разделы Markdown:
                # Общее резюме
                Один короткий связный абзац.

                # Ключевые моменты
                - Один подтверждённый факт [[M:SS]]

                # Задачи
                - Одно согласованное или назначенное действие [[M:SS]]

                # Открытые вопросы
                - Один нерешённый вопрос [[M:SS]]

                Правила:
                - Пиши кратко и по фактам. Используй 2–6 пунктов в каждом списке только если это подтверждается транскрипцией.
                - Каждый содержательный пункт в трёх списках должен заканчиваться одним временем, скопированным из транскрипции, в формате [[M:SS]] или [[H:MM:SS]].
                - Используй время строки транскрипции, которая подтверждает пункт. Не выдумывай время. Не добавляй пункт без явного подтверждения.
                - Если подтверждённых элементов нет, напиши один пункт без времени о том, что их нет.
                - Сохраняй точно имена, технические идентификаторы, решения и числа. Не добавляй комментарии вне этих разделов.
                """
        }
    }

    static func titleInstruction(for language: TranscriptionLanguage) -> String {
        switch language {
        case .english:
            return """
                Generate a concise meeting title from the meeting summary below.

                Rules:
                • 3–8 words, Title Case.
                • No quotes, no trailing punctuation, no preamble.
                • Prefer concrete nouns from the meeting (project, topic, decision) over generic words like "Discussion" or "Meeting".
                • Output the title on a single line. Nothing else.
                """
        case .polish:
            return """
                Wygeneruj zwięzły tytuł spotkania na podstawie poniższego streszczenia.

                Zasady:
                • 3–8 słów, z wielkiej litery tam, gdzie to naturalne.
                • Bez cudzysłowów, bez kropki na końcu, bez wstępu.
                • Preferuj konkretne rzeczowniki ze spotkania (projekt, temat, decyzja) zamiast ogólników typu "Spotkanie" czy "Rozmowa".
                • Zwróć tytuł w jednej linii. Nic więcej.
                """
        case .russian:
            return """
                Сформулируй краткий заголовок встречи по приведённому ниже резюме.

                Правила:
                • 3–8 слов, с естественным использованием заглавных букв.
                • Без кавычек, точки в конце и вступления.
                • Предпочитай конкретные существительные из встречи (проект, тема, решение), а не общие слова вроде «Встреча» или «Обсуждение».
                • Выведи заголовок в одну строку. Больше ничего.
                """
        }
    }

    /// Clean up a model-generated title: strip quotes, markdown, trailing
    /// punctuation, and collapse to the first line (models sometimes leak
    /// explanations below the answer).
    static func sanitizeTitle(_ raw: String) -> String {
        var t = stripThinking(raw)
        if let nl = t.firstIndex(where: \.isNewline) {
            t = String(t[..<nl])
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip wrapping quotes / backticks / asterisks.
        while let first = t.first, "\"'`*".contains(first) { t.removeFirst() }
        while let last = t.last, "\"'`*".contains(last) { t.removeLast() }
        // Strip leading markdown headers.
        while t.hasPrefix("#") { t.removeFirst() }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop trailing period.
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }

    /// Strip any `<think>…</think>` blocks the model might still emit.
    /// Safe to call on streaming partials: if the opening tag was seen but the
    /// closing one hasn't arrived yet, everything from `<think>` onward is
    /// hidden until the matching close tag lands (or stream ends).
    static func stripThinking(_ raw: String) -> String {
        var out = raw
        // Remove complete <think>...</think> blocks first.
        while let open = out.range(of: "<think>"),
              let close = out.range(of: "</think>", range: open.upperBound..<out.endIndex) {
            out.removeSubrange(open.lowerBound..<close.upperBound)
        }
        // For a streaming partial: if <think> opened without a close yet,
        // hide everything from that point so the UI doesn't show reasoning.
        if let open = out.range(of: "<think>") {
            out.removeSubrange(open.lowerBound..<out.endIndex)
        }
        return out
    }
}
