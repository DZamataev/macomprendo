import Foundation

extension FactoryPresetContent {
    static let english = FactoryPresetContent(
        systemPrompt: """
            You are a careful writing assistant. Process the user's text exactly as instructed. \
            Return only the resulting text — no commentary, no explanation, no quotation marks \
            around the output and no markdown code fences.
            """,
        entries: [
            .cleanUp: .init(name: "Clean up", template: """
                Clean up the following text. Remove filler words, false starts and stutters, and \
                fix punctuation and capitalization. Keep the meaning, the tone and the original language.
                {instruction}

                {text}
                """),
            .formal: .init(name: "Formal", template: """
                Rewrite the following text in a formal, professional register. Keep the meaning \
                and the original language.
                {instruction}

                {text}
                """),
            .casual: .init(name: "Casual", template: """
                Rewrite the following text in a relaxed, conversational register. Keep the meaning \
                and the original language.
                {instruction}

                {text}
                """),
            .shorten: .init(name: "Shorten", template: """
                Rewrite the following text so it is significantly shorter while keeping every \
                important point. Keep the original language.
                {instruction}

                {text}
                """),
            .expand: .init(name: "Expand", template: """
                Expand the following text with more detail and clearer structure. Do not invent \
                facts. Keep the original language.
                {instruction}

                {text}
                """),
            .fixGrammar: .init(name: "Fix grammar", template: """
                Correct spelling, grammar and punctuation in the following text. Change nothing \
                else — keep the wording, the tone and the original language.
                {instruction}

                {text}
                """),
            .translate: .init(name: "Translate", template: """
                Translate the following text into {language}. Preserve the tone and the formatting.
                {instruction}

                {text}
                """),
            .translateAndOrganize: .init(name: "Translate & organize", template: """
                Translate the following text into English, then organize the result: group \
                related points together, add short headings or a list where they make the text \
                easier to follow, and remove repetition. Do not invent facts and do not drop \
                information.
                {instruction}

                {text}
                """),
            .brief: .init(name: "Brief", template: """
                Summarize the following text in two or three sentences. Write the summary in the \
                language of the text.
                {instruction}

                {text}
                """),
            .bullets: .init(name: "Bullets", template: """
                Summarize the following text as at most six concise bullet points, one line each, \
                each starting with "- ". Write them in the language of the text.
                {instruction}

                {text}
                """),
            .tldr: .init(name: "TL;DR", template: """
                Give a one-sentence TL;DR of the following text, in the language of the text.
                {instruction}

                {text}
                """),
            .keyActions: .init(name: "Key actions", template: """
                List the concrete action items in the following text as a numbered list, in the \
                language of the text. If there are none, answer exactly "No action items."
                {instruction}

                {text}
                """),
            .briefTranslated: .init(name: "Brief, translated", template: """
                Summarize the following text in two or three sentences. Write the summary in {language}, \
                whatever language the text itself is in.
                {instruction}

                {text}
                """),
            .bulletsTranslated: .init(name: "Bullets, translated", template: """
                Summarize the following text as at most six concise bullet points, one line each, each \
                starting with "- ". Write them in {language}, whatever language the text itself is in.
                {instruction}

                {text}
                """),
            .tldrTranslated: .init(name: "TL;DR, translated", template: """
                Give a one-sentence TL;DR of the following text, written in {language}, whatever language \
                the text itself is in.
                {instruction}

                {text}
                """),
            .keyActionsTranslated: .init(name: "Key actions, translated", template: """
                List the concrete action items in the following text as a numbered list, written in \
                {language}, whatever language the text itself is in. If there are none, answer exactly "No \
                action items."
                {instruction}

                {text}
                """),
        ])
}
