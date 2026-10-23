#!/usr/bin/env python3
"""Fail publication on a skipped test, mismatched extension, or unprocessed build."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile


def next_number(data, version, proposed):
    numbers = [int(b['buildNumber']) for b in data['data']
               if b.get('version') == version and b.get('platform') == 'IOS' and b['buildNumber'].isdigit()]
    return max(int(proposed), max(numbers, default=0) + 1)


def processed_build(data, version, number):
    matches = [b for b in data['data'] if b.get('version') == version and b.get('buildNumber') == number]
    assert len(matches) == 1, 'Uploaded build is missing or ambiguous'
    build = matches[0]
    assert build['processingState'] == 'VALID' and not build['expired'], 'Build is not available'
    return build['id']


def bundled_model(app):
    app = Path(app)
    model = app / 'embeddinggemma-2-text-vision-440m.litertlm'
    assert list(app.rglob('*.litertlm')) == [model], 'Bundle must contain exactly one model, in the main app'
    assert model.stat().st_size == 387710976, 'Bundled model size mismatch'
    digest = hashlib.sha256()
    with model.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    assert digest.hexdigest() == '92dcbea108899e5d6e30d919b0744f90d9967e80c67a4ab5503ac16d54f62eb0', 'Bundled model hash mismatch'
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    assert not any(key in info for key in ('BAHasManagedAssetPacks', 'BAUsesAppleHosting', 'BAAppGroupID')), 'Bundled builds must not request asset predownloads'
    print('Bundled model validated: 387710976 bytes, pinned SHA-256, no asset predownload')


def archive(path, version, number):
    app = Path(path) / 'Products/Applications/SemanticPhotos.app'
    bundles = [app, *app.glob('PlugIns/*.appex'), *app.glob('Extensions/*.appex')]
    expected = {'com.clothpath.mondigital', 'com.clothpath.mondigital.share'}
    actual = set()
    for bundle in bundles:
        info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        actual.add(info['CFBundleIdentifier'])
        assert info['CFBundleVersion'] == number and info['CFBundleShortVersionString'] == version, bundle
        assert info['UIDeviceFamily'] == [1], 'PhotoFind ships for iPhone only'
        subprocess.run(['codesign', '--verify', '--strict', str(bundle)], check=True)
        entitlements = plistlib.loads(subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(bundle)], stderr=subprocess.DEVNULL))
        assert entitlements.get('com.apple.developer.team-identifier') == 'N9Q47Y2LQ4'
        assert not entitlements.get('get-task-allow', False), 'Development signing must not ship'
    assert actual == expected, actual
    bundled_model(app)
    privacy = plistlib.loads((app / 'PrivacyInfo.xcprivacy').read_bytes())
    assert privacy['NSPrivacyTracking'] is False
    assert any(x['NSPrivacyAccessedAPIType'] == 'NSPrivacyAccessedAPICategoryFileTimestamp' for x in privacy['NSPrivacyAccessedAPITypes'])
    for locale, name in [('en', 'PhotoFind'), ('zh-Hans', '一句找图')]:
        strings = subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(app / f'{locale}.lproj/InfoPlist.strings')])
        assert json.loads(strings)['CFBundleDisplayName'] == name
    print(f'Archive validated: {version} ({number}), both shipping bundles')


def tests(path):
    summary = json.loads(subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', path]))
    assert summary['failedTests'] == 0 and summary['passedTests'] > 0, summary
    assert summary.get('skippedTests', 0) == 0, 'Unexpected skipped tests'
    print(f"Tests validated: {summary['passedTests']} passed, none failed or skipped")


if __name__ == '__main__':
    mode, *args = sys.argv[1:]
    if mode == 'archive':
        archive(*args)
    elif mode == 'model':
        bundled_model(*args)
    elif mode == 'tests':
        tests(*args)
    elif mode == 'build':
        print(processed_build(json.loads(Path(args[0]).read_text()), *args[1:]))
    elif mode == 'next-number':
        print(next_number(json.loads(Path(args[0]).read_text()), *args[1:]))
    elif mode == 'self-test':
        good = {'data': [{'id': 'test', 'version': '1.0', 'buildNumber': '2', 'processingState': 'VALID', 'expired': False}]}
        assert processed_build(good, '1.0', '2') == 'test'
        uploads = {'data': [{'version': '1.0', 'platform': 'IOS', 'buildNumber': '2', 'state': 'FAILED'},
                            {'version': '2.0', 'platform': 'IOS', 'buildNumber': '99'}]}
        assert next_number(uploads, '1.0', '2') == 3
        assert next_number(uploads, '1.0', '5') == 5
        assert next_number({'data': []}, '1.0', '1') == 1
        for version, number, state, expired in [('1.1', '2', 'VALID', False), ('1.0', '1', 'VALID', False), ('1.0', '2', 'PROCESSING', False), ('1.0', '2', 'VALID', True)]:
            bad = {'data': [dict(good['data'][0], version=version, buildNumber=number, processingState=state, expired=expired)]}
            try:
                processed_build(bad, '1.0', '2')
            except AssertionError:
                continue
            raise AssertionError('Invalid build accepted')
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            (app / 'Info.plist').write_bytes(plistlib.dumps({}))
            model = app / 'embeddinggemma-2-text-vision-440m.litertlm'
            for failure in ('missing', 'truncated', 'wrong-hash'):
                if failure != 'missing':
                    with model.open('wb') as stream:
                        stream.truncate(3 if failure == 'truncated' else 387710976)
                try:
                    bundled_model(app)
                except AssertionError:
                    continue
                raise AssertionError(f'Invalid model accepted: {failure}')
        print('Release checks self-test passed')
    else:
        raise SystemExit('Unknown check')
