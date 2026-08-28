import Foundation

extension FactoryPresetContent {
    static let portuguese = FactoryPresetContent(
        systemPrompt: """
            Você é um assistente de escrita cuidadoso. Processe o texto do usuário exatamente \
            como indicado na instrução. Devolva apenas o texto resultante — sem comentários, sem \
            explicações, sem aspas em torno do resultado e sem blocos de código markdown.
            """,
        entries: [
            .cleanUp: .init(name: "Limpar", template: """
                Limpe o texto a seguir. Remova palavras de preenchimento, falsos começos e \
                hesitações, e corrija a pontuação e as maiúsculas. Preserve o sentido, o tom e o \
                idioma original.
                {instruction}

                {text}
                """),
            .formal: .init(name: "Formal", template: """
                Reescreva o texto a seguir em um registro formal e profissional. Preserve o \
                sentido e o idioma original.
                {instruction}

                {text}
                """),
            .casual: .init(name: "Coloquial", template: """
                Reescreva o texto a seguir em um registro descontraído e conversacional. Preserve \
                o sentido e o idioma original.
                {instruction}

                {text}
                """),
            .shorten: .init(name: "Encurtar", template: """
                Reescreva o texto a seguir de forma bem mais curta, preservando todos os pontos \
                importantes. Preserve o idioma original.
                {instruction}

                {text}
                """),
            .expand: .init(name: "Expandir", template: """
                Expanda o texto a seguir com mais detalhes e uma estrutura mais clara. Não invente \
                fatos. Preserve o idioma original.
                {instruction}

                {text}
                """),
            .fixGrammar: .init(name: "Corrigir gramática", template: """
                Corrija a ortografia, a gramática e a pontuação do texto a seguir. Não mude mais \
                nada — preserve as palavras, o tom e o idioma original.
                {instruction}

                {text}
                """),
            .translate: .init(name: "Traduzir", template: """
                Traduza o texto a seguir para {language}. Preserve o tom e a formatação.
                {instruction}

                {text}
                """),
            .translateAndOrganize: .init(name: "Traduzir e organizar", template: """
                Traduza o texto a seguir para português e, em seguida, organize o resultado: \
                agrupe pontos relacionados, adicione títulos curtos ou uma lista onde isso facilite \
                a leitura, e remova repetições. Não invente fatos nem omita informações.
                {instruction}

                {text}
                """),
            .brief: .init(name: "Resumo", template: """
                Resuma o texto a seguir em duas ou três frases. Escreva o resumo no idioma do \
                texto.
                {instruction}

                {text}
                """),
            .bullets: .init(name: "Tópicos", template: """
                Resuma o texto a seguir em no máximo seis tópicos concisos, uma linha cada, cada \
                um começando com "- ". Escreva-os no idioma do texto.
                {instruction}

                {text}
                """),
            .tldr: .init(name: "TL;DR", template: """
                Dê um TL;DR de uma frase do texto a seguir, no idioma do texto.
                {instruction}

                {text}
                """),
            .keyActions: .init(name: "Ações", template: """
                Liste os itens de ação concretos do texto a seguir como uma lista numerada, no \
                idioma do texto. Se não houver nenhum, responda exatamente "Sem itens de ação."
                {instruction}

                {text}
                """),
        ])
}
