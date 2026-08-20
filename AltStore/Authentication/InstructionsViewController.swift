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
    @IBOutlet private var scrollView: UIScrollView!
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .default
    }
    
    override func viewDidLoad()
    {
        super.viewDidLoad()
        
        let safeArea = self.view.safeAreaLayoutGuide
        if let scrollView = self.scrollView {
            NSLayoutConstraint.activate([
                self.scrollView.topAnchor.constraint(equalTo: safeArea.topAnchor),
                self.scrollView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
                self.contentStackView.widthAnchor.constraint(equalTo: self.scrollView.frameLayoutGuide.widthAnchor)
            ])
        }
        
        for view in self.contentStackView.arrangedSubviews {
            if let label = view as? UILabel {
                label.textColor = .secondaryLabel
            }
        }
        
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
}

private extension InstructionsViewController
{
    @IBAction func dismiss()
    {
        self.completionHandler?()
    }
}
