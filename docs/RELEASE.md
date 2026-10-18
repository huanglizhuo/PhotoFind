# Release and testing

App Store Connect app: 6823997811. Bundle ID: com.clothpath.mondigital.
Shipping targets: SemanticPhotos, SemanticPhotosShare, SemanticPhotosDownloader.
The version and build number are shared in project.yml; CI overrides the build number for all targets.

## Release acceptance

- [x] Recoverable source/history backup made before cleanup.
- [x] Obsolete implementation plans and reports removed; maintained documentation consolidated.
- [ ] Public source/history scan and GitHub push.
- [ ] Privacy/support pages deployed and linked in the app.
- [ ] Release archive, entitlements, privacy and signing validation.
- [ ] Dedicated macOS runner and repeatable CI tests.
- [ ] GitHub Actions run produces a processed TestFlight build in the internal group.
- [ ] Fresh TestFlight installation downloads the real Apple-hosted model.
- [ ] Device indexing, permissions, offline/retry, sharing and deletion acceptance.
- [ ] Remaining only: bilingual store listing and formal app/asset-pack review submission.

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
- `Publish TestFlight`: manually dispatch on main; tests, archives, validates all bundle versions, exports, uploads, waits for processing and adds the exact build to `findImage`.
- Both jobs serialize through `photofind-mac`; neither runs pull-request code.
- Runner: `photofind-mac-arm64`, label `photofind`; service directory `~/actions-runner-photofind`.
- Requires this Mac to be awake, logged in, with its signing keychain unlocked. The existing Apple Distribution identity is reused; no certificate is revoked.
- Xcode is selected with `DEVELOPER_DIR`. Installed tools: XcodeGen, asc-cli 0.18.6, Python 3, curl.
- TestFlight environment allows main only and stores ASC_KEY_ID, ASC_ISSUER_ID and ASC_PRIVATE_KEY. The job uses a temporary private key file and removes it on exit.
- Repository variable PHOTO_FIND_SIMULATOR identifies the dedicated CI simulator. Dependencies/model cache live in `~/Library/Caches/PhotoFindCI`.
- CI verifies the public model's pinned hash before staging it in the simulator. It tests real text/image inference, unit tests and download-state UI fixtures. This does not prove Apple-hosted delivery.
- The standalone first-keyboard timing benchmark is explicitly excluded from CI: it requires a prepared library/device and must be measured separately. Unexpected skipped tests fail CI.
- Source code alone cannot reproduce Apple-hosted downloads in a simulator. Fresh TestFlight/device acceptance remains a separate release gate.

To publish another build: GitHub → Actions → Publish TestFlight → Run workflow → main. The build number is taken from App Store Connect, not manually incremented in several targets. Do not concurrently upload the same marketing version outside this pipeline.
