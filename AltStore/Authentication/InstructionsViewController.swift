//
//  InstructionsViewController.swift
//  AltStore
//
//  Created by Riley Testut on 9/6/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit

final class InstructionsViewController: UIViewController
{
    var completionHandler: (() -> Void)?
    
    var showsBottomButton: Bool = false
    
    @IBOutlet private var contentStackView: UIStackView!
    @IBOutlet private var dismissButton: UIButton!

    private let scrollView = UIScrollView()
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .default
    }
    
    override func viewDidLoad()
    {
        super.viewDidLoad()

        self.configureAdaptiveAppearance()
        self.embedContentInScrollView()
        
        if UIScreen.main.isExtraCompactHeight
        {
            self.contentStackView.layoutMargins.top = 0
            self.contentStackView.layoutMargins.bottom = self.contentStackView.layoutMargins.left
        }
        
        self.dismissButton.clipsToBounds = true
        self.dismissButton.layer.cornerRadius = 16
        
        if self.showsBottomButton
        {
            self.navigationItem.hidesBackButton = true
        }
        else
        {
            self.dismissButton.isHidden = true
        }
        
    }

    private func configureAdaptiveAppearance()
    {
        self.view.backgroundColor = .systemGroupedBackground

        for label in self.contentStackView.allDescendants.compactMap({ $0 as? UILabel })
        {
            if label.font.pointSize >= 70
            {
                label.textColor = .tertiaryLabel
            }
            else if label.font.fontDescriptor.symbolicTraits.contains(.traitBold)
            {
                label.textColor = .label
            }
            else
            {
                label.textColor = .secondaryLabel
            }
        }
    }

    private func embedContentInScrollView()
    {
        let constraintsToRemove = self.view.constraints.filter {
            ($0.firstItem as? UIView) === self.contentStackView ||
            ($0.secondItem as? UIView) === self.contentStackView
        }
        NSLayoutConstraint.deactivate(constraintsToRemove)

        self.scrollView.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView.alwaysBounceVertical = true
        self.scrollView.keyboardDismissMode = .interactive
        self.view.insertSubview(self.scrollView, belowSubview: self.dismissButton)

        self.contentStackView.removeFromSuperview()
        self.scrollView.addSubview(self.contentStackView)

        let safeArea = self.view.safeAreaLayoutGuide
        let bottomAnchor = self.showsBottomButton ? self.dismissButton.topAnchor : safeArea.bottomAnchor
        NSLayoutConstraint.activate([
            self.scrollView.topAnchor.constraint(equalTo: safeArea.topAnchor),
            self.scrollView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            self.scrollView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            self.scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            self.contentStackView.topAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.topAnchor),
            self.contentStackView.leadingAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.leadingAnchor),
            self.contentStackView.trailingAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.trailingAnchor),
            self.contentStackView.bottomAnchor.constraint(equalTo: self.scrollView.contentLayoutGuide.bottomAnchor),
            self.contentStackView.widthAnchor.constraint(equalTo: self.scrollView.frameLayoutGuide.widthAnchor)
        ])
    }
}

private extension UIView
{
    var allDescendants: [UIView] {
        return self.subviews + self.subviews.flatMap(\.allDescendants)
    }
}

private extension InstructionsViewController
{
    @IBAction func dismiss()
    {
        self.completionHandler?()
    }
}
