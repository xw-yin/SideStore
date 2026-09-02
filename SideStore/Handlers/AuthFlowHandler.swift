//
//  AuthFlowHandler.swift
//  SideStore
//
//  Created by Magesh K on 8/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import UIKit
import SideSign

class AuthFlowHandler: AnyObject, AuthenticationHandler, AnisetteServerHandler {
    
    private weak var presentingViewController: UIViewController?
    private weak var presentedAuthVC: AuthenticationViewController?
    
    private var credentialsContinuation: CheckedContinuation<(String, String), Error>?
    private var activeAuthCompletionHandler: ((Result<(ALTAccount, ALTAppleAPISession), Error>) -> Void)?
    
    private lazy var navigationController: UINavigationController = {
        let storyboard = UIStoryboard(name: "Authentication", bundle: nil)
        let navigationController = storyboard.instantiateViewController(withIdentifier: "navigationController") as! UINavigationController
        navigationController.isModalInPresentation = true
        return navigationController
    }()
    
    init(presentingViewController: UIViewController?) {
        self.presentingViewController = presentingViewController
    }

    private var isPresenterAvailable: Bool {
        return self.presentingViewController != nil || self.navigationController.presentingViewController != nil
    }

    private var activePresenter: UIViewController? {
        if self.navigationController.presentingViewController != nil {
            return self.navigationController
        }
        return self.presentingViewController?.presentedViewController ?? self.presentingViewController
    }
    
    @MainActor
    func credentials() async throws -> (String, String) {
        guard let presentingViewController = self.presentingViewController else {
            throw OperationError.invalidOperationContext("AuthFlowHandler: Cannot prompt for credentials because presentingViewController is nil")
        }
        
        if let _ = self.presentedAuthVC {
            return try await withCheckedThrowingContinuation { continuation in
                self.credentialsContinuation = continuation
            }
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            self.credentialsContinuation = continuation
            
            let storyboard = UIStoryboard(name: "Authentication", bundle: nil)
            let authVC = storyboard.instantiateViewController(withIdentifier: "authenticationViewController") as! AuthenticationViewController
            self.presentedAuthVC = authVC
            
            authVC.authenticationHandler = { [weak self] (appleID, password, completionHandler) in
                guard let self = self else { return }
                self.activeAuthCompletionHandler = completionHandler
                if let credsContinuation = self.credentialsContinuation {
                    self.credentialsContinuation = nil
                    credsContinuation.resume(returning: (appleID, password))
                }
            }
            
            authVC.completionHandler = { [weak self] (result) in
                guard let self = self else { return }
                if result == nil {
                    // Cancelled
                    if let credsContinuation = self.credentialsContinuation {
                        self.credentialsContinuation = nil
                        credsContinuation.resume(throwing: OperationError.cancelled)
                    }
                    self.presentedAuthVC = nil
                    
                    if self.navigationController.presentingViewController != nil {
                        self.navigationController.dismiss(animated: true)
                    }
                } else {
                    // Success (dismissed)
                    self.presentedAuthVC = nil
                }
            }
            
            self.navigationController.navigationBar.tintColor = .altPrimary
            self.navigationController.setViewControllers([authVC], animated: false)
            presentingViewController.present(self.navigationController, animated: true)
        }
    }
    
    @MainActor
    func handleSignInResult(_ result: Result<(ALTAccount, ALTAppleAPISession), Error>) async {
        if let completionHandler = self.activeAuthCompletionHandler {
            self.activeAuthCompletionHandler = nil
            switch result {
            case .success((let account, let session)):
                completionHandler(.success((account, session)))
            case .failure(let error):
                completionHandler(.failure(error))
            }
        }
    }
    
    @MainActor
    func verificationCode(for mode: TwoFactorMode) async throws -> TwoFactorAction {
        guard self.isPresenterAvailable else {
            throw OperationError.invalidOperationContext("AuthFlowHandler: Cannot prompt for 2FA verification code because presenting view controller is unavailable")
        }

        let errorMessage: String?
        switch mode {
        case .trustedDevice(let error):
            errorMessage = error
        case .sms(_, _, let error):
            errorMessage = error
        case .voice(_, _, let error):
            errorMessage = error
        }

        if let errorMessage, !errorMessage.isEmpty {
            let shouldRetry = try await showErrorRetryAlert(message: errorMessage)
            guard shouldRetry else {
                return .cancel
            }
        }

        switch mode {
        case .trustedDevice:
            return try await promptCodeEntry(
                title: NSLocalizedString("Please enter the 6-digit verification code that was sent to your Apple devices.", comment: ""),
                phoneNumbers: [],
                activePhoneID: "",
                currentDeliveryMode: nil,
                isTrustedDevice: true
            )

        case .sms(let phoneNumbers, let activeID, _):
            let activePhone = phoneNumbers.first(where: { $0.id == activeID })
            let title: String
            if let activePhone, !activePhone.number.isEmpty {
                title = String(format: NSLocalizedString("Please enter the 6-digit verification code sent via SMS to %@.", comment: ""), activePhone.number)
            } else {
                title = NSLocalizedString("Please enter the 6-digit verification code sent via SMS to your phone.", comment: "")
            }
            return try await promptCodeEntry(
                title: title,
                phoneNumbers: phoneNumbers,
                activePhoneID: activeID,
                currentDeliveryMode: .sms,
                isTrustedDevice: false
            )

        case .voice(let phoneNumbers, let activeID, _):
            let activePhone = phoneNumbers.first(where: { $0.id == activeID })
            let title: String
            if let activePhone, !activePhone.number.isEmpty {
                title = String(format: NSLocalizedString("Please enter the 6-digit verification code sent via phone call to %@.", comment: ""), activePhone.number)
            } else {
                title = NSLocalizedString("Please enter the 6-digit verification code sent via phone call.", comment: "")
            }
            return try await promptCodeEntry(
                title: title,
                phoneNumbers: phoneNumbers,
                activePhoneID: activeID,
                currentDeliveryMode: .voice,
                isTrustedDevice: false
            )
        }
    }

    @MainActor
    private func showErrorRetryAlert(message: String) async throws -> Bool {
        return try await withCheckedThrowingContinuation { continuation in
            let alert = UIAlertController(
                title: NSLocalizedString("Verification Failed", comment: ""),
                message: message,
                preferredStyle: .alert
            )
            
            alert.addAction(UIAlertAction(title: NSLocalizedString("Retry", comment: ""), style: .default) { _ in
                continuation.resume(returning: true)
            })

            alert.addAction(UIAlertAction(title: RSTSystemLocalizedString("Cancel"), style: .cancel) { _ in
                continuation.resume(returning: false)
            })

            self.present(alert)
        }
    }

    @MainActor
    private func promptCodeEntry(title: String,
                                 phoneNumbers: [TrustedPhoneNumber],
                                 activePhoneID: String,
                                 currentDeliveryMode: TwoFactorDeliveryMode?,
                                 isTrustedDevice: Bool) async throws -> TwoFactorAction
    {
        return try await withCheckedThrowingContinuation { continuation in
            let alertController = UIAlertController(title: title, message: nil, preferredStyle: .alert)
            var observer: NSObjectProtocol?
            alertController.addTextField { (textField) in
                textField.autocorrectionType = .no
                textField.autocapitalizationType = .none
                textField.keyboardType = .numberPad
                
                observer = NotificationCenter.default.addObserver(forName: UITextField.textDidChangeNotification, object: textField, queue: .main) { (notification) in
                    guard let textField = notification.object as? UITextField else { return }
                    alertController.actions.first?.isEnabled = (textField.text ?? "").count == 6
                }
            }
            
            let submitAction = UIAlertAction(title: NSLocalizedString("Continue", comment: ""), style: .default) { _ in
                if let observer = observer {
                    NotificationCenter.default.removeObserver(observer)
                }
                let textField = alertController.textFields?.first
                let code = textField?.text ?? ""
                continuation.resume(returning: .code(code))
            }
            submitAction.isEnabled = false
            alertController.addAction(submitAction)

            if isTrustedDevice {
                let smsAction = UIAlertAction(title: NSLocalizedString("Send Code to Phone", comment: ""), style: .default) { [weak self] _ in
                    if let observer = observer {
                        NotificationCenter.default.removeObserver(observer)
                    }
                    guard let self = self else {
                        continuation.resume(returning: .cancel)
                        return
                    }
                    self.showDeliveryMethodDialog(phoneNumbers: phoneNumbers, activeID: activePhoneID.isEmpty ? "1" : activePhoneID, continuation: continuation)
                }
                alertController.addAction(smsAction)
            } else if let mode = currentDeliveryMode {
                let resendTitle = (mode == .sms)
                    ? NSLocalizedString("Resend SMS", comment: "")
                    : NSLocalizedString("Call Again", comment: "")
                let resendAction = UIAlertAction(title: resendTitle, style: .default) { _ in
                    if let observer = observer {
                        NotificationCenter.default.removeObserver(observer)
                    }
                    continuation.resume(returning: .requestPhone(id: activePhoneID, mode: mode))
                }
                alertController.addAction(resendAction)

                let switchTitle = (mode == .sms)
                    ? NSLocalizedString("Call Me Instead", comment: "")
                    : NSLocalizedString("Send SMS Instead", comment: "")
                let oppositeMode: TwoFactorDeliveryMode = (mode == .sms) ? .voice : .sms
                let switchModeAction = UIAlertAction(title: switchTitle, style: .default) { _ in
                    if let observer = observer {
                        NotificationCenter.default.removeObserver(observer)
                    }
                    continuation.resume(returning: .requestPhone(id: activePhoneID, mode: oppositeMode))
                }
                alertController.addAction(switchModeAction)

                if phoneNumbers.count > 1 {
                    let changeNumberAction = UIAlertAction(title: NSLocalizedString("Choose Different Number", comment: ""), style: .default) { [weak self] _ in
                        if let observer = observer {
                            NotificationCenter.default.removeObserver(observer)
                        }
                        guard let self = self else {
                            continuation.resume(returning: .cancel)
                            return
                        }
                        self.showPhoneNumberSelectionDialog(phoneNumbers: phoneNumbers, activeID: activePhoneID, mode: mode, continuation: continuation)
                    }
                    alertController.addAction(changeNumberAction)
                }
            }
            
            alertController.addAction(UIAlertAction(title: RSTSystemLocalizedString("Cancel"), style: .cancel) { _ in
                if let observer = observer {
                    NotificationCenter.default.removeObserver(observer)
                }
                continuation.resume(returning: .cancel)
            })
            
            self.present(alertController)
        }
    }

    @MainActor
    private func showDeliveryMethodDialog(phoneNumbers: [TrustedPhoneNumber],
                                          activeID: String,
                                          continuation: CheckedContinuation<TwoFactorAction, Error>)
    {
        let alert = UIAlertController(
            title: NSLocalizedString("Verification Method", comment: ""),
            message: NSLocalizedString("How would you like to receive your verification code?", comment: ""),
            preferredStyle: .alert
        )

        let smsAction = UIAlertAction(title: NSLocalizedString("Text Message (SMS)", comment: ""), style: .default) { [weak self] _ in
            guard let self = self else {
                continuation.resume(returning: .cancel)
                return
            }
            if phoneNumbers.count > 1 {
                self.showPhoneNumberSelectionDialog(phoneNumbers: phoneNumbers, activeID: activeID, mode: .sms, continuation: continuation)
            } else {
                let targetID = phoneNumbers.first?.id ?? activeID
                continuation.resume(returning: .requestPhone(id: targetID, mode: .sms))
            }
        }
        alert.addAction(smsAction)

        let voiceAction = UIAlertAction(title: NSLocalizedString("Phone Call", comment: ""), style: .default) { [weak self] _ in
            guard let self = self else {
                continuation.resume(returning: .cancel)
                return
            }
            if phoneNumbers.count > 1 {
                self.showPhoneNumberSelectionDialog(phoneNumbers: phoneNumbers, activeID: activeID, mode: .voice, continuation: continuation)
            } else {
                let targetID = phoneNumbers.first?.id ?? activeID
                continuation.resume(returning: .requestPhone(id: targetID, mode: .voice))
            }
        }
        alert.addAction(voiceAction)

        alert.addAction(UIAlertAction(title: RSTSystemLocalizedString("Cancel"), style: .cancel) { _ in
            continuation.resume(returning: .cancel)
        })

        self.present(alert)
    }

    @MainActor
    private func showPhoneNumberSelectionDialog(phoneNumbers: [TrustedPhoneNumber],
                                                 activeID: String,
                                                 mode: TwoFactorDeliveryMode,
                                                 continuation: CheckedContinuation<TwoFactorAction, Error>)
    {
        let alert = UIAlertController(
            title: NSLocalizedString("Select Phone Number", comment: ""),
            message: NSLocalizedString("Choose a phone number to receive your verification code:", comment: ""),
            preferredStyle: .alert
        )

        for phone in phoneNumbers {
            let isCurrent = (phone.id == activeID)
            let buttonTitle = isCurrent ? "\(phone.number) (Current)" : phone.number
            let action = UIAlertAction(title: buttonTitle, style: .default) { _ in
                continuation.resume(returning: .requestPhone(id: phone.id, mode: mode))
            }
            alert.addAction(action)
        }

        alert.addAction(UIAlertAction(title: RSTSystemLocalizedString("Cancel"), style: .cancel) { _ in
            continuation.resume(returning: .cancel)
        })

        self.present(alert)
    }
    
    @MainActor
    func resolveRevocation(certificates: [ALTX509Certificate], teamType: ALTTeamType) async throws -> RevokeDecision {
        guard self.isPresenterAvailable else {
            throw OperationError.invalidOperationContext("AuthFlowHandler: Cannot resolve certificate revocation because presenting view controller is unavailable")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let alertController = UIAlertController(
                title: NSLocalizedString("Revoke Certificates", comment: ""),
                message: NSLocalizedString("Select iOS Development certificate(s) to revoke:", comment: ""),
                preferredStyle: .alert
            )
            
            let revokeVC = RevokeCertificatesAlertViewController(certificates: certificates, teamType: teamType)
            alertController.setValue(revokeVC, forKey: "contentViewController")
            
            let cancelAction = UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in
                if teamType == .free {
                    let warningAlert = UIAlertController(
                        title: NSLocalizedString("Warning", comment: ""),
                        message: NSLocalizedString("SideStore cannot manage the existing certificate without owning its private key. The apps signed with the existing certificate will expire soon unless they are resigned and renewed explicitly by SideStore.", comment: ""),
                        preferredStyle: .alert
                    )
                    warningAlert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default) { _ in
                        warningAlert.dismiss(animated: true) {
                            continuation.resume(returning: .keepExisting)
                        }
                    })
                    self.present(warningAlert)
                } else {
                    continuation.resume(returning: .keepExisting)
                }
            }
            
            let isPaid = (teamType != .free)
            let initialCount = revokeVC.getSelectedCertificates().count
            let initialTitle = isPaid ? "Revoke Selected (\(initialCount))" : NSLocalizedString("Revoke", comment: "")
            let revokeAction = UIAlertAction(title: initialTitle, style: .destructive) { _ in
                alertController.dismiss(animated: true) {
                    let selected = revokeVC.getSelectedCertificates()
                    continuation.resume(returning: .revokeSelected(selected))
                }
            }
            
            if isPaid {
                revokeAction.isEnabled = !revokeVC.getSelectedCertificates().isEmpty
                revokeVC.onSelectionChanged = { selected in
                    revokeAction.isEnabled = !selected.isEmpty
                    let countText = selected.isEmpty ? "" : " (\(selected.count))"
                    revokeAction.setValue("Revoke Selected\(countText)", forKey: "title")
                }
            }
            
            alertController.addAction(cancelAction)
            alertController.addAction(revokeAction)
            
            self.present(alertController)
        }
    }
    
    @MainActor
    func resolveTeam(_ teams: [ALTTeam]) async throws -> ALTTeam {
        guard self.isPresenterAvailable else {
            throw OperationError.invalidOperationContext("AuthFlowHandler: Cannot resolve team selection because presenting view controller is unavailable")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let storyboard = UIStoryboard(name: "Authentication", bundle: nil)
            let selectTeamViewController = storyboard.instantiateViewController(withIdentifier: "selectTeamViewController") as! SelectTeamViewController
            selectTeamViewController.teams = teams
            selectTeamViewController.completionHandler = { result in
                continuation.resume(with: result)
            }
            self.present(selectTeamViewController)
        }
    }
    
    @MainActor
    func resolvePostAuth() async {
        await withCheckedContinuation { continuation in
            var hasResumed = false
            let storyboard = UIStoryboard(name: "Authentication", bundle: nil)
            let instructionsViewController = storyboard.instantiateViewController(withIdentifier: "instructionsViewController") as! InstructionsViewController
            instructionsViewController.showsBottomButton = true
            instructionsViewController.completionHandler = {
                guard !hasResumed else {
                    debugLog("[AuthFlowHandler] resolvePostAuth completionHandler invoked more than once. Ignoring.")
                    return
                }
                hasResumed = true
                continuation.resume(returning: ())
            }
            self.present(instructionsViewController)
        }
    }
    
    @MainActor
    func resolveProvisioningError(_ error: Error) async -> ProvisioningErrorDecision {
        return await withCheckedContinuation { continuation in
            let alertController = UIAlertController(
                title: NSLocalizedString("Developer Portal Error", comment: ""),
                message: error.localizedDescription,
                preferredStyle: .alert
            )
            
            let cancelAction = UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel) { _ in
                alertController.dismiss(animated: true) {
                    continuation.resume(returning: .cancel)
                }
            }
            
            let retryAction = UIAlertAction(title: NSLocalizedString("Retry", comment: ""), style: .default) { _ in
                alertController.dismiss(animated: true) {
                    continuation.resume(returning: .retry)
                }
            }
            
            alertController.addAction(cancelAction)
            alertController.addAction(retryAction)
            
            self.present(alertController)
        }
    }
    
    @MainActor
    func resolveResign(mismatchReason: CodeSignValidationReason, context: AuthenticatedOperationContext) async throws -> Bool {
        guard self.isPresenterAvailable else {
            throw OperationError.invalidOperationContext("AuthFlowHandler: Cannot resolve resign prompt because presenting view controller is unavailable")
        }

        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            let storyboard = UIStoryboard(name: "Authentication", bundle: nil)
            let resignViewController = storyboard.instantiateViewController(withIdentifier: "resignAltStoreViewController") as! ResignAltStoreViewController
            resignViewController.context = context
            resignViewController.mismatchReason = mismatchReason
            resignViewController.completionHandler = { result in
                guard !hasResumed else {
                    debugLog("[AuthFlowHandler] resolveResign completionHandler invoked more than once. Ignoring.")
                    return
                }
                hasResumed = true
                switch result {
                case .success:
                    continuation.resume(returning: true)
                case .failure:
                    continuation.resume(returning: false)
                }
            }
            self.present(resignViewController)
        }
    }
    
    @MainActor
    func complete() async {
        if self.navigationController.presentingViewController != nil {
            self.navigationController.dismiss(animated: true)
        }
    }
    
    @MainActor
    private func present(_ viewController: UIViewController) {
        let anchorVC = self.activePresenter
        if viewController is UIAlertController {
            anchorVC?.present(viewController, animated: true)
            return
        }
        
        if self.navigationController.presentingViewController != nil {
            if self.navigationController.viewControllers.contains(viewController) {
                // Already in stack
            } else {
                viewController.navigationItem.leftBarButtonItem = nil
                self.navigationController.pushViewController(viewController, animated: true)
            }
        } else {
            self.navigationController.setViewControllers([viewController], animated: false)
            anchorVC?.present(self.navigationController, animated: true)
        }
    }

    @MainActor
    func warnOutdatedAnisetteServer() async throws -> Bool {
        guard let presenter = self.activePresenter else {
            throw OperationError.invalidOperationContext("AuthFlowHandler: Cannot show outdated anisette warning because presenting view controller is unavailable")
        }
        
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: "WARNING: Outdated anisette server", message: "We've detected you are using an older anisette server. Using this server has a higher likelihood of locking your account and causing other issues. Are you sure you want to continue?", preferredStyle: UIAlertController.Style.alert)
            alert.addAction(UIAlertAction(title: "Continue", style: UIAlertAction.Style.destructive, handler: { action in
                continuation.resume(returning: true)
            }))
            alert.addAction(UIAlertAction(title: "Cancel", style: UIAlertAction.Style.cancel, handler: { action in
                continuation.resume(returning: false)
            }))
            
            presenter.present(alert, animated: true)
        }
    }
}
