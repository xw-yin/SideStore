//
//  AppShortcuts.swift
//  AltStore
//
//  Created by Riley Testut on 8/23/22.
//  Copyright © 2022 Riley Testut. All rights reserved.
//

import AppIntents

@available(iOS 17, tvOS 17, *)
public struct ShortcutsProvider: AppShortcutsProvider
{
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RefreshAllAppsIntent(),
                    phrases: [
                        "Refresh \(.applicationName)",
                        "Refresh \(.applicationName) apps",
                        "Refresh my \(.applicationName) apps",
                        "Refresh apps with \(.applicationName)",
                        "刷新 \(.applicationName)",
                        "刷新 \(.applicationName) 应用",
                        "刷新我的 \(.applicationName) 应用",
                        "使用 \(.applicationName) 刷新应用",
                    ],
                    shortTitle: "Refresh All Apps",
                    systemImageName: "arrow.triangle.2.circlepath")

        AppShortcut(intent: InstallIPAIntent(),
                    phrases: [
                        "Install IPA with \(.applicationName)",
                        "Install an IPA with \(.applicationName)",
                        "使用 \(.applicationName) 安装 IPA",
                        "用 \(.applicationName) 安装应用",
                    ],
                    shortTitle: "Install IPA",
                    systemImageName: "square.and.arrow.down")
    }
    
    public static var shortcutTileColor: ShortcutTileColor {
        return .teal
    }
}
