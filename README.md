<p align="center">
  <img src="assets/mirra-logo.png" alt="Mirra logo" width="480">
</p>

<p align="center">
  <strong>English</strong> · <a href="README.zh-CN.md">简体中文</a>
</p>

# Mirra

Mirra is a native macOS floating camera window for live virtual try-on. The app appears as **Try On** in Finder. When the service returns a usable frame, the large portrait preview on the left shows the try-on result and the smaller portrait preview on the right shows the live camera.

## Build

Requires macOS 26 or later and an Xcode toolchain with the macOS 26 SDK or later. Run these commands from the repository root.

```sh
app="build/Try On.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp macos/Info.plist "$app/Contents/Info.plist"
cp assets/mirra-logo.png "$app/Contents/Resources/"
xcrun swiftc -O -parse-as-library -target "$(uname -m)-apple-macosx26.0" \
  macos/*.swift -o "$app/Contents/MacOS/TryOn"
codesign --force --sign - "$app"
open "$app"
```

## Use

Allow camera access when macOS asks. Select **Upload** and choose a JPEG, PNG, or WebP garment image. Confirming the selection starts a paid 30-second Decart session and shares the image and live video with the service. If prompted, enter the access password on the embedded [try-on page](https://try-on.apps.viceme.ai/). The app reuses the website’s sign-in cookie until it expires.
