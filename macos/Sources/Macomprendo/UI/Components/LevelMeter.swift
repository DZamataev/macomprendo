import SwiftUI

enum LevelMeterModel {
    /// How many bars of `count` are lit for a 0…1 level.
    static func litBars(level: Float, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let clamped = min(max(level, 0), 1)
        return Int((Float(count) * clamped).rounded())
    }
}

struct LevelMeter: View {
    let level: Float
    var barCount: Int = 14

    var body: some View {
        let lit = LevelMeterModel.litBars(level: level, count: barCount)
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(index < lit ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: height(for: index))
            }
        }
        .animation(.linear(duration: 0.08), value: lit)
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(min(max(level, 0), 1) * 100)) percent")
    }

    private func height(for index: Int) -> CGFloat {
        let middle = Double(barCount - 1) / 2
        let distance = abs(Double(index) - middle) / max(middle, 1)
        return 8 + (1 - distance) * 14
    }
}
