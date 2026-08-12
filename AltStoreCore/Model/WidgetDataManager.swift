//
//  WidgetDataManager.swift
//  AltStoreCore
//
//  Created by Magesh K on 8/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

@preconcurrency import UIKit
import WidgetKit
import CoreData
@preconcurrency import AltSign

public struct WidgetAppItem: Codable, Sendable {
    public var name: String
    public var bundleIdentifier: String
    public var expirationDate: Date
    public var refreshedDate: Date
    public var tintColorHex: String?

    public init(name: String, bundleIdentifier: String, expirationDate: Date, refreshedDate: Date, tintColorHex: String?) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.expirationDate = expirationDate
        self.refreshedDate = refreshedDate
        self.tintColorHex = tintColorHex
    }
}

public struct WidgetDataSnapshot: Codable, Sendable {
    public var activeApps: [WidgetAppItem]
    public var allApps: [WidgetAppItem]
    public var lastUpdated: Date

    public init(activeApps: [WidgetAppItem] = [], allApps: [WidgetAppItem] = [], lastUpdated: Date = Date()) {
        self.activeApps = activeApps
        self.allApps = allApps
        self.lastUpdated = lastUpdated
    }
}

public final class WidgetDataManager: @unchecked Sendable {
    public static let shared = WidgetDataManager()

    private let fileName = "widget_data.json"
    private let iconFolderName = "WidgetIcons"

    private init() {}

    private var containerURL: URL? {
        FileManager.default.altstoreSharedDirectory
    }

    private var jsonFileURL: URL? {
        containerURL?.appendingPathComponent(fileName)
    }

    private var iconDirectoryURL: URL? {
        containerURL?.appendingPathComponent(iconFolderName, isDirectory: true)
    }

    public func fetchSnapshot() -> WidgetDataSnapshot {
        guard let url = jsonFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(WidgetDataSnapshot.self, from: data) else {
            return WidgetDataSnapshot()
        }
        return snapshot
    }

    public func loadCachedIcon(for bundleIdentifier: String) -> UIImage? {
        guard let iconDir = iconDirectoryURL else { return nil }
        let fileURL = iconDir.appendingPathComponent("\(bundleIdentifier).png")
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let image = UIImage(contentsOfFile: fileURL.path) else {
            return nil
        }
        return image
    }

    public func publishWidgetData(activeItems: [WidgetAppItem], allItems: [WidgetAppItem], icons: [String: UIImage] = [:]) {
        let snapshot = WidgetDataSnapshot(activeApps: activeItems, allApps: allItems, lastUpdated: Date())
        writeSnapshot(snapshot)
        for (bundleID, iconImage) in icons {
            cacheIcon(iconImage, for: bundleID)
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    public func cacheIcon(_ iconImage: UIImage, for bundleIdentifier: String) {
        guard let iconDir = iconDirectoryURL else { return }
        if !FileManager.default.fileExists(atPath: iconDir.path) {
            try? FileManager.default.createDirectory(at: iconDir, withIntermediateDirectories: true)
        }
        let fileURL = iconDir.appendingPathComponent("\(bundleIdentifier).png")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            if let resized = iconImage.resizing(toFill: CGSize(width: 180, height: 180)),
               let pngData = resized.pngData() {
                try? pngData.write(to: fileURL, options: .atomic)
            }
        }
    }

    private func writeSnapshot(_ snapshot: WidgetDataSnapshot) {
        guard let url = jsonFileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            debugLog("[WidgetDataManager] Failed to write snapshot JSON: \(error)")
        }
    }
}

extension WidgetDataManager {
    public static func publishCurrentInstalledApps(in context: NSManagedObjectContext) async {
        await context.performAsync {
            let activeFetch = InstalledApp.activeAppsFetchRequest()
            activeFetch.returnsObjectsAsFaults = false
            let activeApps = (try? context.fetch(activeFetch)) ?? []

            let allFetch = InstalledApp.fetchRequest()
            allFetch.returnsObjectsAsFaults = false
            let allApps = (try? context.fetch(allFetch)) ?? []

            let sortedActiveApps = activeApps.sorted { $0.name < $1.name }
            let sortedAllApps = allApps.sorted { $0.name < $1.name }

            var icons: [String: UIImage] = [:]
            for app in sortedAllApps {
                if let application = ALTApplication(fileURL: app.fileURL),
                   let icon = application.icon {
                    icons[app.bundleIdentifier] = icon
                }
            }

            let activeItems = sortedActiveApps.map { app in
                WidgetAppItem(
                    name: app.name,
                    bundleIdentifier: app.bundleIdentifier,
                    expirationDate: app.expirationDate,
                    refreshedDate: app.refreshedDate,
                    tintColorHex: app.storeApp?.tintColor?.hexString
                )
            }

            let allItems = sortedAllApps.map { app in
                WidgetAppItem(
                    name: app.name,
                    bundleIdentifier: app.bundleIdentifier,
                    expirationDate: app.expirationDate,
                    refreshedDate: app.refreshedDate,
                    tintColorHex: app.storeApp?.tintColor?.hexString
                )
            }

            WidgetDataManager.shared.publishWidgetData(activeItems: activeItems, allItems: allItems, icons: icons)
        }
    }
}
