# PhotoFind · 一句找图

An iPhone photo search app. Describe a photo in Chinese or English, search using another image, or browse your library by color. Photos and search indexes are processed on-device.

## Requirements

- iPhone with iOS 26 or later.
- Xcode with an iOS 26+ SDK, XcodeGen, Apple Developer signing for a physical device.
- Internet for the first Apple-hosted model download (approximately 388 MB); indexed local photos can then be searched offline.

## Build

```sh
xcodegen generate
xcodebuild -project SemanticPhotos.xcodeproj -scheme SemanticPhotos \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The vendored MediaPipe package pins binary download URLs and SHA-256 checksums. The generated Xcode project, downloaded dependencies, model, credentials, and build outputs are not tracked.

## Behavior

- The model downloads before photo authorization and indexing.
- Search accepts input while the model prepares, then searches the latest committed input.
- Chinese IME composition does not run searches; committed text uses a 500 ms debounce.
- First indexing can warm the phone. Later passes usually process only new or edited photos.
- iCloud-only photos are not proactively downloaded for indexing without the user's choice.
- Screenshots support text recognition. Videos are excluded; Live Photos use the still image.
- Deleting a photo deletes it from the system library after confirmation.
- English/Chinese follows the iOS app language. Appearance supports System, Light, and Dark.

## Development model

Run `bash Tools/fetch_model.sh` to obtain the pinned public upstream model. Development builds need a local Background Assets test server or a verified model staged in the simulator; TestFlight/App Store builds use Apple hosting. See [release and testing](docs/RELEASE.md).

## Links

[Privacy policy](https://huanglizhuo.github.io/PhotoFind/privacy/) · [Support](https://huanglizhuo.github.io/PhotoFind/support/) · [Issues](https://github.com/huanglizhuo/PhotoFind/issues)

Third-party licenses and attribution are listed in [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).
