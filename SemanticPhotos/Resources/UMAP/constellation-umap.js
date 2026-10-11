// Adapter for the pinned PAIR-code umap-js 1.4.0 bundle. No PCA or network access.
function projectConstellation(vectors, positions, additions) {
    let seed = 42;
    let calls = 0;
    function check() {
        if ((++calls & 1023) === 0 && projectionCancelled()) throw new Error("Cancelled");
    }
    function random() {
        check();
        seed = (Math.imul(1664525, seed) + 1013904223) >>> 0;
        return seed / 4294967296;
    }
    function cosine(a, b) {
        check();
        let dot = 0, aa = 0, bb = 0;
        for (let i = 0; i < a.length; ++i) {
            dot += a[i] * b[i]; aa += a[i] * a[i]; bb += b[i] * b[i];
        }
        return Math.max(0, Math.min(2, 1 - dot / Math.sqrt(aa * bb)));
    }
    const umap = new UMAP.UMAP({
        nComponents: 3, nNeighbors: Math.min(30, vectors.length - 1),
        minDist: 0.18, spread: 1, nEpochs: 300, distanceFn: cosine, random
    });
    projectionProgress(0.02);
    const epochs = umap.initializeFit(vectors);
    if (!positions.length) {
        for (let epoch = 0; epoch < epochs; ++epoch) {
            if (projectionCancelled()) throw new Error("Cancelled");
            umap.step();
            if (epoch % 3 === 0) projectionProgress(0.2 + 0.8 * epoch / epochs);
        }
        return umap.getEmbedding();
    }
    // 1.4.0 has no restore API: rebuild its neighbour graph, then restore cached anchors.
    umap.embedding = positions;
    const output = [];
    // 1.4.0 moves anchors when batch and training lengths match; always keep them different.
    const batchSize = Math.min(64, vectors.length - 1);
    for (let offset = 0; offset < additions.length; offset += batchSize) {
        if (projectionCancelled()) throw new Error("Cancelled");
        output.push(...umap.transform(additions.slice(offset, offset + batchSize)));
        projectionProgress(0.2 + 0.8 * Math.min(offset + batchSize, additions.length) / additions.length);
    }
    return output;
}
