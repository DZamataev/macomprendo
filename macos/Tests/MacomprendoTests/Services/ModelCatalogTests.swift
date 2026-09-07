import Foundation
import Testing
@testable import Macomprendo

@Suite struct ModelCatalogTests {

    @Test func everyCatalogEntryReportsItsKindFromItsEngine() {
        #expect(LocalEngine.whisperCpp.kind == .asr)
        #expect(LocalEngine.gigaAM.kind == .asr)
        #expect(ModelCatalog.all(kind: .asr).allSatisfy { $0.kind == .asr })
        #expect(ModelCatalog.all(kind: .tts).allSatisfy { $0.kind == .tts })
    }

    @Test func allByKindPartitionsTheCatalog() {
        let asr = ModelCatalog.all(kind: .asr)
        let tts = ModelCatalog.all(kind: .tts)
        #expect(asr.count == 13)
        #expect(tts.count == 8)
        #expect(asr.count + tts.count == ModelCatalog.all.count)
    }

    @Test func localTTSCatalogContainsTheEightPinnedArchives() throws {
        let expected: [String: (fileName: String, size: Int64, sha256: String)] = [
            "vits-piper-ru_RU-ruslan-medium":
                ("vits-piper-ru_RU-ruslan-medium.tar.bz2", 67_210_684,
                 "0690b1cad01f86e8db9ba988af24898bdc1af774e23cb2e46b9c730269b6fd83"),
            "vits-piper-ru_RU-irina-medium":
                ("vits-piper-ru_RU-irina-medium.tar.bz2", 67_153_308,
                 "1fc0f54e5e084fe287c07909f2f6e0ba6d857864cf800e3ab80286a4e8233008"),
            "vits-piper-ru_RU-dmitri-medium":
                ("vits-piper-ru_RU-dmitri-medium.tar.bz2", 67_188_551,
                 "c86d0803737de13d441923ff3b3f309482fab8d7af3ec85949942809eb9a3660"),
            "vits-piper-ru_RU-denis-medium":
                ("vits-piper-ru_RU-denis-medium.tar.bz2", 67_190_991,
                 "efa4c18e0b5e32b81d1b6df36b9d312831e5d545200e27848ef926a4cd930300"),
            "vits-piper-en_US-lessac-medium":
                ("vits-piper-en_US-lessac-medium.tar.bz2", 67_230_653,
                 "9e3febfacf0abf4270172d2958bcec246032b7e88efc2720840cc80c93de334e"),
            "vits-piper-en_US-libritts_r-medium":
                ("vits-piper-en_US-libritts_r-medium.tar.bz2", 82_038_311,
                 "10dc268f3e371696d721486123e2705a9fc1faa113491979fde4d88dba1f1b1c"),
            "vits-piper-en_GB-alba-medium":
                ("vits-piper-en_GB-alba-medium.tar.bz2", 67_212_349,
                 "fcd45962906933eec4431d3688f7d74aaac8713c87c6717f91fd3b23463aa1a1"),
            "kokoro-multi-lang-v1_1":
                ("kokoro-multi-lang-v1_1.tar.bz2", 364_816_464,
                 "a3f4c73d043860e3fd2e5b06f36795eb81de0fc8e8de6df703245edddd87dbad")
        ]

        let models = ModelCatalog.all(kind: .tts)
        #expect(Set(models.map(\.id)) == Set(expected.keys))
        #expect(models.count == 8)

        for model in models {
            let pinned = try #require(expected[model.id])
            let archive = try #require(model.file(.archive))
            #expect(model.files.count == 1)
            #expect(archive.fileName == pinned.fileName)
            #expect(archive.sizeBytes == pinned.size)
            #expect(archive.sha256 == pinned.sha256)
            #expect(archive.downloadURL.absoluteString ==
                    "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/\(pinned.fileName)")
        }
    }

    @Test func localTTSMetadataMatchesTheRuntimeLayouts() {
        #expect(LocalEngine.sherpaVits.kind == .tts)
        #expect(LocalEngine.sherpaKokoro.kind == .tts)

        let piper = ModelCatalog.all(for: .sherpaVits)
        #expect(piper.count == 7)
        #expect(piper.filter { $0.id == "vits-piper-en_US-libritts_r-medium" }
            .allSatisfy { $0.speakerCount == 904 })
        #expect(piper.filter { $0.id != "vits-piper-en_US-libritts_r-medium" }
            .allSatisfy { $0.speakerCount == 1 })
        #expect(piper.allSatisfy { model in
            model.archiveSentinel == String(model.id.dropFirst("vits-piper-".count)) + ".onnx"
        })

        let kokoro = ModelCatalog.model(id: "kokoro-multi-lang-v1_1")
        #expect(kokoro?.engine == .sherpaKokoro)
        #expect(kokoro?.speakerCount == 103)
        #expect(kokoro?.archiveSentinel == "model.onnx")
    }

    @Test func localTTSInstalledSizesAndBriefsDescribeTheActualArchives() throws {
        let expectedSizes: [String: Int64] = [
            "vits-piper-ru_RU-ruslan-medium": 81_146_959,
            "vits-piper-ru_RU-irina-medium": 81_146_778,
            "vits-piper-ru_RU-dmitri-medium": 81_146_850,
            "vits-piper-ru_RU-denis-medium": 81_146_848,
            "vits-piper-en_US-lessac-medium": 81_147_006,
            "vits-piper-en_US-libritts_r-medium": 96_542_847,
            "vits-piper-en_GB-alba-medium": 81_199_214,
            "kokoro-multi-lang-v1_1": 426_654_376
        ]
        let models = ModelCatalog.all(kind: .tts)

        for model in models {
            #expect(model.installedSizeBytes == expectedSizes[model.id])
            #expect(model.brief.limitations.isEmpty == false)
        }
        #expect(Set(models.map(\.brief.summary)).count == models.count)
    }

    @Test func containsExactlyTheThirteenOfferedASRModelsInOrder() {
        #expect(ModelCatalog.all(kind: .asr).map(\.id) == [
            "tiny", "tiny.en", "base", "base.en",
            "small", "small.en", "medium", "medium.en",
            "large-v3-turbo",
            "gigaam-v3-e2e-ctc", "gigaam-v3-e2e-rnnt",
            "gigaam-multilingual-ctc", "gigaam-multilingual-large-ctc"
        ])
    }

    @Test func defaultAndLightweightIDsAreInTheCatalog() {
        #expect(ModelCatalog.defaultID == "large-v3-turbo")
        #expect(ModelCatalog.lightweightID == "base")
        #expect(ModelCatalog.model(id: ModelCatalog.defaultID) != nil)
        #expect(ModelCatalog.model(id: ModelCatalog.lightweightID) != nil)
    }

    @Test func everyModelHasAPositiveApproximateSizeAndANonEmptyDisplayName() {
        for model in ModelCatalog.all {
            #expect(!model.displayName.isEmpty, "missing display name for \(model.id)")
            for file in model.files {
                #expect(file.sizeBytes > 0, "missing size for \(model.id)'s \(file.fileName)")
            }
        }
    }

    @Test func modelIDsAreUnique() {
        #expect(Set(ModelCatalog.all.map(\.id)).count == ModelCatalog.all.count)
    }

    @Test func lookupByIDIsExactAndReturnsNilForUnknownIDs() {
        #expect(ModelCatalog.model(id: "base")?.file(.ggml)?.fileName == "ggml-base.bin")
        #expect(ModelCatalog.model(id: "base.en")?.file(.ggml)?.fileName == "ggml-base.en.bin")
        #expect(ModelCatalog.model(id: "nonexistent") == nil)
        #expect(ModelCatalog.model(id: "BASE") == nil)
    }

    @Test func everyWhisperEntryIsASingleGGMLFileFromHuggingFace() throws {
        for model in ModelCatalog.all where model.engine == .whisperCpp {
            #expect(model.files.count == 1, "\(model.id) should be one file")
            let file = try #require(model.file(.ggml))
            #expect(file.fileName == "ggml-\(model.id).bin")
            #expect(file.downloadURL == URL(
                string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(model.id).bin"
            )!)
        }
    }

    @Test func totalSizeIsTheSumOfTheFileSet() {
        let model = LocalModel(
            id: "x", displayName: "X", engine: .gigaAM, languages: ["ru"],
            files: [
                ModelFile(role: .ctcModel, fileName: "x-model.onnx", sizeBytes: 100,
                          sha256: "", downloadURL: URL(string: "https://example.com/m")!),
                ModelFile(role: .tokens, fileName: "x-tokens.txt", sizeBytes: 23,
                          sha256: "", downloadURL: URL(string: "https://example.com/t")!)
            ],
            brief: ModelBrief(summary: "", strengths: [], limitations: [], benchmarks: [],
                              sourceURL: URL(string: "https://example.com")!)
        )
        #expect(model.totalSizeBytes == 123)
        #expect(model.file(.tokens)?.fileName == "x-tokens.txt")
        #expect(model.file(.encoder) == nil)
    }

    @Test func localFileNamesAreUniqueAcrossTheWholeCatalog() {
        let names = ModelCatalog.all.flatMap { $0.files.map(\.fileName) }
        #expect(names.count == Set(names).count, "two catalog entries share a local file name")
    }

    @Test func everyEntryDeclaresAValidFileSetForItsEngine() {
        for model in ModelCatalog.all {
            let roles = Set(model.files.map(\.role))
            switch model.engine {
            case .whisperCpp:
                #expect(roles == [.ggml], "\(model.id) is not a whisper file set")
            case .gigaAM:
                let ctc: Set<ModelFileRole> = [.ctcModel, .tokens]
                let transducer: Set<ModelFileRole> = [.encoder, .decoder, .joiner, .tokens]
                #expect(roles == ctc || roles == transducer, "\(model.id) is not a sherpa file set")
            case .sherpaVits, .sherpaKokoro:
                #expect(roles == [.archive], "\(model.id) is not an archived TTS model")
            }
        }
    }

    @Test func offersFourGigaAMModels() {
        #expect(ModelCatalog.all(for: .gigaAM).map(\.id) == [
            "gigaam-v3-e2e-ctc",
            "gigaam-v3-e2e-rnnt",
            "gigaam-multilingual-ctc",
            "gigaam-multilingual-large-ctc"
        ])
    }

    @Test func theRussianEntriesDeclareRussianAndTheMultilingualOnesDeclareFive() {
        #expect(ModelCatalog.model(id: "gigaam-v3-e2e-ctc")?.languages == ["ru"])
        #expect(ModelCatalog.model(id: "gigaam-v3-e2e-rnnt")?.languages == ["ru"])
        #expect(ModelCatalog.model(id: "gigaam-multilingual-ctc")?.languages == ["ru", "en", "kk", "ky", "uz"])
        #expect(ModelCatalog.model(id: "gigaam-multilingual-large-ctc")?.languages == ["ru", "en", "kk", "ky", "uz"])
    }

    @Test func everyGigaAMEntryHasAUsableBrief() {
        for model in ModelCatalog.all(for: .gigaAM) {
            #expect(!model.brief.summary.isEmpty, "\(model.id) has no summary")
            #expect(!model.brief.strengths.isEmpty, "\(model.id) lists no strengths")
            #expect(!model.brief.limitations.isEmpty, "\(model.id) lists no limitations")
        }
    }

    @Test func theMultilingualBriefsWarnThatThereIsNoPunctuation() {
        for id in ["gigaam-multilingual-ctc", "gigaam-multilingual-large-ctc"] {
            let model = ModelCatalog.model(id: id)!
            #expect(model.brief.limitations.contains { $0.lowercased().contains("punctuation") },
                    "\(id) does not warn about missing punctuation")
        }
    }

    @Test func everyBenchmarkIsAttributedToAnHTTPSSource() {
        for model in ModelCatalog.all where !model.brief.benchmarks.isEmpty {
            #expect(model.brief.sourceURL.scheme == "https", "\(model.id) benchmark source is not https")
        }
    }

    @Test func theTransducerEntryDeclaresFourFiles() {
        let rnnt = ModelCatalog.model(id: "gigaam-v3-e2e-rnnt")!
        #expect(Set(rnnt.files.map(\.role)) == [.encoder, .decoder, .joiner, .tokens])
    }

    // MARK: - languagesText

    @Test func aModelWithNoPublishedLanguageListIsCalledMultilingualRatherThanBlank() {
        #expect(LocalModel.languagesText(nil) == "90+ languages")
        #expect(LocalModel.languagesText([]) == "90+ languages")
    }

    @Test func aPublishedLanguageListIsNamedInWords() {
        #expect(LocalModel.languagesText(["ru"]) == "Russian")
        #expect(LocalModel.languagesText(["ru", "en"]) == "Russian, English")
        // An unknown code is shown as itself rather than dropped.
        #expect(LocalModel.languagesText(["zzz"]).contains("zzz"))
    }

    @Test func theInstancePropertyMatchesTheStaticFunctionForTheModelsOwnLanguages() {
        let model = LocalModel(id: "x", displayName: "X", engine: .gigaAM, languages: ["ru", "en"],
                                files: [],
                                brief: ModelBrief(summary: "", strengths: [], limitations: [],
                                                  benchmarks: [],
                                                  sourceURL: URL(string: "https://example.com")!))
        #expect(model.languagesText == "Russian, English")
        #expect(model.languagesText == LocalModel.languagesText(model.languages))
    }
}
