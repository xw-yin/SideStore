//
//  AutomaticRefreshManager.swift
//  SideStore
//
//  Schedules and runs automatic app refreshes via BGProcessingTask.
//  Every run is recorded as a RefreshAttempt so the history persists.
//

import BackgroundTasks
import UIKit
import CoreData

enum AutomaticRefreshManager
{
    static let taskIdentifier = "com.SideStore.SideStore.automatic-refresh"
    
    /// Default interval between automatic refreshes (24h). The system may defer
    /// the task; the UI must only ever promise the earliest eligible time.
    static let defaultInterval: TimeInterval = 24 * 60 * 60
    
    static var isEnabled: Bool {
        UserDefaults.standard.isAutomaticRefreshEnabled
    }
    
    static var interval: TimeInterval {
        let hours = UserDefaults.standard.automaticRefreshIntervalHours
        guard hours > 0 else { return Self.defaultInterval }
        return TimeInterval(hours) * 60 * 60
    }
    
    static var lastRunDate: Date? {
        UserDefaults.standard.lastAutomaticRefreshDate
    }
    
    /// Earliest date the next run may start. Never presented as a promise:
    /// BGTaskScheduler decides the actual execution time.
    static var earliestEligibleDate: Date? {
        guard isEnabled else { return nil }
        let base = lastRunDate ?? Date()
        return base.addingTimeInterval(interval)
    }
    
    static func schedule()
    {
        guard isEnabled else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
            return
        }
        
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        request.requiresNetworkConnectivity = true
        
        do {
            try BGTaskScheduler.shared.submit(request)
            debugLog("[AutomaticRefresh] Scheduled next run, earliest eligible: \(request.earliestBeginDate?.description ?? "nil")")
        } catch {
            debugLog("[AutomaticRefresh] Failed to schedule: \(error.localizedDescription)")
        }
    }
    
    static func handle(task: BGProcessingTask)
    {
        debugLog("[AutomaticRefresh] Task started")
        // Always schedule the next run up-front so a crash/termination
        // does not break the cadence.
        schedule()
        
        let operation = Task.detached(priority: .background) {
            await runAutomaticRefresh()
        }
        
        task.expirationHandler = {
            debugLog("[AutomaticRefresh] Task expired, cancelling")
            operation.cancel()
        }
        
        Task.detached {
            let success = await operation.value
            task.setTaskCompleted(success: success)
            debugLog("[AutomaticRefresh] Task completed: \(success)")
        }
    }
    
    @discardableResult
    private static func runAutomaticRefresh() async -> Bool
    {
        // Auth preflight + verification manifest (S4).
        let manifest = await RefreshVerificationManifest.verify()
        debugLog("[AutomaticRefresh] Verification manifest: \(manifest.summary)")
        guard manifest.isValid else {
            debugLog("[AutomaticRefresh] Preflight failed, skipping refresh")
            recordSkippedAttempt(manifest: manifest)
            return false
        }
        
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let installedApps: [InstalledApp] = await context.perform {
            InstalledApp.fetchAppsForBackgroundRefresh(in: context)
        }
        
        guard !installedApps.isEmpty else {
            debugLog("[AutomaticRefresh] No apps need refreshing")
            UserDefaults.standard.lastAutomaticRefreshDate = Date()
            return true
        }
        
        do {
            let results = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Result<InstalledApp, Error>], Error>) in
                do {
                    _ = try AppManager.shared.backgroundRefresh(installedApps, presentsNotifications: true) { result in
                        continuation.resume(with: result)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            
            let failures = results.values.filter {
                if case .failure = $0 { return true }
                return false
            }
            debugLog("[AutomaticRefresh] Finished: \(results.count - failures.count)/\(results.count) succeeded")
            UserDefaults.standard.lastAutomaticRefreshDate = Date()
            // BackgroundRefreshAppsOperation already persisted a RefreshAttempt.
            return failures.isEmpty
        } catch {
            debugLog("[AutomaticRefresh] Refresh failed: \(error.localizedDescription)")
            recordFailedAttempt(error: error)
            return false
        }
    }
    
    private static func recordSkippedAttempt(manifest: RefreshVerificationManifest)
    {
        recordSimpleAttempt(error: OperationError.invalidParameters("Automatic refresh skipped: \(manifest.summary)"))
    }
    
    private static func recordFailedAttempt(error: Error)
    {
        recordSimpleAttempt(error: error)
    }
    
    private static func recordSimpleAttempt(error: Error)
    {
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        context.performAndWait {
            _ = RefreshAttempt(identifier: UUID().uuidString, result: .failure(error), context: context)
            try? context.save()
        }
    }
}
