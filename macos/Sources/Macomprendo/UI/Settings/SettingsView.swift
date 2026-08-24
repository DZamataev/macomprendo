import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label { Text("General") } icon: { Icon(.settings, size: 16) } }
            HotkeysTab()
                .tabItem { Label { Text("Hotkeys") } icon: { Icon(.hotkeys, size: 16) } }
        }
        .frame(width: 640, height: 480)
    }
}
