import Foundation

extension AppState {
    func retryManagedLocalMailPurgeAfterDeleted(
        _ purgeLocalData: Bool,
        generation: UInt64,
        messageSurface: TransientMessageSurface
    ) -> Bool {
        guard purgeLocalMailDataAfterManagedDeleteIfNeeded(
            purgeLocalData,
            generation: generation,
            messageSurface: messageSurface
        ) else { return false }
        saveSettings()
        return true
    }
}
