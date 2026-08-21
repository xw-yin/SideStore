//
//  RefreshAllAppsIntent.swift
//  AltStore
//
//  Created by Riley Testut on 8/18/23.
//  Copyright © 2023 Riley Testut. All rights reserved.
//

import AppIntents
import WidgetKit

// Shouldn't conform types we don't own to protocols we don't own, so make custom
// NSError subclass that conforms to CustomLocalizedStringResourceConvertible instead.
//
// Would prefer to just conform ALTLocalizedError to CustomLocalizedStringResourceConvertible,
// but that can't be done without raising minimum version for ALTLocalizedError to iOS 16 :/
@available(iOS 16, *)
class IntentError: NSError, CustomLocalizedStringResourceConvertible, @unchecked Sendable
{
    var localizedStringResource: LocalizedStringResource {
        return "\(self.localizedDescription)"
    }
    
    init(_ error: some Error)
    {
        let serializedError = (error as NSError).sanitizedForSerialization()
        super.init(domain: serializedError.domain, code: serializedError.code, userInfo: serializedError.userInfo)
    }
    
    required init?(coder: NSCoder)
    {
        super.init(coder: coder)
    }
}

@available(iOS 17.0, *)
struct InstallIPAIntent: AppIntent, ProgressReportingIntent
{
    static var title: LocalizedStringResource = LocalizedStringResource("Install IPA", defaultValue: "安装 IPA")
    static var description = IntentDescription(LocalizedStringResource("Installs an IPA file with SideStore.", defaultValue: "使用 SideStore 安装 IPA 文件。"))
    static var openAppWhenRun = false

    @Parameter(title: "IPA File")
    var ipaFile: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Install \(\.$ipaFile)")
    }

    init()
    {
        self.progress.completedUnitCount = 0
        self.progress.totalUnitCount = 1
    }

    func perform() async throws -> some IntentResult
    {
        do
        {
            try await Self.startDatabaseIfNeeded()
            try await AppBootManager.shared.ensureMinimuxerStarted()

            let temporaryDirectory = FileManager.default.uniqueTemporaryURL()
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

            let ipaURL = temporaryDirectory.appendingPathComponent("App.ipa")
            try self.ipaFile.data.write(to: ipaURL)

            let intentProgress = self.progress
            _ = try await AppManager.shared.installIPA(at: ipaURL) { progress in
                intentProgress.addChild(progress, withPendingUnitCount: 1)
            }

            return .result()
        }
        catch
        {
            let intentError = IntentError(error)
            throw intentError
        }
    }
}

@available(iOS 17.0, *)
fileprivate extension InstallIPAIntent
{
    static func startDatabaseIfNeeded() async throws
    {
        if !DatabaseManager.shared.isStarted
        {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DatabaseManager.shared.start { error in
                    if let error
                    {
                        continuation.resume(throwing: error)
                    }
                    else
                    {
                        continuation.resume()
                    }
                }
            }
        }
    }
}

@available(iOS 17.0, *)
extension RefreshAllAppsIntent
{
    private actor OperationActor
    {
        private(set) var operation: BackgroundRefreshAppsOperation?
        
        func set(_ operation: BackgroundRefreshAppsOperation?)
        {
            self.operation = operation
        }
    }
}

@available(iOS 17.0, *)
struct RefreshAllAppsIntent: AppIntent, CustomIntentMigratedAppIntent, PredictableIntent, ProgressReportingIntent, ForegroundContinuableIntent
{
    static let intentClassName = "RefreshAllIntent"
    
    static var title: LocalizedStringResource = LocalizedStringResource("Refresh All Apps", defaultValue: "刷新所有应用")
    static var description = IntentDescription(LocalizedStringResource("Refreshes your sideloaded apps to prevent them from expiring.", defaultValue: "刷新已侧载的应用以防止证书过期。"))
    
    static var parameterSummary: some ParameterSummary {
        Summary("Refresh All Apps")
    }
    
    static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction {
            DisplayRepresentation(
                title: LocalizedStringResource("Refresh All Apps", defaultValue: "刷新所有应用"),
                subtitle: ""
            )
        }
    }
    
    let presentsNotifications: Bool
    
    private let operationActor = OperationActor()
    
    init(presentsNotifications: Bool)
    {
        self.presentsNotifications = presentsNotifications
        
        self.progress.completedUnitCount = 0
        self.progress.totalUnitCount = 1
    }
    
    init()
    {
        self.init(presentsNotifications: false)
    }
    
    func perform() async throws -> some IntentResult & ProvidesDialog
    {
        do
        {
            // Request foreground execution at ~27 seconds to gracefully handle timeout.
            let deadline: ContinuousClock.Instant = .now + .seconds(27)
            
            try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                taskGroup.addTask {
                    try await self.refreshAllApps()
                }
                
                taskGroup.addTask {
                    try await Task.sleep(until: deadline)
                    throw OperationError.timedOut
                }
                
                do
                {
                    for try await _ in taskGroup.prefix(1)
                    {
                        // We only care about the first child task to complete.
                        taskGroup.cancelAll()
                        break
                    }
                }
                catch OperationError.timedOut
                {
                    // We took too long to finish and return the final result,
                    // so we'll now present a normal notification when finished.
                    let operation = await self.operationActor.operation
                    operation?.presentsFinishedNotification = true
                    
                    try await self.requestToContinueInForeground()
                }
            }
            
            return .result(dialog: IntentDialog(LocalizedStringResource("All apps have been refreshed.", defaultValue: "所有应用已成功刷新。")))
        }
        catch
        {
            let intentError = IntentError(error)
            throw intentError
        }
    }
}

@available(iOS 17.0, *)
private extension RefreshAllAppsIntent
{
    func refreshAllApps() async throws
    {
        try await InstallIPAIntent.startDatabaseIfNeeded()
        try await AppBootManager.shared.ensureMinimuxerStarted()
        
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let installedApps = await context.perform { InstalledApp.fetchAppsForRefreshingAll(in: context) }
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do
            {
                let operation = try AppManager.shared.backgroundRefresh(installedApps, presentsNotifications: self.presentsNotifications, completionHandler: { (result) in
                    do
                    {
                        let results = try result.get()
                        
                        for (_, result) in results
                        {
                            guard case let .failure(error) = result else { continue }
                            throw error
                        }
                        
                        continuation.resume()
                    }
                    catch ~RefreshErrorCode.noInstalledApps
                    {
                        continuation.resume()
                    }
                    catch
                    {
                        continuation.resume(throwing: error)
                    }
                })
                
                operation.ignoresServerNotFoundError = false
                
                self.progress.addChild(operation.progress, withPendingUnitCount: 1)
                
                Task {
                    await self.operationActor.set(operation)
                }
            }
            catch
            {
                continuation.resume(throwing: error)
            }
        }
    }
}
