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
        for entry in LicenseRegistry.all {
            let text = try #require(entry.licenseText(),
                                    "\(entry.component): \(entry.resourceName).txt is missing from the bundle")
            #expect(text.count > 400, "\(entry.component): licence text looks truncated")
        }
    }

    @Test func theBundledTextMatchesTheDeclaredLicence() throws {
        // A file present but holding the wrong licence would be worse than a missing one, so
        // each text is checked for a phrase unique to the licence it claims to be.
        let marker: [String: String] = [
            "MIT": "Permission is hereby granted, free of charge",
            "Apache-2.0": "Apache License",
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
}
