import Foundation

extension FactoryPresetContent {
    static let german = FactoryPresetContent(
        systemPrompt: """
            Du bist ein sorgfältiger Schreibassistent. Verarbeite den Text der Nutzerin oder des \
            Nutzers genau so, wie es in der Anweisung steht. Gib nur den resultierenden Text zurück \
            — ohne Kommentar, ohne Erklärung, ohne Anführungszeichen um die Ausgabe und ohne \
            Markdown-Codeblöcke.
            """,
        entries: [
            .cleanUp: .init(name: "Aufräumen", template: """
                Räume den folgenden Text auf. Entferne Füllwörter, Satzabbrüche und Versprecher \
                und korrigiere Zeichensetzung und Groß-/Kleinschreibung. Behalte Bedeutung, Ton \
                und Originalsprache bei.
                {instruction}

                {text}
                """),
            .formal: .init(name: "Förmlich", template: """
                Formuliere den folgenden Text in einem förmlichen, professionellen Register neu. \
                Behalte die Bedeutung und die Originalsprache bei.
                {instruction}

                {text}
                """),
            .casual: .init(name: "Locker", template: """
                Formuliere den folgenden Text in einem lockeren, umgangssprachlichen Register neu. \
                Behalte die Bedeutung und die Originalsprache bei.
                {instruction}

                {text}
                """),
            .shorten: .init(name: "Kürzen", template: """
                Formuliere den folgenden Text deutlich kürzer, ohne einen wichtigen Punkt zu \
                verlieren. Behalte die Originalsprache bei.
                {instruction}

                {text}
                """),
            .expand: .init(name: "Erweitern", template: """
                Erweitere den folgenden Text um mehr Details und eine klarere Struktur. Erfinde \
                keine Fakten. Behalte die Originalsprache bei.
                {instruction}

                {text}
                """),
            .fixGrammar: .init(name: "Grammatik korrigieren", template: """
                Korrigiere Rechtschreibung, Grammatik und Zeichensetzung im folgenden Text. Ändere \
                sonst nichts — behalte Wortlaut, Ton und Originalsprache bei.
                {instruction}

                {text}
                """),
            .translate: .init(name: "Übersetzen", template: """
                Zielsprache: {chosen_language}
                Übersetze den folgenden Text in diese Sprache. Behalte Ton und Formatierung bei.
                {instruction}

                {text}
                """),
            .translateAndOrganize: .init(name: "Übersetzen und ordnen", template: """
                Zielsprache: {chosen_language}
                Übersetze den folgenden Text in diese Sprache und ordne das Ergebnis anschließend: Fasse \
                zusammengehörige Punkte zusammen, ergänze kurze Überschriften oder eine Liste, wo sie den \
                Text lesbarer machen, und entferne Wiederholungen. Erfinde keine Fakten und lasse nichts \
                weg.
                {instruction}

                {text}
                """),
            .brief: .init(name: "Kurzfassung", template: """
                Fasse den folgenden Text in zwei bis drei Sätzen zusammen. Schreibe die \
                Zusammenfassung in der Sprache des Textes.
                {instruction}

                {text}
                """),
            .bullets: .init(name: "Stichpunkte", template: """
                Fasse den folgenden Text in höchstens sechs knappen Stichpunkten zusammen, je \
                einer pro Zeile, jeder beginnend mit „- ". Schreibe sie in der Sprache des Textes.
                {instruction}

                {text}
                """),
            .tldr: .init(name: "TL;DR", template: """
                Gib ein TL;DR des folgenden Textes in einem Satz, in der Sprache des Textes.
                {instruction}

                {text}
                """),
            .keyActions: .init(name: "Aufgaben", template: """
                Liste die konkreten Aufgaben aus dem folgenden Text als nummerierte Liste auf, in \
                der Sprache des Textes. Gibt es keine, antworte exakt mit „Keine Aufgaben."
                {instruction}

                {text}
                """),
            .briefTranslated: .init(name: "Kurzfassung, mit Übersetzung", template: """
                Zielsprache: {chosen_language}
                Fasse den folgenden Text in zwei bis drei Sätzen in dieser Sprache zusammen, unabhängig \
                davon, in welcher Sprache der Text verfasst ist.
                {instruction}

                {text}
                """),
            .bulletsTranslated: .init(name: "Stichpunkte, mit Übersetzung", template: """
                Zielsprache: {chosen_language}
                Fasse den folgenden Text in höchstens sechs knappen Stichpunkten zusammen, je einer pro \
                Zeile, jeder beginnend mit „- “. Schreibe sie in dieser Sprache, unabhängig von der Sprache \
                des Textes.
                {instruction}

                {text}
                """),
            .tldrTranslated: .init(name: "TL;DR, mit Übersetzung", template: """
                Zielsprache: {chosen_language}
                Gib ein TL;DR des folgenden Textes in einem Satz in dieser Sprache, unabhängig von der \
                Sprache des Textes.
                {instruction}

                {text}
                """),
            .keyActionsTranslated: .init(name: "Aufgaben, mit Übersetzung", template: """
                Zielsprache: {chosen_language}
                Liste die konkreten Aufgaben aus dem folgenden Text als nummerierte Liste in dieser Sprache \
                auf, unabhängig von der Sprache des Textes. Gibt es keine, antworte exakt mit „Keine \
                Aufgaben.“
                {instruction}

                {text}
                """),
        ])
}
