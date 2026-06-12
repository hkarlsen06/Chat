//
//  String+Style.swift
//  Chat
//
//  Created by Matthew Fennell on 01/03/2025.
//

import Foundation
import UIKit

extension String {

    private static let markdownOptions = AttributedString.MarkdownParsingOptions(
        allowsExtendedAttributes: false,
        interpretedSyntax: .inlineOnlyPreservingWhitespace,
        failurePolicy: .returnPartiallyParsedIfPossible,
        languageCode: nil
    )
    
    func applyDefaultAttributes() -> AttributedString {
        let result = (try? AttributedString(markdown: self, options: String.markdownOptions)) ?? AttributedString(stringLiteral: self)

        let mutableResult = NSMutableAttributedString(result)
        mutableResult.enumerateAttribute(NSAttributedString.Key.link, in: NSRange(location: 0, length: mutableResult.length)) { link, range, _ in
            if link != nil {
                mutableResult.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }

        return AttributedString(mutableResult)
    }

    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
