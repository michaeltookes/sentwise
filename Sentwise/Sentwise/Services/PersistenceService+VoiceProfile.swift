import CryptoKit
import Foundation
import os

private let logger = Logger(subsystem: "com.tookes.Sentwise", category: "Persistence")

/// Per-account voice-profile persistence (item 99). Split out of
/// `PersistenceService` so that file stays within the file-length limit. Each
/// account's profile lives in its own `VoiceProfile-<sha256>.json`; the legacy
/// single `VoiceProfile.json` is addressed by the empty account key.
extension PersistenceService {

    /// The file backing the voice profile for `accountKey`. An empty key maps to
    /// the legacy single `VoiceProfile.json`; a non-empty key (normalized account
    /// email) maps to a per-account `VoiceProfile-<sha256>.json`. The email is
    /// hashed into the filename so no address ever lands in a filename.
    private func voiceProfileURL(forAccountKey accountKey: String) -> URL {
        let normalized = SavedMailAccount.normalizedEmail(accountKey)
        guard !normalized.isEmpty else { return voiceProfileURL }
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("VoiceProfile-\(hex).json")
    }

    func loadVoiceProfile(accountKey: String) -> VoiceProfile? {
        let url = voiceProfileURL(forAccountKey: accountKey)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(VoiceProfile.self, from: data)
        } catch {
            logger.error("Failed to load voice profile: \(error.localizedDescription)")
            return nil
        }
    }

    func saveVoiceProfile(_ profile: VoiceProfile, accountKey: String) {
        let url = voiceProfileURL(forAccountKey: accountKey)
        ioQueue.async { [encoder] in
            do {
                let data = try encoder.encode(profile)
                try data.write(to: url, options: .atomic)
            } catch {
                logger.error("Failed to save voice profile: \(error.localizedDescription)")
            }
        }
    }

    func removeVoiceProfile(accountKey: String) throws {
        try removeFile(at: voiceProfileURL(forAccountKey: accountKey))
    }

    func removeAllVoiceProfiles() throws {
        try ioQueue.sync { [directory, voiceProfileURL] in
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: voiceProfileURL.path) {
                try fileManager.removeItem(at: voiceProfileURL)
            }
            let contents = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )) ?? []
            for url in contents where url.lastPathComponent.hasPrefix("VoiceProfile-")
                && url.pathExtension == "json" {
                try fileManager.removeItem(at: url)
            }
        }
    }
}
