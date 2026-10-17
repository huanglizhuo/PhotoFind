import Testing
@testable import SemanticPhotos

/// v0.8: the "no convincing match" and divider rules were extracted from
/// AppModel so these edge cases are pure and cheap to test.
struct SearchEngineRelevanceTests {
    @Test func dividerSitsAtFirstWeakResult() {
        let scores: [Float] = [0.74, 0.72, 0.66, 0.64]
        let best = SearchEngine.Relevance.bestScore(scores, excluding: [])
        #expect(best == 0.74)
        let cutoff = SearchEngine.Relevance.cutoff(best: 0.74, gap: 0.04, floor: 0.68)
        #expect(cutoff == 0.70)
        #expect(SearchEngine.Relevance.firstIndexBelow(scores, cutoff: cutoff, excluding: []) == 2)
        #expect(!SearchEngine.Relevance.isLowConfidence(best: best, floor: 0.68))
    }

    @Test func seedIsIgnoredForTheDivider() {
        let scores: [Float] = [0.99, 0.71, 0.69, 0.60]
        let best = SearchEngine.Relevance.bestScore(scores, excluding: [0])
        #expect(best == 0.71)
        let cutoff = SearchEngine.Relevance.cutoff(best: 0.71, gap: 0.04, floor: 0.68)
        #expect(cutoff == 0.68)
        #expect(SearchEngine.Relevance.firstIndexBelow(scores, cutoff: cutoff, excluding: [0]) == 3)
    }

    @Test func noPlausibleMatchIsLowConfidence() {
        let scores: [Float] = [0.61, 0.58, 0.55]
        let best = SearchEngine.Relevance.bestScore(scores, excluding: [])
        #expect(SearchEngine.Relevance.isLowConfidence(best: best, floor: 0.68))
        let cutoff = SearchEngine.Relevance.cutoff(best: 0.61, gap: 0.04, floor: 0.68)
        #expect(cutoff == 0.68, "floor 应高于最佳结果，分隔线落在最上方")
        #expect(SearchEngine.Relevance.firstIndexBelow(scores, cutoff: cutoff, excluding: []) == 0)
    }

    @Test func textMatchesNeverDefineTheDivider() {
        let scores: [Float] = [0.95, 0.95, 0.70, 0.60]
        // Both text matches are excluded; the next non-text result is 0.70.
        let best = SearchEngine.Relevance.bestScore(scores, excluding: [0, 1])
        #expect(best == 0.70)
        let cutoff = SearchEngine.Relevance.cutoff(best: 0.70, gap: 0.04, floor: 0.68)
        #expect(SearchEngine.Relevance.firstIndexBelow(scores, cutoff: cutoff, excluding: [0, 1]) == 3)
    }

    @Test func emptyOrFullyExcludedScoresHaveNoDivider() {
        #expect(SearchEngine.Relevance.bestScore([], excluding: []) == nil)
        #expect(!SearchEngine.Relevance.isLowConfidence(best: nil, floor: 0.68))
        #expect(SearchEngine.Relevance.firstIndexBelow([0.5], cutoff: 0.68, excluding: [0]) == nil)
    }
}
