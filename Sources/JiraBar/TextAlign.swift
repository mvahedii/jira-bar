import SwiftUI
import JiraBarCore

/// Persian text should sit on the right, English on the left, decided per piece of text.
enum TextAlign {
    static func frame(_ s: String) -> Alignment { TextDirection.isRTL(s) ? .trailing : .leading }
    static func multiline(_ s: String) -> TextAlignment { TextDirection.isRTL(s) ? .trailing : .leading }
}
