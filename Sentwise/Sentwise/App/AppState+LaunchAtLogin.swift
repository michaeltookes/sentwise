import Foundation

extension AppState {
    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        let succeeded = setLaunchAtLoginHandler(enabled)
        launchAtLogin = launchAtLoginStatusProvider()
        return succeeded
    }
}
