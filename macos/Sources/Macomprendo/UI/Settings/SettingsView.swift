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
            ModelsTab()
                .tabItem { Label { Text("Models") } icon: { Icon(.download, size: 16) } }
            ProvidersTab()
                .tabItem { Label { Text("Providers") } icon: { Icon(.endpoint, size: 16) } }
        }
        .frame(width: 640, height: 480)
    }
}
