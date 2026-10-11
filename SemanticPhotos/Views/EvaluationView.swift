import SwiftUI

/// Quality evaluation for the team (F8), behind the debug tools. Marking
/// results 有用 / 没用 (F8.2) is also how the evaluation set is built: every
/// labeled query is re-run for Recall@10, MRR and latency (F8.1).
struct EvaluationView: View {
    @Environment(AppModel.self) private var model
    @State private var labels = EvaluationLabels.load()
    @State private var report: EvaluationReport?
    @State private var consistency: [Float]?
    @State private var running = false
    @State private var newQuery = ""
    @State private var labeling: String?
    @State private var export: ExportFile?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("新增查询,如\u{201C}海边日落\u{201D}", text: $newQuery)
                        .onSubmit(addQuery)
                    Button("标注", action: addQuery)
                        .disabled(newQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(labels.items) { label in
                    Button { labeling = label.query } label: {
                        LabeledContent(label.query,
                                       value: "有用 \(label.relevant.count) · 没用 \(label.irrelevant.count)")
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete { offsets in
                    labels.items.remove(atOffsets: offsets)
                    labels.save()
                }
            } header: {
                Text("评测集")
            } footer: {
                Text("在结果上标\u{201C}有用 / 没用\u{201D};只存本机,可导出给团队。")
            }

            Section("指标") {
                Button(running ? "运行中…" : "运行评测") { Task { await runReport() } }
                    .disabled(running || labels.items.allSatisfy { $0.relevant.isEmpty } || !model.canRunModel)
                if let report {
                    LabeledContent("Recall@10", value: String(format: "%.3f", report.recallAt10))
                    LabeledContent("MRR", value: String(format: "%.3f", report.mrr))
                    LabeledContent("搜索延迟 P50 / P95",
                                   value: String(format: "%.0f / %.0f ms", report.latencyP50 * 1000, report.latencyP95 * 1000))
                    ForEach(report.queries, id: \.query) { item in
                        LabeledContent(item.query, value: String(format: "R@10 %.2f · RR %.2f", item.recallAt10, item.reciprocalRank))
                            .font(.footnote)
                    }
                }
                let durations = model.pipeline.embedDurations
                if durations.isEmpty {
                    Text("本次启动尚未嵌入照片,没有单张耗时数据").font(.footnote).foregroundStyle(.secondary)
                } else {
                    LabeledContent("单张嵌入 均值 / P50 / P95",
                                   value: String(format: "%.0f / %.0f / %.0f ms",
                                                 durations.reduce(0, +) / Double(durations.count) * 1000,
                                                 percentile(durations, 0.5) * 1000, percentile(durations, 0.95) * 1000))
                }
            }

            Section {
                Button(running ? "检查中…" : "检查 GPU / CPU 向量一致性") { Task { await runConsistency() } }
                    .disabled(running || model.photos.isEmpty || !model.canRunModel)
                if let consistency, !consistency.isEmpty {
                    LabeledContent("样本", value: "\(consistency.count) 张")
                    LabeledContent("余弦相似度 最小 / 均值",
                                   value: String(format: "%.4f / %.4f", consistency.min() ?? 0,
                                                 consistency.reduce(0, +) / Float(consistency.count)))
                    Text((consistency.min() ?? 0) >= 0.99 ? "一致:后台回退 CPU 不影响排序" : "差异偏大:后台用 CPU 生成的向量可能影响排序")
                        .font(.footnote)
                        .foregroundStyle((consistency.min() ?? 0) >= 0.99 ? .green : .orange)
                }
            } header: {
                Text("后台回退")
            } footer: {
                Text("用 CPU 重新计算已索引照片的向量,与索引中(前台 GPU 算出)的向量比较(F2.8)。")
            }

            Section {
                Button("导出评测数据") { export = ExportFile(url: labels.export(report: report, consistency: consistency)) }
            }
        }
        .navigationTitle("质量评测")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(get: { labeling.map(LabelTarget.init) }, set: { labeling = $0?.query })) { target in
            LabelingView(query: target.query, labels: $labels)
        }
        .sheet(item: $export) { ShareSheet(items: [$0.url]) }
        .alert("评测失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func addQuery() {
        let query = newQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        if !labels.items.contains(where: { $0.query == query }) {
            labels.items.append(EvaluationLabel(query: query, relevant: [], irrelevant: []))
            labels.save()
        }
        newQuery = ""
        labeling = query
    }

    private func runReport() async {
        running = true
        defer { running = false }
        var results: [EvaluationReport.Query] = []
        var latencies: [Double] = []
        do {
            for label in labels.items where !label.relevant.isEmpty {
                let (ids, seconds) = try await model.rankForEvaluation(label.query)
                latencies.append(seconds)
                let relevant = Set(label.relevant)
                let hits = ids.prefix(10).filter(relevant.contains).count
                let rank = ids.firstIndex(where: relevant.contains).map { $0 + 1 }
                results.append(.init(query: label.query, recallAt10: Double(hits) / Double(relevant.count),
                                     reciprocalRank: rank.map { 1 / Double($0) } ?? 0, latency: seconds))
            }
        } catch {
            self.error = error.localizedDescription
            return
        }
        report = EvaluationReport(
            queries: results,
            recallAt10: results.map(\.recallAt10).reduce(0, +) / Double(max(results.count, 1)),
            mrr: results.map(\.reciprocalRank).reduce(0, +) / Double(max(results.count, 1)),
            latencyP50: percentile(latencies, 0.5),
            latencyP95: percentile(latencies, 0.95))
    }

    private func runConsistency() async {
        running = true
        defer { running = false }
        do {
            consistency = try await model.gpuCPUConsistency(sample: 10)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }
}

private struct LabelTarget: Identifiable {
    let query: String
    var id: String { query }
}

private struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// Results for one query; tap cycles 未标 → 有用 → 没用.
private struct LabelingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let query: String
    @Binding var labels: EvaluationLabels
    @State private var ids: [String] = []
    @State private var failed: String?

    private var label: EvaluationLabel {
        labels.items.first { $0.query == query } ?? EvaluationLabel(query: query, relevant: [], irrelevant: [])
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let failed {
                    Text(failed).foregroundStyle(.secondary).padding()
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                    ForEach(Array(ids.prefix(40).enumerated()), id: \.element) { rank, id in
                        EvaluationThumb(id: id, rank: rank + 1,
                                        state: label.relevant.contains(id) ? true : label.irrelevant.contains(id) ? false : nil)
                            .onTapGesture { cycle(id) }
                    }
                }
                .padding(4)
            }
            .navigationTitle(query)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
            .task {
                do {
                    ids = try await model.rankForEvaluation(query).ids
                } catch {
                    failed = error.localizedDescription
                }
            }
        }
    }

    private func cycle(_ id: String) {
        var item = label
        if item.relevant.contains(id) {
            item.relevant.removeAll { $0 == id }
            item.irrelevant.append(id)
        } else if item.irrelevant.contains(id) {
            item.irrelevant.removeAll { $0 == id }
        } else {
            item.relevant.append(id)
        }
        if let index = labels.items.firstIndex(where: { $0.query == query }) {
            labels.items[index] = item
        } else {
            labels.items.append(item)
        }
        labels.save()
    }
}

private struct EvaluationThumb: View {
    @Environment(AppModel.self) private var model
    let id: String
    let rank: Int
    /// true 有用, false 没用, nil not labeled.
    let state: Bool?
    @State private var image: UIImage?

    var body: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .clipped()
            .overlay(alignment: .topLeading) {
                Text("\(rank)").font(.caption2.monospacedDigit()).padding(3)
                    .background(.black.opacity(0.5), in: .capsule).foregroundStyle(.white).padding(3)
            }
            .overlay(alignment: .bottomTrailing) {
                if let state {
                    Image(systemName: state ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                        .foregroundStyle(.white, state ? .green : .red)
                        .padding(5)
                        .background(state ? .green : .red, in: .circle)
                        .padding(4)
                }
            }
            .task { image = await model.photoService.fullImage(for: id, targetSize: CGSize(width: 90, height: 90)) }
    }
}

struct EvaluationLabel: Codable, Identifiable {
    let query: String
    var relevant: [String]
    var irrelevant: [String]
    var id: String { query }
}

struct EvaluationReport: Codable {
    struct Query: Codable {
        let query: String
        let recallAt10: Double
        let reciprocalRank: Double
        let latency: Double
    }
    let queries: [Query]
    let recallAt10: Double
    let mrr: Double
    let latencyP50: Double
    let latencyP95: Double
}

/// Labels persisted as JSON next to the index; never uploaded.
struct EvaluationLabels {
    var items: [EvaluationLabel]

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("evaluation.json")
    }

    static func load() -> EvaluationLabels {
        let items = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([EvaluationLabel].self, from: $0) }
        return EvaluationLabels(items: items ?? [])
    }

    func save() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: Self.url, options: .atomic) }
    }

    /// Labels plus the latest metrics, as a file for the share sheet.
    func export(report: EvaluationReport?, consistency: [Float]?) -> URL {
        struct Export: Codable {
            let exportedAt: Date
            let labels: [EvaluationLabel]
            let report: EvaluationReport?
            let gpuCPUCosine: [Float]?
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SemanticPhotos-评测.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Export(exportedAt: .now, labels: items, report: report, gpuCPUCosine: consistency)) {
            try? data.write(to: url, options: .atomic)
        }
        return url
    }
}

extension AppModel {
    /// Same ranking as the search bar, without filters; returns ids and the
    /// end-to-end time (text embedding + scan).
    func rankForEvaluation(_ query: String) async throws -> (ids: [String], seconds: Double) {
        let start = ContinuousClock.now
        let vector = try await engine.embedText(query, dimension: dimension)
        let rows = try await store.searchRows()
        let hits = SearchEngine.rank(query: vector, text: query, rows: rows, k: 60)
        let elapsed = ContinuousClock.now - start
        return (hits.map(\.id),
                Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }

    /// Cosine similarity between stored (foreground GPU) vectors and fresh CPU
    /// vectors for up to `sample` indexed photos (F2.8 / F8.1).
    func gpuCPUConsistency(sample: Int) async throws -> [Float] {
        var images: [UIImage] = []
        var stored: [[Float]] = []
        for photo in photos.prefix(sample) {
            guard let vector = try await store.vector(for: photo.id),
                  let image = try? await photoService.embeddingImage(for: photo.id) else { continue }
            images.append(image)
            stored.append(vector)
        }
        let cpu = try await engine.embedImagesOnCPU(images, dimension: dimension)
        return zip(stored, cpu).map { a, b in
            let n = min(a.count, b.count)
            return (0..<n).reduce(Float(0)) { $0 + a[$1] * b[$1] }
        }
    }
}
