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
            ModelsTab()
                .tabItem { Label { Text("Models") } icon: { Icon(.download, size: 16) } }
            ProvidersTab()
                .tabItem { Label { Text("Providers") } icon: { Icon(.endpoint, size: 16) } }
        }
        .frame(width: 640, height: 480)
    }
}
