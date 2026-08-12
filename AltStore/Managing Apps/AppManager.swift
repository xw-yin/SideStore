//
//  AppManager.swift
//  AltStore
//
//  Created by Riley Testut on 5/29/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import Foundation
import CoreData
@preconcurrency import UIKit
import UserNotifications
import MobileCoreServices
import Intents
import Combine
import WidgetKit
@preconcurrency import AltStoreCore
@preconcurrency import AltSign
import UniformTypeIdentifiers

extension AppManager
{
    static let didFetchSourceNotification = Notification.Name("io.sidestore.AppManager.didFetchSource")
    static let didAddSourceNotification = Notification.Name("io.sidestore.AppManager.didAddSource")
    static let didRemoveSourceNotification = Notification.Name("io.sidestore.AppManager.didRemoveSource")
    static let willInstallAppFromNewSourceNotification = Notification.Name("io.sidestore.AppManager.willInstallAppFromNewSource")
    
    static let expirationWarningNotificationID = "sidestore-expiration-warning"
    static let enableJITResultNotificationID = "sidestore-enable-jit"
}

@available(iOS 13, *)
final class AppManagerPublisher: ObservableObject
{
    @Published
    fileprivate(set) var installationProgress = [String: Progress]()
    
    @Published
    fileprivate(set) var refreshProgress = [String: Progress]()
}

final class AppManager: ObservableObject, @unchecked Sendable
{
    static let shared = AppManager()

    lazy var pipelineRunner: PipelineRunner = {
        PipelineRunner(
            progress: self, 
            context: self, 
            logger: self, 
            defaultEntitlements: OperationEntitlements.defaultAdditionalEntitlements
        )
    }()

    private static let restartLock = NSLock()
    
    private(set) var updatePatronsResult: Result<Void, Error>?
    
    @Published
    private(set) var updateSourcesResult: Result<Void, Error>? = .success(()) // nil == loading
    
    private let operationQueue = OperationQueue()
    private let serialOperationQueue = OperationQueue()
    
    @Published private var installationProgress = [String: Progress]()
    @Published private var refreshProgress = [String: Progress]()
    private var cancellables: Set<AnyCancellable> = []
    
    private let progressLock = NSLock()
    
    
    
    private init()
    {
        self.operationQueue.name = "com.altstore.AppManager.operationQueue"
        
        self.serialOperationQueue.name = "com.altstore.AppManager.serialOperationQueue"
        self.serialOperationQueue.maxConcurrentOperationCount = 1
        
        self.prepareSubscriptions()
    }
    
    func prepareSubscriptions()
    {
        /// Every time refreshProgress is changed, update all InstalledApps in memory
        /// so that app.isRefreshing == refreshProgress.keys.contains(app.bundleID)
        
        self.$refreshProgress
            .receive(on: RunLoop.main)
            .map(\.keys)
            .flatMap { (bundleIDs) in
                DatabaseManager.shared.viewContext.registeredObjects.publisher
                    .compactMap { $0 as? InstalledApp }
                    .map { ($0, bundleIDs.contains($0.bundleIdentifier)) }
            }
            .sink { (installedApp, isRefreshing) in
                if installedApp.isRefreshing != isRefreshing {
                    installedApp.isRefreshing = isRefreshing
                }
            }
            .store(in: &self.cancellables)
    }
}

extension AppManager
{
    func reconcileInstalledApps() async
    {
        await Task.detached {
            let dbBackgroundContext = DatabaseManager.shared.persistentContainer.newBackgroundContext()
            var altstoreAppObjectID: NSManagedObjectID?
    
            #if targetEnvironment(simulator)
            // Apps aren't ever actually installed to simulator, so just do nothing rather than delete them from database.
            #else
        
            do
            {
                try await dbBackgroundContext.perform {
                    let installedApps = InstalledApp.all(in: dbBackgroundContext)
                
                    if UserDefaults.standard.legacySideloadedApps == nil
                    {
                        // First time updating apps since updating AltStore to use custom UTIs,
                        // so cache all existing apps temporarily to prevent us from accidentally
                        // deleting them due to their custom UTI not existing (yet).
                        let apps = installedApps.map { $0.bundleIdentifier }
                        UserDefaults.standard.legacySideloadedApps = apps
                    }
                
                    let legacySideloadedApps = Set(UserDefaults.standard.legacySideloadedApps ?? [])
                
                    for app in installedApps
                    {
                        guard app.bundleIdentifier != StoreApp.altstoreAppID else {
                            altstoreAppObjectID = app.objectID
                            continue
                        }
                    
                        guard !self.isActivelyManagingApp(withBundleID: app.bundleIdentifier) else { continue }
                    
                        if !UserDefaults.standard.isLegacyDeactivationSupported
                        {
                            // We can't (ab)use provisioning profiles to deactivate apps,
                            // which means we must delete apps to free up active slots.
                            // So, only check if active apps are installed to prevent
                            // false positives when checking inactive apps.
                            guard app.isActive else { continue }
                        }
                    
                        let isDeclared = UTType(app.installedAppUTI)?.isDeclared ?? false
                        if !isDeclared && !legacySideloadedApps.contains(app.bundleIdentifier)
                        {
                            // This UTI is not declared by any apps, which means this app has been deleted by the user.
                            // This app is also not a legacy sideloaded app, so we can assume it's fine to delete it.
                            dbBackgroundContext.delete(app)
                        
                            if var patchedApps = UserDefaults.standard.patchedApps, let index = patchedApps.firstIndex(of: app.bundleIdentifier)
                            {
                                patchedApps.remove(at: index)
                                UserDefaults.standard.patchedApps = patchedApps
                            }
                        }
                    }
                
                    if dbBackgroundContext.hasChanges {
                        try dbBackgroundContext.save()
                    }
                }
            
                if let objectID = altstoreAppObjectID {
                    let context = StandaloneOperationContext(steps: .scheduleExpirationWarningNotification, dbBackgroundContext: dbBackgroundContext)
                    let app = await dbBackgroundContext.perform {
                        dbBackgroundContext.object(with: objectID) as! InstalledApp
                    }
                    let scheduleNotifOp = try ScheduleExpirationWarningNotificationOperation(
                        installedApp: app,
                        context: context
                    )
                    try await scheduleNotifOp.execute()
                }
            }
            catch
            {
                debugLog("Error while fetching installed apps. \(error)")
            }
            #endif
        
            do
            {
                let installedAppBundleIDs = await dbBackgroundContext.perform {
                    InstalledApp.all(in: dbBackgroundContext).map { $0.bundleIdentifier }
                }
                            
                let cachedAppDirectories = try FileManager.default.contentsOfDirectory(at: InstalledApp.appsDirectoryURL,
                                                                                       includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
                                                                                       options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles])
                for appDirectory in cachedAppDirectories
                {
                    do
                    {
                        let resourceValues = try appDirectory.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
                        guard let isDirectory = resourceValues.isDirectory, let bundleID = resourceValues.name else { continue }
                    
                        if isDirectory && !installedAppBundleIDs.contains(bundleID) && !self.isActivelyManagingApp(withBundleID: bundleID)
                        {
                            debugLog("DELETING CACHED APP: \(bundleID)")
                            try FileManager.default.removeItem(at: appDirectory)
                        }
                    }
                    catch
                    {
                        debugLog("Failed to remove cached app directory. \(error)")
                    }
                }
            }
            catch
            {
                debugLog("Failed to remove cached apps. \(error)")
            }
    
        }.value
    }
    
    private func makePipelineHandler(presentingViewController: UIViewController?) -> PipelineExecutionHandler {
        return PipelineHandler(presentingViewController: presentingViewController)
    }

    private func makeAuthenticatedContext(presentingViewController: UIViewController?, baseContext: AuthenticatedOperationContext? = nil, dbBackgroundContext: NSManagedObjectContext? = nil) -> AuthenticatedOperationContext {
        if let baseContext = baseContext { return baseContext }
        let authFlowHandler = AuthFlowHandler(presentingViewController: presentingViewController)
        return AuthenticatedOperationContext(
            authenticationHandler: authFlowHandler,
            anisetteServerHandler: authFlowHandler,
            dbBackgroundContext: dbBackgroundContext
        )
    }

    func authenticate(presentingViewController: UIViewController?,
                      skipDeviceRegistration: Bool = false,
                      skipCertificateProvisioning: Bool = false,
                      completionHandler: @escaping (Result<(ALTTeam, ALTCertificate?, ALTAppleAPISession), Error>) -> Void)
    {
        Task.detached {
            do {
                let result = try await AuthManager.shared.authenticate(
                    presentingViewController: presentingViewController,
                    skipDeviceRegistration: skipDeviceRegistration,
                    skipCertificateProvisioning: skipCertificateProvisioning
                )
                completionHandler(.success((result.team, result.certificate, result.session)))
            } catch {
                completionHandler(.failure(error))
            }
        }
    }
    
    func deactivateApps(for appBundle: ALTApplication, presentingViewController: UIViewController?, completion: @escaping (Result<Void, Error>) -> Void)
    {
        guard !UserDefaults.standard.isAppLimitDisabled, let activeAppsLimit = UserDefaults.standard.activeAppsLimit else { return completion(.success(())) }
        
        DispatchQueue.main.async {
            // Only apps signed with a free developer certificate count toward the 3-app free account limit.
            // Apps signed with a paid certificate coexist independently and must not be counted here.
            let activeApps = InstalledApp.fetchActiveApps(in: DatabaseManager.shared.viewContext)
                .filter { $0.bundleIdentifier != appBundle.bundleIdentifier } // Don't count app towards total if it matches activating app
                .filter { ($0.team?.type ?? .unknown) == .free }        // Only free-cert-signed apps count against the free limit
                .sorted { ($0.name, $0.refreshedDate) < ($1.name, $1.refreshedDate) }
            
            var title: String = NSLocalizedString("Cannot Activate More than 3 Apps", comment: "")
            let message: String
            
            if UserDefaults.standard.activeAppLimitIncludesExtensions
            {
                if appBundle.appExtensions.isEmpty
                {
                    message = NSLocalizedString("Non-developer Apple IDs are limited to 3 active apps and app extensions. Please choose an app to deactivate.", comment: "")
                }
                else
                {
                    title = NSLocalizedString("Cannot Activate More than 3 Apps and App Extensions", comment: "")
                    
                    let appExtensionText = appBundle.appExtensions.count == 1 ? NSLocalizedString("app extension", comment: "") : NSLocalizedString("app extensions", comment: "")
                    message = String(format: NSLocalizedString("Non-developer Apple IDs are limited to 3 active apps and app extensions, and \"%@\" contains %@ %@. Please choose an app to deactivate.", comment: ""), appBundle.name, NSNumber(value: appBundle.appExtensions.count), appExtensionText)
                }
            }
            else
            {
                message = NSLocalizedString("Non-developer Apple IDs are limited to 3 active apps. Please choose an app to deactivate.", comment: "")
            }
            
            let activeAppsCount = activeApps.map { $0.requiredActiveSlots }.reduce(0, +)
                    
            let availableActiveApps = max(activeAppsLimit - activeAppsCount, 0)
            let requiredActiveSlots = UserDefaults.standard.activeAppLimitIncludesExtensions ? (1 + appBundle.appExtensions.count) : 1
            guard requiredActiveSlots > availableActiveApps else { return completion(.success(())) }

            guard let presentingViewController else {
                let failureReason = String(format: NSLocalizedString("SideStore needs to deactivate another app before installing %@.", comment: ""), appBundle.name)
                return completion(.failure(OperationError.forbidden(failureReason: failureReason)))
            }
            
            let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: UIAlertAction.cancel.title, style: UIAlertAction.cancel.style) { (action) in
                completion(.failure(OperationError.cancelled))
            })
            
            for activeApp in activeApps where activeApp.bundleIdentifier != StoreApp.altstoreAppID
            {
                alertController.addAction(UIAlertAction(title: activeApp.name, style: .default) { (action) in
                    activeApp.isActive = false
                                    
                    self.deactivate(activeApp, presentingViewController: presentingViewController) { (result) in
                        switch result
                        {
                        case .failure(let error):
                            activeApp.managedObjectContext?.perform {
                                activeApp.isActive = true
                                completion(.failure(error))
                            }
                            
                        case .success:
                            self.deactivateApps(for: appBundle, presentingViewController: presentingViewController, completion: completion)
                        }
                    }
                })
            }
            
            presentingViewController.present(alertController, animated: true, completion: nil)
        }
    }
    
    func clearAppCache(completion: @escaping (Result<Void, Error>) -> Void)
    {
        Task.detached {
            do {
                let context = StandaloneOperationContext(steps: .clearAppCache)
                try await ClearAppCacheOperation(context: context).execute()
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func log(_ error: Error, operation: LoggedError.Operation, app: AppProtocol)
    {
        switch error
        {
            case is CancellationError: return // Don't log CancellationErrors
            case let nsError as NSError where nsError.domain == CancellationError()._domain: return
            default: break
        }

        // Sanitize NSError on same thread before performing background task.
        let sanitizedError = (error as NSError).sanitizedForSerialization()

        DatabaseManager.shared.persistentContainer.performBackgroundTask { context in
            var app = app
            if let managedApp = app as? NSManagedObject, let tempApp = context.object(with: managedApp.objectID) as? AppProtocol
            {
                app = tempApp
            }

            do
            {
                let loggedError = LoggedError(error: sanitizedError, app: app, operation: operation, context: context)
                debugLog("""
                [AppManager] log() error: \(sanitizedError)
                  • app            : \(app.bundleIdentifier)
                  • operation      : \(operation)
                  • loggedErrorID  : \(loggedError.objectID)
                """)
                if context.hasChanges {
                    try context.save()
                }
            }
            catch let saveError
            {
                debugLog("[ALTLog] Failed to log error \(sanitizedError.domain) code \(sanitizedError.code) for \(app.bundleIdentifier): \(saveError)")
            }
        }
    }

}

extension AppManager
{
    func fetchSource(sourceURL: URL, managedObjectContext: NSManagedObjectContext) async throws -> Source
    {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try fetchSource(sourceURL: sourceURL, managedObjectContext: managedObjectContext) { result in
                    continuation.resume(with: result)
                }
            }catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    func fetchSources() async throws -> (Set<Source>, NSManagedObjectContext)
    {
        try await withCheckedThrowingContinuation { continuation in
            fetchSources { result in
                continuation.resume(with: result)
            }
        }
    }
    
    func add(@AsyncManaged _ source: Source,
             message: String? = NSLocalizedString("Make sure to only add sources that you trust.", comment: ""),
             presentingViewController: UIViewController) async throws
    {
        let (sourceName, sourceURL) = await $source.perform { ($0.name, $0.sourceURL) }
        
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        async let fetchedSource = try await self.fetchSource(sourceURL: sourceURL, managedObjectContext: context) // Fetch source async while showing alert.

        let title = String(format: NSLocalizedString("Would you like to add the source “%@”?", comment: ""), sourceName)
        let action = await UIAlertAction(title: NSLocalizedString("Add Source", comment: ""), style: .default)
        try await presentingViewController.presentConfirmationAlert(title: title, message: message ?? "", primaryAction: action)

        // Wait for fetch to finish before saving context to make
        // sure there isn't already a source with this identifier.
        let sourceExists = try await fetchedSource.isAdded
        
        // This is just a sanity check, so pass nil for existingSource to keep code simple.
        guard !sourceExists else { throw SourceError.duplicate(source, existingSource: nil) }
        
        try await context.performAsync {
            try context.save()
        }
        
        NotificationCenter.default.post(name: AppManager.didAddSourceNotification, object: source)
    }
    
    func remove(@AsyncManaged _ source: Source, presentingViewController: UIViewController) async throws
    {
        let (sourceName, sourceID) = await $source.perform { ($0.name, $0.identifier) }
        guard sourceID != Source.altStoreIdentifier else {
            throw OperationError.forbidden(failureReason: NSLocalizedString("The default SideStore source cannot be removed.", comment: ""))
        }
        
        let title = String(format: NSLocalizedString("Are you sure you want to remove the source “%@”?", comment: ""), sourceName)
        let message = NSLocalizedString("Any apps you've installed from this source will remain, but they'll no longer receive any app updates.", comment: "")
        let action = await UIAlertAction(title: NSLocalizedString("Remove Source", comment: ""), style: .destructive)
        try await presentingViewController.presentConfirmationAlert(title: title, message: message, primaryAction: action)
        
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        try await context.performAsync {
            let predicate = NSPredicate(format: "%K == %@", #keyPath(Source.identifier), sourceID)
            guard let source = Source.first(satisfying: predicate, in: context) else { return } // Doesn't exist == success.
            
            context.delete(source)
            try context.save()
        }
        
        NotificationCenter.default.post(name: AppManager.didRemoveSourceNotification, object: source)
    }
    
    @discardableResult
    func installAsync<T: AppProtocol>(@AsyncManaged _ app: T, presentingViewController: UIViewController?, completionHandler: @escaping (Result<InstalledApp, Error>) -> Void) async -> RefreshGroup
    {
        @AsyncManaged var installingApp: AppProtocol = app
        var didAddSource = false
        
        let context = self.makeAuthenticatedContext(presentingViewController: presentingViewController)
        
        do
        {
            // Check if we need to add source first before installing app.
            if let source = await $app.perform({ $0.storeApp?.source }), try await !source.isAdded
            {
                // This app's source is not yet added, so add it first.
                guard let presentingViewController else { throw OperationError.sourceNotAdded(source) }
                
                let (appName, appBundleID, sourceID) = await $app.perform { ($0.name, $0.bundleIdentifier, source.identifier) }
                
                do
                {
                    let message = String(format: NSLocalizedString("You must add this source before installing apps from it.\n\n“%@” will begin downloading once it has been added.", comment: ""), appName)
                    try await AppManager.shared.add(source, message: message, presentingViewController: presentingViewController)
                }
                catch let error as CancellationError 
                {
                    throw error
                }
                catch
                {
                    // This should be an alert, so show directly rather than re-throwing error.
                    await presentingViewController.presentAlert(title: NSLocalizedString("Unable to Add Source", comment: ""), message: error.localizedDescription)
                    
                    // Don't rethrow error
                    // throw error
                    
                    throw CancellationError()
                }
                
                // Fetch persisted StoreApp to use for remainder of operation.
                installingApp = try await DatabaseManager.shared.viewContext.performAsync {
                    let fetchRequest = StoreApp.fetchRequest()
                    fetchRequest.predicate = NSPredicate(format: "%K == %@ AND %K == %@",
                                                         #keyPath(StoreApp.bundleIdentifier), appBundleID,
                                                         #keyPath(StoreApp.sourceIdentifier), sourceID)
                    
                    guard let storeApp = try DatabaseManager.shared.viewContext.fetch(fetchRequest).first else { throw OperationError.appNotFound(name: appName) }
                    return storeApp
                }
                
                didAddSource = true
            }
        }
        catch
        {
            completionHandler(.failure(error))
            
            let group = RefreshGroup(context: context)
            group.progress.cancel()
            return group
        }
        
        let group = await $installingApp.perform { self.install($0, presentingViewController: presentingViewController, context: context, completionHandler: completionHandler) }
        
        if didAddSource
        {
            // Post notification from main queue _after_ assigning progress for it
            await MainActor.run { [installingApp] in
                NotificationCenter.default.post(name: AppManager.willInstallAppFromNewSourceNotification, object: installingApp)
            }
        }
        
        return group
    }
    
    @discardableResult
    func fetchSource(sourceURL: URL,
                     managedObjectContext: NSManagedObjectContext,
                     completionHandler: @escaping (Result<Source, Error>) -> Void) throws -> FetchSourceOperation
    {
        let context = StandaloneOperationContext(steps: [], dbBackgroundContext: managedObjectContext)
        let fetchSourceOperation = try FetchSourceOperation(sourceURL: sourceURL, context: context)
        Task.detached {
            do {
                let source = try await fetchSourceOperation.execute()
                completionHandler(.success(source))
            } catch {
                completionHandler(.failure(error))
            }
        }
        return fetchSourceOperation
    }
    
    func fetchSources(completionHandler: @escaping (Result<(Set<Source>, NSManagedObjectContext), FetchSourcesError>) -> Void)
    {
        Task.detached(priority: .utility) {
            let managedObjectContext = DatabaseManager.shared.persistentContainer.newBackgroundContext()
            
            var sourceData = [(objectID: NSManagedObjectID, sourceURL: URL)]()
            
            managedObjectContext.performAndWait {
                let sources = Source.all(in: managedObjectContext)
                sourceData = sources.map { ($0.objectID, $0.sourceURL) }
            }
            
            guard !sourceData.isEmpty else {
                completionHandler(.failure(.init(OperationError.noSources)))
                return
            }
            
            var fetchedSources = Set<Source>()
            var errors = [Source: Error]()
            
            await withTaskGroup(of: (NSManagedObjectID, Result<Source, Error>).self) { taskGroup in
                for data in sourceData {
                    taskGroup.addTask {
                        do {
                            let source = managedObjectContext.performAndWait { managedObjectContext.object(with: data.objectID) as! Source }
                            let context = StandaloneOperationContext(steps: [], dbBackgroundContext: managedObjectContext)
                            let fetchSourceOperation = try FetchSourceOperation(source: source, context: context)
                            let fetchedSource = try await fetchSourceOperation.execute()
                            return (data.objectID, .success(fetchedSource))
                        } catch {
                            return (data.objectID, .failure(error))
                        }
                    }
                }
                
                for await (objectID, result) in taskGroup {
                    managedObjectContext.performAndWait {
                        let source = managedObjectContext.object(with: objectID) as! Source
                        switch result {
                        case .success(let fetchedSource):
                            fetchedSources.insert(fetchedSource)
                        case .failure(let nsError as NSError):
                            let title = String(format: NSLocalizedString("Unable to Refresh “%@” Source", comment: ""), source.name)
                            let error = nsError.withLocalizedTitle(title)
                            errors[source] = error
                            source.error = error.sanitizedForSerialization()
                        }
                    }
                }
            }
            
            await managedObjectContext.perform {
                do {
                    if managedObjectContext.hasChanges {
                        try managedObjectContext.save()
                    }
                } catch {
                    debugLog("Failed to save managedObjectContext in fetchSources: \(error.localizedDescription)")
                }
                
                if !errors.isEmpty {
                    let sourcesSet = Set(sourceData.compactMap { managedObjectContext.object(with: $0.objectID) as? Source })
                    completionHandler(.failure(.init(sources: sourcesSet, errors: errors, context: managedObjectContext)))
                } else {
                    completionHandler(.success((fetchedSources, managedObjectContext)))
                }
                NotificationCenter.default.post(name: AppManager.didFetchSourceNotification, object: self)
            }
        }
    }
    
    func syncAppIDs(presentingViewController: UIViewController? = nil, showAuthIfRequired: Bool = false, completionHandler: @escaping (Result<Void, Error>) -> Void)
    {
        guard AuthManager.shared.isAuthenticated || showAuthIfRequired else {
            debugLog("[AppManager] syncAppIDs: User is unauthenticated and showAuthIfRequired is false. Skipping syncAppIDs.")
            completionHandler(.failure(OperationError.notAuthenticated))
            return
        }
        
        let effectivePresentingVC = showAuthIfRequired ? presentingViewController : nil
        
        Task.detached(priority: .utility) {
            do {
                let managedObjectContext = DatabaseManager.shared.persistentContainer.newBackgroundContext()
                let context = self.makeAuthenticatedContext(presentingViewController: effectivePresentingVC, dbBackgroundContext: managedObjectContext)
                try await AuthManager.shared.authenticate(
                    context: context,
                    skipDeviceRegistration: true,
                    skipCertificateProvisioning: true
                )
                
                let syncAppIDsOperation = try SyncAppIDsOperation(context: context)
                try await syncAppIDsOperation.execute()
                completionHandler(.success(()))
            } catch {
                completionHandler(.failure(error))
            }
        }
    }
    
    @discardableResult
    func updateKnownSources(completionHandler: @escaping (Result<([KnownSource], [KnownSource]), Error>) -> Void) -> UpdateKnownSourcesOperation
    {
        let updateKnownSourcesOperation = UpdateKnownSourcesOperation()
        Task.detached(priority: .utility) {
            do {
                let result = try await updateKnownSourcesOperation.execute()
                completionHandler(.success(result))
            } catch {
                completionHandler(.failure(error))
            }
        }
        return updateKnownSourcesOperation
    }
    
    func updateAllSources(completion: @escaping (Result<Void, Error>) -> Void)
    {
        let context = DatabaseManager.shared.persistentContainer.viewContext
        let hasApps = (try? context.count(for: StoreApp.fetchRequest())) ?? 0 > 0
        if !hasApps {
            self.updateSourcesResult = nil
        }
        
        self.fetchSources() { (result) in
            do
            {
                // Check if the result is failure and rethrow
                if case .failure(let error) = result {
                    throw error  // Rethrow the error
                }
                
                do
                {
                    let (_, context) = try result.get()
//                    debugLog("\n\n\n\(context.insertedObjects)\n\n\n")
//                    debugLog("\n\n\n\(context.updatedObjects)\n\n\n")
//                    debugLog("\n\n\n\(context.deletedObjects)\n\n\n")
                    try context.save()
                    
                    DispatchQueue.main.async {
                        self.updateSourcesResult = .success(())
                        completion(.success(()))
                    }
                }
                catch let error as AppManager.FetchSourcesError
                {
                    try error.managedObjectContext?.save()
                    throw error
                }
                catch let mergeError as MergeError
                {
                    guard let sourceID = mergeError.sourceID else { throw mergeError }
                    
                    let sanitizedError = (mergeError as NSError).sanitizedForSerialization()
                    DatabaseManager.shared.persistentContainer.performBackgroundTask { context in
                        do
                        {
                            guard let source = Source.first(satisfying: NSPredicate(format: "%K == %@", #keyPath(Source.identifier), sourceID), in: context) else { return }
                            
                            source.error = sanitizedError
                            try context.save()
                        }
                        catch
                        {
                            debugLog("Failed to assign error \(sanitizedError.localizedErrorCode) to source \(sourceID). \(error.localizedDescription)")
                        }
                    }
                    
                    throw mergeError
                }
            }
            catch var error as NSError
            {
                if error.localizedTitle == nil
                {
                    error = error.withLocalizedTitle(NSLocalizedString("Unable to Refresh Store", comment: ""))
                }
                
                DispatchQueue.main.async {
                    self.updateSourcesResult = .failure(error)
                    completion(.failure(error))
                }
            }
        }
    }

    @discardableResult
    func install<T: AppProtocol>(_ app: T, presentingViewController: UIViewController?, context: AuthenticatedOperationContext? = nil, completionHandler: @escaping (Result<InstalledApp, Error>) -> Void) -> RefreshGroup
    {
        debugLog("[AppManager] install() called for app: \(app.bundleIdentifier)")
        if context != nil {
            debugLog("[AppManager] install invoked using existing context for app: \(app.bundleIdentifier)")
        }
        let pipelineHandler = self.makePipelineHandler(presentingViewController: presentingViewController)
        let context = self.makeAuthenticatedContext(presentingViewController: presentingViewController, baseContext: context)
        return self.pipelineRunner.performSingleOperation(
            .install(app), 
            handler: pipelineHandler, 
            context: context, 
            completionHandler: completionHandler
        )
    }

    func installIPA(at ipaURL: URL, progressHandler: ((Progress) -> Void)? = nil) async throws -> InstalledApp
    {
        debugLog("[AppManager] installIPA() called for file: \(ipaURL.lastPathComponent)")
        guard ipaURL.pathExtension.lowercased() == "ipa" else { throw OperationError.invalidApp }

        let temporaryDirectory = FileManager.default.uniqueTemporaryURL()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let unzippedAppDirectory = temporaryDirectory.appendingPathComponent("App")
        try FileManager.default.createDirectory(at: unzippedAppDirectory, withIntermediateDirectories: true)

        let unzippedApplicationURL = try FileManager.default.unzipAppBundle(at: ipaURL, toDirectory: unzippedAppDirectory)
        guard let appBundle = ALTApplication(fileURL: unzippedApplicationURL) else { throw OperationError.invalidApp }

        let context = self.makeAuthenticatedContext(presentingViewController: nil)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<InstalledApp, Error>) in
            let group = self.install(appBundle, presentingViewController: nil, context: context) { result in
                continuation.resume(with: result)
            }

            progressHandler?(group.progress)
        }
    }
    
    @discardableResult
    func update(_ installedApp: InstalledApp, to version: AppVersion? = nil, presentingViewController: UIViewController?, completionHandler: @escaping (Result<InstalledApp, Error>) -> Void) -> Progress
    {
        debugLog("[AppManager] update() called for app: \(installedApp.bundleIdentifier)")
        guard let appVersion = version ?? installedApp.storeApp?.latestSupportedVersion else {
            completionHandler(.failure(OperationError.appNotFound(name: installedApp.name)))
            return Progress.discreteProgress(totalUnitCount: 1)
        }
        guard appVersion as AnyObject !== installedApp else {
            completionHandler(.failure(OperationError.invalidParameters("Make sure we never accidentally 'update' to already installed app.")))
            return Progress.discreteProgress(totalUnitCount: 1)
        }
        let pipelineHandler = self.makePipelineHandler(presentingViewController: presentingViewController)
        let context = self.makeAuthenticatedContext(presentingViewController: presentingViewController)
        let group = self.pipelineRunner.performSingleOperation(
            .update(appVersion, customBundleIdentifier: installedApp.customBundleIdentifier), 
            handler: pipelineHandler, 
            context: context, 
            completionHandler: completionHandler
        )
        return group.progress
    }
    
    @discardableResult
    func refresh(_ installedApps: [InstalledApp], presentingViewController: UIViewController?, group: RefreshGroup? = nil) -> RefreshGroup
    {
        debugLog("[AppManager] refresh() called for apps: \(installedApps.map { $0.bundleIdentifier })")
        let pipelineHandler = self.makePipelineHandler(presentingViewController: presentingViewController)
        
        let actualGroup: RefreshGroup
        if let group = group {
            actualGroup = group
        } else {
            let context = self.makeAuthenticatedContext(presentingViewController: presentingViewController)
            actualGroup = RefreshGroup(context: context)
        }
        
        actualGroup.activeTask = Task.detached {
            do {
                try await self.pipelineRunner.perform(installedApps.map { .refresh($0) }, handler: pipelineHandler, group: actualGroup)
            } catch {
                actualGroup.context.error = error
                let results = Dictionary(uniqueKeysWithValues: installedApps.map { ($0.bundleIdentifier, Result<InstalledApp, Error>.failure(error)) })
                actualGroup.completionHandler?(results)
            }
        }
        
        return actualGroup
    }
    
    func activate(_ installedApp: InstalledApp, presentingViewController: UIViewController?, completionHandler: @escaping (Result<InstalledApp, Error>) -> Void)
    {
        debugLog("[AppManager] activate() called for app: \(installedApp.bundleIdentifier)")
        let pipelineHandler = self.makePipelineHandler(presentingViewController: presentingViewController)
        let context = self.makeAuthenticatedContext(presentingViewController: presentingViewController)
        self.pipelineRunner.performSingleOperation(.activate(installedApp), handler: pipelineHandler, context: context, completionHandler: completionHandler)
    }
    
    func deactivate(_ installedApp: InstalledApp, presentingViewController: UIViewController?, completionHandler: @escaping (Result<InstalledApp, Error>) -> Void)
    {
        debugLog("[AppManager] deactivate() called for app: \(installedApp.bundleIdentifier)")
        let pipelineHandler = self.makePipelineHandler(presentingViewController: presentingViewController)
        let context = self.makeAuthenticatedContext(presentingViewController: presentingViewController)
        self.pipelineRunner.performSingleOperation(.deactivate(installedApp), handler: pipelineHandler, context: context, completionHandler: completionHandler)
    }
    
    func deleteApp(_ installedApp: InstalledApp, presentingViewController: UIViewController?, completionHandler: @escaping (Result<InstalledApp, Error>) -> Void)
    {
        debugLog("[AppManager] deleteApp() called for app: \(installedApp.bundleIdentifier)")
        let pipelineHandler = self.makePipelineHandler(presentingViewController: presentingViewController)
        let context = self.makeAuthenticatedContext(presentingViewController: presentingViewController)
        self.pipelineRunner.performSingleOperation(.deleteApp(installedApp), handler: pipelineHandler, context: context, completionHandler: completionHandler)
    }
    
    @discardableResult
    func resign(_ installedApp: InstalledApp, alternateIconMode: AlternateIconMode = .preserve, presentingViewController: UIViewController?, completionHandler: @escaping (Result<InstalledApp, Error>) -> Void) -> RefreshGroup
    {
        debugLog("[AppManager] resign() called for app: \(installedApp.bundleIdentifier)")
        let pipelineHandler = self.makePipelineHandler(presentingViewController: presentingViewController)
        let context = self.makeAuthenticatedContext(presentingViewController: presentingViewController)
        return self.pipelineRunner.performSingleOperation(.resign(installedApp, alternateIconMode: alternateIconMode), handler: pipelineHandler, context: context, completionHandler: completionHandler)
    }
    
    func backup(_ installedApp: InstalledApp, presentingViewController: UIViewController?, completionHandler: @escaping (Result<InstalledApp, Error>) -> Void)
    {
        debugLog("[AppManager] backup() called for app: \(installedApp.bundleIdentifier)")
        let pipelineHandler = self.makePipelineHandler(presentingViewController: presentingViewController)
        let context = self.makeAuthenticatedContext(presentingViewController: presentingViewController)
        self.pipelineRunner.performSingleOperation(.backup(installedApp), handler: pipelineHandler, context: context, completionHandler: completionHandler)
    }
    
    func restore(_ installedApp: InstalledApp, presentingViewController: UIViewController?, completionHandler: @escaping (Result<InstalledApp, Error>) -> Void)
    {
        debugLog("[AppManager] restore() called for app: \(installedApp.bundleIdentifier)")
        let pipelineHandler = self.makePipelineHandler(presentingViewController: presentingViewController)
        let context = self.makeAuthenticatedContext(presentingViewController: presentingViewController)
        self.pipelineRunner.performSingleOperation(.restore(installedApp), handler: pipelineHandler, context: context, completionHandler: completionHandler)
    }
    
    func removeDeactivatedApp(_ installedApp: InstalledApp, completionHandler: @escaping (Result<Void, Error>) -> Void)
    {
        debugLog("[AppManager] removeDeactivatedApp() called for app: \(installedApp.bundleIdentifier)")
        let pipelineHandler = self.makePipelineHandler(presentingViewController: nil)
        let context = self.makeAuthenticatedContext(presentingViewController: nil)
        self.pipelineRunner.performVoidOperation(.removeDeactivatedApp(installedApp), handler: pipelineHandler, context: context, completionHandler: completionHandler)
    }
    }
    
    func enableJIT(for installedApp: InstalledApp, completionHandler: @escaping (Result<Void, Error>) -> Void)
    {
        debugLog("[AppManager] enableJIT() called for app: \(installedApp.bundleIdentifier)")
        let pipelineHandler = self.makePipelineHandler(presentingViewController: nil)
        let context = self.makeAuthenticatedContext(presentingViewController: nil)
        self.pipelineRunner.performVoidOperation(.enableJIT(installedApp), handler: pipelineHandler, context: context, completionHandler: completionHandler)
    }

    @discardableResult
    func backgroundRefresh(_ installedApps: [InstalledApp],
                           presentsNotifications: Bool = false,
                           completionHandler: @escaping (Result<[String: Result<InstalledApp, Error>], Error>) -> Void) throws -> BackgroundRefreshAppsOperation
    {
        let dbBackgroundContext = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let context = StandaloneOperationContext(steps: .backgroundRefreshApps, dbBackgroundContext: dbBackgroundContext)
        let backgroundRefreshAppsOperation = try BackgroundRefreshAppsOperation(installedApps: installedApps, context: context)
        Task.detached {
            do {
                backgroundRefreshAppsOperation.presentsFinishedNotification = presentsNotifications
                
                let result = try await backgroundRefreshAppsOperation.execute()
                completionHandler(.success(result))
            } catch {
                completionHandler(.failure(error))
            }
        }
        return backgroundRefreshAppsOperation
    }


    
    func installationProgress(for app: AppProtocol) -> Progress?
    {
        return self.progressLock.withLock {
            self.installationProgress[app.bundleIdentifier]
        }
    }
    
    func refreshProgress(for app: AppProtocol) -> Progress?
    {
        return self.progressLock.withLock {
            let bundleID = app.bundleIdentifier
            
            guard let progress = self.refreshProgress[bundleID] ?? self.installationProgress[bundleID] else {
                return nil
            }
            
            guard !progress.isCancelled else {
                self.refreshProgress[bundleID] = nil
                self.installationProgress[bundleID] = nil
                return nil
            }
            
            return progress
        }
    }
    
    func isActivelyManagingApp(withBundleID bundleID: String) -> Bool
    {
        let isActivelyManaging = self.installationProgress.keys.contains(bundleID) || self.refreshProgress.keys.contains(bundleID)
        return isActivelyManaging
    }
    
    var isActivelyManagingAnyApp: Bool
    {
        return self.progressLock.withLock {
            !self.installationProgress.isEmpty || !self.refreshProgress.isEmpty
        }
    }
    private func perform(_ operations: [AppOperation], presentingViewController: UIViewController?, group: RefreshGroup) async throws -> RefreshGroup
    {
        let operations = operations.filter { self.progress(for: $0) == nil || self.progress(for: $0)?.isCancelled == true }
        
        for operation in operations
        {
            let progress = Progress.discreteProgress(totalUnitCount: 100)
            self.set(progress, for: operation)
        }
        
        if let viewController = presentingViewController
        {
            group.context.presentingViewController = viewController
        }
        
        /* Authenticate (if necessary) */
        var authenticationOperation: AuthenticationOperation?
        if group.context.session == nil
        {
            authenticationOperation = self.authenticate(presentingViewController: presentingViewController, context: group.context, skipDeviceRegistration: false) { (result) in
                switch result
                {
                case .failure(let error):
                    group.context.error = error
                case .success:
                    break
                }
            }
        }
        
        func performAppOperations()
        {
            for operation in operations
            {
                let progress = self.progress(for: operation)
                
                if let progress = progress
                {
                    group.progress.totalUnitCount += 1
                    group.progress.addChild(progress, withPendingUnitCount: 1)
                    
                    if group.context.session != nil
                    {
                        // Finished authenticating, so increase completed unit count.
                        progress.completedUnitCount += 20
                    }
                }
                
                switch operation
                {
                case .install(let app, let customBundleIdentifier):
                    let installProgress = self._install(app, customBundleIdentifier: customBundleIdentifier, operation: operation, group: group, reviewPermissions: .all) { (result) in
                        self.finish(operation, result: result, group: group, progress: progress)
                    }
                    progress?.addChild(installProgress, withPendingUnitCount: 80)
                    
                case .update(let app, let customBundleIdentifier):
                    let updateProgress = self._install(app, customBundleIdentifier: customBundleIdentifier, operation: operation, group: group, reviewPermissions: .added) { (result) in
                        self.finish(operation, result: result, group: group, progress: progress)
                    }
                    progress?.addChild(updateProgress, withPendingUnitCount: 80)
                    
                case .resign(let app, _):
                    let resignProgress = self._install(app, operation: operation, group: group, reviewPermissions: .none) { (result) in
                        self.finish(operation, result: result, group: group, progress: progress)
                    }
                    progress?.addChild(resignProgress, withPendingUnitCount: 80)
                    
                case .activate(let app) where UserDefaults.standard.isLegacyDeactivationSupported: fallthrough
                case .refresh(let app):
                    let refreshProgress = self._refresh(app, operation: operation, group: group) { (result) in
                        self.finish(operation, result: result, group: group, progress: progress)
                    }
                    progress?.addChild(refreshProgress, withPendingUnitCount: 80)
                case .activate(let app):
                    let activateProgress = self._activate(app, operation: operation, group: group) { (result) in
                        self.finish(operation, result: result, group: group, progress: progress)
                    }
                    progress?.addChild(activateProgress, withPendingUnitCount: 80)
                    
                case .deactivate(let app):
                    let deactivateProgress = self._deactivate(app, operation: operation, group: group) { (result) in
                        self.finish(operation, result: result, group: group, progress: progress)
                    }
                    progress?.addChild(deactivateProgress, withPendingUnitCount: 80)
                    
                case .backup(let app):
                    let backupProgress = self._backup(app, operation: operation, group: group) { (result) in
                        self.finish(operation, result: result, group: group, progress: progress)
                    }
                    progress?.addChild(backupProgress, withPendingUnitCount: 80)
                    
                case .restore(let app):
                    // Restoring, which is effectively just activating an app.
                    
                    let activateProgress = self._activate(app, operation: operation, group: group) { (result) in
                        self.finish(operation, result: result, group: group, progress: progress)
                    }
                    progress?.addChild(activateProgress, withPendingUnitCount: 80)
                }
            }
        }
        
        if let authenticationOperation = authenticationOperation
        {
            let awaitAuthenticationOperation = BlockOperation {
                if let managedObjectContext = operations.lazy.compactMap({ ($0.app as? NSManagedObject)?.managedObjectContext }).first
                {
                    managedObjectContext.perform { performAppOperations() }
                }
                else
                {
                    performAppOperations()
                }
            }
            awaitAuthenticationOperation.addDependency(authenticationOperation)
            self.run([awaitAuthenticationOperation], context: group.context, requiresSerialQueue: true)
        }
        else
        {
            // Disable the idleTimeout
            DispatchQueue.main.schedule {
                if !UIApplication.shared.isIdleTimerDisabled {       // accept only once if concurrent
                    UIApplication.shared.isIdleTimerDisabled = UserDefaults.standard.isIdleTimeoutDisableEnabled
                }
            }
            performAppOperations()
        }
        
        return group
    }
    
    private func _install(_ app: AppProtocol,
                          customBundleIdentifier: String? = nil,
                          operation appOperation: AppOperation,
                          group: RefreshGroup,
                          context: InstallAppOperationContext? = nil,
                          additionalEntitlements: [ALTEntitlement: Any]? = [.increasedDebuggingMemoryLimit: ALTEntitlement.increasedDebuggingMemoryLimit, .increasedMemoryLimit: ALTEntitlement.increasedMemoryLimit, .extendedVirtualAddressing: ALTEntitlement.extendedVirtualAddressing],
                          reviewPermissions permissionReviewMode: VerifyAppOperation.PermissionReviewMode = .none,
                          cacheApp: Bool = true,
                          completionHandler: @escaping (Result<InstalledApp, Error>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 100)
        
        let context = InstallAppOperationContext(bundleIdentifier: app.bundleIdentifier, authenticatedContext: group.context)
        context.customBundleIdentifier = customBundleIdentifier ?? (app as? InstalledApp)?.customBundleIdentifier
        assert(context.authenticatedContext === group.context)
        
        context.beginInstallationHandler = { (installedApp) in
            group.beginInstallationHandler?(installedApp)
        }
        

        var downloadingApp = app
        
        if let installedApp = app as? InstalledApp
        {
            if case .resign = appOperation {
                // For resign, we MUST use the cached app bundle and not download from the store/web
                downloadingApp = installedApp
            }
            else if let storeApp = installedApp.storeApp, !FileManager.default.fileExists(atPath: installedApp.fileURL.path)
            {
                // Cached app has been deleted, so we need to redownload it.
                downloadingApp = storeApp
            }
            
            if case .resign(_, let mode) = appOperation {
                context.alternateIconMode = mode
            }
        }
        
        /* Download */
        let downloadedAppURL = context.temporaryDirectory.appendingPathComponent("Cached.app")
        let downloadOperation = DownloadAppOperation(app: downloadingApp, destinationURL: downloadedAppURL, context: context)
        downloadOperation.resultHandler = { (result) in
            do
            {
                let app = try result.get()
                context.app = app
                
                if cacheApp
                {
                    let updatedApp = AnyApp(from: app, bundleId: context.targetBundleIdentifier)
                    try FileManager.default.copyItem(at: app.fileURL, to: InstalledApp.fileURL(for: updatedApp), shouldReplace: true)
                }
            }
            catch
            {
                context.error = error
            }
        }
        progress.addChild(downloadOperation.progress, withPendingUnitCount: 25)
        
        /* Verify App */
        let permissionsMode = UserDefaults.shared.permissionCheckingDisabled ? .none : permissionReviewMode
        let verifyOperation = VerifyAppOperation(permissionsMode: permissionsMode, context: context)
        verifyOperation.resultHandler = { (result) in
            do
            {
                try result.get()
                
                // Wait until we've finished verifying app before caching it.
                if let app = context.app, cacheApp
                {
                    try FileManager.default.copyItem(at: app.fileURL, to: InstalledApp.fileURL(for: app), shouldReplace: true)
                }
            }
            catch
            {
                context.error = error
            }
        }
        verifyOperation.addDependency(downloadOperation)
        
        /* Remove App Extensions */
        let localAppExtensions = (app as? ALTApplication)?.appExtensions
        let removeAppExtensionsOperation = RemoveAppExtensionsOperation(context: context,
                                                                        localAppExtensions: localAppExtensions)
        removeAppExtensionsOperation.resultHandler = { (result) in
            switch result
            {
            case .failure(let error):
                context.error = error
            case .success: break
            }
        }
        removeAppExtensionsOperation.addDependency(verifyOperation)

        
        /* Refresh Anisette Data */
        let refreshAnisetteDataOperation = FetchAnisetteDataOperation(context: group.context)
        refreshAnisetteDataOperation.resultHandler = { (result) in
            switch result
            {
            case .failure(let error):
                context.error = error
            case .success(let anisetteData): group.context.session?.anisetteData = anisetteData
            }
        }
        refreshAnisetteDataOperation.addDependency(removeAppExtensionsOperation)


        /* Fetch Provisioning Profiles */
        let fetchProvisioningProfilesOperation = FetchProvisioningProfilesInstallOperation(context: context)
        fetchProvisioningProfilesOperation.additionalEntitlements = additionalEntitlements
        fetchProvisioningProfilesOperation.resultHandler = { (result) in
            switch result
            {
            case .failure(let error):
                context.error = error
            case .success(let provisioningProfiles):
                context.provisioningProfiles = provisioningProfiles
                debugLog("PROVISIONING PROFILES \(context.provisioningProfiles)")
            }
        }
        fetchProvisioningProfilesOperation.addDependency(refreshAnisetteDataOperation)
        progress.addChild(fetchProvisioningProfilesOperation.progress, withPendingUnitCount: 5)


        /* Deactivate Apps (if necessary) */
        let deactivateAppsOperation = RSTAsyncBlockOperation { [weak self] (operation) in
            do
            {
                // Only attempt to deactivate apps if we're installing a new app.
                // We handle deactivating apps separately when activating an app.
                guard case .install = appOperation else {
                    operation.finish()
                    return
                }
                
                if let error = context.error
                {
                    throw error
                }
                
                guard let profiles = context.provisioningProfiles else {
                    throw OperationError.invalidParameters("AppManager._install.deactivateAppsOperation: context.provisioningProfiles is nil")
                }
                if !profiles.contains(where: { $1.isFreeProvisioningProfile == true }) {
                    operation.finish()
                    return
                }
                                
                guard let app = context.app else {
                    throw OperationError.invalidParameters("AppManager._install.deactivateAppsOperation: self.context.app is nil")
                }

                self?.deactivateApps(for: app, presentingViewController: context.authenticatedContext.presentingViewController) { result in
                    switch result
                    {
                    case .failure(let error): group.context.error = error
                    case .success: break
                    }
                    
                    operation.finish()
                }
            }
            catch
            {
                group.context.error = error
                operation.finish()
            }
        }
        deactivateAppsOperation.addDependency(fetchProvisioningProfilesOperation)

        let modifyAppExBundleIdOperation = RSTAsyncBlockOperation { operation in
            if !context.useMainProfile {
                operation.finish()
                return
            }
            
            if let app = context.app, let profile = context.provisioningProfiles?[context.bundleIdentifier] {
                var appexBundleIds: [String: String] = [:]
                for appex in app.appExtensions {
                    appexBundleIds[appex.bundleIdentifier] = appex.bundleIdentifier.replacingOccurrences(of: app.bundleIdentifier, with: profile.bundleIdentifier)
                }
                context.appexBundleIds = appexBundleIds
            }
            operation.finish()
            
        }
        modifyAppExBundleIdOperation.addDependency(fetchProvisioningProfilesOperation)
        
        /* Patch App Icon */
        let patchAppIconOperation = PatchAppIconOperation(context: context)
        patchAppIconOperation.resultHandler = { (result) in
            switch result
            {
            case .failure(let error):
                context.error = error
            case .success:
                debugLog("App icon patched successfully for \(context.targetBundleIdentifier)")
            }
        }
        patchAppIconOperation.addDependency(deactivateAppsOperation)
        patchAppIconOperation.addDependency(modifyAppExBundleIdOperation)
        
        /* Resign */
        let resignAppOperation = ResignAppOperation(context: context)
        resignAppOperation.resultHandler = { (result) in
            switch result
            {
            case .failure(let error):
                context.error = error
            case .success(let resignedApp):
                context.resignedApp = resignedApp
                
                self.exportResginedAppsToDocsDir(resignedApp)
            }
        }
        resignAppOperation.addDependency(patchAppIconOperation)
        progress.addChild(resignAppOperation.progress, withPendingUnitCount: 20)
        
        
        /* Send */
        let sendAppOperation = SendAppOperation(context: context)
        sendAppOperation.resultHandler = { (result) in
            switch result
            {
            case .failure(let error):
                context.error = error
            case .success(_): debugLog("App reported as installed")
            }
        }
        sendAppOperation.addDependency(resignAppOperation)
        progress.addChild(sendAppOperation.progress, withPendingUnitCount: 20)
        
        
        /* Install */
        let installOperation = InstallAppOperation(context: context)
        installOperation.resultHandler = { (result) in
            switch result
            {
            case .failure(let error): completionHandler(.failure(error))
            case .success(let installedApp):
                context.installedApp = installedApp
                
                if let app = app as? StoreApp, let storeApp = installedApp.managedObjectContext?.object(with: app.objectID) as? StoreApp
                {
                    installedApp.storeApp = storeApp
                }
                
                if let index = UserDefaults.standard.legacySideloadedApps?.firstIndex(of: installedApp.bundleIdentifier)
                {
                    // No longer a legacy sideloaded app, so remove it from cached list.
                    UserDefaults.standard.legacySideloadedApps?.remove(at: index)
                }
                
                completionHandler(.success(installedApp))
            }
        }
        progress.addChild(installOperation.progress, withPendingUnitCount: 30)
        installOperation.addDependency(sendAppOperation)
        
        // Operations picked for request
        var operations = [
            downloadOperation,
            verifyOperation,
            removeAppExtensionsOperation,
            deactivateAppsOperation,
            refreshAnisetteDataOperation,
            fetchProvisioningProfilesOperation,
            modifyAppExBundleIdOperation,
            patchAppIconOperation,
            resignAppOperation,
            sendAppOperation,
            installOperation
        ].compactMap { $0 }
        
        group.add(operations)
        
        if let storeApp = downloadingApp.storeApp, storeApp.isPledgeRequired
        {
            self.run([downloadOperation], context: group.context, requiresSerialQueue: true)
            
            if let index = operations.firstIndex(of: downloadOperation)
            {
                // Remove downloadOperation from operations to prevent running it twice.
                operations.remove(at: index)
            }
        }

        self.run(operations, context: group.context)
        
        return progress
    }
    
    private func exportResginedAppsToDocsDir(_ resignedApp: ALTApplication)
    {
        // Check if the user has enabled exporting resigned apps to the Documents directory and continue
        guard UserDefaults.standard.isExportResignedAppEnabled else {
            return
        }
        
        let sourceURL = resignedApp.fileURL
        
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let resignedAppsURL = documentsURL.appendingPathComponent("ResignedApps")
        // Create the ResignedApps subfolder if it doesn't exist
        do {
            if !FileManager.default.fileExists(atPath: resignedAppsURL.path) {
                try FileManager.default.createDirectory(at: resignedAppsURL, withIntermediateDirectories: true, attributes: nil)
            }
        } catch {
            debugLog("Failed to create ResignedApps folder: \(error)")
            return
        }
        
//        let destinationURL = resignedAppsURL.appendingPathComponent(sourceURL.lastPathComponent)
        let utis = Bundle(url: resignedApp.fileURL)?.infoDictionary?[Bundle.Info.exportedUTIs] as? [[String: Any]]
        let isSideBackup = utis?.first?["UTTypeDescription"] as? String == "SideStore Backup App"
        
        let destPath = isSideBackup ? resignedApp.name + "-sidebackup" : resignedApp.name
        let destinationURL = resignedAppsURL.appendingPathComponent(destPath + ".app")
        
        // Delete the existing file if it exists
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
        } catch {
            debugLog("Failed to delete existing file at destination: \(error)")
            return
        }
        
        // Copy the file to the ResignedApps folder
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            debugLog("File copied to: \(destinationURL.path)")
        } catch {
            debugLog("Failed to copy file: \(error)")
        }
    }
    
    
    private func _refresh(_ app: InstalledApp, operation: AppOperation, group: RefreshGroup, completionHandler: @escaping (Result<InstalledApp, Error>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 100)
        
        let context = AppOperationContext(bundleIdentifier: app.bundleIdentifier, authenticatedContext: group.context)
        context.customBundleIdentifier = app.customBundleIdentifier
        context.app = ALTApplication(fileURL: app.fileURL)
        context.useMainProfile = app.useMainProfile

        let activeSerial = group.context.certificate?.serialNumber ?? (Keychain.shared.signingCertificate.flatMap { try? ALTCertificate(p12Data: $0, password: nil) }?.serialNumber)
        if let activeSerial = activeSerial,
           let appSerial = app.certificateSerialNumber,
           activeSerial != appSerial
        {
            if group.context.presentingViewController == nil
            {
                debugLog("AppManager.refresh: Certificate mismatch detected in headless mode for \(app.name). Active: \(activeSerial), App: \(appSerial). Auto-resigning instead of throwing mismatch error.")
                let resignProgress = self._install(app, operation: .resign(app), group: group, reviewPermissions: .none) { (result) in
                    completionHandler(result)
                }
                return resignProgress
            }
            else
            {
                debugLog("AppManager.refresh: Certificate mismatch detected for \(app.name). Active Certificate SN: \(activeSerial), Target Certificate SN: \(appSerial).")
                let errMessage = "The certificate used to sign “\(app.name)” has been revoked or changed. Please reinstall the app to re-sign it with the new active certificate."
                context.error = OperationError.refreshAppFailed(message: errMessage)
            }
        }
        
        if context.error == nil
        {
            // Since this doesn't involve modifying app bundle which will cause re-install, this is safe in refresh path
            // App-Extensions: Ensure DB data and disk state must match
            let dbAppEx: Set<InstalledExtension> = Set(app.appExtensions)
            if let appObj = context.app {
                let diskAppEx: Set<ALTApplication> = Set(appObj.appExtensions)
                let diskAppExNames = diskAppEx.map { $0.bundleIdentifier }
                let dbAppExNames = dbAppEx.map { $0.bundleIdentifier }
                let isMatching = Set(dbAppExNames) == Set(diskAppExNames)
                
                if !isMatching {
                    let errMessage = "AppManager.refresh: App Extensions in DB and Disk are matching: \(isMatching)\n"
                                   + "AppManager.refresh: dbAppEx: \(dbAppExNames); diskAppEx: \(String(describing: diskAppExNames))\n"
                    debugLog(errMessage)
                    context.error = OperationError.refreshAppFailed(message: errMessage)
                }
            }
        }
        
        /* Fetch Provisioning Profiles */
        let fetchProvisioningProfilesOperation = FetchProvisioningProfilesRefreshOperation(context: context)
        fetchProvisioningProfilesOperation.resultHandler = { (result) in
            switch result
            {
            case .failure(let error):
                context.error = error
            case .success(let provisioningProfiles): context.provisioningProfiles = provisioningProfiles
            }
        }
        progress.addChild(fetchProvisioningProfilesOperation.progress, withPendingUnitCount: 60)
        // fetchProvisioningProfilesOperation.addDependency(validateAppExtensionsOperation)

        /* Refresh */
        let refreshAppOperation = RefreshAppOperation(context: context)
        refreshAppOperation.resultHandler = { (result) in
            Task {
                switch result
                {
                case .success(let installedApp):
                    completionHandler(.success(installedApp))


                case .failure(let error) where error.isMinimuxerNoConnection:
                    completionHandler(.failure(OperationError.noConnection))
                    
                case .failure(let error) where error.isMinimuxerNoVPN:
                    completionHandler(.failure(OperationError.noVPN))

                case .failure(let error) where error.isMinimuxerProfileInstall:
                    let error = await getMinimuxerStatus().operationError ?? error
                    completionHandler(.failure(error))
                    
                case .failure(ALTServerError.unknownRequest), .failure(OperationError.appNotFound(name: app.name)):
                    // Fall back to installation if AltServer doesn't support newer provisioning profile requests,
                    // OR if the cached app could not be found and we may need to redownload it.
                    app.managedObjectContext?.performAndWait { // Must performAndWait to ensure we add operations before we return.
                        Task {
                            switch await getMinimuxerStatus() {
                            case .ready:
                                let installProgress = self._install(app, operation: operation, group: group) { (result) in
                                    completionHandler(result)
                                }
                                progress.addChild(installProgress, withPendingUnitCount: 40)
                            case let status:
                                let error = status.operationError ?? OperationError.unknown()
                                completionHandler(.failure(error))
                            }
                        }
                    }
                    
                case .failure(let error):
                    completionHandler(.failure(error))
                }
            }
        }
        progress.addChild(refreshAppOperation.progress, withPendingUnitCount: 40)
        refreshAppOperation.addDependency(fetchProvisioningProfilesOperation)
        
//        let operations = [validateAppExtensionsOperation, fetchProvisioningProfilesOperation, refreshAppOperation]
        let operations = [fetchProvisioningProfilesOperation, refreshAppOperation]
        group.add(operations)
        self.run(operations, context: group.context)

        return progress
    }
    
    private func _activate(_ app: InstalledApp, operation appOperation: AppOperation, group: RefreshGroup, completionHandler: @escaping (Result<InstalledApp, Error>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 100)
        
        let restoreContext = InstallAppOperationContext(bundleIdentifier: app.bundleIdentifier, authenticatedContext: group.context)
        restoreContext.customBundleIdentifier = app.customBundleIdentifier
        let appContext = InstallAppOperationContext(bundleIdentifier: app.bundleIdentifier, authenticatedContext: group.context)
        appContext.customBundleIdentifier = app.customBundleIdentifier
        
        let installBackupAppProgress = Progress.discreteProgress(totalUnitCount: 100)
        let installBackupAppOperation = RSTAsyncBlockOperation { [weak self] (operation) in
            app.managedObjectContext?.perform {
                guard let self = self else { return }
                
                let progress = self._installBackupApp(for: app, operation: appOperation, group: group, context: restoreContext) { (result) in
                    switch result
                    {
                    case .success(let installedApp): restoreContext.installedApp = installedApp
                    case .failure(let error):
                        restoreContext.error = error
                        appContext.error = error
                    }
                    
                    operation.finish()
                }
                installBackupAppProgress.addChild(progress, withPendingUnitCount: 100)
            }
        }
        progress.addChild(installBackupAppProgress, withPendingUnitCount: 30)
        
        let restoreAppOperation = BackupAppOperation(action: .restore, context: restoreContext)
        restoreAppOperation.resultHandler = { (result) in
            switch result
            {
            case .success: break
            case .failure(let error):
                restoreContext.error = error
                appContext.error = error
            }
        }
        restoreAppOperation.addDependency(installBackupAppOperation)
        progress.addChild(restoreAppOperation.progress, withPendingUnitCount: 15)
        
        let installAppProgress = Progress.discreteProgress(totalUnitCount: 100)
        let installAppOperation = RSTAsyncBlockOperation { [weak self] (operation) in
            app.managedObjectContext?.perform {
                guard let self = self else { return }
                
                let progress = self._install(app, operation: appOperation, group: group, context: appContext) { (result) in
                    switch result
                    {
                    case .success(let installedApp): appContext.installedApp = installedApp
                    case .failure(let error): appContext.error = error
                    }
                    
                    operation.finish()
                }
                installAppProgress.addChild(progress, withPendingUnitCount: 100)
            }
        }
        installAppOperation.addDependency(restoreAppOperation)
        progress.addChild(installAppProgress, withPendingUnitCount: 50)
        
        let cleanUpProgress = Progress.discreteProgress(totalUnitCount: 100)
        let cleanUpOperation = RSTAsyncBlockOperation { (operation) in
            do
            {
                let installedApp = try Result(appContext.installedApp, appContext.error).get()
                
                var result: Result<Void, Error>!
                installedApp.managedObjectContext?.performAndWait {
                    result = Result { try installedApp.managedObjectContext?.save() }
                }
                try result.get()
                
                // Successfully saved, so _now_ we can remove backup.
                
                let removeAppBackupOperation = RemoveAppBackupOperation(context: appContext)
                removeAppBackupOperation.resultHandler = { (result) in
                    installedApp.managedObjectContext?.perform {
                        switch result
                        {
                        case .failure(let error):
                            // Don't report error, since it doesn't really matter.
                            debugLog("Failed to delete app backup. \(error)")
                            
                        case .success: break
                        }
                        
                        completionHandler(.success(installedApp))
                        operation.finish()
                    }
                }
                cleanUpProgress.addChild(removeAppBackupOperation.progress, withPendingUnitCount: 100)
                
                group.add([removeAppBackupOperation])
                self.run([removeAppBackupOperation], context: group.context)
            }
            catch let error where restoreContext.installedApp != nil
            {
                // Activation failed, but restore app was installed, so remove the app.
                
                // Remove error so operation doesn't quit early,
                restoreContext.error = nil
                
                let removeAppOperation = RemoveAppOperation(context: restoreContext)
                removeAppOperation.resultHandler = { (result) in
                    completionHandler(.failure(error))
                    operation.finish()
                }
                cleanUpProgress.addChild(removeAppOperation.progress, withPendingUnitCount: 100)
                
                group.add([removeAppOperation])
                self.run([removeAppOperation], context: group.context)
            }
            catch
            {
                // Activation failed.
                completionHandler(.failure(error))
                operation.finish()
            }
        }
        cleanUpOperation.addDependency(installAppOperation)
        progress.addChild(cleanUpProgress, withPendingUnitCount: 5)
        
        group.add([installBackupAppOperation, restoreAppOperation, installAppOperation, cleanUpOperation])
        self.run([installBackupAppOperation, installAppOperation, restoreAppOperation, cleanUpOperation], context: group.context)
        
        return progress
    }
    
    private func _deactivate(_ app: InstalledApp, operation appOperation: AppOperation, group: RefreshGroup, completionHandler: @escaping (Result<InstalledApp, Error>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 100)
        let context = InstallAppOperationContext(bundleIdentifier: app.bundleIdentifier, authenticatedContext: group.context)
        context.customBundleIdentifier = app.customBundleIdentifier
        
        let installBackupAppProgress = Progress.discreteProgress(totalUnitCount: 100)
        let installBackupAppOperation = RSTAsyncBlockOperation { [weak self] (operation) in
            app.managedObjectContext?.perform {
                guard let self = self else { return }
                
                let progress = self._installBackupApp(for: app, operation: appOperation, group: group, context: context) { (result) in
                    switch result
                    {
                    case .success(let installedApp): context.installedApp = installedApp
                    case .failure(let error): context.error = error
                    }
                    
                    operation.finish()
                }
                installBackupAppProgress.addChild(progress, withPendingUnitCount: 100)
            }
        }
        progress.addChild(installBackupAppProgress, withPendingUnitCount: 70)
                    
        let backupAppOperation = BackupAppOperation(action: .backup, context: context)
        backupAppOperation.resultHandler = { (result) in
            switch result
            {
            case .failure(let error):
                context.error = error
            case .success: break
            }
        }
        backupAppOperation.addDependency(installBackupAppOperation)
        progress.addChild(backupAppOperation.progress, withPendingUnitCount: 15)
        
        let removeAppOperation = RemoveAppOperation(context: context)
        removeAppOperation.resultHandler = { (result) in
            completionHandler(result)
        }
        removeAppOperation.addDependency(backupAppOperation)
        progress.addChild(removeAppOperation.progress, withPendingUnitCount: 15)
        
        group.add([installBackupAppOperation, backupAppOperation, removeAppOperation])
        self.run([installBackupAppOperation, backupAppOperation, removeAppOperation], context: group.context)
        
        return progress
    }
    
    private func _backup(_ app: InstalledApp, operation appOperation: AppOperation, group: RefreshGroup, completionHandler: @escaping (Result<InstalledApp, Error>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 100)
        
        let restoreContext = InstallAppOperationContext(bundleIdentifier: app.bundleIdentifier, authenticatedContext: group.context)
        restoreContext.customBundleIdentifier = app.customBundleIdentifier
        let appContext = InstallAppOperationContext(bundleIdentifier: app.bundleIdentifier, authenticatedContext: group.context)
        appContext.customBundleIdentifier = app.customBundleIdentifier
        
        let installBackupAppProgress = Progress.discreteProgress(totalUnitCount: 100)
        let installBackupAppOperation = RSTAsyncBlockOperation { [weak self] (operation) in
            app.managedObjectContext?.perform {
                guard let self = self else { return }
                
                let progress = self._installBackupApp(for: app, operation: appOperation, group: group, context: restoreContext) { (result) in
                    switch result
                    {
                    case .success(let installedApp): restoreContext.installedApp = installedApp
                    case .failure(let error):
                        restoreContext.error = error
                        appContext.error = error
                    }
                    
                    operation.finish()
                }
                installBackupAppProgress.addChild(progress, withPendingUnitCount: 100)
            }
        }
        progress.addChild(installBackupAppProgress, withPendingUnitCount: 30)
        
        let backupAppOperation = BackupAppOperation(action: .backup, context: restoreContext)
        backupAppOperation.resultHandler = { (result) in
            switch result
            {
            case .success: break
            case .failure(let error):
                restoreContext.error = error
                appContext.error = error
            }
        }
        backupAppOperation.addDependency(installBackupAppOperation)
        progress.addChild(backupAppOperation.progress, withPendingUnitCount: 15)
        
        let installAppProgress = Progress.discreteProgress(totalUnitCount: 100)
        let installAppOperation = RSTAsyncBlockOperation { [weak self] (operation) in
            app.managedObjectContext?.perform {
                guard let self = self else { return }
                
                let progress = self._install(app, operation: appOperation, group: group, context: appContext) { (result) in
                    completionHandler(result)
                    operation.finish()
                }
                installAppProgress.addChild(progress, withPendingUnitCount: 100)
            }
        }
        installAppOperation.addDependency(backupAppOperation)
        progress.addChild(installAppProgress, withPendingUnitCount: 55)
        
        let operations = [installBackupAppOperation, backupAppOperation, installAppOperation]
        group.add(operations)
        self.run(operations, context: group.context)
        
        return progress
    }
    
    private func _installBackupApp(for app: InstalledApp, operation appOperation: AppOperation, group: RefreshGroup, context: InstallAppOperationContext, completionHandler: @escaping (Result<InstalledApp, Error>) -> Void) -> Progress
    {
        let progress = Progress.discreteProgress(totalUnitCount: 100)
        
        if let error = context.error
        {
            completionHandler(.failure(error))
            return progress
        }
        
        guard let application = ALTApplication(fileURL: app.fileURL) else {
            completionHandler(.failure(OperationError.appNotFound(name: app.name)))
            return progress
        }
        
        let prepareProgress = Progress.discreteProgress(totalUnitCount: 1)
        let prepareOperation = RSTAsyncBlockOperation { (operation) in
            app.managedObjectContext?.perform {
                do
                {
                    let temporaryDirectoryURL = context.temporaryDirectory.appendingPathComponent("SideBackup-" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true, attributes: nil)
                    
                    guard let sidebackupFileURL = Bundle.main.url(forResource: "SideBackup", withExtension: "ipa") else { throw OperationError.appNotFound(name: "SideBackup") }

                    let unzippedAppBundleURL = try FileManager.default.unzipAppBundle(at: sidebackupFileURL, toDirectory: temporaryDirectoryURL)
                    guard let unzippedAppBundle = Bundle(url: unzippedAppBundleURL) else { throw OperationError.invalidApp }
                    
                    if var infoDictionary = unzippedAppBundle.infoDictionary
                    {
                        // Replace name + bundle identifier so AltStore treats it as the same app.
                        infoDictionary["CFBundleDisplayName"] = app.name
                        infoDictionary[kCFBundleIdentifierKey as String] = context.targetBundleIdentifier
                        
                        // Add app-specific exported UTI so we can check later if this temporary backup app is still installed or not.
                        let installedAppUTI = ["UTTypeConformsTo": [],
                                               "UTTypeDescription": "SideStore Backup App",
                                               "UTTypeIconFiles": [],
                                               "UTTypeIdentifier": app.installedBackupAppUTI,
                                               "UTTypeTagSpecification": [:]] as [String : Any]
                        
                        var exportedUTIs = infoDictionary[Bundle.Info.exportedUTIs] as? [[String: Any]] ?? []
                        exportedUTIs.append(installedAppUTI)
                        infoDictionary[Bundle.Info.exportedUTIs] = exportedUTIs
                        
                        if let cachedApp = ALTApplication(fileURL: app.fileURL), let icon = cachedApp.icon?.resizing(to: CGSize(width: 180, height: 180))
                        {
                            let iconFileURL = unzippedAppBundleURL.appendingPathComponent("AppIcon.png")
                            
                            if let iconData = icon.pngData()
                            {
                                do
                                {
                                    try iconData.write(to: iconFileURL, options: .atomic)
                                    
                                    let bundleIcons = ["CFBundlePrimaryIcon": ["CFBundleIconFiles": [iconFileURL.lastPathComponent]]]
                                    infoDictionary["CFBundleIcons"] = bundleIcons
                                }
                                catch
                                {
                                    debugLog("Failed to write app icon data. \(error)")
                                }
                            }
                        }
                        
                        try (infoDictionary as NSDictionary).write(to: unzippedAppBundle.infoPlistURL)
                    }
                    
                    guard let backupApp = ALTApplication(fileURL: unzippedAppBundleURL) else { throw OperationError.invalidApp }
                    context.app = backupApp
                    
                    prepareProgress.completedUnitCount += 1
                }
                catch
                {
                    debugLog("\(error)")
                    
                    context.error = error
                }
                
                operation.finish()
            }
        }
        progress.addChild(prepareProgress, withPendingUnitCount: 20)
        
        let installProgress = Progress.discreteProgress(totalUnitCount: 100)
        let installOperation = RSTAsyncBlockOperation { [weak self] (operation) in
            guard let self = self else { return }
            
            guard let backupApp = context.app else {
                context.error = OperationError.invalidApp
                operation.finish()
                return
            }
            
            var appGroups = application.entitlements[.appGroups] as? [String] ?? []
            appGroups.append(Bundle.baseAltStoreAppGroupID)
            
            let additionalEntitlements: [ALTEntitlement: Any] = [.appGroups: appGroups]
            let progress = self._install(backupApp, customBundleIdentifier: context.customBundleIdentifier, operation: appOperation, group: group, context: context, additionalEntitlements: additionalEntitlements, cacheApp: false) { (result) in
                completionHandler(result)
                operation.finish()
            }
            installProgress.addChild(progress, withPendingUnitCount: 100)
        }
        installOperation.addDependency(prepareOperation)
        progress.addChild(installProgress, withPendingUnitCount: 80)
        
        group.add([prepareOperation, installOperation])
        self.run([prepareOperation, installOperation], context: group.context)
        
        return progress
    }
    
    func finish(_ operation: AppOperation, result: Result<InstalledApp, Error>, group: RefreshGroup, progress: Progress?)
    {
        // Remove disableIdleTimeout
        // TODO: This should disable for the last finish() request not the first though for batches
        //       probably if we are in batch mode, we can count expected no of finishes() to arrive
        //       and schedule disabling only on last request by matching it with count.
        DispatchQueue.main.schedule {
            if UIApplication.shared.isIdleTimerDisabled {       // accept only once if concurrent
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }

        // Must remove before saving installedApp.
        if let currentProgress = self.progress(for: operation), currentProgress == progress
        {
            // Only remove progress if it hasn't been replaced by another one.
            self.set(nil, for: operation)
        }
        
        do
        {
            let installedApp = try result.get()
            group.set(.success(installedApp), forAppWithBundleIdentifier: installedApp.bundleIdentifier)
            
            if installedApp.bundleIdentifier == StoreApp.altstoreAppID
            {
                self.scheduleExpirationWarningLocalNotification(for: installedApp)
            }
            
            // Ask widgets to be refreshed
            WidgetCenter.shared.reloadAllTimelines()
            
            do 
            {
                try installedApp.managedObjectContext?.save()
            }
            catch
            {
                debugLog("Failed to save InstalledApp to database. \(error.localizedDescription)")
                throw error
            }
        }
        catch let nsError as NSError
        {
            var appName: String!
            if let app = operation.app as? (NSManagedObject & AppProtocol)
            {
                if let context = app.managedObjectContext
                {
                    context.performAndWait {
                        appName = app.name
                    }
                }
                else
                {
                    appName = NSLocalizedString("Unknown App", comment: "")
                }
            }
            else
            {
                appName = operation.app.name
            }

            let localizedTitle: String
            switch operation
            {
            case .install: localizedTitle = String(format: NSLocalizedString("Failed to Install %@", comment: ""), appName)
            case .refresh: localizedTitle = String(format: NSLocalizedString("Failed to Refresh %@", comment: ""), appName)
            case .update: localizedTitle = String(format: NSLocalizedString("Failed to Update %@", comment: ""), appName)
            case .activate: localizedTitle = String(format: NSLocalizedString("Failed to Activate %@", comment: ""), appName)
            case .deactivate: localizedTitle = String(format: NSLocalizedString("Failed to Deactivate %@", comment: ""), appName)
            case .backup: localizedTitle = String(format: NSLocalizedString("Failed to Backup %@", comment: ""), appName)
            case .restore: localizedTitle = String(format: NSLocalizedString("Failed to Restore %@ Backup", comment: ""), appName)
            case .resign: localizedTitle = String(format: NSLocalizedString("Failed to Resign %@", comment: ""), appName)
            }
            let error = nsError.withLocalizedTitle(localizedTitle)
            group.set(.failure(error), forAppWithBundleIdentifier: operation.bundleIdentifier)
            
            self.log(error, operation: operation.loggedErrorOperation, app: operation.app)
        }
    }
    
    func scheduleExpirationWarningLocalNotification(for app: InstalledApp)
    {
        let notificationDate = app.expirationDate.addingTimeInterval(-1 * 60 * 60 * 24) // 24 hours before expiration.
        
        let timeIntervalUntilNotification = notificationDate.timeIntervalSinceNow
        guard timeIntervalUntilNotification > 0 else {
            // Crashes if we pass negative value to UNTimeIntervalNotificationTrigger initializer.
            return
        }
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: timeIntervalUntilNotification, repeats: false)
        
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("SideStore Expiring Soon", comment: "")
        content.body = NSLocalizedString("SideStore will expire in 24 hours. Open the app and refresh it to prevent it from expiring.", comment: "")
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: AppManager.expirationWarningNotificationID, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    func run(_ operations: [Foundation.Operation], context: OperationContext?, requiresSerialQueue: Bool = false)
    {
        // Find "Install AltStore" operation if it already exists in `context`
        // so we can ensure it runs after any additional serial operations in `operations`.
        let installAltStoreOperation = context?.operations.allObjects.lazy.compactMap { $0 as? InstallAppOperation }.first { $0.context.bundleIdentifier == StoreApp.altstoreAppID }
        
        for operation in operations
        {
            switch operation
            {
            case _ where requiresSerialQueue: fallthrough
            case is InstallAppOperation, is RefreshAppOperation, is BackupAppOperation:
                if let installAltStoreOperation = operation as? InstallAppOperation, installAltStoreOperation.context.bundleIdentifier == StoreApp.altstoreAppID
                {
                    // Add dependencies on previous serial operations in `context` to ensure re-installing AltStore goes last.
                    let previousSerialOperations = context?.operations.allObjects.filter { self.serialOperationQueue.operations.contains($0) }
                    previousSerialOperations?.forEach { installAltStoreOperation.addDependency($0) }
                }
                else if let installAltStoreOperation = installAltStoreOperation
                {
                    // Re-installing AltStore should _always_ be the last serial operation in `context`.
                    installAltStoreOperation.addDependency(operation)
                }
                
                self.serialOperationQueue.addOperation(operation)
                
            default: self.operationQueue.addOperation(operation)
            }
            
            context?.operations.add(operation)
        }
    }
}

// MARK: - PipelineRunner Protocol Conformances
extension AppManager: PipelineProgress, PipelineExecutionContext, PipelineErrorLogger {
    func progress(for operation: AppOperation) -> Progress?
    {
        // Access outside critical section to avoid deadlock due to `bundleIdentifier` potentially calling performAndWait() on main thread.
        let bundleID = operation.bundleIdentifier
        
        return self.progressLock.withLock {
            switch operation
            {
            case .install, .update: 
                return self.installationProgress[bundleID]
            case .refresh, .activate, .deactivate, .deleteApp, .backup, .restore, .resign, .removeDeactivatedApp, .enableJIT: 
                return self.refreshProgress[bundleID]
            }
        }
    }
    
    func set(_ progress: Progress?, for operation: AppOperation)
    {
        // Access outside critical section to avoid deadlock due to `bundleIdentifier` potentially calling performAndWait() on main thread.
        let bundleID = operation.bundleIdentifier
        let operationName = String(describing: operation.loggedErrorOperation)

        self.progressLock.withLock {
            switch operation
            {
            case .install, .update: 
                self.installationProgress[bundleID] = progress
            case .refresh, .activate, .deactivate, .deleteApp, .backup, .restore, .resign, .removeDeactivatedApp, .enableJIT: 
                self.refreshProgress[bundleID] = progress
            }
            debugLog("[AppManager] setProgress: \(progress.map { "\($0)" } ?? "nil") for operation: .\(operationName), totalUnitCount: \(progress?.totalUnitCount ?? 0)")
        }
    }
    
    func getMappedError(for operation: AppOperation, error: Error) -> Error {
        var appName: String!
        if let app = operation.app as? (NSManagedObject & AppProtocol) {
            if let context = app.managedObjectContext {
                context.performAndWait {
                    appName = app.name
                }
            } else {
                appName = NSLocalizedString("Unknown App", comment: "")
            }
        } else {
            appName = operation.app.name
        }

        let localizedTitle: String
        switch operation
        {
            case .install:    localizedTitle = String(format: NSLocalizedString("Failed to Install %@",        comment: ""), appName)
            case .refresh:    localizedTitle = String(format: NSLocalizedString("Failed to Refresh %@",        comment: ""), appName)
            case .update:     localizedTitle = String(format: NSLocalizedString("Failed to Update %@",         comment: ""), appName)
            case .activate:   localizedTitle = String(format: NSLocalizedString("Failed to Activate %@",       comment: ""), appName)
            case .deactivate: localizedTitle = String(format: NSLocalizedString("Failed to Deactivate %@",     comment: ""), appName)
            case .deleteApp:  localizedTitle = String(format: NSLocalizedString("Failed to Deactivate %@",     comment: ""), appName)
            case .backup:     localizedTitle = String(format: NSLocalizedString("Failed to Backup %@",         comment: ""), appName)
            case .restore:    localizedTitle = String(format: NSLocalizedString("Failed to Restore %@ Backup", comment: ""), appName)
            case .resign:     localizedTitle = String(format: NSLocalizedString("Failed to Resign %@",         comment: ""), appName)
            case .removeDeactivatedApp: localizedTitle = String(format: NSLocalizedString("Failed to Remove %@", comment: ""), appName)
            case .enableJIT:  localizedTitle = String(format: NSLocalizedString("Failed to Enable JIT for %@", comment: ""), appName)
        }
        
        let nsError = error as NSError
        let mappedError = nsError.withLocalizedTitle(localizedTitle)
        return mappedError
    }
}


