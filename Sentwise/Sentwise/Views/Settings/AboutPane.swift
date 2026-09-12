import AppKit
import SwiftUI

/// The branded About tab of Settings (item 65), mirroring ContainerBar's
/// `AboutPane`: the Sentwise owl icon, the app name and version/build read from
/// the bundle, the local-first privacy statement, links to the repo and
/// sentwise.ai, the Check for Updates action, and copyright.
///
/// The updater is observed directly because the Settings window keeps this pane
/// hosted while the window is open; Sparkle's availability can change while the
/// cached pane remains mounted.
struct AboutPane: View {
    @ObservedObject var updateManager: UpdateManager

    private var appIcon: NSImage {
        if let named = NSImage(named: "AppIcon") {
            return named
        }
        if let appIcon = NSImage(named: NSImage.applicationIconName) {
            return appIcon
        }
        return NSApp.applicationIconImage
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 10) {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 88, height: 88)
                        .accessibilityHidden(true)

                    Text("Sentwise")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("Version \(appVersion) (\(buildNumber))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Version \(appVersion), build \(buildNumber)")
                }

                Text(AppState.privacyStatement)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 380)

                Divider()
                    .frame(maxWidth: 200)

                VStack(spacing: 10) {
                    Link(destination: URL(string: "https://github.com/michaeltookes/sentwise")!) {
                        Label("GitHub Repository", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .accessibilityLabel("Open the Sentwise GitHub repository")

                    Link(destination: URL(string: "https://sentwise.ai")!) {
                        Label("sentwise.ai", systemImage: "globe")
                    }
                    .accessibilityLabel("Open sentwise.ai")
                }

                Divider()
                    .frame(maxWidth: 200)

                LegalSupportSection()

                Divider()
                    .frame(maxWidth: 200)

                VStack(spacing: 4) {
                    Button("Check for Updates…") {
                        updateManager.checkForUpdates()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(!updateManager.canCheckForUpdates)
                    .accessibilityLabel("Check for Sentwise updates")

                    if !updateManager.canCheckForUpdates,
                       let reason = updateManager.unavailableReason {
                        Text(reason)
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: 320)
                    }
                }

                Text("\(copyrightYear) Sentwise · Made with Swift and SwiftUI")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private var copyrightYear: String {
        String(Calendar.current.component(.year, from: Date()))
    }
}

/// The "Legal & Support" block of the About pane (item 72): outbound links to the
/// hosted Terms, Privacy, Security, and Support pages on sentwise.ai. Definitions
/// live in `LegalSupportLinks` so the destinations stay testable; this view is a
/// plain declarative render of `LegalSupportLinks.all`.
private struct LegalSupportSection: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("Legal & Support")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityAddTraits(.isHeader)

            ForEach(LegalSupportLinks.all) { item in
                Link(destination: item.url) {
                    Label(item.title, systemImage: item.systemImage)
                }
                .accessibilityIdentifier(item.id)
                .accessibilityLabel(item.accessibilityLabel)
            }
        }
    }
}
