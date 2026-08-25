//
//  SideJITServerConfigView.swift
//  SideStore
//
//  Created by Magesh K on 23/8/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import SwiftUI

enum SideJITConnectionStatus: Equatable {
    case ready(latencyMs: Int, address: String)
    case discovering
    case disconnected(reason: String)
    case checking
    
    var color: Color {
        switch self {
        case .ready: return .green
        case .discovering, .checking: return .orange
        case .disconnected: return .red
        }
    }
    
    var title: String {
        switch self {
        case .ready(let latency, _): return "Ready (\(latency) ms)"
        case .discovering: return "Discovering Bonjour…"
        case .checking: return "Checking Connection…"
        case .disconnected: return "Unreachable"
        }
    }
}

struct SideJITResponseLog: Identifiable {
    let id = UUID()
    let timestamp: Date
    let endpoint: String
    let httpMethod: String
    let statusCode: Int
    let latencyMs: Int
    let rawPayload: String
    
    var isSuccess: Bool {
        statusCode >= 200 && statusCode < 300
    }
}

enum SideJITDiagnosticAction: Equatable {
    case ping
    case refresh
    case version
}

struct SideJITServerConfigView: View {
    @State private var isServerEnabled: Bool = UserDefaults.standard.isSideJITServerEnabled
    @State private var customAddress: String = UserDefaults.standard.textInputSideJITServerurl ?? ""
    @State private var resolvedAddress: String = ""
    @State private var connectionStatus: SideJITConnectionStatus = .checking
    @State private var latestLog: SideJITResponseLog? = nil
    @State private var activeAction: SideJITDiagnosticAction? = nil
    @State private var showCopiedToast = false

    var body: some View {
        List {
            headerSection
            statusSection
            configurationSection
            diagnosticActionsSection
            if let log = latestLog {
                responseInspectorSection(log: log)
            }
            aboutSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("SideJITServer")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(
            Group {
                if showCopiedToast {
                    copiedToastView
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            },
            alignment: .bottom
        )
        .onAppear {
            refreshServerState()
        }
    }
    
    private var headerSection: some View {
        Section {
            Toggle(isOn: $isServerEnabled) {
                HStack(spacing: 12) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable SideJITServer")
                            .font(.body.weight(.semibold))
                        Text("Required for JIT on iOS 17+")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .onChange(of: isServerEnabled) { newValue in
                UserDefaults.standard.isSideJITServerEnabled = newValue
                if newValue {
                    refreshServerState()
                }
            }
        }
    }
    
    private var statusSection: some View {
        Section(header: Text("Connection Status")) {
            HStack {
                Text("Status")
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(connectionStatus.color)
                        .frame(width: 8, height: 8)
                    Text(connectionStatus.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.secondary)
                }
            }
            
            HStack {
                Text("Resolved Address")
                    .layoutPriority(1)
                Spacer()
                Text(resolvedAddress.isEmpty ? "Resolving…" : resolvedAddress)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(resolvedAddress.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .contextMenu {
                if !resolvedAddress.isEmpty {
                    SwiftUI.Button {
                        UIPasteboard.general.string = resolvedAddress
                        showCopied()
                    } label: {
                        Label("Copy Address", systemImage: "doc.on.doc")
                    }
                }
            }
            
            HStack {
                Text("Resolution Mode")
                Spacer()
                Text(customAddress.isEmpty ? "Auto (Bonjour mDNS)" : "Manual Override")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var configurationSection: some View {
        Section(
            header: Text("Server Address"),
            footer: Text("Leave empty to automatically discover SideJITServer on your local network via Bonjour.")
        ) {
            HStack {
                TextField(AppConstants.SideJIT.defaultServerURL, text: $customAddress)
                    .font(.system(size: 12.5, design: .monospaced))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                    .onChange(of: customAddress) { newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        UserDefaults.standard.textInputSideJITServerurl = trimmed.isEmpty ? nil : trimmed
                        refreshServerState()
                    }
                
                if !customAddress.isEmpty {
                    SwiftUI.Button {
                        customAddress = ""
                        UserDefaults.standard.textInputSideJITServerurl = nil
                        refreshServerState()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }
    
    private var diagnosticActionsSection: some View {
        Section(header: Text("Diagnostics & Tools")) {
            SwiftUI.Button {
                testHealthCheck()
            } label: {
                HStack {
                    Label("Test Connection (Ping)", systemImage: "network")
                        .foregroundColor(.primary)
                    Spacer()
                    if activeAction == .ping {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(activeAction != nil)
            
            SwiftUI.Button {
                triggerDeviceRefresh()
            } label: {
                HStack {
                    Label("Refresh Device Cache (/re/)", systemImage: "arrow.clockwise")
                        .foregroundColor(.primary)
                    Spacer()
                    if activeAction == .refresh {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(activeAction != nil)
            
            SwiftUI.Button {
                queryVersionEndpoint()
            } label: {
                HStack {
                    Label("Check Version Info (/ver/)", systemImage: "info.circle")
                        .foregroundColor(.primary)
                    Spacer()
                    if activeAction == .version {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(activeAction != nil)
        }
    }
    
    private func responseInspectorSection(log: SideJITResponseLog) -> some View {
        Section(header: Text("Latest Server Response")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(log.httpMethod)
                        .font(.system(.caption, design: .monospaced).bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                    
                    Text(log.endpoint)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    Text("\(log.statusCode)")
                        .font(.system(.caption, design: .monospaced).bold())
                        .foregroundColor(log.isSuccess ? .green : .red)
                    
                    Text("\(log.latencyMs)ms")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Text(log.rawPayload)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.primary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            }
            .padding(.vertical, 4)
            .contextMenu {
                SwiftUI.Button {
                    UIPasteboard.general.string = log.rawPayload
                    showCopied()
                } label: {
                    Label("Copy Response", systemImage: "doc.on.doc")
                }
            }
        }
    }
    
    private var aboutSection: some View {
        Section(header: Text("About")) {
            VStack(alignment: .leading, spacing: 6) {
                Text("SideJITServer attaches Apple's debugserver service on macOS to running apps on iOS 17+ over local Wi-Fi or USB.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("When SideStore triggers JIT, SideJITServer sends the debug attach signal and enables Just-In-Time execution instantly.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 2)
        }
    }
    
    private var copiedToastView: some View {
        Text("Copied to Clipboard")
            .font(.subheadline.weight(.medium))
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.accentColor))
            .padding(.bottom, 16)
    }
    
    private func showCopied() {
        withAnimation(.spring(response: 0.3)) {
            showCopiedToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.spring(response: 0.3)) {
                showCopiedToast = false
            }
        }
    }
    
    private func refreshServerState() {
        connectionStatus = .checking
        Task {
            let serverURL = await SideJITManager.shared.resolveServerURL()
            await MainActor.run {
                self.resolvedAddress = serverURL
            }
            await performPing(to: serverURL)
        }
    }
    
    private func performPing(to serverURL: String) async {
        guard let url = URL(string: serverURL) else {
            await MainActor.run {
                self.connectionStatus = .disconnected(reason: "Invalid URL")
            }
            return
        }
        
        let start = Date()
        var request = URLRequest(url: url)
        request.timeoutInterval = AppConstants.SideJIT.timeout
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let latency = Int(Date().timeIntervalSince(start) * 1000)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            let payload = String(data: data, encoding: .utf8) ?? "<binary data>"
            
            await MainActor.run {
                if status >= 200 && status < 400 {
                    self.connectionStatus = .ready(latencyMs: latency, address: serverURL)
                } else {
                    self.connectionStatus = .disconnected(reason: "HTTP \(status)")
                }
                self.latestLog = SideJITResponseLog(
                    timestamp: Date(),
                    endpoint: "/",
                    httpMethod: "GET",
                    statusCode: status,
                    latencyMs: latency,
                    rawPayload: payload.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        } catch {
            await MainActor.run {
                self.connectionStatus = .disconnected(reason: error.localizedDescription)
                self.latestLog = SideJITResponseLog(
                    timestamp: Date(),
                    endpoint: "/",
                    httpMethod: "GET",
                    statusCode: 0,
                    latencyMs: Int(Date().timeIntervalSince(start) * 1000),
                    rawPayload: "Error: \(error.localizedDescription)"
                )
            }
        }
    }
    
    private func testHealthCheck() {
        activeAction = .ping
        Task {
            let serverURL = await SideJITManager.shared.resolveServerURL()
            await performPing(to: serverURL)
            await MainActor.run {
                self.activeAction = nil
            }
        }
    }
    
    private func triggerDeviceRefresh() {
        activeAction = .refresh
        Task {
            let serverURL = await SideJITManager.shared.resolveServerURL()
            guard let url = URL(string: "\(serverURL)/re/") else {
                await MainActor.run { self.activeAction = nil }
                return
            }
            
            let start = Date()
            var request = URLRequest(url: url)
            request.timeoutInterval = AppConstants.SideJIT.timeout
            
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let latency = Int(Date().timeIntervalSince(start) * 1000)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                let payload = String(data: data, encoding: .utf8) ?? ""
                
                await MainActor.run {
                    self.latestLog = SideJITResponseLog(
                        timestamp: Date(),
                        endpoint: "/re/",
                        httpMethod: "GET",
                        statusCode: status,
                        latencyMs: latency,
                        rawPayload: payload.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    self.activeAction = nil
                }
            } catch {
                await MainActor.run {
                    self.latestLog = SideJITResponseLog(
                        timestamp: Date(),
                        endpoint: "/re/",
                        httpMethod: "GET",
                        statusCode: 0,
                        latencyMs: Int(Date().timeIntervalSince(start) * 1000),
                        rawPayload: "Error: \(error.localizedDescription)"
                    )
                    self.activeAction = nil
                }
            }
        }
    }
    
    private func queryVersionEndpoint() {
        activeAction = .version
        Task {
            let serverURL = await SideJITManager.shared.resolveServerURL()
            guard let url = URL(string: "\(serverURL)/ver/") else {
                await MainActor.run { self.activeAction = nil }
                return
            }
            
            let start = Date()
            var request = URLRequest(url: url)
            request.timeoutInterval = AppConstants.SideJIT.timeout
            
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let latency = Int(Date().timeIntervalSince(start) * 1000)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                let payload = String(data: data, encoding: .utf8) ?? ""
                
                await MainActor.run {
                    self.latestLog = SideJITResponseLog(
                        timestamp: Date(),
                        endpoint: "/ver/",
                        httpMethod: "GET",
                        statusCode: status,
                        latencyMs: latency,
                        rawPayload: payload.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    self.activeAction = nil
                }
            } catch {
                await MainActor.run {
                    self.latestLog = SideJITResponseLog(
                        timestamp: Date(),
                        endpoint: "/ver/",
                        httpMethod: "GET",
                        statusCode: 0,
                        latencyMs: Int(Date().timeIntervalSince(start) * 1000),
                        rawPayload: "Error: \(error.localizedDescription)"
                    )
                    self.activeAction = nil
                }
            }
        }
    }
}
