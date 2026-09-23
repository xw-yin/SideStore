//
//  AppIDCustomizationAlertViewController.swift
//  SideStore
//
//  Liquid Glass replacement for the AppID customization UIAlertController.
//  The old implementation performed surgery on UIAlertController's private
//  view hierarchy (hiding a second text field, restyling its containers),
//  which caused asymmetric input margins and a stray separator line.
//  This view controller draws the whole dialog itself: symmetric 16pt
//  margins everywhere, no leftover separators.
//

@preconcurrency import UIKit
import Foundation
import SideSign

/// Alert-style dialog that lets the user customize the App ID (bundle ID)
/// and choose whether the Team ID suffix is appended.
final class AppIDCustomizationAlertViewController: UIViewController {

    /// Called with the confirmed result, or `nil` when cancelled.
    var onComplete: (((customID: String, appendTeamID: Bool)?) -> Void)?

    private let initialText: String
    private let fallbackBaseID: String
    private let teamID: String

    private let checkboxView: AppendTeamIDCheckboxView
    private let textField = UITextField()
    private let cardEffectView = UIVisualEffectView()

    init(initialText: String, fallbackBaseID: String, teamID: String) {
        self.initialText = initialText
        self.fallbackBaseID = fallbackBaseID
        self.teamID = teamID
        self.checkboxView = AppendTeamIDCheckboxView(isChecked: true, teamID: teamID)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        setupCard()
        setupContent()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        cardEffectView.transform = CGAffineTransform(scaleX: 1.04, y: 1.04)
        cardEffectView.alpha = 0
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseOut) {
            self.cardEffectView.transform = .identity
            self.cardEffectView.alpha = 1
        } completion: { _ in
            self.textField.becomeFirstResponder()
        }
    }

    // MARK: - Setup

    private func setupCard() {
        if #available(iOS 26.0, tvOS 26.0, *) {
            let glass = UIGlassEffect()
            glass.isInteractive = true
            cardEffectView.effect = glass
        } else {
            cardEffectView.effect = UIBlurEffect(style: .systemMaterial)
        }
        cardEffectView.layer.cornerRadius = 28
        cardEffectView.layer.cornerCurve = .continuous
        cardEffectView.clipsToBounds = true
        cardEffectView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cardEffectView)

        let widthConstraint = cardEffectView.widthAnchor.constraint(equalToConstant: 300)
        widthConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            cardEffectView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cardEffectView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            widthConstraint,
            cardEffectView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            cardEffectView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
    }

    private func setupContent() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        cardEffectView.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: cardEffectView.contentView.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: cardEffectView.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: cardEffectView.contentView.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: cardEffectView.contentView.bottomAnchor, constant: -16),
        ])

        let titleLabel = UILabel()
        titleLabel.text = NSLocalizedString("AppID Customization", comment: "")
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        stack.addArrangedSubview(titleLabel)

        let messageLabel = UILabel()
        messageLabel.text = NSLocalizedString("Customize the AppID if required and press 'Confirm' to proceed.", comment: "")
        messageLabel.font = .systemFont(ofSize: 13, weight: .regular)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        stack.addArrangedSubview(messageLabel)

        textField.text = initialText
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.clearButtonMode = .whileEditing
        textField.font = .systemFont(ofSize: 15, weight: .regular)
        textField.textColor = .label
        textField.backgroundColor = .tertiarySystemFill
        textField.layer.cornerRadius = 14
        textField.layer.cornerCurve = .continuous
        let leftPad = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        textField.leftView = leftPad
        textField.leftViewMode = .always
        let rightPad = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        textField.rightView = rightPad
        textField.rightViewMode = .always
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.heightAnchor.constraint(equalToConstant: 46).isActive = true
        stack.addArrangedSubview(textField)
        checkboxView.attach(to: textField, teamID: teamID)

        checkboxView.translatesAutoresizingMaskIntoConstraints = false
        checkboxView.heightAnchor.constraint(equalToConstant: 40).isActive = true
        stack.addArrangedSubview(checkboxView)

        let buttonStack = UIStackView()
        buttonStack.axis = .horizontal
        buttonStack.spacing = 12
        buttonStack.distribution = .fillEqually
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.heightAnchor.constraint(equalToConstant: 48).isActive = true

        var cancelConfig = UIButton.Configuration.tinted()
        cancelConfig.title = NSLocalizedString("Cancel", comment: "")
        cancelConfig.cornerStyle = .large
        let cancelButton = UIButton(configuration: cancelConfig)
        cancelButton.addTarget(self, action: #selector(didTapCancel), for: .touchUpInside)
        buttonStack.addArrangedSubview(cancelButton)

        var confirmConfig = UIButton.Configuration.filled()
        confirmConfig.title = NSLocalizedString("Confirm", comment: "")
        confirmConfig.cornerStyle = .large
        let confirmButton = UIButton(configuration: confirmConfig)
        confirmButton.addTarget(self, action: #selector(didTapConfirm), for: .touchUpInside)
        buttonStack.addArrangedSubview(confirmButton)

        stack.addArrangedSubview(buttonStack)
    }

    // MARK: - Actions

    @objc private func didTapCancel() {
        dismiss(animated: true) { [onComplete] in
            onComplete?(nil)
        }
    }

    @objc private func didTapConfirm() {
        let baseID = checkboxView.cleanBaseID()
        let customID = InfoPlistParser.sanitizeBundleID(!baseID.isEmpty ? baseID : fallbackBaseID)
        let appendTeamID = checkboxView.isChecked
        debugLog("[PipelineHandler] resolveBundleIDOverride confirmed: baseID='\(baseID)', customID='\(customID)', appendTeamID=\(appendTeamID)")
        dismiss(animated: true) { [onComplete] in
            onComplete?((customID, appendTeamID))
        }
    }
}
