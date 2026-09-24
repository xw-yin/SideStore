//
//  CompositeImportPickerViewController.swift
//  SideStore
//
//  Liquid Glass multi-select dialog shown when an imported pairing file is a
//  composite (dual-protocol) record, e.g. exported by iLoader. Lets the user
//  choose which protocol records to import instead of silently picking one.
//  Visual language mirrors AppIDCustomizationAlertViewController.
//

import UIKit
import Foundation
import MinimuxerCommon

/// Multi-select dialog for composite pairing files. Both rows start selected.
final class CompositeImportPickerViewController: UIViewController {

    /// Called with the selected protocols after the dialog dismisses.
    var onConfirm: (([PairingProtocol]) -> Void)?
    /// Called after the dialog dismisses without importing.
    var onCancel: (() -> Void)?

    private let modes: [PairingProtocol]
    private var selected: Set<PairingProtocol>

    private let cardEffectView = UIVisualEffectView()
    private var checkmarkViews: [PairingProtocol: UIImageView] = [:]
    private var importButton: UIButton!

    init(modes: [PairingProtocol]) {
        self.modes = modes
        self.selected = Set(modes)
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
        titleLabel.text = NSLocalizedString("Select Protocols to Import", comment: "")
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        stack.addArrangedSubview(titleLabel)

        let messageLabel = UILabel()
        messageLabel.text = NSLocalizedString(
            "This pairing file contains both Lockdown and Remote Pairing records. Choose which ones to import.",
            comment: ""
        )
        messageLabel.font = .systemFont(ofSize: 13, weight: .regular)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        stack.addArrangedSubview(messageLabel)

        let rowsStack = UIStackView()
        rowsStack.axis = .vertical
        rowsStack.spacing = 8
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(rowsStack)

        for (index, mode) in modes.enumerated() {
            let row = makeRowButton(for: mode, tag: index)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.heightAnchor.constraint(equalToConstant: 56).isActive = true
            rowsStack.addArrangedSubview(row)
        }

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

        var importConfig = UIButton.Configuration.filled()
        importConfig.title = NSLocalizedString("Import Selected", comment: "")
        importConfig.cornerStyle = .large
        importButton = UIButton(configuration: importConfig)
        importButton.addTarget(self, action: #selector(didTapImport), for: .touchUpInside)
        buttonStack.addArrangedSubview(importButton)

        stack.addArrangedSubview(buttonStack)
        updateSelectionUI()
    }

    private func makeRowButton(for mode: PairingProtocol, tag: Int) -> UIButton {
        let button = UIButton(type: .custom)
        button.tag = tag
        button.backgroundColor = .tertiarySystemFill
        button.layer.cornerRadius = 14
        button.layer.cornerCurve = .continuous
        button.addTarget(self, action: #selector(didTapRow(_:)), for: .touchUpInside)

        let rowStack = UIStackView()
        rowStack.axis = .horizontal
        rowStack.spacing = 12
        rowStack.alignment = .center
        rowStack.isUserInteractionEnabled = false
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 14),
            rowStack.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -14),
            rowStack.topAnchor.constraint(equalTo: button.topAnchor, constant: 8),
            rowStack.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -8),
        ])

        let (iconName, iconTint) = icon(for: mode)
        let iconView = UIImageView(image: UIImage(systemName: iconName))
        iconView.tintColor = iconTint
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 28).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 28).isActive = true
        rowStack.addArrangedSubview(iconView)

        let titleLabel = UILabel()
        titleLabel.text = title(for: mode)
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = .label
        rowStack.addArrangedSubview(titleLabel)

        let checkmark = UIImageView()
        checkmark.contentMode = .scaleAspectFit
        checkmark.tintColor = .systemBlue
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        checkmark.widthAnchor.constraint(equalToConstant: 22).isActive = true
        checkmark.heightAnchor.constraint(equalToConstant: 22).isActive = true
        rowStack.addArrangedSubview(checkmark)
        checkmarkViews[mode] = checkmark

        return button
    }

    // MARK: - Helpers

    private func icon(for mode: PairingProtocol) -> (String, UIColor) {
        switch mode {
        case .rppairing:
            return ("bolt.horizontal.circle.fill", .cyan)
        case .lockdown:
            return ("lock.shield.fill", .green)
        case .unknown:
            return ("questionmark.circle.fill", .gray)
        }
    }

    private func title(for mode: PairingProtocol) -> String {
        switch mode {
        case .rppairing:
            return NSLocalizedString("Remote Pairing File", comment: "")
        case .lockdown:
            return NSLocalizedString("Lockdown Pairing File", comment: "")
        case .unknown:
            return mode.rawValue
        }
    }

    private func updateSelectionUI() {
        for mode in modes {
            let isSelected = selected.contains(mode)
            checkmarkViews[mode]?.image = UIImage(
                systemName: isSelected ? "checkmark.circle.fill" : "circle"
            )
            checkmarkViews[mode]?.tintColor = isSelected ? .systemBlue : .tertiaryLabel
        }
        let canImport = !selected.isEmpty
        importButton.isEnabled = canImport
        importButton.alpha = canImport ? 1.0 : 0.5
    }

    // MARK: - Actions

    @objc private func didTapRow(_ sender: UIButton) {
        let mode = modes[sender.tag]
        if selected.contains(mode) {
            selected.remove(mode)
        } else {
            selected.insert(mode)
        }
        updateSelectionUI()
    }

    @objc private func didTapCancel() {
        dismiss(animated: true) { [onCancel] in
            onCancel?()
        }
    }

    @objc private func didTapImport() {
        let ordered = modes.filter { selected.contains($0) }
        debugLog("[PairingFile] Composite import confirmed: \(ordered.map(\.rawValue))")
        dismiss(animated: true) { [onConfirm] in
            onConfirm?(ordered)
        }
    }
}
