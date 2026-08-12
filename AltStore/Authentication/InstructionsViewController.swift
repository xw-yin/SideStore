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
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
    
    override func viewDidLoad()
    {
        super.viewDidLoad()
        
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
        
        if let scrollView = self.view.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView,
           let containerView = scrollView.subviews.first {
            containerView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor).isActive = true
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
