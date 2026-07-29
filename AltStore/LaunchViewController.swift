//
//  LaunchViewController.swift
//  AltStore
//
//  Created by Riley Testut on 7/30/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import UIKit

import WidgetKit

import AltSign
import AltStoreCore
import UniformTypeIdentifiers

let pairingFileName = "ALTPairingFile.mobiledevicepairing"

final class LaunchViewController: UIViewController, UIDocumentPickerDelegate {
    private var didFinishLaunching = false
    private var retries = 0
    private var maxRetries = 3
    private var splashView: SplashView!
    private var destinationViewController: TabBarController?
    private var startTime: Date!

    override func viewDidLoad() {
        super.viewDidLoad()
        splashView = SplashView(frame: view.bounds, appName: "SideStore")
        destinationViewController = storyboard!.instantiateViewController(withIdentifier: "tabBarController") as? TabBarController
        view.addSubview(splashView)
    }

    override func viewDidAppear(_ animated: Bool) {
        debugLog("LaunchViewController.viewDidAppear() invoked")
        super.viewDidAppear(animated)
        guard !didFinishLaunching else { return }
        startTime = Date()
        
        // spin off the startup sequence concurrently
        Task.detached { [weak self] in
            await self?.runLaunchSequence()
        }
        Task.detached { [weak self] in
            await self?.doPostLaunch()
        }
    }

    private nonisolated func runLaunchSequence() async {
        guard await retries < maxRetries else { return }
        await MainActor.run{
            retries += 1
        }
        if !DatabaseManager.shared.isStarted {
            await withCheckedContinuation { continuation in
                DatabaseManager.shared.start { error in
                    if let error {
                        Task { await self.handleLaunchError(error, retryCallback: self.runLaunchSequence) }
                    } else {
                        Task { await self.finishLaunching() }
                    }
                    continuation.resume(returning: ())
                }
            }
        } else {
            await self.finishLaunching()
        }
    }

    private nonisolated func doPostLaunch() async {
        #if !targetEnvironment(simulator)
        await detectAndImportAccountFile()
        #endif
    }

    @MainActor
    func showPairingPrompt(isRetry: Bool) {
        let title = isRetry ? NSLocalizedString("Invalid Pairing File", comment: "") : NSLocalizedString("Pairing File", comment: "")
        let message = isRetry
            ? NSLocalizedString("The selected pairing file is invalid or not usable. Please select a valid pairing file.", comment: "")
            : NSLocalizedString("Select the pairing file or select \"Help\" for help.", comment: "")
        
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        
        alert.addAction(UIAlertAction(title: NSLocalizedString("Help", comment: ""), style: .default) { _ in
            if let url = URL(string: "https://docs.sidestore.io/docs/advanced/pairing-file") { UIApplication.shared.open(url) }
            sleep(2); exit(0)
        })
        
        alert.addAction(UIAlertAction(title: NSLocalizedString("Select File", comment: ""), style: .default) { _ in
            var types = UTType.types(tag: "plist", tagClass: .filenameExtension, conformingTo: nil)
            types.append(contentsOf: UTType.types(tag: "mobiledevicepairing", tagClass: .filenameExtension, conformingTo: .data))
            types.append(.xml)
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
            picker.delegate = self
            picker.shouldShowFileExtensions = true
            self.present(picker, animated: true)
        })
        
        let cancelTitle = isRetry ? NSLocalizedString("Skip", comment: "") : NSLocalizedString("Cancel", comment: "")
        alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel) { _ in
            self.showPairingWarningAndProceed()
        })
        
        self.present(alert, animated: true)
    }

    func showPairingWarningAndProceed() {
        let warningAlert = UIAlertController(
            title: "⚠️ " + NSLocalizedString("Pairing Required", comment: ""),
            message: NSLocalizedString("Without a valid pairing file, operations that require a pairing file (such as installing, refreshing, or resigning apps) will not function.", comment: ""),
            preferredStyle: .alert
        )
        warningAlert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
        self.present(warningAlert, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let isSecuredURL = url.startAccessingSecurityScopedResource()
        defer {
            if isSecuredURL {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        do {
            debugLog("[LaunchViewController] User picked pairing file from: \(url.path)")
            let data = try Data(contentsOf: url)
            guard let pairingString = String(data: data, encoding: .utf8) else {
                debugLog("[LaunchViewController] Unable to read pairing file")
                self.showPairingPrompt(isRetry: true)
                return
            }
            let fm = FileManager.default
            let documentsPath = fm.documentsDirectory.appendingPathComponent(pairingFileName)
            if fm.fileExists(atPath: documentsPath.path) {
                try? fm.removeItem(at: documentsPath)
            }
            try pairingString.write(to: documentsPath, atomically: true, encoding: .utf8)
            debugLog("[LaunchViewController] Successfully copied and saved pairing file to: \(documentsPath.path)")
            UserDefaults.standard.isPairingReset = false
            
            Task {
                do {
                    try await AppBootManager.shared.startMinimuxer(pairingFile: pairingString)
                } catch {
                    await MainActor.run {
                        self.showPairingPrompt(isRetry: true)
                    }
                }
            }
        } catch {
            debugLog("[LaunchViewController] Error importing pairing file: \(error)")
            self.showPairingPrompt(isRetry: true)
        }
    }
    
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        self.showPairingPrompt(isRetry: true)
    }

    func fetchPairingFile() -> String? { AppBootManager.shared.getSavedPairingFile() }

    @MainActor
    func displayError(_ msg: String) {
        debugLog("[SideStore] \(msg)")
        let alert = UIAlertController(title: "Error launching SideStore", message: msg, preferredStyle: .alert)
        self.present(alert, animated: true)
    }
    
    func importAccountAtFile(_ file: URL, remove: Bool = false) {
        _ = file.startAccessingSecurityScopedResource()
        defer { file.stopAccessingSecurityScopedResource() }
        guard let accountD = try? Data(contentsOf: file) else {
            return debugLog("Could not parse data from file \(file)")
        }
        guard let account = try? Foundation.JSONDecoder().decode(ImportedAccount.self, from: accountD) else {
            return debugLog("Could not parse data from file \(file)")
        }
        debugLog("We want to import this account probably: \(account)")
        if remove {
            try? FileManager.default.removeItem(at: file)
        }
        Keychain.shared.reset()
        Keychain.shared.appleIDEmailAddress = account.email
        Keychain.shared.appleIDPassword = account.password
        Keychain.shared.adiPb = account.adiPB
        Keychain.shared.identifier = account.local_user
        do {
            let altCert = try ALTCertificate(p12Data: account.cert, password: account.certpass)
            Keychain.shared.signingCertificate = altCert.encryptedP12Data(withPassword: "")!
            Keychain.shared.signingCertificatePassword = account.certpass
            let toastView = ToastView(text: String(format: NSLocalizedString("Successfully imported '%@'!", comment: ""), account.email), detailText: "SideStore should be fully operational!")
            return toastView.show(in: self)
        } catch {
            let toastView = ToastView(text: NSLocalizedString("Failed to import account certificate!", comment: ""), detailText: "Error: \(error.localizedDescription). Still imported account/adi.pb details!")
            return toastView.show(in: self)
        }
    }
    
    func detectAndImportAccountFile() {
        let accountFileURL = FileManager.default.documentsDirectory.appendingPathComponent("Account.sideconf")
        #if !DEBUG
        importAccountAtFile(accountFileURL, remove: true)
        #else
        importAccountAtFile(accountFileURL)
        #endif
    }
}

extension LaunchViewController {
    @MainActor
    func handleLaunchError(_ error: Error, retryCallback: (() async -> Void)? = nil) {
        do { throw error } catch let error as NSError {
            let title = error.userInfo[NSLocalizedFailureErrorKey] as? String ?? NSLocalizedString("Unable to Launch SideStore", comment: "")
            let desc: String
            if #available(iOS 14.5, *) {
                desc = ([error.debugDescription] + error.underlyingErrors.map { ($0 as NSError).debugDescription }).joined(separator: "\n\n")
            } else {
                desc = error.debugDescription
            }
            let alert = UIAlertController(title: title, message: desc, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("Retry", comment: ""), style: .default) { _ in
                Task { await retryCallback?() }
            })
            present(alert, animated: true)
        }
    }

    @MainActor
    func finishLaunching() async {
        guard !didFinishLaunching else { return }
        didFinishLaunching = true
        
        AppManager.shared.update()
        ProxyStatusManager.shared.performWhenReady { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                guard let self = self, let destinationVC = self.destinationViewController else { return }
                AppManager.shared.updateAllSources { result in
                    guard case .failure(let error) = result else { return }
                    debugLog("Failed to update sources on launch. \(error.localizedDescription)")
                    
                    let errorDesc = ErrorProcessing(.fullError).getDescription(error: error as NSError)
                    debugLog("Failed to update sources on launch. \(errorDesc)")
                    
                    var mode: ToastView.InfoMode = .fullError
                    if String(describing: error).contains("The Internet connection appears to be offline"){
                        mode = .localizedDescription    // dont make noise!
                    }
                    let toastView = ToastView(error: error, mode: mode)
                    toastView.addTarget(destinationVC, action: #selector(TabBarController.presentSources), for: .touchUpInside)
                    toastView.show(in: destinationVC.selectedViewController ?? destinationVC)
                }
                self.updateKnownSources()
            }
        }
        WidgetCenter.shared.reloadAllTimelines()
        didFinishLaunching = true
        
        let destinationVC = destinationViewController!
        
        let elapsed = abs(startTime.timeIntervalSinceNow)
        let remaining = elapsed >= 1 ? 0 : 1 - elapsed
        try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        
        destinationVC.loadViewIfNeeded()
        addChild(destinationVC)
        destinationVC.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(destinationVC.view)
        destinationVC.didMove(toParent: self)
        
        // Pin edges BEFORE animation
        NSLayoutConstraint.activate([
            destinationVC.view.topAnchor.constraint(equalTo: view.topAnchor),
            destinationVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            destinationVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            destinationVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        // Set initial alpha for fade-in
        destinationVC.view.alpha = 0

        UIView.transition(with: view, duration: 0.3, options: .transitionCrossDissolve) { [self] in
            self.splashView.alpha = 0
            destinationVC.view.alpha = 1
        } completion: { [self] _ in
            self.splashView.removeFromSuperview()
            self.destinationViewController = destinationVC
            
            if AppBootManager.shared.needsPairingPrompt {
                self.showPairingPrompt(isRetry: false)
            }
            
            if AppBootManager.shared.needsSideJITPrompt {
                SideJITManager.shared.presentJITPrompt(presentingVC: self)
            }
        }
    }

    func updateKnownSources() {
        AppManager.shared.updateKnownSources { result in
            switch result {
            case .failure(let error): debugLog("[ALTLog] Failed to update known sources: \(error)")
            case .success((_, let blockedSources)):
                DatabaseManager.shared.persistentContainer.performBackgroundTask { context in
                    let blockedSourceIDs = Set(blockedSources.lazy.map { $0.identifier })
                    let blockedSourceURLs = Set(blockedSources.lazy.compactMap { $0.sourceURL })
                    let predicate = NSPredicate(format: "%K IN %@ OR %K IN %@", #keyPath(Source.identifier), blockedSourceIDs, #keyPath(Source.sourceURL), blockedSourceURLs)
                    let sourceErrors = Source.all(satisfying: predicate, in: context).map { source in
                        let blocked = blockedSources.first { $0.identifier == source.identifier }
                        return SourceError.blocked(source, bundleIDs: blocked?.bundleIDs, existingSource: source)
                    }
                    guard !sourceErrors.isEmpty else { return }
                    Task {
                        for error in sourceErrors {
                            let title = String(format: NSLocalizedString("“%@” Blocked", comment: ""), error.$source.name)
                            let message = [error.localizedDescription, error.recoverySuggestion].compactMap { $0 }.joined(separator: "\n\n")
                            await self.presentAlert(title: title, message: message)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - SplashView
final class SplashView: UIView {
    let iconView = UIImageView()
    let titleLabel = UILabel()
    private var iconContainer: UIView!

    init(frame: CGRect, appName: String) {
        super.init(frame: frame)
        setupIcon()
        setupTitle(appName: appName)
        setupSleekSpinner()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let sublayers = layer.sublayers, let grad = sublayers.first(where: { $0 is CAGradientLayer }) as? CAGradientLayer {
            grad.frame = bounds
        } else {
            let gradient = CAGradientLayer()
            gradient.frame = bounds
            gradient.colors = [
                UIColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1.0).cgColor,
                UIColor(red: 0.01, green: 0.01, blue: 0.02, alpha: 1.0).cgColor
            ]
            gradient.locations = [0.0, 1.0]
            layer.insertSublayer(gradient, at: 0)
        }
    }

    private func setupIcon() {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)
        self.iconContainer = container
        
        let blurEffect = UIBlurEffect(style: .systemThinMaterialDark)
        let blurView = UIVisualEffectView(effect: blurEffect)
        blurView.translatesAutoresizingMaskIntoConstraints = false
        blurView.layer.cornerRadius = 28
        blurView.clipsToBounds = true
        blurView.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        blurView.layer.borderWidth = 1.0
        container.addSubview(blurView)
        
        iconView.image = UIImage(named: "AppIcon") ?? UIImage(named: "AppIcon60x60") ?? UIImage(systemName: "app.fill")
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.layer.cornerRadius = 20
        iconView.clipsToBounds = true
        container.addSubview(iconView)
        
        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: centerXAnchor),
            container.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -30),
            container.widthAnchor.constraint(equalToConstant: 130),
            container.heightAnchor.constraint(equalToConstant: 130),
            
            blurView.topAnchor.constraint(equalTo: container.topAnchor),
            blurView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            blurView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            
            iconView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 84),
            iconView.heightAnchor.constraint(equalToConstant: 84)
        ])
    }

    private func setupTitle(appName: String) {
        titleLabel.text = appName
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: iconContainer.bottomAnchor, constant: 24),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor)
        ])
    }

    private func setupSleekSpinner() {
        let size: CGFloat = 36
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)
        
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 28),
            container.centerXAnchor.constraint(equalTo: centerXAnchor),
            container.widthAnchor.constraint(equalToConstant: size),
            container.heightAnchor.constraint(equalToConstant: size)
        ])
        
        let circularPath = UIBezierPath(arcCenter: CGPoint(x: size/2, y: size/2), radius: size/2 - 3, startAngle: 0, endAngle: CGFloat.pi * 2, clockwise: true)
        
        // Track layer
        let trackLayer = CAShapeLayer()
        trackLayer.path = circularPath.cgPath
        trackLayer.strokeColor = UIColor.white.withAlphaComponent(0.1).cgColor
        trackLayer.lineWidth = 3
        trackLayer.fillColor = UIColor.clear.cgColor
        container.layer.addSublayer(trackLayer)
        
        // Loading progress layer
        let loaderLayer = CAShapeLayer()
        loaderLayer.path = circularPath.cgPath
        loaderLayer.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
        loaderLayer.lineWidth = 3
        loaderLayer.fillColor = UIColor.clear.cgColor
        loaderLayer.strokeEnd = 0.3
        loaderLayer.lineCap = .round
        container.layer.addSublayer(loaderLayer)
        
        // Rotation animation
        let animation = CABasicAnimation(keyPath: "transform.rotation")
        animation.toValue = CGFloat.pi * 2
        animation.duration = 1.0
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        container.layer.add(animation, forKey: "spin")
    }
}


final class SideJITManager {
    static let shared = SideJITManager()
    
    @MainActor
    func presentJITPrompt(presentingVC: UIViewController) {
        let alert = UIAlertController(
            title: "SideJITServer Detected",
            message: "Would you like to enable SideJITServer",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in UserDefaults.standard.sidejitenable = true })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presentingVC.present(alert, animated: true)
    }
}
