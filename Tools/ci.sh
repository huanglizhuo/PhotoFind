#!/bin/bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
cd "$(dirname "$0")/.."
mode=${1:?Use test or release}
[[ "$mode" == test || "$mode" == release ]] || exit 2
cache="${PHOTO_FIND_CACHE:-$HOME/Library/Caches/PhotoFindCI}"
simulator="${PHOTO_FIND_SIMULATOR:?Set the dedicated PhotoFind CI simulator UUID}"
mkdir -p "$cache/SourcePackages" "$cache/Model" build
[[ -e Model ]] || ln -s "$cache/Model" Model
bash Tools/fetch_model.sh
xcodegen generate
xcrun simctl boot "$simulator" 2>/dev/null || true
xcrun simctl bootstatus "$simulator" -b
# Only this simulator belongs to CI. UI fixtures contain no personal library data.
xcodebuild -project SemanticPhotos.xcodeproj -scheme SemanticPhotos \
  -destination "platform=iOS Simulator,id=$simulator" \
  -derivedDataPath build/CI -clonedSourcePackagesDirPath "$cache/SourcePackages" \
  CODE_SIGNING_ALLOWED=NO build-for-testing > build/test-build.log 2>&1 || { tail -60 build/test-build.log; exit 1; }
python3 Tools/release_checks.py model build/CI/Build/Products/Debug-iphonesimulator/SemanticPhotos.app
xcodebuild -project SemanticPhotos.xcodeproj -scheme SemanticPhotos \
  -destination "platform=iOS Simulator,id=$simulator" \
  -derivedDataPath build/CI -clonedSourcePackagesDirPath "$cache/SourcePackages" \
  -parallel-testing-enabled NO -resultBundlePath "build/Tests-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}.xcresult" \
  -only-testing:SemanticPhotosTests \
  -skip-testing:SemanticPhotosTests/PerformanceTests/testFirstSearchFocusResponsiveness \
  -only-testing:SemanticPhotosUITests/ModelPreparationUITests \
  -only-testing:SemanticPhotosUITests/LocalizationAppearanceUITests/testEnglishPreparationAndFailure \
  CODE_SIGNING_ALLOWED=NO test-without-building > build/tests.log 2>&1 || { tail -80 build/tests.log; exit 1; }
python3 Tools/release_checks.py tests "build/Tests-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}.xcresult"
[[ "$mode" == release ]] || exit 0

: "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}" "${ASC_PRIVATE_KEY:?}" "${CI_KEYCHAIN_PASSWORD:?}"
umask 077
auth_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/photofind-auth.XXXXXX")
trap 'rm -rf "$auth_dir"' EXIT
mkdir -p "$auth_dir/home"
printf '%s' "$ASC_PRIVATE_KEY" > "$auth_dir/AuthKey_$ASC_KEY_ID.p8"
unset ASC_PRIVATE_KEY
export ASC_PRIVATE_KEY_PATH="$auth_dir/AuthKey_$ASC_KEY_ID.p8"
# asc prefers the user's saved account over env vars; isolate Foundation's home.
asc_ci() { CFFIXED_USER_HOME="$auth_dir/home" asc "$@"; }
asc_ci auth check > "$auth_dir/check.json"
python3 - "$auth_dir/check.json" <<'PY'
import json, os, sys
data = json.load(open(sys.argv[1]))
text = json.dumps(data)
assert os.environ['ASC_KEY_ID'] in text and 'environment' in text, 'Unexpected ASC credentials'
PY
asc_ci profiles list --type IOS_APP_STORE > "$auth_dir/profiles.json"
python3 - "$auth_dir/profiles.json" <<'PY'
import base64, json, os, pathlib, subprocess
import sys
keychain = str(pathlib.Path.home() / 'Library/Keychains/photofind-ci.keychain-db')
subprocess.run(['security', 'unlock-keychain', '-p', os.environ['CI_KEYCHAIN_PASSWORD'], keychain], check=True, capture_output=True)
profiles = pathlib.Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles'
profiles.mkdir(parents=True, exist_ok=True)
expected = {'PhotoFind App Store': 'TJGTSMJT2W', 'PhotoFind Share App Store': '44VF4NZK55'}
found = set()
for p in json.load(open(sys.argv[1]))['data']:
    if p['name'] not in expected:
        continue
    assert p['bundleIdId'] == expected[p['name']] and p['profileState'] == 'ACTIVE', 'Invalid signing profile'
    (profiles / (p['id'] + '.mobileprovision')).write_bytes(base64.b64decode(p['profileContent'], validate=True))
    found.add(p['name'])
assert found == set(expected), 'Missing PhotoFind distribution profiles'
PY
unset CI_KEYCHAIN_PASSWORD
# CI signing is explicit; the normal development project keeps automatic signing.
ruby -ryaml -rjson -e '
spec = YAML.load_file("project.yml")
{"SemanticPhotos" => "PhotoFind App Store", "SemanticPhotosShare" => "PhotoFind Share App Store"}.each do |target, profile|
  spec["targets"][target]["settings"]["base"].merge!({"CODE_SIGN_STYLE" => "Manual", "CODE_SIGN_IDENTITY" => "93A4223AB109F4BC046C1E8DD71E0056F3EFC545", "PROVISIONING_PROFILE_SPECIFIER" => profile})
end
File.write("build/ci-project.json", JSON.generate(spec))'
xcodegen generate --spec build/ci-project.json --project-root . --project .
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/CI/Build/Products/Debug-iphonesimulator/SemanticPhotos.app/Info.plist)
build_number=$(asc_ci builds next-number --app-id 6823997811 --version "$version" --platform ios)
[[ "$build_number" =~ ^[0-9]+$ ]] || { echo 'Invalid next build number'; exit 1; }
asc_ci builds uploads list --app-id 6823997811 > build/previous-uploads.json
build_number=$(python3 Tools/release_checks.py next-number build/previous-uploads.json "$version" "$build_number")
signing=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_PRIVATE_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
xcodebuild -project SemanticPhotos.xcodeproj -scheme SemanticPhotos -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/Release \
  -clonedSourcePackagesDirPath "$cache/SourcePackages" -archivePath build/PhotoFind.xcarchive \
  CURRENT_PROJECT_VERSION="$build_number" \
  OTHER_CODE_SIGN_FLAGS="--keychain $HOME/Library/Keychains/photofind-ci.keychain-db" \
  "${signing[@]}" archive > build/archive.log 2>&1 || { tail -60 build/archive.log; exit 1; }
python3 Tools/release_checks.py archive build/PhotoFind.xcarchive "$version" "$build_number"
xcodebuild -exportArchive -archivePath build/PhotoFind.xcarchive \
  -exportOptionsPlist Config/ExportOptions.plist -exportPath build/Export \
  "${signing[@]}" > build/export.log 2>&1 || { tail -60 build/export.log; exit 1; }
asc_ci builds upload --app-id 6823997811 --file build/Export/SemanticPhotos.ipa \
  --version "$version" --build-number "$build_number" --platform ios --wait > build/upload.json
asc_ci builds list --app-id 6823997811 --version "$version" --platform ios --limit 100 > build/builds.json
build_id=$(python3 Tools/release_checks.py build build/builds.json "$version" "$build_number")
# Apple's internal-group assignment can lag behind successful build processing.
distributed=false
for attempt in {1..30}; do
  if swift Tools/verify_testflight.swift "$build_id" 1910af7c-a927-495c-92be-a2b47c787691 > build/distribution.txt 2>&1; then
    distributed=true
    break
  fi
  sleep 30
done
[[ "$distributed" == true ]] || { cat build/distribution.txt; exit 1; }
printf 'TestFlight %s (%s), build ID %s\n' "$version" "$build_number" "$build_id" | tee build/release-result.txt
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then cat build/release-result.txt >> "$GITHUB_STEP_SUMMARY"; fi
