import SwiftUI

/// What one model is good and bad at, and the published numbers behind that claim.
///
/// The benchmarks are third-party measurements quoted from the publisher, not this app's own,
/// which is why every table carries its source as a link rather than a footnote.
struct ModelBriefView: View {
    let brief: ModelBrief

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(brief.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !brief.strengths.isEmpty || !brief.limitations.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(brief.strengths, id: \.self) { line in
                        bullet(line, icon: .success, tint: .green)
                    }
                    ForEach(brief.limitations, id: \.self) { line in
                        bullet(line, icon: .warning, tint: .orange)
                    }
                }
            }

            if !brief.benchmarks.isEmpty {
                benchmarks
            }

            Link("Source", destination: brief.sourceURL)
                .font(.caption)
        }
    }

    private func bullet(_ text: String, icon: AppIcon, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Icon(icon, size: 11)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Published WER numbers. Wide on purpose, so it scrolls sideways rather than wrapping
    /// each cell into an unreadable column.
    private var benchmarks: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    Text("Language").gridColumnAlignment(.leading)
                    Text("Dataset")
                    Text("Metric")
                    Text("This model")
                    Text("Published elsewhere")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

                ForEach(Array(brief.benchmarks.enumerated()), id: \.offset) { _, benchmark in
                    GridRow {
                        Text(DictationTabModel.languagesText([benchmark.language]))
                        Text(benchmark.dataset)
                        Text(benchmark.metric)
                        Text(DictationTabModel.benchmarkValue(benchmark.value))
                            .monospacedDigit()
                        Text(DictationTabModel.comparisonText(benchmark.comparedTo))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
            .padding(.vertical, 2)
        }
    }
}
