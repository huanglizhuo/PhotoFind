# PhotoFind · 一句找图

[![SLOC](https://api.octocounts.com/badge/huanglizhuo/PhotoFind?type=code)](https://octocounts.com/github/huanglizhuo/PhotoFind)

<img src="docs/assets/app-icon.png" alt="PhotoFind app icon" width="120" />

Find the photo you have in mind. PhotoFind is an iPhone app that searches your library with words, a reference image, or color. Photo analysis and search run on-device.

![PhotoFind app overview](StoreAssets/screenshot-overview.png)

## Features

- **Describe a memory** — search in Chinese or English without manually tagging photos.
- **Search with an image** — find visually similar photos from a reference image.
- **Explore by color** — browse your library through the continuous spectrum of Color Universe.
- **Find text in screenshots** — combine recognized text with visual search.
- **Keep photos private** — photos, queries, and indexes stay on your device. Indexed local photos are searchable offline after the initial model download.
- **Organize what you find** — select, share, create albums, and delete with confirmation.
- **Feel at home** — Chinese and English interfaces, with light, dark, and system appearance.

## Technical approach

| Area | Implementation |
| --- | --- |
| App icon | Original meerkat-and-photo composition in Icon Composer, with a separate background, Liquid Glass edge highlights, and system-rendered dark, clear, and tinted appearances. |
| Native interface | Swift 6 and SwiftUI, with a reusable UIKit collection view for the photo grid. |
| On-device AI | EmbeddingGemma text-and-image embeddings through MediaPipe, with a fixed 256-dimensional search index. |
| Model delivery | Apple-hosted Background Assets download the model separately from the app. |
| Local storage | SQLite stores embeddings, photo metadata, recognized text, and indexing progress. |
| Photo integration | PhotoKit manages authorized photo access, thumbnail caching, library changes, and photo actions. |
| Text recognition | Apple Vision extracts text from screenshots for search. |
| Responsive search | IME-aware input handling, a 500 ms debounce, adaptive inference spacing, cached query vectors, and only the latest waiting request. |
| Incremental indexing | Later indexing passes normally process only new or modified photos. |
