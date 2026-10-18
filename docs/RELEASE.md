# Release and testing

App Store Connect app: 6823997811. Bundle ID: com.clothpath.mondigital.
Shipping targets: SemanticPhotos, SemanticPhotosShare, SemanticPhotosDownloader.
The version and build number are shared in project.yml; CI overrides the build number for all targets.

## Release acceptance

- [x] Recoverable source/history backup made before cleanup.
- [x] Obsolete implementation plans and reports removed; maintained documentation consolidated.
- [x] Public source/history scan and GitHub push (main; private mirror removed from history).
- [x] Privacy/support pages deployed and linked in the app; Apple privacy disclosure published.
- [x] Release archive 1.0 (5): all three bundles, versions, entitlements, privacy, iPhone targeting and distribution signing validated.
- [x] Dedicated macOS runner and repeatable CI tests: 93 passed, zero failed/skipped in both the current CI and release workflow.
- [x] GitHub Actions run produces a processed TestFlight build in the internal group: 1.0 (5), VALID, findImage membership verified.
- [x] User-reported physical-device model download passed on 18 October 2026. The agent did not independently observe the installation path or network trace; this does not claim the separate retained-data upgrade checklist was completed.
- [x] Simulator UI acceptance: 18 distinct scenarios passed after fixing test scrolling and completing the color fixtures (406 indexed photos). Covers startup input/cancel, selection/deletion confirmation, sharing, photo detail dismissal, search controls, color scrolling, EN/ZH, appearance and storage confirmation.
- [ ] Physical-device upgrade and retained-data acceptance: user elected to install manually after pipeline completion. Existing device data remains untouched; protected backup has 1,219 indexed photos and zero pending photos. Full fresh-install, limited-permission and real network-failure/offline coverage is not claimed.
- [x] Bilingual store name, subtitle, description, keywords, promotional text, support/privacy URLs and review contact saved on 18 October 2026. English store name: PhotoFind: Private Search; Chinese: 一句找图.
- [x] Store screenshots uploaded via asc: 5 per locale (zh-Hans/en-US), each in 1320×2868 and 1206×2622. All 20 images COMPLETE; all 20 placements ACTIVE in correct 1–5 order. Actual simulator captures use licensed demo photos and the current working tree. Evidence: StoreAssets/asc-verification.json; reproduction: StoreAssets/editor/app-store-screenshots.json.
- [x] First release priced free; all 175 current territories selected, including China mainland. Future territories are not automatically enabled. Version 1.0 is configured for manual release.
- [x] Current source `232e090` was pushed, published as TestFlight 1.0 (5), and linked to App Store version 1.0. English and Chinese beta notes saved.
- [ ] Retained-data physical-device acceptance and China mainland ICP work are explicitly deferred by the user. No filing number is entered; region selection does not establish distribution eligibility.
- [ ] The Business page reports an updated Apple Developer Program License Agreement that the Account Holder must review and accept before new-app/update submission. This legal acceptance was not performed by the agent; the user has been notified.
- [ ] Formal review remains deliberately unsubmitted. Submit the first app and SemanticPhotosModel v1 together only on a later explicit instruction.

CI validation for build 4: 80 tests passed, zero failures or unexpected skips. UI evidence is retained locally in ReleaseAcceptance.xcresult, ReleaseAcceptanceRetry.xcresult and ColorScrollAcceptance.xcresult. The initial UI run had two failures: a test needed to scroll to the storage row, and the color-scroll fixture needed enough fully indexed photos; both targeted reruns passed.

Latest processed TestFlight build: **1.0 (5)**, build ID `8717a760-fae9-4968-897d-759c3850235d`, source commit `232e090`. [Publish TestFlight run](https://github.com/huanglizhuo/PhotoFind/actions/runs/39135173845) completed the full test → archive → export → upload → Apple processing → internal-group verification flow. [Independent CI run](https://github.com/huanglizhuo/PhotoFind/actions/runs/39135156951) also passed. Each validated 93 tests, none failed or skipped. The app and both extensions are signed as 1.0 (5).

The previous build 3 was valid, but its workflow failed on redundant manual assignment to an automatically populated internal group. The pipeline now reads Apple's group/build relationship and verifies the exact uploaded build instead.

Unchecked items are not claimed complete. Update this file with verified outcomes and build/run links.

## Model

Pack ID: SemanticPhotosModel. Filename: embeddinggemma-2-text-vision-440m.litertlm.
Size: 387710976 bytes. SHA-256: 92dcbea108899e5d6e30d919b0744f90d9967e80c67a4ab5503ac16d54f62eb0.
Manifest: BackgroundAssets/model-manifest.json. Keep the app and pack compatible; never replace the pinned model independently.

```sh
bash Tools/fetch_model.sh
xcrun ba-package evaluate BackgroundAssets/model-manifest.json
xcrun ba-package package BackgroundAssets/model-manifest.json --output-path build/SemanticPhotosModel.aar
```

Development downloads use Apple's ba-serve and a trusted TLS URL configured in Settings > Developer > Background Assets Testing. Clear development overrides before TestFlight acceptance. Model download UI fixtures are Debug-only and do not prove Apple hosting works.

## Boundaries

CI fixtures must contain synthetic photos only. Never upload private photos, credentials, provisioning profiles, model binaries or diagnostic attachments containing personal information to this public repository.
Formal App Store review is intentionally separate from the TestFlight workflow. The first app and its required asset pack must be submitted together.

## GitHub Actions

- `iOS tests`: runs on main pushes affecting code, or manually.
- `Publish TestFlight`: manually dispatch on main; tests, archives, validates all bundle versions, exports, uploads, waits for processing and verifies that the exact build is available in the automatically populated internal group `findImage`.
- Both jobs serialize through `photofind-mac`; neither runs pull-request code.
- Runner: `photofind-mac-arm64`, label `photofind`; service directory `~/actions-runner-photofind`.
- Requires this Mac to be awake and logged in. The job unlocks only its dedicated `photofind-ci.keychain-db` using CI_KEYCHAIN_PASSWORD. The existing Apple Distribution identity is reused; no certificate is revoked.
- Xcode is selected with `DEVELOPER_DIR`. Installed tools: XcodeGen, asc-cli 0.18.6, Python 3, curl.
- TestFlight environment allows main only and stores ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY and CI_KEYCHAIN_PASSWORD. The job uses a temporary private key file and removes it on exit.
- Repository variable PHOTO_FIND_SIMULATOR identifies the dedicated CI simulator. Dependencies/model cache live in `~/Library/Caches/PhotoFindCI`.
- CI verifies the public model's pinned hash before staging it in the simulator. It tests real text/image inference, unit tests and download-state UI fixtures. This does not prove Apple-hosted delivery.
- The standalone first-keyboard timing benchmark is explicitly excluded from CI: it requires a prepared library/device and must be measured separately. Unexpected skipped tests fail CI.
- Source code alone cannot reproduce Apple-hosted downloads in a simulator. Fresh TestFlight/device acceptance remains a separate release gate.

To publish another build: GitHub → Actions → Publish TestFlight → Run workflow → main. The build number is greater than both processed builds and upload records (including failed/pending attempts), not manually incremented in several targets. Do not concurrently upload the same marketing version outside this pipeline.

The dedicated keychain contains only the selected distribution identity (expires 25 April 2027). CI downloads the three named PhotoFind App Store profiles, signs manually and verifies get-task-allow is false. Renew the certificate/profiles before expiration. Other apps’ runners and keychains are retained.

Privacy declaration: published “Data Not Collected” after explicit confirmation. Policy URL and support URL saved in App Store Connect. Age rating configured (4+), categories Photo & Video / Utilities, no review login required, model-download review notes saved. The first release is free in all 175 current territories by user instruction, with manual release after approval. China mainland ICP information remains unresolved. Apple-hosted SemanticPhotosModel v1 is Ready for Internal Testing (314 MB compressed).

Release validation also rejects accidental iPad targeting (`UIDeviceFamily` must be `[1]`). Keep TARGETED_DEVICE_FAMILY quoted in project.yml: XcodeGen can interpret JSON numeric 1 as a Boolean when generating the CI signing project.

## Manual upgrade acceptance

Install version 1.0 (5), or a later processed build, through TestFlight over the existing app; do not delete the app first. Confirm the build number in About, existing search history/settings, retained index count (baseline: 1,219), and no repeated model download. Try a text search, scroll results and open/close a photo. Do not rebuild the index or clear storage during this upgrade check. The protected local backup is outside Git at `/Users/lizhuo/owork/photofind-backups/2026-10-18/device-library`.

## Store materials (18 October 2026)

`StoreAssets/metadata/` contains the uploaded bilingual copy and review instructions; personal reviewer contact was entered directly into App Store Connect, not stored here. `photo-sources.json` records demo image sources. `capture-manifest.json` records the simulator and raw screenshot hashes. The screenshot editor uses the requested app-store-screenshots skill template with a lilac palette; all five screens stand alone so controls and captions are never split. The editor build passed, and its standard Export bundle generated 40 opaque PNGs across two locales and four sizes.

App Store Connect readiness now passes build linkage/validity, localization, screenshots, price and review contact after attaching build 5. Its `isReadyToSubmit` result does not validate the outstanding developer agreement, China mainland eligibility, model asset-pack submission or deferred device acceptance. China mainland remains selected without an ICP filing number. No review submission or automatic release was performed; version 1.0 remains PREPARE_FOR_SUBMISSION with releaseType MANUAL. The first App Store review must include SemanticPhotosModel v1 together with the app.

To reopen the screenshot editor:

```sh
cd /Users/lizhuo/owork/monDigital/iOS/SemanticPhotos/StoreAssets/editor
npm install --legacy-peer-deps
npm run dev -- --hostname 127.0.0.1 --port 3088
```

Open http://127.0.0.1:3088. Export bundle recreates the localized iPhone PNGs. Raw screenshots and source photos are not production app resources.
