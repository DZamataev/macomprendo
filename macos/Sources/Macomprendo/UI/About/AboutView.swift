import SwiftUI

/// The About window: what the app is, what it ships under, and the full text of every
/// third-party licence it redistributes.
///
/// All state and link handling live in `AboutModel`; this file only lays them out.
struct AboutView: View {
    @ObservedObject var model: AboutModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                componentList
                Divider()
                licensePane
            }
        }
        .onAppear { model.selectDefaultIfNeeded() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.appName)
                    .font(.title2.weight(.semibold))
                Text(model.versionText)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            // The copyleft disclosure sits at the top rather than under the licence list:
            // it is the one thing a reader must not have to scroll to find.
            Text(model.copyleftDisclosure)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))

            Button("Privacy statement") { model.openPrivacyStatement() }
                .buttonStyle(.link)
        }
        .padding(16)
    }

    // MARK: - Components

    /// Selection is keyed by `component`, which is unique in the registry, so `LicenseEntry`
    /// does not have to gain a `Hashable`/`Identifiable` conformance for a view's sake.
    private var selectedComponent: Binding<String?> {
        Binding(
            get: { model.selected?.component },
            set: { name in
                guard let entry = model.entries.first(where: { $0.component == name }) else { return }
                model.select(entry)
            })
    }

    private var componentList: some View {
        List(selection: selectedComponent) {
            ForEach(model.entries, id: \.component) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.component)
                    Text(entry.spdx)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(entry.component)
            }
        }
        .frame(width: 220)
    }

    // MARK: - Licence text

    @ViewBuilder
    private var licensePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let entry = model.selected {
                Text(entry.component)
                    .font(.headline)
                Text(entry.origin)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(entry.homepage.absoluteString) { model.openHomepage(of: entry) }
                    .buttonStyle(.link)
            }

            if let message = model.errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            } else if let text = model.licenseText {
                // A licence is legally exact: it is shown whole, selectable, wrapped but
                // never truncated, and in a monospaced face so its own layout survives.
                ScrollView {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 8)
                }
            } else {
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
