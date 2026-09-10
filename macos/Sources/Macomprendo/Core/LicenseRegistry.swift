import Foundation

/// One redistributed third-party component and the licence its terms come from.
///
/// The list exists because MIT and Apache-2.0 both require their notices to travel with the
/// software, and because some components are *statically linked* into the vendored
/// xcframeworks: `onnxruntime` and `espeak-ng` never appear in `otool -L` output yet are
/// unmistakably compiled into `SherpaOnnxC`, so a list built from linked dylibs alone would
/// silently omit exactly the entries that matter most.
struct LicenseEntry: Sendable, Equatable {
    /// Display name, e.g. `whisper.cpp`.
    let component: String
    /// SPDX identifier, e.g. `Apache-2.0`.
    let spdx: String
    /// How the component reaches the user — its own framework, static linkage, a package.
    let origin: String
    let homepage: URL
    /// Base name of the bundled licence text under `Resources/Licenses`.
    let resourceName: String
    /// True when the licence's terms reach the whole combined binary.
    let isCopyleft: Bool
    /// Shown next to the entry when there is something the reader must not miss.
    let note: String?

    /// The bundled licence text, or nil when the resource is missing.
    func licenseText(in bundle: Bundle = ResourceBundle.current) -> String? {
        guard let url = bundle.url(forResource: resourceName, withExtension: "txt",
                                   subdirectory: "Licenses") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// Every third-party component redistributed inside the app.
///
/// Verified against the shipped artifact rather than assembled from documentation: symbols
/// and verbatim source strings were read out of
/// `Macomprendo.app/Contents/Frameworks/SherpaOnnxC.framework` and `whisper.framework`.
enum LicenseRegistry {

    static let all: [LicenseEntry] = [
        LicenseEntry(
            component: "whisper.cpp",
            spdx: "MIT",
            origin: "Vendored xcframework v1.9.2 (whisper.framework)",
            homepage: URL(string: "https://github.com/ggml-org/whisper.cpp")!,
            resourceName: "whisper.cpp",
            isCopyleft: false,
            note: nil
        ),
        LicenseEntry(
            component: "sherpa-onnx",
            spdx: "Apache-2.0",
            origin: "Vendored xcframework v1.13.4 (SherpaOnnxC.framework)",
            homepage: URL(string: "https://github.com/k2-fsa/sherpa-onnx")!,
            resourceName: "sherpa-onnx",
            isCopyleft: false,
            note: nil
        ),
        LicenseEntry(
            component: "espeak-ng",
            spdx: "GPL-3.0-only",
            origin: "Statically linked inside SherpaOnnxC.framework, via piper-phonemize",
            homepage: URL(string: "https://github.com/espeak-ng/espeak-ng")!,
            resourceName: "espeak-ng",
            isCopyleft: true,
            note: """
            espeak-ng is the phonemiser behind Local TTS and is compiled into the \
            sherpa-onnx framework this app bundles. Its licence is GPL-3.0, whose terms \
            extend to the combined binary — so while Macomprendo's own source is MIT, the \
            application you received is governed by GPL-3.0. The full corresponding source \
            is public: this app at github.com/DZamataev/macomprendo, and the framework at \
            github.com/k2-fsa/sherpa-onnx. Upstream is removing espeak-ng in sherpa-onnx \
            2.0.0 (issue #3731), after which this no longer applies.
            """
        ),
        LicenseEntry(
            component: "onnxruntime",
            spdx: "MIT",
            origin: "Statically linked inside SherpaOnnxC.framework",
            homepage: URL(string: "https://github.com/microsoft/onnxruntime")!,
            resourceName: "onnxruntime",
            isCopyleft: false,
            note: nil
        ),
        LicenseEntry(
            component: "Kaldi",
            spdx: "Apache-2.0",
            origin: "Statically linked inside SherpaOnnxC.framework",
            homepage: URL(string: "https://github.com/kaldi-asr/kaldi")!,
            resourceName: "kaldi",
            isCopyleft: false,
            note: nil
        ),
        LicenseEntry(
            component: "Abseil",
            spdx: "Apache-2.0",
            origin: "Statically linked inside SherpaOnnxC.framework",
            homepage: URL(string: "https://github.com/abseil/abseil-cpp")!,
            resourceName: "abseil",
            isCopyleft: false,
            note: nil
        ),
        LicenseEntry(
            component: "RE2",
            spdx: "BSD-3-Clause",
            origin: "Statically linked inside SherpaOnnxC.framework",
            homepage: URL(string: "https://github.com/google/re2")!,
            resourceName: "re2",
            isCopyleft: false,
            note: nil
        ),
        LicenseEntry(
            component: "Protocol Buffers",
            spdx: "BSD-3-Clause",
            origin: "Statically linked inside SherpaOnnxC.framework",
            homepage: URL(string: "https://github.com/protocolbuffers/protobuf")!,
            resourceName: "protobuf",
            isCopyleft: false,
            note: nil
        ),
        LicenseEntry(
            component: "OpenFst",
            spdx: "Apache-2.0",
            origin: "Statically linked inside SherpaOnnxC.framework",
            homepage: URL(string: "https://www.openfst.org")!,
            resourceName: "openfst",
            isCopyleft: false,
            note: nil
        ),
        LicenseEntry(
            component: "KeyboardShortcuts",
            spdx: "MIT",
            origin: "Swift package 2.4.0",
            homepage: URL(string: "https://github.com/sindresorhus/KeyboardShortcuts")!,
            resourceName: "keyboardshortcuts",
            isCopyleft: false,
            note: nil
        ),
        LicenseEntry(
            component: "Phosphor Icons",
            spdx: "MIT",
            origin: "Vendored SVGs in Resources/Icons",
            homepage: URL(string: "https://phosphoricons.com")!,
            resourceName: "phosphor-icons",
            isCopyleft: false,
            note: nil
        ),
    ]

    /// Entries whose licence terms reach the whole combined binary.
    static var copyleft: [LicenseEntry] { all.filter(\.isCopyleft) }
}
