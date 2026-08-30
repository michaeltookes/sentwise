import AppKit
import SwiftUI

/// Connect-screen guidance for Google Workspace / Gmail policy failures (item 75):
/// when an admin has disabled app passwords or IMAP, or Google demands a web
/// login, the generic "Sign-in failed" error reads as a Sentwise bug. This block
/// explains what actually happened, that it's an account/admin policy, and the
/// concrete options — plus a one-tap "copy a message for your admin" and a "notify
/// me when Sign in with Google is available" demand capture. Shared by onboarding
/// and Settings so the copy lives in one place. Renders nothing when the last
/// failure wasn't a recognized policy failure.
struct WorkspaceAuthGuidanceView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let guidance = appState.workspaceAuthGuidance {
            content(guidance)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.yellow.opacity(0.12))
                )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("workspaceGuidance")
        }
    }

    @ViewBuilder
    private func content(_ guidance: WorkspaceAuthGuidance) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(guidance.headline, systemImage: "building.2.crop.circle")
                .font(.callout).bold()
                .foregroundStyle(.primary)

            Text(guidance.explanation)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(guidance.options.enumerated()), id: \.offset) { _, option in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(option).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if let url = guidance.supportURL {
                Link("Google support article", destination: url)
                    .font(.caption)
            }

            if guidance.showsAskAdmin {
                askAdminSection
            }

            interestSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Ask your admin

    private var askAdminSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(WorkspaceAuthGuidance.askAdminMessage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))

            Button {
                copyAskAdminMessage()
            } label: {
                Label("Copy message for your admin", systemImage: "doc.on.doc")
                    .font(.caption)
            }
            .accessibilityIdentifier("askAdminCopy")
        }
        .padding(.top, 2)
    }

    private func copyAskAdminMessage() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(WorkspaceAuthGuidance.askAdminMessage, forType: .string)
    }

    // MARK: - "Notify me when Sign in with Google is available"

    @ViewBuilder
    private var interestSection: some View {
        if appState.googleOAuthInterestRegistered {
            Label("You're on the list — we'll let you know when Sign in with Google is available.",
                  systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .accessibilityIdentifier("oauthInterestConfirmation")
        } else if appState.canOfferGoogleOAuthInterest {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    Task { await appState.registerGoogleOAuthInterest() }
                } label: {
                    if appState.isRegisteringGoogleOAuthInterest {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Notify me when Sign in with Google is available", systemImage: "bell")
                            .font(.caption)
                    }
                }
                .disabled(appState.isRegisteringGoogleOAuthInterest)
                .accessibilityIdentifier("oauthInterestButton")

                if let error = appState.googleOAuthInterestError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            .padding(.top, 2)
        }
    }
}
