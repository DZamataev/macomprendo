import Foundation

extension FactoryPresetContent {
    static let chinese = FactoryPresetContent(
        systemPrompt: """
            你是一位细致的写作助手。请严格按照指令处理用户的文本。只返回处理后的文本——不要添加评论、\
            不要解释、不要在结果外加引号，也不要使用 markdown 代码块。
            """,
        entries: [
            .cleanUp: .init(name: "整理", template: """
                整理以下文本。去掉口头禅、说了一半又重来的话和结巴，并修正标点和大小写。保留原意、\
                语气和原文语言。
                {instruction}

                {text}
                """),
            .formal: .init(name: "正式", template: """
                用正式、专业的语气改写以下文本。保留原意和原文语言。
                {instruction}

                {text}
                """),
            .casual: .init(name: "口语", template: """
                用轻松、口语化的语气改写以下文本。保留原意和原文语言。
                {instruction}

                {text}
                """),
            .shorten: .init(name: "缩短", template: """
                在保留所有要点的前提下，把以下文本改写得明显更短。保留原文语言。
                {instruction}

                {text}
                """),
            .expand: .init(name: "扩展", template: """
                为以下文本补充更多细节，并让结构更清晰。不要编造事实。保留原文语言。
                {instruction}

                {text}
                """),
            .fixGrammar: .init(name: "修正语法", template: """
                修正以下文本中的拼写、语法和标点。不要改动其他任何内容——保留原有措辞、语气和原文\
                语言。
                {instruction}

                {text}
                """),
            .translate: .init(name: "翻译", template: """
                目标语言：{chosen_language}
                把以下文本翻译成该语言。保留语气和排版格式。
                {instruction}

                {text}
                """),
            .translateAndOrganize: .init(name: "翻译并整理", template: """
                目标语言：{chosen_language}
                把以下文本翻译成该语言，然后整理结果：把相关内容归到一起，在有助于阅读的地方加上简短小标题或列表，删除重复。不要编造事实，也不要遗漏信息。
                {instruction}

                {text}
                """),
            .brief: .init(name: "简述", template: """
                用两三句话概括以下文本。用原文的语言撰写摘要。
                {instruction}

                {text}
                """),
            .bullets: .init(name: "要点", template: """
                将以下文本概括为最多六条简洁的要点，每条一行，每条以“- ”开头。用原文的语言\
                撰写。
                {instruction}

                {text}
                """),
            .tldr: .init(name: "一句话总结", template: """
                用原文的语言，给以下文本一句话总结。
                {instruction}

                {text}
                """),
            .keyActions: .init(name: "待办事项", template: """
                用原文的语言，把以下文本中具体的待办事项列成编号列表。如果没有，就原样回答\
                “没有待办事项。”
                {instruction}

                {text}
                """),
            .briefTranslated: .init(name: "简述并翻译", template: """
                目标语言：{chosen_language}
                无论原文是什么语言，都用该语言把以下文本概括为两三句话。
                {instruction}

                {text}
                """),
            .bulletsTranslated: .init(name: "要点并翻译", template: """
                目标语言：{chosen_language}
                把以下文本概括为最多六条要点，每条一行，每条以“- ”开头。无论原文是什么语言，都用该语言撰写。
                {instruction}

                {text}
                """),
            .tldrTranslated: .init(name: "一句话总结并翻译", template: """
                目标语言：{chosen_language}
                无论原文是什么语言，都用该语言用一句话总结以下文本。
                {instruction}

                {text}
                """),
            .keyActionsTranslated: .init(name: "待办事项并翻译", template: """
                目标语言：{chosen_language}
                把以下文本中的具体待办事项整理成编号列表。无论原文是什么语言，都用该语言书写。如果没有，就原样回答“没有待办事项。”
                {instruction}

                {text}
                """),
        ])
}
