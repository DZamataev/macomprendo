import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem {
                    Label { Text("General") } icon: { Icon(.settings) }
                }
        }
        .frame(width: 520, height: 320)
    }
}
