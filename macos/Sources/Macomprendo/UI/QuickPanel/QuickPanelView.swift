import SwiftUI

/// Root of the floating panel: picks the layout the controller is currently presenting.
struct QuickPanelView: View {
    @ObservedObject var panel: QuickPanelController
    @ObservedObject var refine: RefineController
    @ObservedObject var summarize: SummarizeController
    @ObservedObject var speak: SpeakController
    @ObservedObject var app: AppModel

    var body: some View {
        Group {
            switch panel.layout {
            case .refine:
                RefineLayout(controller: refine,
                            presets: app.settings.presets(of: .refine, language: app.settings.promptLanguage),
                            speak: speak)
            case .summary:
                SummaryLayout(controller: summarize,
                             presets: app.settings.presets(of: .summarize, language: app.settings.promptLanguage),
                             speak: speak)
            }
        }
        .frame(minWidth: 520, minHeight: 300)
        .background(.thinMaterial)
    }
}
