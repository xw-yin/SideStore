//
//  DatabaseManager.swift
//  AltStore
//
//  Created by Riley Testut on 5/20/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import CoreData
import SideSign

extension CFNotificationName
{
    fileprivate static let willMigrateDatabase = CFNotificationName("com.rileytestut.AltStore.WillMigrateDatabase" as CFString)
}

private let ReceivedWillMigrateDatabaseNotification: @convention(c) (CFNotificationCenter?, UnsafeMutableRawPointer?, CFNotificationName?, UnsafeRawPointer?, CFDictionary?) -> Void = { (center, observer, name, object, userInfo) in
    DatabaseManager.shared.receivedWillMigrateDatabaseNotification()
}

public class DatabaseManager: @unchecked Sendable
{
    public static private(set) var shared = DatabaseManager()
    
    public let persistentContainer: PersistentContainer
    
    private let lock = NSLock()
    private var _isStarted = false
    public var isStarted: Bool {
        self.lock.withLock { self._isStarted }
    }
    
    private var startTask: Task<Void, Error>?
    
    private let coordinator = NSFileCoordinator()
    private let coordinatorQueue = OperationQueue()
    
    private var ignoreWillMigrateDatabaseNotification = false

    private init()
    {
        self.persistentContainer = PersistentContainer(name: "AltStore", bundle: Bundle(for: DatabaseManager.self))
        self.persistentContainer.preferredMergePolicy = MergePolicy()
        
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer, ReceivedWillMigrateDatabaseNotification, CFNotificationName.willMigrateDatabase.rawValue, nil, .deliverImmediately)
    }
    private class func loadPersistentStoresSync() {
        let container = Self.shared.persistentContainer
        if !container.persistentStoreCoordinator.persistentStores.isEmpty {
            return
        }
        let semaphore = DispatchSemaphore(value: 0)  // Semaphore to wait for async completion
        
        container.loadPersistentStores { description, error in
            if let error = error {
                debugLog("Failed to load store: \(error)")
            } else {
                debugLog("Store URL: \(description.url ?? URL(string: "unknown")!)")
            }
            
            semaphore.signal()  // Signal the semaphore to unblock the thread
        }
        
        semaphore.wait()  // Wait for the semaphore signal to unblock the thread
        debugLog("Persistent store loading complete.")
    }
    
    public class func deleteDatabase() -> Bool
    {
        // delete existing database and start fresh if required
        do {
            let container = Self.shared.persistentContainer
            
            var databaseStore = container.persistentStoreCoordinator.persistentStores.first
            let databaseStoreURL = databaseStore?.url ?? PersistentContainer.defaultDirectoryURL().appendingPathComponent("AltStore.sqlite")
            
            // Reset the managed object context
            Self.shared.persistentContainer.viewContext.reset()

            // Remove all existing persistent stores
            for store in Self.shared.persistentContainer.persistentStoreCoordinator.persistentStores {
                try? Self.shared.persistentContainer.persistentStoreCoordinator.remove(store)
            }

            // Now destroy the persistent store
            if FileManager.default.fileExists(atPath: databaseStoreURL.path) {
                try Self.shared.persistentContainer.persistentStoreCoordinator.destroyPersistentStore(
                    at: databaseStoreURL,
                    ofType: NSSQLiteStoreType,
                    options: nil
                )
                try? FileManager.default.removeItem(at: databaseStoreURL)
            }
                
            debugLog("\nDatabase Delete: SUCCEEDED\n")
            return true
        } catch {
            debugLog("\nDatabase Delete request FAILED: \(error)\n")
            return false
        }
    }
    
    public class func recreateDatabase() {
        // Try to perform delete if one exists
        _ = Self.deleteDatabase()
        
        // create new instance and load persistence store
        Self.shared = DatabaseManager()
    }

    public func start() async throws
    {
        if self.isStarted { return }
        
        let task = self.lock.withLock {
            if let startTask { return startTask }
            let task = Task<Void, Error>.detached(priority: .userInitiated) { try await self.performStart() }
            self.startTask = task
            return task
        }
        
        do {
            try await task.value
            self.lock.withLock { self._isStarted = true }
        } catch {
            self.lock.withLock { self.startTask = nil }
            throw error
        }
    }


    private func performStart() async throws
    {
        if self.persistentContainer.isMigrationRequired
        {
            // Quit any other running AltStore processes to prevent concurrent database access during and after migration.
            self.ignoreWillMigrateDatabaseNotification = true
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), .willMigrateDatabase, nil, nil, true)
        }

        try await self.migrateDatabaseToAppGroupIfNeeded()
        try await self.persistentContainer.loadPersistentStores()
        try await self.prepareDatabase()
    }

    public func purgeLoggedErrors(before date: Date? = nil) async throws
    {
        try await self.persistentContainer.performBackgroundTask { context in
            let predicate = date.map { NSPredicate(format: "%K <= %@", #keyPath(LoggedError.date), $0 as NSDate) }
            let loggedErrors = LoggedError.all(satisfying: predicate, in: context, requestProperties: [\.returnsObjectsAsFaults: true])
            loggedErrors.forEach { context.delete($0) }
            try context.save()
        }
    }

    
    public func updateFeaturedSortIDs() async
    {
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy // DON'T use our custom merge policy, because that one ignores changes to featuredSortID.
        await context.performAsync {
            do
            {
                // Randomize source order
                let fetchRequest = Source.fetchRequest()
                let sources = try context.fetch(fetchRequest)
                
                for source in sources
                {
                    source.featuredSortID = UUID().uuidString
                }
                
                try context.save()
            }
            catch
            {
                debugLog("Failed to update source order. \(error.localizedDescription)")
            }
            
            do
            {
                // Randomize app order
                let fetchRequest = StoreApp.fetchRequest()
                let apps = try context.fetch(fetchRequest)
                
                for app in apps
                {
                    app.featuredSortID = UUID().uuidString
                }
                
                try context.save()
            }
            catch
            {
                debugLog("Failed to update app order. \(error.localizedDescription)")
            }
        }
    }


    public var viewContext: NSManagedObjectContext {
        return self.persistentContainer.viewContext
    }
    
    public func activeAccount(in context: NSManagedObjectContext) -> Account?
    {
        let predicate = NSPredicate(format: "%K == YES", #keyPath(Account.isActiveAccount))
        
        let activeAccount = Account.first(satisfying: predicate, in: context)
        return activeAccount
    }
    
    public func activeTeam(in context: NSManagedObjectContext) -> Team?
    {
        let predicate = NSPredicate(format: "%K == YES", #keyPath(Team.isActiveTeam))
        
        let activeTeam = Team.first(satisfying: predicate, in: context)
        return activeTeam
    }
    func embeddedLiveContainerApplication(from hostBundle: Bundle) -> (application: ALTApplication, temporaryBundleURL: URL)?
    {
        guard Bundle.isBundledWithLiveContainer,
              let executableURL = hostBundle.executableURL,
              FileManager.default.fileExists(atPath: hostBundle.provisioningProfileURL.path)
        else { return nil }

        let temporaryBundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("app")

        do
        {
            try FileManager.default.createDirectory(at: temporaryBundleURL, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: hostBundle.infoPlistURL, to: temporaryBundleURL.appendingPathComponent("Info.plist"))
            try FileManager.default.createSymbolicLink(at: temporaryBundleURL.appendingPathComponent(executableURL.lastPathComponent), withDestinationURL: executableURL)
            try FileManager.default.copyItem(at: hostBundle.provisioningProfileURL, to: temporaryBundleURL.appendingPathComponent("embedded.mobileprovision"))

            guard let application = ALTApplication(fileURL: temporaryBundleURL), application.provisioningProfile != nil else {
                try? FileManager.default.removeItem(at: temporaryBundleURL)
                return nil
            }

            return (application, temporaryBundleURL)
        }
        catch
        {
            try? FileManager.default.removeItem(at: temporaryBundleURL)
            debugLog("Failed to prepare embedded LiveContainer application: \(error)")
            return nil
        }
    }

    private func prepareDatabase() async throws
    {
        guard !Bundle.isAppExtension() else { return }
        
        let context = self.persistentContainer.newBackgroundContext()
        try await context.perform {
            let appBundle = Bundle.realMainBundle
            let embeddedApplication = self.embeddedLiveContainerApplication(from: appBundle)
            let localApp = embeddedApplication?.application ?? ALTApplication(fileURL: Bundle.Info.activeBundleURL)
            defer {
                if let temporaryBundleURL = embeddedApplication?.temporaryBundleURL {
                    try? FileManager.default.removeItem(at: temporaryBundleURL)
                }
            }

            guard let localAppBundle = localApp else { return }
            
            #if !targetEnvironment(simulator)
            guard localAppBundle.provisioningProfile != nil else {
                throw ALTError(.invalidApp)
            }
            #endif
            
            let liveContainerSource: Source? = {
                guard Bundle.isBundledWithLiveContainer else { return nil }
                let sourceURL = URL(string: "https://github.com/LiveContainer/LiveContainer/releases/download/1.0/apps_ss_lc.json")!
                guard let sourceID = try? Source.sourceID(from: sourceURL) else { return nil }
                return Source.first(satisfying: NSPredicate(format: "%K == %@", #keyPath(Source.identifier), sourceID), in: context)
                    ?? Source.make(name: "LiveContainer", groupID: Source.altStoreGroupIdentifier, sourceURL: sourceURL, context: context)
            }()

            let altStoreSource: Source?
            
            if let source = Source.first(satisfying: NSPredicate(format: "%K == %@", #keyPath(Source.identifier), Source.altStoreIdentifier), in: context)
            {
                altStoreSource = source
            }
            else
            {
                altStoreSource = UserDefaults.standard.isDefaultSourceRemoved ? nil : Source.makeAltStoreSource(in: context)
            }

            // Make sure to always update source URL to be current.
            if let altStoreSource {
                try! altStoreSource.setSourceURL(Source.altStoreSourceURL)
            }
            
            let storeApp: StoreApp
            
            if let app = StoreApp.first(satisfying: NSPredicate(format: "%K == %@", #keyPath(StoreApp.bundleIdentifier), StoreApp.altstoreAppID), in: context)
            {
                storeApp = app
            }
            else
            {
                storeApp = StoreApp.makeAltStoreApp(version: localAppBundle.version, buildVersion: nil, in: context)
                storeApp.source = altStoreSource ?? liveContainerSource
            }

            if Bundle.isBundledWithLiveContainer {
                if let liveContainerSource {
                    storeApp.configureForEmbeddedLiveContainer()
                    storeApp.source = liveContainerSource
                } else {
                    storeApp.configureForEmbeddedLiveContainer()
                    storeApp.source = altStoreSource
                }
            }
                        
            let serialNumber = (appBundle.object(forInfoDictionaryKey: Bundle.Info.certificateID) as? String) ?? CertificateManager.shared.getSigningCertificate(at: Bundle.Info.activeBundleURL)?.serialNumber
            
            let installedApp: InstalledApp
            
            if let app = storeApp.installedApp
            {
                installedApp = app
            }
            else
            {
                //TODO: Support build versions.
                // For backwards compatibility reasons, we cannot use localApp's buildVersion as storeBuildVersion,
                // or else the latest update will _always_ be considered new because we don't use buildVersions in our source (yet).
                installedApp = try InstalledApp(
                    resignedAppBundle: localAppBundle,
                    originalBundleIdentifier: StoreApp.altstoreAppID,
                    certificateSerialNumber: serialNumber,
                    storeBuildVersion: nil,
                    context: context
                )
                
                if Bundle.isBundledWithLiveContainer {
                    // LiveContainer owns its widget, which is not part of SideStore's self-refresh bundle.
                    installedApp.useMainProfile = true
                } else {
                    // figure out if the current AltStoreApp is signed with "Use Main Profie" option
                    // by checking if the first extension's entitlement's application-identifier matches current one
                    repeat {
                        guard let pluginURL = Bundle.main.builtInPlugInsURL else {
                            installedApp.useMainProfile = true
                            break
                        }
                        guard let pluginFolders = try? FileManager.default.contentsOfDirectory(at: pluginURL, includingPropertiesForKeys: nil) else {
                            installedApp.useMainProfile = true
                            break
                        }
                        
                        guard let pluginFolder = pluginFolders.first, let altPluginAppBundle = ALTApplication(fileURL: pluginFolder) else {
                            installedApp.useMainProfile = true
                            break
                        }
                        
                        let entitlements = altPluginAppBundle.entitlements
                        guard let appId = entitlements[ALTEntitlement.applicationIdentifier] as? String else {
                            installedApp.useMainProfile = false
                            debugLog("no ALTEntitlementApplicationIdentifier???")
                            break
                        }
                        
                        if appId.hasSuffix(Bundle.Info.activeBundleIdentifier) {
                            installedApp.useMainProfile = true
                        } else {
                            installedApp.useMainProfile = false
                        }
                    } while(false)
                }
                
                installedApp.storeApp = storeApp
                // Persist the release track for newly created self-app entries
                if installedApp.releaseTrack == nil,
                   let trackEntity = storeApp.latestSupportedVersion?.releaseTrack {
                    installedApp.releaseTrack = trackEntity
                }
            }
            
            /* App Extensions */
            var installedExtensions = Set<InstalledExtension>()
            
            for appExtension in localAppBundle.appExtensions
            {
                let resignedBundleID = appExtension.bundleIdentifier
                let originalBundleID = resignedBundleID.replacingOccurrences(of: localAppBundle.bundleIdentifier, with: StoreApp.altstoreAppID)
                
                let installedExtension: InstalledExtension
                
                if let appExtension = installedApp.appExtensions.first(where: { $0.bundleIdentifier == originalBundleID })
                {
                    installedExtension = appExtension
                }
                else
                {
                    installedExtension = try InstalledExtension(resignedAppExtensionBundle: appExtension, originalBundleIdentifier: originalBundleID, context: context)
                }
                
                installedExtension.update(resignedAppExtensionBundle: appExtension)
                
                installedExtensions.insert(installedExtension)
            }
            
            installedApp.appExtensions = installedExtensions
            
            let bundleURL = Bundle.isBundledWithLiveContainer ? Bundle.realMainBundle.bundleURL : Bundle.Info.activeBundleURL
            let altstoreAppID = StoreApp.altstoreAppID
            let extensionBundleIDMap = installedExtensions.reduce(into: [String: String]()) { dict, ext in
                dict[ext.resignedBundleIdentifier] = ext.bundleIdentifier
            }
            
            FileManager.default.prepareTemporaryURL { temporaryDirectory in
                do {
                    let temporaryAppURL = temporaryDirectory.appendingPathComponent(bundleURL.lastPathComponent)
                    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: bundleURL, to: temporaryAppURL)
                    
                    guard let tempAppBundle = ALTApplication(fileURL: temporaryAppURL) else { throw ALTError(.invalidApp) }
                    try tempAppBundle.updateInfoPlist(with: [kCFBundleIdentifierKey as String: altstoreAppID])
                    
                    for appExtension in tempAppBundle.appExtensions {
                        guard let originalBundleID = extensionBundleIDMap[appExtension.bundleIdentifier] else { throw ALTError(.invalidApp) }
                        try appExtension.updateInfoPlist(with: [kCFBundleIdentifierKey as String: originalBundleID])
                    }
                    
                    let (signature, _) = try CacheAppOperation.cachePayload(for: temporaryAppURL)
                    installedApp.appBundleFingerprint = signature
                } catch {
                    debugLog("Failed to cache SideStore app bundle: \(error)")
                }
            }
            
            let cachedRefreshedDate = installedApp.refreshedDate
            let cachedExpirationDate = installedApp.expirationDate
                        
            // Must go after comparing versions to see if we need to update our cached AltStore app bundle.
            self.reconcileSelfFromSelfBinary(installedApp: installedApp, localAppBundle: localAppBundle, serialNumber: serialNumber)
            
            if installedApp.refreshedDate < cachedRefreshedDate
            {
                // Embedded provisioning profile has a creation date older than our refreshed date.
                // This most likely means we've refreshed the app since then, and profile is now outdated,
                // so use cached dates instead (i.e. not the dates updated from provisioning profile).
                
                installedApp.refreshedDate = cachedRefreshedDate
                installedApp.expirationDate = cachedExpirationDate
            }

            self.recoverEmbeddedInstalledAppsFromCache(in: context)

            try context.save()
        }
        
        await self.updateFeaturedSortIDs()
    }

    private func recoverEmbeddedInstalledAppsFromCache(in context: NSManagedObjectContext)
    {
        guard Bundle.isBundledWithLiveContainer else { return }

        let directories = [InstalledApp.appsDirectoryURL, InstalledApp.legacyAppsDirectoryURL]
        var scannedPaths = Set<String>()

        for directory in directories where scannedPaths.insert(directory.standardizedFileURL.path).inserted
        {
            guard let cachedDirectories = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for cachedDirectory in cachedDirectories
            {
                let appURL = cachedDirectory.appendingPathComponent("App.app")
                guard let appBundle = ALTApplication(fileURL: appURL),
                      appBundle.bundleIdentifier != Bundle.Info.activeBundleIdentifier,
                      appBundle.provisioningProfile != nil
                else { continue }

                let bundle = Bundle(url: appURL)
                let originalBundleIdentifier = (bundle?.object(forInfoDictionaryKey: Bundle.Info.altBundleID) as? String)
                    ?? cachedDirectory.lastPathComponent
                let predicate = NSPredicate(format: "%K == %@", #keyPath(InstalledApp.bundleIdentifier), originalBundleIdentifier)
                guard InstalledApp.first(satisfying: predicate, in: context) == nil else { continue }

                do
                {
                    let certificate = CertificateManager.shared.getSigningCertificate(at: appURL)
                    let installedApp = try InstalledApp(
                        resignedAppBundle: appBundle,
                        originalBundleIdentifier: originalBundleIdentifier,
                        certificateSerialNumber: certificate?.serialNumber,
                        storeBuildVersion: nil,
                        context: context
                    )
                    installedApp.isActive = true

                    if let storeApp = StoreApp.first(
                        satisfying: NSPredicate(format: "%K == %@", #keyPath(StoreApp.bundleIdentifier), originalBundleIdentifier),
                        in: context
                    ) {
                        installedApp.storeApp = storeApp
                    }

                    debugLog("[DatabaseManager] Recovered installed app from cache: \(originalBundleIdentifier)")
                }
                catch
                {
                    debugLog("[DatabaseManager] Failed to recover cached app at \(appURL.path): \(error)")
                }
            }
        }
    }
    
    private func reconcileSelfFromSelfBinary(installedApp: InstalledApp, localAppBundle: ALTApplication, serialNumber: String?) {
        debugLog("[DatabaseManager] reconcileSelfFromSelfBinary: Started for '\(localAppBundle.name)' (\(localAppBundle.bundleIdentifier)).")
        var binaryCertSerial: String? = nil
        defer {
            debugLog("""
            [DatabaseManager] reconcileSelfFromSelfBinary: Completed
              • name: '\(installedApp.name)'
              • bundleID: '\(installedApp.bundleIdentifier)'
              • version: '\(installedApp.version)'
              • buildVersion: '\(installedApp.buildVersion)'
              • refreshedDate: \(installedApp.refreshedDate)
              • expirationDate: \(installedApp.expirationDate)
              • installCertSerial: '\(installedApp.certificateSerialNumber ?? "nil")'
              • binaryCertSerial: '\(binaryCertSerial ?? "nil")'
              • binaryCertStatus: \(installedApp.certificateStatus)
            
            """)
        }
        
        installedApp.name = localAppBundle.name
        installedApp.resignedBundleIdentifier = localAppBundle.bundleIdentifier
        installedApp.version = localAppBundle.version
        installedApp.buildVersion = localAppBundle.buildVersion
        
        var status: CertificateStatus = .valid(isCrossSigned: false)
        if let binaryCert = CertificateManager.shared.getSigningCertificate(at: localAppBundle.fileURL) {
            binaryCertSerial = binaryCert.serialNumber
            CertificateManager.shared.saveX509Certificate(binaryCert)
            if binaryCert.expiryDate <= Date() {
                status = .expired
            }
        }
        
        let effectiveSerial = binaryCertSerial ?? serialNumber
        installedApp.certificateSerialNumber = effectiveSerial
        
        let activeKeychainSerial = CertificateManager.shared.activeCertificate?.serialNumber
        let isCross = (activeKeychainSerial != nil && !activeKeychainSerial!.isEmpty && effectiveSerial != nil && effectiveSerial != activeKeychainSerial)
        if case .valid = status {
            status = .valid(isCrossSigned: isCross)
        }
        installedApp.certificateStatus = status
        
        if let provisioningProfile = localAppBundle.provisioningProfile {
            installedApp.refreshedDate = provisioningProfile.creationDate
            installedApp.expirationDate = provisioningProfile.expirationDate
        }
    }
    
    private func migrateDatabaseToAppGroupIfNeeded() async throws
    {
        // Only migrate if we haven't migrated yet and there's a valid AltStore app group.
        guard UserDefaults.standard.requiresAppGroupMigration && Bundle.main.altstoreAppGroup != nil else { return }

        let previousDatabaseURL = PersistentContainer.legacyDirectoryURL().appendingPathComponent("AltStore.sqlite")
        let databaseURL = PersistentContainer.defaultDirectoryURL().appendingPathComponent("AltStore.sqlite")
        
        let previousAppsDirectoryURL = InstalledApp.legacyAppsDirectoryURL
        let appsDirectoryURL = InstalledApp.appsDirectoryURL
        
        let databaseIntent = NSFileAccessIntent.writingIntent(with: databaseURL, options: [.forReplacing])
        let appsIntent = NSFileAccessIntent.writingIntent(with: appsDirectoryURL, options: [.forReplacing])
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.coordinator.coordinate(with: [databaseIntent, appsIntent], queue: self.coordinatorQueue) { (error) in
                do
                {
                    if let error = error
                    {
                        throw error
                    }
                    
                    let description = NSPersistentStoreDescription(url: previousDatabaseURL)
                    
                    // Disable WAL to remove extra files automatically during migration.
                    description.setOption(["journal_mode": "DELETE"] as NSDictionary, forKey: NSSQLitePragmasOption)
                    
                    let persistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: self.persistentContainer.managedObjectModel)
                    
                    // Never replace an existing App Group database with a stale legacy database.
                    if FileManager.default.fileExists(atPath: previousDatabaseURL.path),
                       !FileManager.default.fileExists(atPath: databaseURL.path)
                    {
                        let previousDatabase = try persistentStoreCoordinator.addPersistentStore(ofType: description.type, configurationName: description.configuration, at: description.url, options: description.options)
                        
                        // Pass nil options to prevent later error due to self.persistentContainer using WAL.
                        try persistentStoreCoordinator.migratePersistentStore(previousDatabase, to: databaseURL, options: nil, withType: NSSQLiteStoreType)
                        
                        try FileManager.default.removeItem(at: previousDatabaseURL)
                    }
                    
                    // Only migrate cached apps when the destination has no cached entries.
                    if FileManager.default.fileExists(atPath: previousAppsDirectoryURL.path, isDirectory: nil)
                    {
                        let destinationContents = (try? FileManager.default.contentsOfDirectory(atPath: appsDirectoryURL.path)) ?? []
                        if previousAppsDirectoryURL.path != appsDirectoryURL.path && destinationContents.isEmpty
                        {
                            for item in try FileManager.default.contentsOfDirectory(at: previousAppsDirectoryURL, includingPropertiesForKeys: nil)
                            {
                                let destination = appsDirectoryURL.appendingPathComponent(item.lastPathComponent)
                                guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
                                try FileManager.default.copyItem(at: item, to: destination)
                            }
                        }
                    }
                    
                    UserDefaults.standard.requiresAppGroupMigration = false
                    continuation.resume()
                }
                catch
                {
                    debugLog("Failed to migrate database to app group: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    fileprivate func receivedWillMigrateDatabaseNotification()
    {
        defer { self.ignoreWillMigrateDatabaseNotification = false }

        // Ignore notifications sent by the current process.
        guard !self.ignoreWillMigrateDatabaseNotification else { return }

        exit(104)
    }
}
