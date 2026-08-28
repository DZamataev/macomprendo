import Foundation

extension FactoryPresetContent {
    static let french = FactoryPresetContent(
        systemPrompt: """
            Tu es un assistant de rédaction rigoureux. Traite le texte de l'utilisateur exactement \
            comme l'indique l'instruction. Renvoie uniquement le texte résultant — sans commentaire, \
            sans explication, sans guillemets autour du résultat et sans bloc de code markdown.
            """,
        entries: [
            .cleanUp: .init(name: "Nettoyer", template: """
                Nettoie le texte suivant. Retire les mots de remplissage, les faux départs et les \
                hésitations, et corrige la ponctuation et les majuscules. Conserve le sens, le ton \
                et la langue d'origine.
                {instruction}

                {text}
                """),
            .formal: .init(name: "Formel", template: """
                Réécris le texte suivant dans un registre formel et professionnel. Conserve le \
                sens et la langue d'origine.
                {instruction}

                {text}
                """),
            .casual: .init(name: "Familier", template: """
                Réécris le texte suivant dans un registre détendu et conversationnel. Conserve le \
                sens et la langue d'origine.
                {instruction}

                {text}
                """),
            .shorten: .init(name: "Raccourcir", template: """
                Réécris le texte suivant nettement plus court, en conservant tous les points \
                importants. Conserve la langue d'origine.
                {instruction}

                {text}
                """),
            .expand: .init(name: "Développer", template: """
                Développe le texte suivant avec plus de détails et une structure plus claire. \
                N'invente aucun fait. Conserve la langue d'origine.
                {instruction}

                {text}
                """),
            .fixGrammar: .init(name: "Corriger la grammaire", template: """
                Corrige l'orthographe, la grammaire et la ponctuation du texte suivant. Ne change \
                rien d'autre — conserve la formulation, le ton et la langue d'origine.
                {instruction}

                {text}
                """),
            .translate: .init(name: "Traduire", template: """
                Traduis le texte suivant en {language}. Conserve le ton et la mise en forme.
                {instruction}

                {text}
                """),
            .translateAndOrganize: .init(name: "Traduire et organiser", template: """
                Traduis le texte suivant en français, puis organise le résultat : regroupe les \
                points liés entre eux, ajoute de courts titres ou une liste là où ils facilitent \
                la lecture, et supprime les répétitions. N'invente aucun fait et ne perds aucune \
                information.
                {instruction}

                {text}
                """),
            .brief: .init(name: "Bref", template: """
                Résume le texte suivant en deux ou trois phrases. Rédige le résumé dans la langue \
                du texte.
                {instruction}

                {text}
                """),
            .bullets: .init(name: "Puces", template: """
                Résume le texte suivant en six puces concises maximum, une ligne chacune, chacune \
                commençant par « - ». Rédige-les dans la langue du texte.
                {instruction}

                {text}
                """),
            .tldr: .init(name: "TL;DR", template: """
                Donne un TL;DR en une phrase du texte suivant, dans la langue du texte.
                {instruction}

                {text}
                """),
            .keyActions: .init(name: "Actions clés", template: """
                Liste les actions concrètes du texte suivant sous forme de liste numérotée, dans \
                la langue du texte. S'il n'y en a aucune, réponds exactement « Aucune action. »
                {instruction}

                {text}
                """),
        ])
}
