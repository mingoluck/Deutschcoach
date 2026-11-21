import SwiftUI

extension Alignment {
    /// Matched words plain, misread words red with what was heard, missing words struck through,
    /// foreign names (not checked) gray with what was heard.
    var attributedText: AttributedString {
        var result = AttributedString()
        for (offset, word) in words.enumerated() {
            if offset > 0 { result += AttributedString(" ") }
            var piece = AttributedString(word.text)
            switch word.status {
            case .match:
                break
            case .substituted(let heard):
                piece.foregroundColor = .red
                piece.underlineStyle = .single
                var heardPiece = AttributedString(" (\(heard))")
                heardPiece.foregroundColor = .secondary
                piece += heardPiece
            case .missing:
                piece.foregroundColor = .red
                piece.strikethroughStyle = .single
            case .name(let heard):
                piece.foregroundColor = .secondary
                if let heard {
                    var heardPiece = AttributedString(" (\(heard))")
                    heardPiece.foregroundColor = .secondary
                    piece += heardPiece
                }
            }
            result += piece
        }
        return result
    }
}
