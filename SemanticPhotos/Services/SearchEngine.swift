import Foundation
import Accelerate

/// Brute-force ranking over the whole index. Vectors are L2-normalized, so
/// cosine similarity is a dot product; 10k x 256-dim scans complete in <10ms.
enum SearchEngine {
    struct Hit: Equatable {
        let id: String
        let score: Float
        let textMatch: Bool
    }

    /// A photo whose recognized text contains every query word ranks as if it
    /// were this much more similar (F4.12).
    static let textBoost: Float = 0.3

    /// Top-K by score, never cut off (F4.3); the caller places the
    /// "相关度较低" divider.
    static func rank(query: [Float], text: String = "", rows: [EmbeddingStore.SearchRow], k: Int) -> [Hit] {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        var hits: [Hit] = []
        hits.reserveCapacity(rows.count)
        for row in rows {
            let n = min(query.count, row.vector.count)
            guard n > 0 else { continue }
            var dot: Float = 0
            vDSP_dotpr(query, 1, row.vector, 1, &dot, vDSP_Length(n))
            let textMatch = !words.isEmpty && row.text.map { recognized in
                let lowered = recognized.lowercased()
                return words.allSatisfy { lowered.contains($0) }
            } == true
            hits.append(Hit(id: row.id, score: dot + (textMatch ? textBoost : 0), textMatch: textMatch))
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(k))
    }
}
