import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label { Text("General") } icon: { Icon(.settings, size: 16) } }
            HotkeysTab()
                .tabItem { Label { Text("Hotkeys") } icon: { Icon(.hotkeys, size: 16) } }
            DictationTab()
                .tabItem { Label { Text("Dictation") } icon: { Icon(.microphone, size: 16) } }
            SpeechTab(model: AppRoot.model.speechTabModel, app: AppRoot.model)
                .tabItem { Label { Text("Speech") } icon: { Icon(.speak, size: 16) } }
            PromptsTab(model: AppRoot.model.promptsTabModel, app: AppRoot.model)
                .tabItem { Label { Text("Refine & Summarize") } icon: { Icon(.presets, size: 16) } }
            ProvidersTab()
                .tabItem { Label { Text("Providers") } icon: { Icon(.endpoint, size: 16) } }
        }
        // A floor rather than a fixed size, and wide enough for the densest tabs: Refine &
        // Summarize carries three pickers over a list and an editor, and Providers is a split
        // view whose two panes each need room. At 640 both were clipped. Resizable from here up.
        .frame(minWidth: 760, idealWidth: 760, minHeight: 560, idealHeight: 560)
    }
}
