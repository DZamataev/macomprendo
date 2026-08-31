import Foundation
import Testing
@testable import Macomprendo

@Suite struct SherpaRuntimeTests {

    @Test func reportsTheLinkedSherpaVersion() {
        let version = SherpaRuntime.version()
        #expect(!version.isEmpty)
        #expect(version.hasPrefix("1.13"), "linked sherpa-onnx is \(version), expected the 1.13 series")
    }

    @Test func reportsTheStaticallyLinkedOnnxruntimeVersion() {
        // onnxruntime is linked into this xcframework variant rather than shipped beside it;
        // a non-empty answer here is what proves that.
        #expect(!SherpaRuntime.onnxruntimeVersion().isEmpty)
    }
}
