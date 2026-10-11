# 照片三维星团

从照片页左上角的星团按钮进入。使用已索引照片的原始向量，直接做 cosine UMAP → 3D，不经过 PCA。默认索引为 256 维，也会检查现有索引的实际维度是否一致。

## 已实现

- 单指旋转、双指缩放/平移、点击照片聚焦、回到全景；菜单提供相机按钮和返回照片列表的辅助操作。
- SceneKit 批量绘制星点，按视野展示最多 36 张朝向相机的缩略图；静止时不重新挑选缩略图。
- 复用现有照片详情、时间/地点/收藏筛选和搜索。过滤只改变高亮，不重新投影。搜索按现有相关度分界高亮，原始向量用于相似照片检索。
- 坐标存储在 SQLite 的照片向量行中。重新嵌入会清除该照片的坐标；删除照片、移出索引和清空索引会一并删除坐标。
- 保留不少于 4 个有效缓存点时，使用 UMAP transform 加入新照片，原有坐标不动。缓存版本变化、缺少足够锚点时重新拟合；不足 4 张仅展示明确标注的预览。
- 后台线程计算，离开页面/进入后台/索引发生变化会取消当前任务。运行中不下载代码或上传向量。

## 算法依赖

使用 PAIR-code `umap-js` 1.4.0，通过系统 JavaScriptCore 执行。算法资源随 App 打包；不需要 Node、WebView 或运行时 CDN。

- 来源：https://registry.npmjs.org/umap-js/-/umap-js-1.4.0.tgz
- 原始 bundle：`SemanticPhotos/Resources/UMAP/umap-js.min.js`
- SHA-256：`9d226db25cc57eae1e1843765eac64c90f6bccfdeb2c2be2520b2e310abc3ded`
- 参数：`nComponents=3`, `nNeighbors=min(30, N-1)`, `minDist=0.18`, `nEpochs=300`, 固定随机种子。
- 分发包 LICENSE 为 Apache-2.0（其 package.json 标为 MIT）；保留分发的完整许可证及数值计算依赖的 MIT 通知。
- `constellation-umap.js` 是本项目适配器。恢复缓存使用此固定版本的 `embedding` 字段；增量 batch 小于训练集，避开该版本按数组长度判断是否移动锚点的行为。升级依赖需要重新验证适配器并更新缓存版本。

## 验证

在 iOS 26.5 / iPhone 17e 模拟器上，5 项 Swift Testing 测试和 2 项 UI 测试通过。使用现有的 18 张真实索引照片检查了缩略图、聚焦和详情跳转。

```sh
xcodegen generate
xcodebuild -project SemanticPhotos.xcodeproj -scheme SemanticPhotos \
  -destination 'platform=iOS Simulator,id=<ARM64_SIMULATOR_UDID>' \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:SemanticPhotosTests \
  -only-testing:SemanticPhotosUITests/SemanticPhotosUITests/testConstellationNavigationCameraAndFilters \
  -only-testing:SemanticPhotosUITests/SemanticPhotosUITests/testDetailShowsActionsAndFindsSimilar test
```

现有 MediaPipe 二进制仅提供 arm64 模拟器架构，使用具体 Apple Silicon 模拟器运行，不要用同时构建 x86_64 的 generic destination。UI 测试需要模拟器已经有模型和至少 4 张索引照片，否则会跳过。

## 当前边界

尚未进行万张照片库的真机性能、内存及耗电测量。UMAP 首次构图需要完整向量集；JavaScriptCore 会产生额外数据副本。当前没有自动主题命名、聚类标签或颜色维度切换，时间和地点通过既有筛选器查看。大量新主题持续加入后，固定旧坐标会牺牲部分全局结构质量。三维距离和方向不作为精确的语义度量。
