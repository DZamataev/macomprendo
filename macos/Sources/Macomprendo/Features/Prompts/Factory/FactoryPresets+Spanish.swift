import Foundation

extension FactoryPresetContent {
    static let spanish = FactoryPresetContent(
        systemPrompt: """
            Eres un asistente de escritura cuidadoso. Procesa el texto del usuario exactamente \
            como se indica en la instrucción. Devuelve solo el texto resultante — sin comentarios, \
            sin explicaciones, sin comillas alrededor del resultado y sin bloques de código markdown.
            """,
        entries: [
            .cleanUp: .init(name: "Limpiar", template: """
                Limpia el siguiente texto. Elimina muletillas, arranques en falso y titubeos, y \
                corrige la puntuación y las mayúsculas. Conserva el sentido, el tono y el idioma original.
                {instruction}

                {text}
                """),
            .formal: .init(name: "Formal", template: """
                Reescribe el siguiente texto en un registro formal y profesional. Conserva el \
                sentido y el idioma original.
                {instruction}

                {text}
                """),
            .casual: .init(name: "Coloquial", template: """
                Reescribe el siguiente texto en un registro distendido y conversacional. Conserva \
                el sentido y el idioma original.
                {instruction}

                {text}
                """),
            .shorten: .init(name: "Acortar", template: """
                Reescribe el siguiente texto de forma considerablemente más breve, conservando \
                todos los puntos importantes. Conserva el idioma original.
                {instruction}

                {text}
                """),
            .expand: .init(name: "Ampliar", template: """
                Amplía el siguiente texto con más detalle y una estructura más clara. No inventes \
                datos. Conserva el idioma original.
                {instruction}

                {text}
                """),
            .fixGrammar: .init(name: "Corregir gramática", template: """
                Corrige la ortografía, la gramática y la puntuación del siguiente texto. No \
                cambies nada más — conserva las palabras, el tono y el idioma original.
                {instruction}

                {text}
                """),
            .translate: .init(name: "Traducir", template: """
                Traduce el siguiente texto al {language}. Conserva el tono y el formato.
                {instruction}

                {text}
                """),
            .translateAndOrganize: .init(name: "Traducir y organizar", template: """
                Traduce el siguiente texto al español y luego organiza el resultado: agrupa los \
                puntos relacionados, añade títulos breves o una lista donde faciliten la lectura, \
                y elimina las repeticiones. No inventes datos ni omitas información.
                {instruction}

                {text}
                """),
            .brief: .init(name: "Breve", template: """
                Resume el siguiente texto en dos o tres frases. Escribe el resumen en el idioma \
                del texto.
                {instruction}

                {text}
                """),
            .bullets: .init(name: "Viñetas", template: """
                Resume el siguiente texto en un máximo de seis viñetas concisas, una por línea, \
                cada una empezando con "- ". Escríbelas en el idioma del texto.
                {instruction}

                {text}
                """),
            .tldr: .init(name: "TL;DR", template: """
                Da un TL;DR de una sola frase del siguiente texto, en el idioma del texto.
                {instruction}

                {text}
                """),
            .keyActions: .init(name: "Acciones clave", template: """
                Enumera las tareas concretas del siguiente texto en una lista numerada, en el \
                idioma del texto. Si no hay ninguna, responde exactamente "Sin tareas pendientes."
                {instruction}

                {text}
                """),
        ])
}
