# Release and testing

App Store Connect app: 6823997811. Bundle ID: com.clothpath.mondigital.
Shipping targets: SemanticPhotos and SemanticPhotosShare. The legacy downloader extension is no longer embedded.
The version and build number are shared in project.yml; CI overrides the build number for all targets.

## Bundled model (24 October 2026)

The model is now a normal Copy Bundle Resources entry in the main app only.
The model bytes and index version are unchanged. Startup never invokes Background
Assets or the R2 fallback. The downloader target/dependency and BA Info.plist keys
are removed from shipping builds. Existing R2/Apple assets are retained for users
of older builds; do not delete or replace them as part of this migration.

Local preparation reuses the existing verified hash-addressed copy, or clones the
bundled file into Application Support, validates size/SHA-256 with 1 MiB reads,
and atomically publishes it. LiteRT writes cache files beside the model, so it
cannot use the read-only bundle path directly. Preparation runs off the UI actor.
The writable model directory remains excluded from backup. Successful preparation
removes this model's obsolete `.partial` download; photos and indexes are unchanged.
A failed preparation exposes Retry and has a 60-second deadline.

Apple guidance applied:
- Resolve resources through `Bundle.url(forResource:withExtension:)`, not an
  installation path. Keep one unlocalized copy in the main app, none in extensions.
- Treat the app bundle as read-only; use Application Support for required writable
  support files. Exclude recreatable files from backups.
- Prefer APFS cloning, stream validation rather than loading the whole model into
  memory, and reuse validated local files. Cloning can fall back to copying, so
  do not promise that physical storage always contains just one model's worth.
- Measure the exported app, not only source/archive size; actual App Store download
  size depends on compression and device thinning. iOS/iPadOS allow a 4 GB
  uncompressed app; this 387,710,976-byte model is a resource, not executable code.

Sources:
- https://developer.apple.com/documentation/foundation/bundle/url(forresource:withextension:)
- https://developer.apple.com/documentation/foundation/using-the-file-system-effectively
- https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup
- https://developer.apple.com/documentation/xcode/reducing-your-app-s-disk-usage
- https://developer.apple.com/documentation/xcode/reducing-your-app-s-size
- https://developer.apple.com/help/app-store-connect/reference/app-uploads/maximum-build-file-sizes/

Build preparation runs `Tools/fetch_model.sh` before XcodeGen. The model stays out
of Git. Both the test product and release archive must contain exactly one model
with the pinned size/hash and no BA predownload keys. Archive checks also require
exactly the main app and share extension, matching versions and distribution signing.
CI no longer injects a model into the simulator: tests exercise the bundled source.

Local validation: `build/Bundled-iPad27.xcresult` passed 14 tests, none failed or skipped, on a newly created iPad Air 11-inch (M3), iPadOS 27.0 simulator. Coverage includes actual bundled-model size/hash, writable preparation, cache reuse, truncated-file repair, partial-download cleanup, cancellation, timeouts, retry and Chinese/English UI. The built app passed the independent bundle-resource check.

A separate fresh iPadOS 27.0 simulator installation of the ARM64 Release build prepared the bundled model in 1.92 seconds and reached photo selection without any preloaded model. Full size/hash readback passed (`build/bundled-ipad27-first-launch.json`). This is simulator timing, not a real-device performance promise. Generic simulator builds include x86_64, which the upstream inference binaries do not support; the Release check uses the actual ARM64 simulator architecture.

Earlier entries below describe previous builds and their historical verification.
Formal review remains separate; the requested next distribution is TestFlight.

## Second startup rejection follow-up (23 October 2026)

Review submission `d9eb0165-f5bb-4105-9fdb-d14630e896e6` rejected app 1.0 (7)
on iPad Air 11-inch (M3), iPadOS 27.0.1. The screenshot shows "Connecting to the
model download…" and the backup-server description. ASC currently reports model
v2 accepted; this does not establish its availability at the time of review.

Three defects were reproduced and corrected:
- Checking and preparing states never expired under the previous watchdog.
- Alternating download progress and reconnecting could repeatedly reset the
  watchdog without receiving new data. Only a new progress high-water mark now
  extends the deadline, and all preparation phases have a deadline.
- The HTTPS fallback used async `URLSession.download` with a `didWriteData`
  callback that did not report progress. A real Release simulator download
  received 117,703,874 response bytes but was cancelled after 30.6 seconds as
  "stalled". The task delegate now exposes the actual task's `Progress` through
  `didCreateTask`. The watchdog observes `fractionCompleted`, because the task's
  composite progress can advance while its `completedUnitCount` remains unchanged.

The local HTTP regression streams 2 MiB over approximately 1.6 seconds, longer
than its 400 ms stall deadline. It failed with the previous download callback,
also failed when using the task's integer completed count, and passes with the
final implementation. It uses loopback only, without Apple/R2 or a model fixture.
The focused suite passed 13 test methods (including five stall phases):
`build/Review8-HTTP-Green2.xcresult`. Failure evidence is in
`build/Review8-HTTP-Red.xcresult` and `build/Review7-StallPhases-Red3.xcresult`.
The final loopback-only revision also passed all 13 methods in
`build/Review8-FinalProvisioner.xcresult`.

A fresh iPad Air 11-inch (M3), iPadOS 26.5 simulator with no injected model
completed the full Release-build HTTPS fallback in 125.162 seconds and reached
photo selection. Independent readback confirmed 387,710,976 bytes and SHA-256
`92dcbea108899e5d6e30d919b0744f90d9967e80c67a4ab5503ac16d54f62eb0`.
Evidence: `build/review8-ipad-download-receipt.json` and
`build/review8-ipad-download-complete.log`. This verifies a real transfer beyond
the former 30-second failure point, not Apple-hosted distribution.

These are confirmed defects, not proof of the exact reviewer-side sequence.
No iPadOS 27 device is available. The installed 27.1 simulator runtime supports
only iPhone Duo; an unsigned simulator build failed App Group validation during
AssetPackManager initialization there, so it is not a valid distribution test.
The user requested a TestFlight testing build first, with no review resubmission.
Model bytes, model asset v2, R2 object, and the persisted index format are unchanged.

### Retry and resumable backup follow-up

At the user's request, the idle timeout is now 60 seconds for both the watchdog
and backup HTTP requests. The download screen exposes Retry while connecting,
downloading, paused, preparing, or failed. Retry cancels the previous preparation
and waits for its owner to finish before starting another attempt; no photo/index
data is cleared. Local startup checks retain their existing separate startup UI.

The backup saves complete 8 MiB ranges in an Application Support partial file
keyed by the pinned model hash, excluded from backup. Subsequent attempts and
process launches start at the saved file length. A cancelled attempt checks
cancellation before committing a range; each append commits without actor
suspension. The server's 206 status, exact Content-Range and downloaded range
size are checked before append. If a server ignores Range and returns a complete
200 response, the existing partial is replaced, never concatenated. A completed
model still requires the pinned full-file size and SHA-256 validation. Invalid
models are discarded; recoverable failures preserve the partial for retry.
The unfinished range may be downloaded again (at most 8 MiB); the backup remains
a foreground transfer and is not promised to continue while iOS suspends the app.

The Worker now supports bounded/open-ended single byte ranges, If-Range ETag
matching, 206/416 responses, and HEAD/Accept-Ranges. The private bucket/object
and exact-path access restriction are unchanged. Worker version
`19a87072-3282-4cd0-aeff-b7fdfc0e50eb` was deployed; live readback of 1 KiB from
offset 8 MiB matched the original model (`build/review8-worker-range-receipt.json`).

Validation:
- 18 focused tests passed with no failures/skips in
  `build/Review8-ResumeAndRetry2.xcresult`, including a connecting-state retry UI
  test and real loopback HTTP cases for failure, cancellation, wrong Content-Range,
  and a server ignoring Range. Completed partial bytes survive retries and the
  final payload matches exactly.
- A fresh iPad Air M3 / iPadOS 26.5 simulator ran the Release build against R2.
  Manual Retry preserved progress. After terminating the process with 310,378,496
  bytes saved, relaunch issued ten successful 206 requests totaling 77,423,367
  response bytes (including protocol overhead), rather than fetching 388 MB again.
  The completed 387,710,976-byte file matched the pinned SHA-256 and reached photo
  selection. Receipts: `build/review8-resume-checkpoints.json`,
  `build/review8-resume-network.log`, `build/review8-resume-ready.png`.
- The earlier partial-fix release workflow `39970875036` was cancelled before
  publication so the final TestFlight build can include retry and resumption.

## R2 fallback release (21 October 2026)

Apple-hosted delivery remains the first choice. On an Apple error or 30 seconds
without byte progress, the app switches once to the HTTPS backup. A cancelled
attempt never starts the backup; both sources remain retryable and stale callbacks
cannot change the current attempt. Existing verified copies remain usable offline.
The 388 MB backup streams to a temporary file, then uses the same pinned size and
SHA-256 validation and atomic publication as Apple assets. The model bytes and
embedding version have not changed, so the search index does not need rebuilding.

The private `shotsync` bucket contains
`embeddinggemma-2-text-vision-440m.litertlm` (387,710,976 bytes), SHA-256
`92dcbea108899e5d6e30d919b0744f90d9967e80c67a4ab5503ac16d54f62eb0`.
S3 multipart upload and full readback were verified. The Worker in
`Cloudflare/model-download` exposes only this object's hash-qualified path, using
GET/HEAD; it cannot list, upload or download other bucket objects. The app contains
no R2 credentials. Deploy with `npx wrangler@4.151.3 deploy --config
Cloudflare/model-download/wrangler.jsonc`; run its checks with
`node Cloudflare/model-download/worker.test.mjs`.

Download URL:
https://photofind-model.clothpath.workers.dev/92dcbea108899e5d6e30d919b0744f90d9967e80c67a4ab5503ac16d54f62eb0/embeddinggemma-2-text-vision-440m.litertlm

Verification before release:
- Complete HTTP readback matched the size and SHA-256 above.
- iPhone SE (3rd generation), iOS 27.0: the development app with the failing
  Background Assets override downloaded and verified the model, then reached
  photo selection. Existing device data was retained; photo access was not granted.
- The same iPhone was subsequently updated through TestFlight to 1.0 (7). The
  distribution build opened successfully, reused the verified local model and
  reached photo selection (`build/r2-testflight7-iphone-ready.jpg`). This is an
  upgrade/reuse check, not a fresh Apple-hosted download check.
- Fresh iPad Air 11-inch (M3) simulator, iPadOS 26.5: no injected model or previous
  installation; real download, independent file hash verification and photo
  selection passed. Exact review-device iPadOS 27.0 testing remains unavailable.
- Full unit suite and model-download UI suite: 112 passed, none failed or skipped
  (`build/R2Fallback-AllUnit.xcresult`). New failure and stall fallback regressions
  failed before the implementation and pass after it.
- The release includes the current photo detail, grid and similarity changes.
  UI regression exposed test-harness issues: a launch-argument authorization
  default shadowed the value saved after permission was granted, and the
  exploration test selected a clipped thumbnail whose center was under the
  navigation bar. The tests now allow the saved authorization value and select
  a fully visible thumbnail while still checking restored scroll position. An
  older search test also expected the retired "找到" summary; it now checks
  the current searchable-photo coverage text.
- 42 distinct main-flow UI scenarios passed across the audit runs: 22 in the
  initial run's log, 18 in `build/R2Fallback-FinalUI.xcresult`, plus the corrected
  onboarding and search-summary cases in `build/R2Fallback-OnboardingFixed.xcresult`
  and `build/R2Fallback-SearchSummaryFixed.xcresult`. The latter bundle verifies
  the sole failure in FinalUI after correcting the obsolete text assertion.
  These are combined results, not a claim that one full UI suite was green.
  The initial run was interrupted during the long photo-by-photo place-name
  scan; its xcresult did not finalize, so its 22 passes are retained in
  `build/r2-current-ui.log`. The place-name scan and launch-performance benchmarks
  were not completed in this audit. A separate run on a fixture reset by the
  onboarding test was abandoned and replaced by the prepared acceptance-library
  run; missing-fixture failures are not counted as passes.

Release source: `593adb843d4ca38bc30f97cfa66fc2ad2189b753`.
The self-hosted macOS ARM64 release workflow
https://github.com/huanglizhuo/PhotoFind/actions/runs/39477505244 succeeded.
All three shipping bundles passed archive validation. App **1.0 (7)** is
`VALID`, with membership in the internal `findImage` TestFlight group verified;
build ID `4e93dedb-73a8-4a8c-a194-5518bdbce46c`. English and Chinese beta notes
describe the fallback and photo-browsing changes.

Review submission `d9eb0165-f5bb-4105-9fdb-d14630e896e6` includes this app
version and SemanticPhotosModel v2
(`5ccad275-bd64-4ea3-8f15-341c338e6912`). The rejected app item was removed from
the old unresolved submission using `reviewSubmissionItems` PATCH
`removed: true`; CLI `items remove` uses draft deletion and cannot remove an
already-submitted item. The old accepted v1 item was not replaced. Review notes
describe the startup fix and actual test coverage. The release setting was
found to be `AFTER_APPROVAL` and explicitly restored to `MANUAL` before
resubmission, matching the release policy recorded below.

Submitted with `asc review-submissions submit` on 21 October 2026. Both the
submission and app version were independently read back as `WAITING_FOR_REVIEW`;
the selected build is 7 and release type is `MANUAL`. The submission's two items
are the app version and asset v2. Receipts are in `build/r2-review-submitted.json`,
`build/r2-submitted-version.json` and `build/r2-submitted-items.json`.
Follow-up commits only change tests, CI diagnostics and this record; shipping
app, configuration and Worker sources still match release commit `593adb8`.

The backup uses a foreground URLSession; an interrupted backup may restart on
retry. It is subject to the Cloudflare account's Workers availability and limits.
GitHub release CI now waits for Apple's delayed internal-group assignment rather
than failing immediately after a build becomes VALID.

## Review rejection follow-up (21 October 2026)

This section supersedes the 18 October submission-status notes below.
Submission `f434a2ac-484c-4797-ad30-2101892b4c0c` contains both the app and
SemanticPhotosModel v1. App Store Connect reports the app rejected and the asset
version accepted. The reviewer reported indefinite loading on iPad Air 11-inch
(M3), iPadOS 27.0; the user also observed a Background Assets `PipelineNotFound`
error in TestFlight 1.0 (5).

Relaunching the installed build 5 on the connected iPhone SE (3rd generation),
iOS 27.0, reached photo selection with resources ready. No reinstall or model
injection was performed on that device. This does not establish the cause of
the transient system error or prove a fresh install succeeds reliably.

The local fix changes the required model pack from `prefetch` to `essential`,
so its download participates in installation. The app also ends a download
attempt after 120 seconds without byte progress and exposes retry without
waiting for an unresponsive system call. Active downloads can take longer;
late callbacks cannot overwrite a retry. Retry remains visible at the bottom
of the download screen. Local model validation and the pinned model bytes are
unchanged.

TestFlight upload (21 October): app **1.0 (6)** was uploaded and processed
as `VALID`, build ID `db2956c2-ddcc-489b-94d3-aa7341e09e8d`. Its beta state is
`IN_BETA_TESTING`, and membership in the internal group `findImage` is verified.
SemanticPhotosModel **v2**
(`5ccad275-bd64-4ea3-8f15-341c338e6912`) is `READY_FOR_TESTING` and is the active
internal beta asset version. The model bytes are unchanged; v2 publishes the
new download policy.

This upload was built locally from reviewed source `232e090` plus only the
startup fix, isolated from unrelated working-tree changes. The isolated
release suite passed 96 tests, none failed or skipped. Source, archive, IPA
and logs are under `build/TestFlightStartupSource-20261021`; the patch is
`build/startup-only.patch` and checksums are in
`build/startup-release-receipt.json`. This release did not run through GitHub
Actions. No App Store resubmission was made.

The subsequent iPhone SE Xcode Run reported “A server with the specified
hostname could not be found”; Xcode logged that refreshing the manifest
failed. This is distinct from the earlier `PipelineNotFound` report.
The installed app was development build 2. The device's Development Overrides
contained `https://receptors-kid-biol-must-trycloudflare.com`, which failed DNS
resolution. The normal Cloudflare quick-tunnel suffix is `.trycloudflare.com`;
the entered URL uses a hyphen instead. Neither `ba-serve` nor `cloudflared`
was running on the Mac. Correcting spelling alone does not establish a live
development resource server. This development-path failure does not establish
the cause of the earlier TestFlight `PipelineNotFound` error. No phone setting
was changed during this check.

Before resubmission:

- Test a fresh TestFlight installation on a spare iPhone and iPad, with
  Background Assets development overrides disabled and no injected model.
  Preserve the user's existing app data; also test an upgrade separately.
- Verify first launch, a failed/stalled connection and retry, then offline
  relaunch. Simulator fixtures do not verify Apple-hosted delivery.
- Include the new asset version with the corrected app submission after
  physical-device acceptance.

Local package: `build/SemanticPhotosModel-essential.aar` (generated and ignored
by Git). `ba-package evaluate` and packaging succeeded; model SHA-256 matches
the pinned value below.

Validation: the stalled-request regression failed before the fix and passed
after it. The ModelProvisioner, ModelFile and ModelDownload UI suites passed
on iPhone 17e and iPad Pro 13-inch (M5) simulators running 26.5: 13 tests per
run, none failed or skipped. Results: `build/ReviewStartupFix-iPhone.xcresult`
and `build/ReviewStartupFix-iPad.xcresult`. Coverage includes connecting,
stalled byte progress, pause, cancellation of an unresponsive request,
successful retry, stale callbacks, active progress, model validation and
visible retry controls. The exact review device/OS and fresh Apple-hosted
delivery of the new pack remain unverified.

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

## Legacy separately hosted model (builds through 8)

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
Formal App Store review is intentionally separate from the TestFlight workflow. Bundled-model builds do not require a separate model asset submission.

## GitHub Actions

- `iOS tests`: runs on main pushes affecting code, or manually.
- `Publish TestFlight`: manually dispatch on main; tests, archives, validates all bundle versions, exports, uploads, waits for processing and verifies that the exact build is available in the automatically populated internal group `findImage`.
- Both jobs serialize through `photofind-mac`; neither runs pull-request code.
- Runner: `photofind-mac-arm64`, label `photofind`; service directory `~/actions-runner-photofind`.
- Requires this Mac to be awake and logged in. The job unlocks only its dedicated `photofind-ci.keychain-db` using CI_KEYCHAIN_PASSWORD. The existing Apple Distribution identity is reused; no certificate is revoked.
- Xcode is selected with `DEVELOPER_DIR`. Installed tools: XcodeGen, asc-cli 0.18.6, Python 3, curl.
- TestFlight environment allows main only and stores ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY and CI_KEYCHAIN_PASSWORD. The job uses a temporary private key file and removes it on exit.
- Repository variable PHOTO_FIND_SIMULATOR identifies the dedicated CI simulator. Dependencies/model cache live in `~/Library/Caches/PhotoFindCI`.
- CI verifies the public model's pinned hash before copying it into the app bundle. It tests real text/image inference, unit tests and local preparation UI fixtures.
- The standalone first-keyboard timing benchmark is explicitly excluded from CI: it requires a prepared library/device and must be measured separately. Unexpected skipped tests fail CI.
- Fresh TestFlight/device acceptance remains a separate release gate; simulator tests do not establish real-device performance.

To publish another build: GitHub → Actions → Publish TestFlight → Run workflow → main. The build number is greater than both processed builds and upload records (including failed/pending attempts), not manually incremented in several targets. Do not concurrently upload the same marketing version outside this pipeline.

The dedicated keychain contains only the selected distribution identity (expires 25 April 2027). CI downloads the two named PhotoFind App Store profiles, signs manually and verifies get-task-allow is false. Renew the certificate/profiles before expiration. Other apps’ runners and keychains are retained.

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
npm ci --legacy-peer-deps
npm run dev -- --hostname 127.0.0.1 --port 3088
```

Open http://127.0.0.1:3088. Export bundle recreates the localized iPhone PNGs. Raw screenshots and source photos are not production app resources.
