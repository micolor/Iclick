//
//  LaunchAtLogin.swift
//  IClick
//  from https://github.com/sindresorhus/LaunchAtLogin-Modern
//  Created by 李旭 on 2024/12/19.
//

import Foundation

import SwiftUI
import ServiceManagement
import os.log

public enum LaunchAtLogin {
    private static let logger = Logger(subsystem:  Bundle.main.bundleIdentifier ?? "LaunchAtLogin", category: "main")
    nonisolated(unsafe) fileprivate static let observable = Observable()

    /**
    Toggle “launch at login” for your app or check whether it's enabled.
    */
    public static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set { setEnabled(newValue) }
    }

    /// 「已登记为登录项」，包含 `.requiresApproval`（已在系统里登记、等待用户在
    /// 系统设置中批准）。设置页的开关用它，否则待批准状态会显示成「关」，
    /// 用户再去开一次只会得到一个看似无效的开关。
    public static var isRegistered: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    /// - Parameter openApprovalSettings: 需要用户批准时是否打开系统设置的登录项页面。
    ///   只有设置页的手动开关传 true；启动时自动重指登录项不传，避免每次启动都弹系统设置。
    public static func setEnabled(_ enabled: Bool, openApprovalSettings: Bool = false) {
        observable.objectWillChange.send()

        let wasEnabled = SMAppService.mainApp.status == .enabled
        do {
            if enabled {
                let status = SMAppService.mainApp.status
                // 已经在等批准：再 register 只会报错，直接把用户带到批准页面
                if status == .requiresApproval {
                    if openApprovalSettings {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                    return
                }
                if status == .enabled {
                    try? SMAppService.mainApp.unregister()
                }

                try SMAppService.mainApp.register()

                // 新注册在 macOS 上可能进入「等待批准」，顺手把用户带过去
                if openApprovalSettings, SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("Failed to \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)")
            // 开启失败时尽力恢复原来的登录项：上面为了重指路径先 unregister 了，
            // 不回滚的话用户会「点了开启，结果反而被关掉」。
            if enabled, wasEnabled {
                try? SMAppService.mainApp.register()
            }
        }
    }

    /**
    Whether the app was launched at login.

    - Important: This property must only be checked in `NSApplicationDelegate#applicationDidFinishLaunching`.
    */
    public static var wasLaunchedAtLogin: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

extension LaunchAtLogin {
    final class Observable: ObservableObject {
        var isEnabled: Bool {
            // 设置页开关反映「已登记（含待批准）」；内部逻辑仍用 LaunchAtLogin.isEnabled
            get { LaunchAtLogin.isRegistered }
            set {
                LaunchAtLogin.setEnabled(newValue, openApprovalSettings: true)
            }
        }
    }
}

extension LaunchAtLogin {
    /**
    This package comes with a `LaunchAtLogin.Toggle` view which is like the built-in `Toggle` but with a predefined binding and label. Clicking the view toggles “launch at login” for your app.

    ```
    struct ContentView: View {
        var body: some View {
            LaunchAtLogin.Toggle()
        }
    }
    ```

    The default label is `"Launch at login"`, but it can be overridden for localization and other needs:

    ```
    struct ContentView: View {
        var body: some View {
            LaunchAtLogin.Toggle {
                Text("Launch at login")
            }
        }
    }
    ```
    */
    public struct Toggle<Label: View>: View {
        @ObservedObject private var launchAtLogin = LaunchAtLogin.observable
        private let label: Label

        /**
        Creates a toggle that displays a custom label.

        - Parameters:
            - label: A view that describes the purpose of the toggle.
        */
        public init(@ViewBuilder label: () -> Label) {
            self.label = label()
        }

        public var body: some View {
            SwiftUI.Toggle(isOn: $launchAtLogin.isEnabled) { label }
        }
    }
}

extension LaunchAtLogin.Toggle<Text> {
    /**
    Creates a toggle that generates its label from a localized string key.

    This initializer creates a ``Text`` view on your behalf with the provided `titleKey`.

    - Parameters:
        - titleKey: The key for the toggle's localized title, that describes the purpose of the toggle.
    */
    public init(_ titleKey: LocalizedStringKey) {
        label = Text(titleKey)
    }

    /**
    Creates a toggle that generates its label from a string.

    This initializer creates a `Text` view on your behalf with the provided `title`.

    - Parameters:
        - title: A string that describes the purpose of the toggle.
    */
    public init(_ title: some StringProtocol) {
        label = Text(title)
    }

    /**
    Creates a toggle with the default title of `Launch at login`.
    */
    public init() {
        self.init("Launch at login")
    }
}

