//
//  AppsTimelineProvider.swift
//  AltWidgetExtension
//
//  Created by Riley Testut on 8/23/23.
//  Copyright © 2023 Riley Testut. All rights reserved.
//

import WidgetKit
@preconcurrency import AltStoreCore

struct AppsEntry<T>: TimelineEntry
{
    var date: Date
    var relevance: TimelineEntryRelevance?
    
    var apps: [AppSnapshot]
    var isPlaceholder: Bool = false
    
    var context: T?
}

class AppsTimelineProviderBase<T>
{
    typealias Entry = AppsEntry<T>
    
    func placeholder(in context: TimelineProviderContext) -> AppsEntry<T>
    {
        return Entry(date: Date(), apps: [], isPlaceholder: true)
    }
    
    func snapshot(for appBundleIDs: [String], in context: T? = nil) async -> AppsEntry<T>
    {
        do
        {
            try await self.prepare()
            
            var apps = try await self.fetchApps(withBundleIDs: appBundleIDs)
            
            apps = getUpdatedData(apps, context)
            
            let entry = Entry(date: Date(), apps: apps, context: context)
            return entry
        }
        catch
        {
            debugLog("Failed to prepare widget snapshot: \(error)")
            
            let entry = Entry(date: Date(), apps: [], context: context)
            return entry
        }
    }
    
    func timeline(for appBundleIDs: [String], in context: T? = nil) async -> Timeline<AppsEntry<T>>
    {
        do
        {
            try await self.prepare()
            
            var apps = try await self.fetchApps(withBundleIDs: appBundleIDs)

            apps = getUpdatedData(apps, context)

            var entries = self.makeEntries(for: apps, in: context)
            
//            #if targetEnvironment(simulator)
//            if let first = entries.first{
//                entries = [first]
//            }
//            #endif
            
            let timeline = Timeline(entries: entries, policy: .atEnd)
            return timeline
        }
        catch
        {
            debugLog("Failed to prepare widget timeline: \(error)")
            
            let entry = Entry(date: Date(), apps: [], context: context)
            let timeline = Timeline(entries: [entry], policy: .atEnd)
            return timeline
        }
    }
    
    func getUpdatedData(_ apps: [AppSnapshot], _ context: T?) -> [AppSnapshot]{
        // override in subclasses as required
        return apps
    }
}

extension AppsTimelineProviderBase
{
    private func prepare() async throws
    {
        // No-op in push-pull architecture: widget snapshot JSON is read directly from App Group container.
    }
    
    private func fetchApps(withBundleIDs bundleIDs: [String]) async throws -> [AppSnapshot]
    {
        let snapshot = WidgetDataManager.shared.fetchSnapshot()
        let matchingItems = snapshot.allApps.filter { bundleIDs.contains($0.bundleIdentifier) }
        let apps = matchingItems.map { AppSnapshot(item: $0) }
        let sortedApps = apps.sorted { $0.name < $1.name }
        return sortedApps
    }
    
    func makeEntries(for snapshots: [AppSnapshot], in context: T? = nil) -> [AppsEntry<T>]
    {
        let sortedAppsByExpirationDate = snapshots.sorted { $0.expirationDate < $1.expirationDate }
        guard let firstExpiringApp = sortedAppsByExpirationDate.first, let lastExpiringApp = sortedAppsByExpirationDate.last else { return [] }
        
        let currentDate = Calendar.current.startOfDay(for: Date())
        let numberOfDays = lastExpiringApp.expirationDate.numberOfCalendarDays(since: currentDate)
        
        // Generate a timeline consisting of one entry per day.
        var entries: [AppsEntry<T>] = []
        
        switch numberOfDays
        {
        case ..<0:
            let entry = Entry(date: currentDate, relevance: TimelineEntryRelevance(score: 0.0), apps: snapshots, context: context)
            entries.append(entry)
            
        case 0:
            let entry = Entry(date: currentDate, relevance: TimelineEntryRelevance(score: 1.0), apps: snapshots, context: context)
            entries.append(entry)
            
        default:
            // To reduce memory consumption, we only generate entries for the next week. This includes:
            // * 1 for each day the "least expired" app is valid (up to 7)
            // * 1 "0 days remaining"
            // * 1 "Expired"
            
            let numberOfEntries = min(numberOfDays, 7) + 2
            
            let appEntries = (0 ..< numberOfEntries).map { (dayOffset) -> Entry in
                let entryDate = Calendar.current.date(byAdding: .day, value: dayOffset, to: currentDate) ?? currentDate.addingTimeInterval(Double(dayOffset) * 60 * 60 * 24)
                                
                let daysSinceRefresh = entryDate.numberOfCalendarDays(since: firstExpiringApp.refreshedDate)
                let totalNumberOfDays = firstExpiringApp.expirationDate.numberOfCalendarDays(since: firstExpiringApp.refreshedDate)
                
                var score = (entryDate <= firstExpiringApp.expirationDate) ? Float(daysSinceRefresh + 1) / Float(totalNumberOfDays + 1) : 1 // Expired apps have a score of 1.
                if snapshots.allSatisfy({ $0.expirationDate > currentDate })
                {
                    // Unless ALL apps are expired, in which case relevance is 0.
                    score = 0
                }
                
                let entry = Entry(date: entryDate, relevance: TimelineEntryRelevance(score: score), apps: snapshots, context: context)
                return entry
            }
            
            entries.append(contentsOf: appEntries)
        }
        
        return entries
    }
    
    func fetchActiveAppBundleIDs() async -> [String]
    {
        let snapshot = WidgetDataManager.shared.fetchSnapshot()
        let bundleIDs = snapshot.activeApps.map { $0.bundleIdentifier }
        return bundleIDs.isEmpty ? [StoreApp.altstoreAppID] : bundleIDs
    }
}

typealias Intent = ViewAppIntent

class AppsTimelineProvider: AppsTimelineProviderBase<Intent>, IntentTimelineProvider
{
    func getSnapshot(for intent: Intent, in context: Context, completion: @escaping (AppsEntry<Intent>) -> Void)
    {
        Task {
            let bundleIDs = [intent.app?.identifier ?? StoreApp.altstoreAppID]
            
            let snapshot = await self.snapshot(for: bundleIDs, in: intent)
            completion(snapshot)
        }
    }
    
    func getTimeline(for intent: Intent, in context: Context, completion: @escaping (Timeline<AppsEntry<Intent>>) -> Void)
    {
        Task {
            let bundleIDs = [intent.app?.identifier ?? StoreApp.altstoreAppID]
            
            let timeline = await self.timeline(for: bundleIDs, in: intent)
            completion(timeline)
        }
    }
}

// Modern AppIntents-based provider for AppDetailWidget on iOS 17+.
// Replaces AppsTimelineProvider (IntentTimelineProvider) which uses the legacy
// SiriKit Intents framework that breaks containerBackground on iOS 17+.
@available(iOSApplicationExtension 17, *)
class SelectAppTimelineProvider: AppsTimelineProviderBase<SelectAppIntent>, AppIntentTimelineProvider
{
    typealias Intent = SelectAppIntent

    func snapshot(for intent: SelectAppIntent, in context: Context) async -> AppsEntry<SelectAppIntent>
    {
        let bundleID = await resolvedBundleID(for: intent)
        return await self.snapshot(for: [bundleID], in: intent)
    }

    func timeline(for intent: SelectAppIntent, in context: Context) async -> Timeline<AppsEntry<SelectAppIntent>>
    {
        let bundleID = await resolvedBundleID(for: intent)
        return await self.timeline(for: [bundleID], in: intent)
    }

    // If the user hasn't picked an app yet, fall back to the first active app
    // rather than a hardcoded bundle ID that may not exist in the database.
    private func resolvedBundleID(for intent: SelectAppIntent) async -> String
    {
        if let id = intent.app?.id { return id }
        let activeIDs = await self.fetchActiveAppBundleIDs()
        return activeIDs.first ?? StoreApp.altstoreAppID
    }
}
