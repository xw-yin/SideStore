//
//  RefreshScheduleView.swift
//  SideStore
//
//  Settings UI for the automatic background refresh schedule.
//

import SwiftUI

struct RefreshScheduleView: View
{
    @AppStorage("isAutomaticRefreshEnabled") private var isEnabled = true
    @AppStorage("automaticRefreshIntervalHours") private var intervalHours = 24.0
    
    @State private var lastRun: Date?
    @State private var earliestEligible: Date?
    @State private var lastManifestSummary: String?
    
    private let intervalOptions: [Double] = [6, 12, 24, 48]
    
    var body: some View
    {
        List {
            Section {
                Toggle(NSLocalizedString("Automatic Refresh", comment: ""), isOn: $isEnabled)
                    .onChange(of: isEnabled) { _ in reschedule() }
            } footer: {
                Text(NSLocalizedString("Automatically refresh apps in the background when the system allows it.", comment: ""))
            }
            
            Section {
                Picker(NSLocalizedString("Refresh Interval", comment: ""), selection: $intervalHours) {
                    ForEach(intervalOptions, id: \.self) { hours in
                        Text(intervalLabel(hours)).tag(hours)
                    }
                }
                .onChange(of: intervalHours) { _ in reschedule() }
            }
            
            Section {
                HStack {
                    Text(NSLocalizedString("Earliest Eligible Refresh", comment: ""))
                    Spacer()
                    Text(earliestEligibleText)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text(NSLocalizedString("Last Automatic Refresh", comment: ""))
                    Spacer()
                    Text(lastRunText)
                        .foregroundColor(.secondary)
                }
            } footer: {
                // Never promise an exact time: the system decides when to run.
                Text(NSLocalizedString("The system decides the actual run time. This is only the earliest time a refresh may start.", comment: ""))
            }
            
            if let manifestSummary = lastManifestSummary {
                Section(NSLocalizedString("Last Verification", comment: "")) {
                    Text(manifestSummary)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(NSLocalizedString("Refresh Schedule", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
    }
    
    private func intervalLabel(_ hours: Double) -> String
    {
        let format = NSLocalizedString("Every %d hours", comment: "")
        return String(format: format, Int(hours))
    }
    
    private var earliestEligibleText: String {
        guard isEnabled else { return NSLocalizedString("Disabled", comment: "") }
        guard let date = earliestEligible else { return "–" }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }
    
    private var lastRunText: String {
        guard let date = lastRun else { return NSLocalizedString("Never", comment: "") }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }
    
    private func reload()
    {
        lastRun = UserDefaults.standard.lastAutomaticRefreshDate
        earliestEligible = AutomaticRefreshManager.earliestEligibleDate
        lastManifestSummary = RefreshVerificationManifest.loadLast()?.summary
    }
    
    private func reschedule()
    {
        AutomaticRefreshManager.schedule()
        reload()
    }
}
