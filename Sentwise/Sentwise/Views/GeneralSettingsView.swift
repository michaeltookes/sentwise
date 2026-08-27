import AppKit
import SwiftUI

/// The "General" tab of Settings: app-wide preferences that aren't tied to a
/// specific account or AI provider (item 48 split the single scrolling form into
/// dedicated tabs).
struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { appState.launchAtLogin },
                    set: { appState.setLaunchAtLogin($0) }
                ))
                .accessibilityLabel("Launch Sentwise at login")

                Stepper(
                    "Inbox poll interval: \(appState.pollIntervalSeconds)s",
                    value: $appState.pollIntervalSeconds,
                    in: 30...3600,
                    step: 30
                )
                .accessibilityLabel("Inbox poll interval in seconds")

                Picker("On approve", selection: $appState.sendBehavior) {
                    Text("Save as draft").tag(SendBehavior.saveAsDraft)
                    Text("Send immediately").tag(SendBehavior.autoSend)
                }
                .accessibilityLabel("What approving a draft does")
                Text(appState.sendBehavior == .autoSend
                     ? "Approving a draft sends it right away over SMTP."
                     : "Approving a draft saves it to your Gmail Drafts to send yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.sendBehavior == .autoSend {
                    Picker("Undo window", selection: $appState.sendDelaySeconds) {
                        Text("Off (send instantly)").tag(0)
                        Text("5 seconds").tag(5)
                        Text("10 seconds").tag(10)
                        Text("30 seconds").tag(30)
                        Text("60 seconds").tag(60)
                    }
                    .accessibilityLabel("Auto-send undo window")
                    Text(appState.sendDelaySeconds > 0
                         ? "After you approve, Sentwise waits "
                           + "\(appState.sendDelaySeconds)s so you can cancel before it sends."
                         : "Approved drafts send immediately with no cancel window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SignatureSettingsView()

            Section("Post-call follow-ups") {
                Toggle("Watch a folder for new transcripts", isOn: Binding(
                    get: { appState.transcriptWatchedFolderEnabled },
                    set: { appState.setTranscriptWatchedFolderEnabled($0) }
                ))
                .accessibilityLabel("Watch a folder for new call transcripts")

                if appState.transcriptWatchedFolderEnabled {
                    HStack {
                        Text(appState.transcriptWatchedFolderPath.isEmpty
                             ? "No folder chosen"
                             : appState.transcriptWatchedFolderPath)
                            .font(.caption)
                            .foregroundStyle(appState.transcriptWatchedFolderPath.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { chooseWatchedFolder() }
                    }
                    Text("A new .txt, .vtt, .srt, or .md file here is drafted into a follow-up "
                         + "automatically. Add recipients in review before sending.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = appState.transcriptFolderError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Diagnostics") {
                Toggle("Verbose diagnostic logging", isOn: $appState.verboseDiagnosticLogging)
                    .accessibilityLabel("Verbose diagnostic logging")
                    .accessibilityIdentifier("verboseDiagnosticLoggingToggle")
                Text(appState.verboseDiagnosticLogging
                     ? "Sentwise records extra non-personal detail. Turn this on before "
                       + "reproducing a bug, then use Report a Problem from the menu."
                     : "Off by default. Report a Problem (in the menu bar menu) packages a "
                       + "redacted log — no email content — to send to the maintainer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text(AppState.privacyStatement)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseWatchedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch Folder"
        if !appState.transcriptWatchedFolderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: appState.transcriptWatchedFolderPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            appState.setTranscriptWatchedFolderPath(url.path)
        }
    }
}
