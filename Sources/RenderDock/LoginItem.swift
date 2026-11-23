import Foundation
import ServiceManagement
import RenderDockCore

/// Launch at login, using the system's login items (visible and switchable in System Settings → General → Login Items & Extensions); no LaunchAgent is written.
enum LoginItem {
    /// Only the copy installed in Applications may register: what gets registered is the app's path, and a build product in a working tree can disappear at any time.
    static var installed: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: return L("已开启", "Enabled")
        case .notRegistered: return L("未开启", "Disabled")
        case .requiresApproval: return L("等待在「系统设置 → 通用 → 登录项与扩展」里允许", "Waiting for approval in System Settings → General → Login Items & Extensions")
        case .notFound: return L("系统找不到这个应用", "The system can't find this app")
        @unknown default: return L("未知", "Unknown")
        }
    }

    static func set(_ on: Bool) throws {
        if on {
            guard installed else {
                throw NSError(domain: "RenderDock", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: L("先把渲染坞装到「应用程序」（zsh scripts/install.sh），再开登录时启动。现在这份在 \(Bundle.main.bundlePath)", "Install RenderDock to Applications first (zsh scripts/install.sh), then turn on Launch at Login. This copy is at \(Bundle.main.bundlePath)")])
            }
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else if SMAppService.mainApp.status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
    }
}
