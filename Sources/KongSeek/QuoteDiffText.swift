import SwiftUI
import KongSeekCore

/// 逐字异文 shown in a line of text (0.26): agreeing characters plain; a character the
/// quotation has wrong struck through in red, followed by the source's in green; 脱字
/// (left out of the quotation) in green brackets; 衍字 (not in the source) struck through.
enum QuoteDiffText {
    static func make(_ segments: [QuoteDiff.Segment]) -> Text {
        segments.reduce(Text("")) { text, segment in
            switch segment {
            case .same(let same):
                return text + Text(same).foregroundColor(.secondary)
            case .changed(let quote, let source):
                return text + Text(quote).foregroundColor(.red).strikethrough() + Text(source).foregroundColor(.green).bold()
            case .missing(let missing):
                return text + Text("〔" + missing + "〕").foregroundColor(.green).bold()
            case .extra(let extra):
                return text + Text(extra).foregroundColor(.red).strikethrough()
            case .equivalent(let quote, let source):
                // 通假、古今字: the quotation's character, then the edition's, in blue; not an error.
                return text + Text(quote).foregroundColor(.blue) + Text("（\(source)）").foregroundColor(.blue).font(.caption2)
            }
        }
    }

    /// "逐字：…" with the summary after it, for a near match.
    static func line(_ segments: [QuoteDiff.Segment]) -> Text {
        Text("逐字：").foregroundColor(.secondary) + make(segments) + Text("　" + QuoteDiff.summary(segments)).foregroundColor(.orange)
    }
}
