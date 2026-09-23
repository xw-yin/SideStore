//
//  RefreshHistoryRecorder.swift
//  SideStore
//
//  Records manual refreshes into the persistent RefreshAttempt history.
//

import Foundation
import CoreData

enum RefreshHistoryRecorder
{
    /// Records a manual (user-initiated) refresh as a RefreshAttempt.
    /// Cancellation-only results are not recorded.
    static func recordManualRefresh(results: [String: Result<InstalledApp, Error>])
    {
        let failures = results.values.compactMap { result -> Error? in
            switch result
            {
            case .failure(let error) where error is CancellationError: return nil
            case .failure(let error): return error
            case .success: return nil
            }
        }
        
        // Skip recording pure cancellations.
        let nonCancelled = results.values.filter {
            if case .failure(let error) = $0, error is CancellationError { return false }
            return true
        }
        guard !nonCancelled.isEmpty else { return }
        
        let result: Result<[String: Result<InstalledApp, Error>], Error>
        if let firstFailure = failures.first {
            result = .failure(firstFailure)
        } else {
            result = .success(results)
        }
        
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        context.performAndWait {
            _ = RefreshAttempt(identifier: UUID().uuidString, result: result, context: context)
            try? context.save()
        }
    }
}
