//
//  SideStoreClient.swift
//  AltStore
//
//  Created by s s on 2025/7/20.
//  Copyright © 2025 SideStore. All rights reserved.
//

import Foundation
import CoreData

@objc public protocol RefreshServer: AnyObject {
    func updateProgress(_ value: Double)
    func finish(_ error: String?)
    func finishedLaunching()
}

@objc public protocol RefreshClient: AnyObject {
    func refreshAllApps()
}

@objc(SideStoreClient)
public final class SideStoreClient: NSObject, RefreshClient, @unchecked Sendable {
    @objc public static let shared = SideStoreClient()

    private static let liveProcessHandlerClass: AnyClass? = NSClassFromString("LiveProcessSideStoreHandler")

    @objc public func notifyFinishedLaunching() {
        guard let handlerClass = Self.liveProcessHandlerClass as? NSObject.Type,
              let handler = handlerClass.value(forKey: "shared") as? NSObject else {
            return
        }
        if let server = handler.value(forKey: "server") as? NSObject {
            _ = server.perform(NSSelectorFromString("finishedLaunching"))
        }
    }

    @objc public func relaunchLC() {
        if let utilsClass = NSClassFromString("LCSharedUtils") as? NSObject.Type {
            _ = utilsClass.perform(NSSelectorFromString("launchToGuestApp"))
        }
    }

    @objc public func refreshAllApps() {
        guard let handlerClass = Self.liveProcessHandlerClass as? NSObject.Type,
              let handler = handlerClass.value(forKey: "shared") as? NSObject,
              let server = handler.value(forKey: "server") as? (any RefreshServer) else {
            return
        }
        self.performRefreshForReal(server: server)
    }

    @objc public func performRefreshForReal(server: any RefreshServer) {
        Task {
            do {
                let progress = Progress(totalUnitCount: 1)
                progress.completedUnitCount = 0
                _ = progress.observe(\.fractionCompleted, options: [.new]) { progress, change in
                    if let newValue = change.newValue {
                        server.updateProgress(newValue)
                    }
                }

                try await refreshAllApps(progress: progress)
                server.finish(nil)
            } catch {
                server.finish(error.localizedDescription)
            }
        }
    }

    public func refreshAllApps(progress: Progress) async throws {
        if !DatabaseManager.shared.isStarted {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DatabaseManager.shared.start { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
        try await AppBootManager.shared.ensureMinimuxerStarted()

        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let installedApps = await context.perform { InstalledApp.fetchAppsForRefreshingAll(in: context) }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                let operation = try AppManager.shared.backgroundRefresh(installedApps, presentsNotifications: true) { result in
                    do {
                        let results = try result.get()
                        for (_, res) in results {
                            guard case let .failure(error) = res else { continue }
                            throw error
                        }
                        continuation.resume()
                    } catch ~RefreshErrorCode.noInstalledApps {
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }

                progress.addChild(operation.progress, withPendingUnitCount: 1)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

