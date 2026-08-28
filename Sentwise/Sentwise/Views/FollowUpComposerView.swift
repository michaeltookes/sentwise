import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The entry point for the post-call follow-up workflow (item 51): the user
/// pastes a transcript or chooses/drops a transcript file, optionally sets
/// recipients and a subject, and drafts a follow-up. The draft is enqueued into
/// the existing review queue, where it flows through the same approve →
/// send/save path as inbox replies.
struct FollowUpComposerView: View {
    @EnvironmentObject var appState: AppState

    @State private var transcriptText = ""
    @State private var fileURL: URL?
    @State private var recipients = ""
    @State private var subject = ""
    @State private var isBusy = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            recipientsAndSubject
            transcriptSection
            footer
        }
        .padding(16)
        .frame(width: 560, height: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("New follow-up from a call")
                .font(.headline)
            Text("Paste or drop the call transcript. Sentwise drafts the follow-up in "
                 + "your voice and adds it to Review Drafts for approval.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var recipientsAndSubject: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recipients").font(.caption).foregroundStyle(.secondary)
                TextField("dana@example.com, marcus@example.com", text: $recipients)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Follow-up recipients")
                Text("Optional now — you can add or edit these in review before approving.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Subject").font(.caption).foregroundStyle(.secondary)
                TextField("Post-call follow-up", text: $subject)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Follow-up subject")
            }
        }
    }

    @ViewBuilder
    private var transcriptSection: some View {
        Text("Transcript").font(.caption).foregroundStyle(.secondary)
        if let fileURL {
            chosenFileRow(fileURL)
        } else {
            transcriptEditor
        }
    }

    private func chosenFileRow(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Clear") { fileURL = nil }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var transcriptEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $transcriptText)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 180)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                            lineWidth: isDropTargeted ? 2 : 1))
                .accessibilityLabel("Paste transcript text")
            HStack {
                Button("Choose File…") { chooseFile() }
                Text("or drag a .txt, .md, .vtt, or .srt file here")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if !appState.canCreateFollowUp {
            Label("Connect an email account and AI provider to draft follow-ups.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if let statusMessage {
            HStack {
                Label(statusMessage, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
                Spacer()
                Button("Open Review Drafts") { appState.openReviewHandler?() }
                    .accessibilityIdentifier("openReviewDraftsFromComposer")
            }
        }
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        }
        HStack {
            Spacer()
            if isBusy { ProgressView().controlSize(.small) }
            Button("Draft follow-up") {
                Task { await create() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isBusy || !appState.canCreateFollowUp || !hasSource)
        }
    }

    private var hasSource: Bool {
        fileURL != nil || !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    private func create() async {
        errorMessage = nil
        statusMessage = nil
        isBusy = true
        defer { isBusy = false }
        do {
            let ingested = try await makeIngested()
            let recipientEdit = AppState.parseRecipientEdit(recipients)
            guard !recipientEdit.hasInvalidEntries else {
                errorMessage = "Fix invalid recipient addresses before drafting this follow-up."
                return
            }
            let recipientList = recipientEdit.recipients
            let trimmedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await appState.createFollowUp(
                from: ingested,
                recipients: recipientList,
                subject: trimmedSubject.isEmpty ? nil : trimmedSubject
            )
            statusMessage = recipientList.isEmpty
                ? "Follow-up drafted. Open Review Drafts to add recipients and approve it."
                : "Follow-up drafted. Open Review Drafts to approve it."
            transcriptText = ""
            fileURL = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    private func makeIngested() async throws -> IngestedTranscript {
        if let fileURL {
            return try await TranscriptIngest.fromFileDetached(fileURL)
        }
        return try TranscriptIngest.fromPaste(transcriptText)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Transcript"
        let types = TranscriptFormat.supportedFileExtensions.compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty { panel.allowedContentTypes = types }
        if panel.runModal() == .OK, let url = panel.url {
            setFile(url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            Task { @MainActor in
                guard let url, TranscriptFormat.isSupportedFile(url) else {
                    errorMessage = "Drop a .txt, .md, .vtt, or .srt transcript file."
                    return
                }
                setFile(url)
            }
        }
        return true
    }

    private func setFile(_ url: URL) {
        fileURL = url
        errorMessage = nil
        statusMessage = nil
    }

    private static func message(for error: Error) -> String {
        switch error {
        case TranscriptIngestError.emptyTranscript:
            return "Add a transcript first — paste text or choose a file."
        case TranscriptIngestError.unsupportedFormat(let ext):
            return "That file type (.\(ext)) isn't supported. Use .txt, .md, .vtt, or .srt."
        case TranscriptIngestError.unreadableFile(let name):
            return "Couldn't read \(name)."
        default:
            return AppState.draftMessage(for: error)
        }
    }
}
