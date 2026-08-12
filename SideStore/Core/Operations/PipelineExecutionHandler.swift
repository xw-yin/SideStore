//
//  PipelineExecutionHandler.swift
//  SideStore
//
//  Created by Magesh K on 8/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
@preconcurrency import AltSign
@preconcurrency import AltStoreCore

protocol PipelineExecutionHandler: AnyObject {
    var preflightChecksHandler: PreflightChecksHandler { get }
    var entitlementsReviewHandler: EntitlementsReviewHandler { get }
    var extensionRemovalHandler: ExtensionRemovalHandler { get }
    var unsupportedVersionHandler: UnsupportedVersionHandler { get }
    var installAppHandler: InstallAppHandler { get }
    var userCustomizationHandler: UserCustomizationHandler { get }
}



protocol PreflightChecksHandler: AnyObject {
    func resolveBundleIDMismatch(targetID: String, activeEffectiveID: String) async -> Bool
    var isResignActive: Bool { get }
}

protocol EntitlementsReviewHandler: AnyObject {
    func reviewPermissions(_ permissions: [ALTEntitlement], for app: AppProtocol, mode: PermissionReviewMode) async throws
}

enum ExtensionRemovalDecision: Sendable {
    case cancel
    case keepAll(useMainProfile: Bool)
    case removeAll
    case removeSelected(Set<ALTApplication>)
}

protocol ExtensionRemovalHandler: AnyObject {
    func selectAppExtensionsToRemove(
        appBundle: ALTApplication,
        localAppExtensions: [ALTApplication],
        excessExtensions: Set<ALTApplication>
    ) async throws -> ExtensionRemovalDecision
}

protocol UnsupportedVersionHandler: AnyObject {
    func resolveUnsupportediOSVersion(errorDescription: String, appName: String, compatibleVersion: String) async throws -> Bool
}

protocol InstallAppHandler: AnyObject {
    func requestBackgroundSuspension(completion: @escaping () -> Void)
    func suspendToHomeScreen(shouldTurnOffData: Bool)
    var isAppInForeground: Bool { get }
}

protocol UserCustomizationHandler: AnyObject {
    func resolveBundleIDOverride(initialBundleID: String) async throws -> String?
}
