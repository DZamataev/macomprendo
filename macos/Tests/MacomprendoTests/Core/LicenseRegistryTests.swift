import Foundation
import Testing
@testable import Macomprendo

@Suite struct LicenseRegistryTests {

    @Test func listsEveryComponentTheAppRedistributes() {
        let names = Set(LicenseRegistry.all.map(\.component))
        // Everything compiled into a binary the user receives, whether it arrives as its own
        // framework or is statically linked inside one. Omitting a statically linked component
        // is the failure this guards: onnxruntime and espeak-ng do not appear in `otool -L`
        // yet are unmistakably present in SherpaOnnxC.
        #expect(names == [
            "whisper.cpp",
            "sherpa-onnx",
            "espeak-ng",
            "onnxruntime",
            "Kaldi",
            "Abseil",
            "RE2",
            "Protocol Buffers",
            "OpenFst",
            "KeyboardShortcuts",
            "Phosphor Icons",
        ])
    }

    @Test func recordsTheCopyleftComponentAsSuch() throws {
        let espeak = try #require(LicenseRegistry.all.first { $0.component == "espeak-ng" })
        #expect(espeak.spdx == "GPL-3.0-only")
        #expect(espeak.isCopyleft)
        // The one entry whose terms reach the whole combined binary must say so where a
        // reader will see it, not only in a licence file they have to open.
        #expect(espeak.note?.isEmpty == false)
        #expect(LicenseRegistry.all.filter(\.isCopyleft).count == 1)
    }

    @Test func everyEntryDeclaresHowItReachesTheUser() {
        for entry in LicenseRegistry.all {
            #expect(!entry.component.isEmpty)
            #expect(!entry.spdx.isEmpty)
            #expect(!entry.origin.isEmpty)
            #expect(entry.homepage.scheme == "https")
        }
    }

    @Test func everyEntryHasItsLicenceTextBundled() throws {
        // The floor is per-SPDX rather than one flat number: the full Apache-2.0 and
        // GPL-3.0 bodies run to five figures of bytes, so a flat 400-byte floor would pass
        // a file holding only the short "how to apply this licence" boilerplate instead of
        // the licence itself (which is exactly what shipped for OpenFst).
        let minimumLength: [String: Int] = [
            "MIT": 400,
            "Apache-2.0": 10_000,
            "GPL-3.0-only": 10_000,
            "BSD-3-Clause": 1_000,
        ]
        for entry in LicenseRegistry.all {
            let text = try #require(entry.licenseText(),
                                    "\(entry.component): \(entry.resourceName).txt is missing from the bundle")
            let floor = try #require(minimumLength[entry.spdx], "no length floor for \(entry.spdx)")
            #expect(text.count > floor,
                    "\(entry.component): licence text looks truncated (\(text.count) bytes, \(entry.spdx) needs > \(floor))")
        }
    }

    @Test func theBundledTextMatchesTheDeclaredLicence() throws {
        // A file present but holding the wrong licence would be worse than a missing one, so
        // each text is checked for a phrase from the operative body of the licence it claims
        // to be — not merely a phrase that also appears in the short "how to apply this
        // licence to your work" boilerplate, which is not the licence itself.
        let marker: [String: String] = [
            "MIT": "Permission is hereby granted, free of charge",
            "Apache-2.0": "4. Redistribution.",
            "GPL-3.0-only": "GNU GENERAL PUBLIC LICENSE",
            "BSD-3-Clause": "Redistribution and use in source and binary forms",
        ]
        for entry in LicenseRegistry.all {
            let text = try #require(entry.licenseText())
            let expected = try #require(marker[entry.spdx], "no marker for \(entry.spdx)")
            #expect(text.contains(expected),
                    "\(entry.component) claims \(entry.spdx) but its text does not read like it")
        }
    }

    /// `try?` alone collapses "no such resource" and "resource present but unreadable" into
    /// the same `nil`, which then reports an unreadable file as "missing from this build" —
    /// the wrong recovery text for a reader whose disk has a permissions problem.
    @Test func readLicenseTextDistinguishesMissingFromUnreadable() throws {
        let entry = try #require(LicenseRegistry.all.first)
        let emptyRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LicenseRegistryTests-empty-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        let emptyBundle = try #require(Bundle(url: emptyRoot))

        #expect(throws: MacomprendoError.licenseTextMissing(entry.component)) {
            try entry.readLicenseText(in: emptyBundle)
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LicenseRegistryTests-unreadable-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let licensesDir = root.appendingPathComponent("Licenses", isDirectory: true)
        try FileManager.default.createDirectory(at: licensesDir, withIntermediateDirectories: true)
        // A directory where a .txt file is expected: `Bundle.url` still resolves it (it
        // matches the name and extension) but reading its contents as a file fails.
        let fakeFile = licensesDir.appendingPathComponent("\(entry.resourceName).txt",
                                                          isDirectory: true)
        try FileManager.default.createDirectory(at: fakeFile, withIntermediateDirectories: true)
        let bundle = try #require(Bundle(url: root))

        #expect(throws: MacomprendoError.licenseTextUnreadable(entry.component)) {
            try entry.readLicenseText(in: bundle)
        }
    }
}
