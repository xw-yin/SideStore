//
//  SettingsHeaderFooterView.swift
//  AltStore
//
//  Created by Riley Testut on 8/31/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit


final class SettingsHeaderFooterView: UITableViewHeaderFooterView
{
    @IBOutlet var primaryLabel: UILabel!
    @IBOutlet var secondaryLabel: UILabel!
    @IBOutlet var button: UIButton!
        
    @IBOutlet private var stackView: UIStackView!
    
    override func awakeFromNib()
    {
        super.awakeFromNib()
        
        self.preservesSuperviewLayoutMargins = false
        self.contentView.preservesSuperviewLayoutMargins = false
        self.insetsLayoutMarginsFromSafeArea = false
        self.contentView.insetsLayoutMarginsFromSafeArea = false
        self.updateContentMargins()
        
        self.stackView.translatesAutoresizingMaskIntoConstraints = false
        self.contentView.addSubview(self.stackView)
        
        NSLayoutConstraint.activate([self.stackView.leadingAnchor.constraint(equalTo: self.contentView.layoutMarginsGuide.leadingAnchor),
                                     self.stackView.trailingAnchor.constraint(equalTo: self.contentView.layoutMarginsGuide.trailingAnchor),
                                     self.stackView.topAnchor.constraint(equalTo: self.contentView.layoutMarginsGuide.topAnchor),
                                     self.stackView.bottomAnchor.constraint(equalTo: self.contentView.layoutMarginsGuide.bottomAnchor)])
    }

    override func safeAreaInsetsDidChange()
    {
        super.safeAreaInsetsDidChange()
        self.updateContentMargins()
    }

    private func updateContentMargins()
    {
        self.contentView.layoutMargins = UIEdgeInsets(
            top: 8,
            left: self.safeAreaInsets.left + 30,
            bottom: 8,
            right: self.safeAreaInsets.right + 30
        )
    }
}
