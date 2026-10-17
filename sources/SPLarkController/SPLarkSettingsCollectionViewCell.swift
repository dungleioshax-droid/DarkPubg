// The MIT License (MIT)
// Copyright © 2017 Ivan Vorobei (hello@ivanvorobei.by)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import UIKit

@available(iOS 8.2, *)
public class SPLarkSettingsCollectionViewCell: UICollectionViewCell {

    let titleLabel = UILabel()
    let subtitleLabel = UILabel()
    let backgroundColorView = UIView()
    let iconImageView = UIImageView()

    private static let pressDownScale: CGFloat = 0.92
    private static let animationDuration: TimeInterval = 0.4
    private static let animationDamping: CGFloat = 0.6

    private func animatePress() {
        UIView.animate(withDuration: Self.animationDuration, delay: 0, usingSpringWithDamping: Self.animationDamping, initialSpringVelocity: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction], animations: {
            self.transform = CGAffineTransform(scaleX: Self.pressDownScale, y: Self.pressDownScale)
        }, completion: nil)
    }

    private func animateRelease() {
        UIView.animate(withDuration: Self.animationDuration, delay: 0, usingSpringWithDamping: Self.animationDamping, initialSpringVelocity: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction], animations: {
            self.transform = .identity
        }, completion: nil)
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        animatePress()
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        animateRelease()
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        animateRelease()
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        self.commonInit()
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        self.commonInit()
    }
    
    func commonInit() {
        self.backgroundColor = .clear

        self.backgroundColorView.layer.masksToBounds = true
        self.backgroundColorView.layer.cornerRadius = 18
        self.backgroundColorView.layer.borderWidth = 1
        self.backgroundColorView.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        self.contentView.addSubview(self.backgroundColorView)

        self.iconImageView.contentMode = .scaleAspectFit
        self.iconImageView.tintColor = UIColor.white.withAlphaComponent(0.9)
        self.contentView.addSubview(self.iconImageView)

        self.titleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        self.titleLabel.numberOfLines = 0
        self.titleLabel.textAlignment = .left
        self.titleLabel.baselineAdjustment = .alignBaselines
        self.titleLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        self.titleLabel.text = "Title"
        self.contentView.addSubview(self.titleLabel)

        self.subtitleLabel.font = UIFont.systemFont(ofSize: 16, weight: .bold)
        self.subtitleLabel.numberOfLines = 1
        self.subtitleLabel.textAlignment = .left
        self.subtitleLabel.textColor = UIColor.white
        self.subtitleLabel.text = "Subtitle"
        self.contentView.addSubview(self.subtitleLabel)
    }
    
    func setHighlighted(_ state: Bool, color: UIColor) {
        self.backgroundColorView.backgroundColor = color
    }
    
    func setEnabled(_ enabled: Bool) {
        self.contentView.alpha = enabled ? 1.0 : 0.4
        self.isUserInteractionEnabled = enabled
    }
    
    public override func prepareForReuse() {
        super.prepareForReuse()
        self.contentView.alpha = 1.0
        self.isUserInteractionEnabled = true
        self.titleLabel.text = "Title"
        self.subtitleLabel.text = "Subtitle"
        self.layoutSubviews()
    }
    
    public override func layoutSubviews() {
        super.layoutSubviews()

        self.backgroundColorView.frame = self.contentView.bounds

        let sideInset: CGFloat = 14
        let iconSize: CGFloat = 22
        let iconX: CGFloat = sideInset
        let textX: CGFloat = sideInset + iconSize + 10

        self.iconImageView.frame = CGRect(x: iconX, y: (self.contentView.frame.height - iconSize) / 2, width: iconSize, height: iconSize)

        if self.subtitleLabel.text == nil {
            self.titleLabel.frame = CGRect(
                x: textX,
                y: 0,
                width: self.contentView.frame.width - textX - sideInset,
                height: self.contentView.frame.height
            )
        } else {
            let topInset: CGFloat = 10
            self.subtitleLabel.sizeToFit()
            self.subtitleLabel.frame = CGRect(
                x: textX,
                y: self.contentView.frame.height - topInset - self.subtitleLabel.frame.height,
                width: self.contentView.frame.width - textX - sideInset,
                height: self.subtitleLabel.frame.height
            )

            self.titleLabel.frame = CGRect(
                x: textX,
                y: topInset,
                width: self.contentView.frame.width - textX - sideInset,
                height: self.subtitleLabel.frame.minY - topInset
            )
        }
    }
}
