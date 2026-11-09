# Mirra

Mirra is a native macOS floating camera window for live virtual try-on. The app appears as **Try On** in Finder. When the service returns a usable frame, the large preview shows the try-on result and the smaller preview below shows the live camera.

## Build

Requires macOS 26 or later and an Xcode toolchain with the macOS 26 SDK or later. Run these commands from the repository root.

```sh
app="build/Try On.app"
mkdir -p "$app/Contents/MacOS"
cp macos/Info.plist "$app/Contents/Info.plist"
xcrun swiftc -O -parse-as-library -target "$(uname -m)-apple-macosx26.0" \
  macos/*.swift -o "$app/Contents/MacOS/TryOn"
codesign --force --sign - "$app"
open "$app"
```

## Use

Allow camera access when macOS asks. Select **Upload** and choose a JPEG, PNG, or WebP garment image. Confirming the selection starts a paid 30-second Decart session and shares the image and live video with the service. If prompted, sign in with your [try-on service account](https://try-on.apps.viceme.ai/). The app saves successful sign-ins in the macOS Keychain.
