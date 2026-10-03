import Foundation

public enum TextLanguage: Sendable {
    case persian
    case english
}

/// Helpers for mixed Persian / English text (titles are written in either).
public enum TextDirection {
    /// Arabic-script blocks (covers Persian), Hebrew, and their presentation forms.
    static func isRTLScalar(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (0x0590...0x08FF).contains(v) || (0xFB1D...0xFDFF).contains(v) || (0xFE70...0xFEFF).contains(v)
    }

    /// True when the first letter in the text is right-to-left (the Unicode "first strong" rule).
    public static func isRTL(_ text: String) -> Bool {
        for s in text.unicodeScalars where s.properties.isAlphabetic {
            return isRTLScalar(s)
        }
        return false
    }

    /// Persian when Arabic-script letters outnumber everything else; otherwise English.
    public static func detect(_ text: String) -> TextLanguage {
        var rtl = 0
        var other = 0
        for s in text.unicodeScalars where s.properties.isAlphabetic {
            if isRTLScalar(s) { rtl += 1 } else { other += 1 }
        }
        return rtl > other ? .persian : .english
    }
}
