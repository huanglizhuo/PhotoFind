import Foundation
import JavaScriptCore

struct ConstellationNode: Identifiable, Equatable, Sendable {
    let id: String
    let position: SIMD3<Float>
}

struct ConstellationRow: Sendable {
    let id: String
    let vector: [Float]
    var position: SIMD3<Float>?
}

enum ConstellationProjection {
    static let cacheVersion = "umap-js-1.4.0-cosine-3d-n30-md018-v1"

    enum ProjectionError: LocalizedError {
        case invalidVectors, unavailable, failed(String)
        var errorDescription: String? {
            switch self {
            case .invalidVectors: "照片向量无效或维度不一致，请重建索引后重试。"
            case .unavailable: "无法加载星团投影组件。"
            case .failed(let message): "星团生成失败：\(message)"
            }
        }
    }

    // JavaScriptCore and all of its objects stay on this worker; only values cross executors.
    @concurrent
    static func project(_ input: [ConstellationRow],
                        progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [ConstellationNode] {
        try Task.checkCancellation()
        let rows = input.sorted { $0.id < $1.id }
        guard let dimension = rows.first?.vector.count else { return [] }
        guard dimension > 0, Set(rows.map(\.id)).count == rows.count,
              rows.allSatisfy({ row in
                  row.vector.count == dimension && row.vector.allSatisfy(\.isFinite)
                      && row.vector.contains(where: { $0 != 0 })
              }) else { throw ProjectionError.invalidVectors }

        // A tiny library has no meaningful neighbourhood graph; the UI labels this as a preview.
        if rows.count < 4 {
            return rows.enumerated().map { index, row in
                let angle = Float(index) * 2 * .pi / Float(rows.count)
                return ConstellationNode(id: row.id, position: SIMD3(cos(angle) * 2, sin(angle) * 2, 0))
            }
        }
        let anchors = rows.filter { $0.position.map { p in p.x.isFinite && p.y.isFinite && p.z.isFinite } ?? false }
        if anchors.count == rows.count {
            return anchors.compactMap { row in row.position.map { ConstellationNode(id: row.id, position: $0) } }
        }

        guard let context = JSContext(),
              let libraryURL = Bundle.main.url(forResource: "umap-js.min", withExtension: "js"),
              let adapterURL = Bundle.main.url(forResource: "constellation-umap", withExtension: "js") else {
            throw ProjectionError.unavailable
        }
        let cancelled: @convention(block) () -> Bool = { Task.isCancelled }
        let report: @convention(block) (Double) -> Void = { progress($0) }
        context.setObject(cancelled, forKeyedSubscript: "projectionCancelled" as NSString)
        context.setObject(report, forKeyedSubscript: "projectionProgress" as NSString)
        context.evaluateScript(try String(contentsOf: libraryURL, encoding: .utf8))
        context.evaluateScript(try String(contentsOf: adapterURL, encoding: .utf8))
        let anchored = anchors.count >= 4
        let anchorIDs = Set(anchors.map(\.id))
        let additions = anchored ? rows.filter { !anchorIDs.contains($0.id) } : rows
        let training = anchored ? anchors : rows
        let coordinates = anchored ? anchors.compactMap { row in row.position.map { [Double($0.x), Double($0.y), Double($0.z)] } } : []
        let result = context.objectForKeyedSubscript("projectConstellation")?.call(withArguments: [
            training.map(\.vector), coordinates, anchored ? additions.map(\.vector) : [],
        ])
        try Task.checkCancellation()
        if let exception = context.exception {
            throw ProjectionError.failed(exception.toString() ?? "UMAP")
        }
        guard let values = result?.toArray() as? [[Double]], values.count == additions.count,
              values.allSatisfy({ $0.count == 3 && $0.allSatisfy { $0.isFinite && abs($0) < Double(Float.greatestFiniteMagnitude) } }) else {
            throw ProjectionError.failed("投影结果不完整")
        }
        let newNodes = zip(additions, values).map { row, p in
            ConstellationNode(id: row.id, position: SIMD3(Float(p[0]), Float(p[1]), Float(p[2])))
        }
        let oldNodes = anchored ? anchors.compactMap { row in row.position.map { ConstellationNode(id: row.id, position: $0) } } : []
        return (oldNodes + newNodes).sorted { $0.id < $1.id }
    }
}
