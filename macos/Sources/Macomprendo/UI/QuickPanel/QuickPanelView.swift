import SwiftUI

/// Root of the floating panel: picks the layout the controller is currently presenting.
struct QuickPanelView: View {
    @ObservedObject var panel: QuickPanelController
    @ObservedObject var refine: RefineController
    @ObservedObject var summarize: SummarizeController
    @ObservedObject var app: AppModel

    var body: some View {
        Group {
            switch panel.layout {
            case .refine:
                RefineLayout(controller: refine,
                            presets: app.settings.presets(of: .refine, language: app.settings.promptLanguage))
            case .summary:
                SummaryLayout(controller: summarize,
                             presets: app.settings.presets(of: .summarize, language: app.settings.promptLanguage))
            }
        }
        .frame(minWidth: 520, minHeight: 300)
        .background(.thinMaterial)
    }
}
