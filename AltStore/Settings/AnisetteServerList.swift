//
//  AnisetteServerList.swift
//  SideStore
//
//  Created by ny on 6/18/24.
//  Copyright © 2024 SideStore. All rights reserved.
//

import UIKit
import SwiftUI
import AltStoreCore

typealias SUIButton = SwiftUI.Button

// MARK: - AnisetteServerData
struct AnisetteServerData: Codable {
    let servers: [Server]
}

// MARK: - Server
struct Server: Codable {
    var name: String
    var address: String
}

class AnisetteViewModel: ObservableObject {
    @Published var selected: String = ""

    @Published var source: String = "https://servers.sidestore.io/servers.json"
    @Published var servers: [Server] = []
    
    init() {
        // using the custom Anisette list
        if !UserDefaults.standard.menuAnisetteList.isEmpty {
            self.source = UserDefaults.standard.menuAnisetteList
        }
    }
    
    @MainActor
    func getCurrentListOfServers(_ completionHandler: @escaping (Result<Void, Error>) -> Void = {_ in }) {
        // dispatch fetch operation but don't do a blocking wait for results
        Task {
            do {
                let anisetteServers = try await AnisetteViewModel.getListOfServers(serverSource: self.source)
                // Update UI-related state on the main thread
                self.servers = anisetteServers
                debugLog("AnisetteViewModel: Server list refresh request completed for sourceURL: \(self.source)")
                completionHandler(.success(()))
            } catch {
                debugLog("AnisetteViewModel: Server list refresh request Failed for sourceURL: \(self.source) Error: \(error)")
                completionHandler(.failure(error))
            }
        }
    }
    
    static func getListOfServers(serverSource: String) async throws -> [Server] {
        var aniServers: [Server] = []

        guard let url = URL(string: serverSource) else {
            return aniServers
        }

        // DO NOT use local cache when fetching anisette servers
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            // Use async/await pattern here, avoiding CheckedContinuation directly
            let (data, response) = try await URLSession.shared.data(for: request)
            
            // Check if the response is valid and has a 2xx HTTP status code
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                // Handle non-2xx status codes
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw NSError(domain: "AnisetteViewModel: ServerError", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Request failed with status code: \(statusCode)"])
            }
            
            let decoder = Foundation.JSONDecoder()
            let servers = try decoder.decode(AnisetteServerData.self, from: data)
            debugLog("AnisetteViewModel: JSON Decode successful for sourceURL: \(serverSource) servers: \(servers)")
            aniServers.append(contentsOf: servers.servers)
            // Store server addresses as list
            UserDefaults.standard.menuAnisetteServersList = aniServers.map(\.address)
            return aniServers
        } catch {
            if let urlError = error as? URLError {
                debugLog("AnisetteViewModel: URL Error: \(urlError.localizedDescription)")
            } else if let decodingError = error as? DecodingError {
                debugLog("AnisetteViewModel: Failed to decode JSON: \(decodingError.localizedDescription)")
            } else {
                debugLog("AnisetteViewModel: An unexpected error occurred: \(error.localizedDescription)")
            }
            throw error // Propagate the error
        }
    }
}

struct AnisetteServersView: View {
    @Environment(\.presentationMode) var presentationMode
    @StateObject var viewModel: AnisetteViewModel = AnisetteViewModel()
    @State var selected: String? = nil
    @State private var showingConfirmation = false
    @State private var isRefreshing = false
    var errorCallback: () -> ()
    var refreshCallback: (Result<Void, any Error>) -> Void

    var body: some View {
        Form {
            Section {
                if let selected, !selected.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedServerName)
                            .font(.headline)
                        Text(selected)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                } else {
                    Text("No server selected")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Current Server")
            }
            
            Section {
                if isRefreshing && viewModel.servers.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Loading servers...")
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                } else if viewModel.servers.isEmpty {
                    Text("No servers available")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(viewModel.servers, id: \.address) { server in
                        SUIButton {
                            select(server)
                        } label: {
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(server.name)
                                        .font(.body.weight(.semibold))
                                        .foregroundColor(.primary)
                                    Text(server.address)
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                if selected == server.address {
                                    Image(systemName: "checkmark.circle.fill")
                                        .imageScale(.large)
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                }
            } header: {
                Text("Servers")
            } footer: {
                Text("Choose the Anisette server SideStore should use for Apple ID requests.")
            }
            
            Section {
                TextField("Anisette Server List", text: $viewModel.source)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .onChange(of: viewModel.source) { newValue in
                        UserDefaults.standard.menuAnisetteList = newValue
                    }
            }
            
            Section {
                SUIButton {
                    refreshServers(showToast: true)
                } label: {
                    Text("Refresh Servers")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                
                SUIButton {
                    showingConfirmation = true
                } label: {
                    Text("Reset adi.pb")
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } footer: {
                Text("Resetting adi.pb removes cached Anisette data. You will need to log back into your Apple ID.")
            }
        }
        .navigationTitle("Anisette Servers")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if selected == nil {
                selected = UserDefaults.standard.menuAnisetteURL
            }
            refreshServers(showToast: false)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                SUIButton {
                    refreshServers(showToast: true)
                } label: {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)
            }
        }
        .alert(isPresented: $showingConfirmation) {
            Alert(
                title: Text("Reset adi.pb"),
                message: Text("Are you sure you want to clear adi.pb from the keychain?"),
                primaryButton: .destructive(Text("Reset")) {
                    #if !DEBUG
                    if Keychain.shared.adiPb != nil {
                        Keychain.shared.adiPb = nil
                    }
                    #endif
                    debugLog("Cleared adi.pb from keychain")
                    errorCallback()
                    presentationMode.wrappedValue.dismiss()
                },
                secondaryButton: .cancel()
            )
        }
    }
    
    private var selectedServerName: String {
        guard let selected,
              let server = viewModel.servers.first(where: { $0.address == selected }) else {
            return "Custom Server"
        }
        return server.name
    }
    
    private func select(_ server: Server) {
        selected = server.address
        UserDefaults.standard.menuAnisetteURL = server.address
        UserDefaults.standard.synchronize()
    }
    
    private func refreshServers(showToast: Bool) {
        guard !isRefreshing else { return }
        isRefreshing = true
        viewModel.getCurrentListOfServers { result in
            isRefreshing = false
            if showToast {
                refreshCallback(result)
            }
        }
    }
}
