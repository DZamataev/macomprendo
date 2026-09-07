import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  rewriteModelFileLiteral, downloadURLOf, resolveConstants, extractFileRecords,
} from '../lib/model-hashes.mjs'

const line = '                ModelFile(role: .tokens, fileName: "x-tokens.txt", sizeBytes: 4000, sha256: "", downloadURL: URL(string: "https://example.com/tokens.txt")!)'

test('rewrites sizeBytes and sha256 in place', () => {
  const out = rewriteModelFileLiteral(line, { sizeBytes: 4137, sha256: 'ab12' })
  assert.match(out, /sizeBytes: 4137/)
  assert.match(out, /sha256: "ab12"/)
  assert.match(out, /fileName: "x-tokens\.txt"/)
  assert.match(out, /role: \.tokens/)
})

test('reads the download URL out of a literal', () => {
  assert.equal(downloadURLOf(line), 'https://example.com/tokens.txt')
})

test('archive roles use the same source-aware parsing and rewriting path', () => {
  const archive = 'ModelFile(role: .archive, fileName: "voice.tar.bz2", sizeBytes: 12, sha256: "old", downloadURL: URL(string: "https://example.com/voice.tar.bz2")!)'
  assert.equal(downloadURLOf(archive), 'https://example.com/voice.tar.bz2')
  assert.match(rewriteModelFileLiteral(archive, { sizeBytes: 34, sha256: 'new' }),
    /role: \.archive.*sizeBytes: 34, sha256: "new"/)
})

test('leaves a line that is not a ModelFile literal untouched', () => {
  const other = '    static let defaultID = "large-v3-turbo"'
  assert.equal(rewriteModelFileLiteral(other, { sizeBytes: 1, sha256: 'z' }), other)
  assert.equal(downloadURLOf(other), null)
})

test('ignores an interpolated URL it cannot resolve statically', () => {
  const interpolated = '                ModelFile(role: .tokens, fileName: "y.txt", sizeBytes: 1, sha256: "", downloadURL: URL(string: "\\(base)/tokens.txt")!)'
  assert.equal(downloadURLOf(interpolated), null)
})

// A small multi-model fixture, shaped like the real catalog: one GigaAM-style entry
// whose downloadURL interpolates a private static let base, one entry with a plain
// literal downloadURL, and the whisper `whisperModel(...)` helper shape, whose single
// ModelFile literal interpolates a function parameter (`\(id)`) rather than a
// resolvable constant — that's the one real case in the catalog most likely to be
// restructured later, so it gets its own coverage here rather than being assumed safe.
const FIXTURE = `enum ModelCatalog {
    private static let v3CTCBase = "https://huggingface.co/example/v3-ctc/resolve/main"
    private static let whisperSource = URL(string: "https://github.com/openai/whisper")!

    private static let gigaAM: [LocalModel] = [
        LocalModel(
            id: "gigaam-v3-e2e-ctc",
            files: [
                ModelFile(role: .ctcModel, fileName: "gigaam-v3-e2e-ctc-model.onnx", sizeBytes: 224900000, sha256: "", downloadURL: URL(string: "\\(v3CTCBase)/model.int8.onnx")!),
                ModelFile(role: .tokens, fileName: "gigaam-v3-e2e-ctc-tokens.txt", sizeBytes: 4000, sha256: "", downloadURL: URL(string: "\\(v3CTCBase)/tokens.txt")!)
            ]
        ),
        LocalModel(
            id: "literal-example",
            files: [
                ModelFile(role: .tokens, fileName: "literal-example-tokens.txt", sizeBytes: 500, sha256: "", downloadURL: URL(string: "https://example.com/fixed/tokens.txt")!)
            ]
        )
    ]

    private static func whisperModel(_ id: String, _ sizeBytes: Int64) -> LocalModel {
        LocalModel(
            id: id,
            files: [
                ModelFile(role: .ggml, fileName: "ggml-\\(id).bin", sizeBytes: sizeBytes, sha256: "", downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\\(id).bin")!)
            ]
        )
    }
}
`

test('resolveConstants collects private static let string constants into a name to value map', () => {
  const source = 'private static let v3CTCBase = "https://example.com/v3-ctc/resolve/main"\n'
    + 'private static let multilingualBase = "https://example.com/multilingual"\n'
  assert.deepEqual(resolveConstants(source), {
    v3CTCBase: 'https://example.com/v3-ctc/resolve/main',
    multilingualBase: 'https://example.com/multilingual',
  })
})

test('resolveConstants ignores a constant that is not a plain string literal', () => {
  const source = 'private static let whisperSource = URL(string: "https://github.com/openai/whisper")!\n'
  assert.deepEqual(resolveConstants(source), {})
})

test('resolveConstants returns an empty map when the source has no string constants', () => {
  assert.deepEqual(resolveConstants('static let all: [LocalModel] = whisper + gigaAM\n'), {})
})

test('extractFileRecords resolves an interpolated base into a full downloadURL', () => {
  const records = extractFileRecords(FIXTURE)
  assert.deepEqual(records.find((r) => r.fileName === 'gigaam-v3-e2e-ctc-model.onnx'), {
    fileName: 'gigaam-v3-e2e-ctc-model.onnx',
    downloadURL: 'https://huggingface.co/example/v3-ctc/resolve/main/model.int8.onnx',
  })
  assert.deepEqual(records.find((r) => r.fileName === 'gigaam-v3-e2e-ctc-tokens.txt'), {
    fileName: 'gigaam-v3-e2e-ctc-tokens.txt',
    downloadURL: 'https://huggingface.co/example/v3-ctc/resolve/main/tokens.txt',
  })
})

test('extractFileRecords leaves a literal (non-interpolated) downloadURL as-is', () => {
  const records = extractFileRecords(FIXTURE)
  assert.deepEqual(records.find((r) => r.fileName === 'literal-example-tokens.txt'), {
    fileName: 'literal-example-tokens.txt',
    downloadURL: 'https://example.com/fixed/tokens.txt',
  })
})

test('extractFileRecords skips rather than mis-records the whisper-template literal whose URL interpolates a function parameter', () => {
  const records = extractFileRecords(FIXTURE)
  assert.equal(records.some((r) => r.fileName.startsWith('ggml-')), false)
  // Not merely absent by accident: no record anywhere carries an unresolved "\(...)".
  assert.equal(records.every((r) => !r.downloadURL.includes('\\(')), true)
})

test('extractFileRecords returns exactly the resolvable records, in source order', () => {
  const records = extractFileRecords(FIXTURE)
  assert.deepEqual(records.map((r) => r.fileName), [
    'gigaam-v3-e2e-ctc-model.onnx',
    'gigaam-v3-e2e-ctc-tokens.txt',
    'literal-example-tokens.txt',
  ])
})
