//
//  PrepareAppExtensionBundleIDsOperation.swift
//  SideStore
//
//  Created by Magesh K on 01/08/26.
//  Copyright © 2026 AltStore. All rights reserved.
//

import Foundation

final class PrepareAppExtensionBundleIDsOperation: BasePipelineOperation<InstallAppOperationContext, Void>, @unchecked Sendable {
    override func execute(parentProgress: Progress?) async throws {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[PrepareAppExtensionBundleIDsOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[PrepareAppExtensionBundleIDsOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        
        if self.context.useMainProfile {
            if let appBundle = self.context.targetAppBundle,
               let profile = self.context.provisioningProfiles?[self.context.targetBundleIdentifier] ?? self.context.provisioningProfiles?[self.context.bundleIdentifier] {
                let resolvedMainID = profile.resolvedBundleIdentifier(for: self.context.targetBundleIdentifier)
                var appexBundleIds: [String: String] = [:]
                for appex in appBundle.appExtensions {
                    let updatedAppExBundleId = appex.bundleIdentifier.replacingOccurrences(of: appBundle.bundleIdentifier, with: self.context.targetBundleIdentifier)
                    let resolvedAppExID = appex.bundleIdentifier.replacingOccurrences(of: appBundle.bundleIdentifier, with: resolvedMainID)
                    appexBundleIds[appex.bundleIdentifier] = resolvedAppExID
                    appexBundleIds[updatedAppExBundleId] = resolvedAppExID
                }
                self.context.appexBundleIds = appexBundleIds
            }
        }
        self.setProgress(100)
    }
}
