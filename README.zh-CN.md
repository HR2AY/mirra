<p align="center">
  <img src="assets/mirra-logo.png" alt="Mirra 标志" width="480">
</p>

<p align="center">
  <a href="README.md">English</a> · <strong>简体中文</strong>
</p>

# Mirra

Mirra 是一款用于实时虚拟试穿的 macOS 原生悬浮窗应用，在访达中显示为 **Try On**。收到可显示的变装画面后，左侧竖屏大窗显示试穿效果，右侧竖屏小窗显示摄像头实拍。

## 构建

需要 macOS 26 或更高版本，以及包含 macOS 26 或更高版本 SDK 的 Xcode 工具链。在仓库根目录运行以下命令。

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

## 使用

在 macOS 提示时允许访问摄像头。点击 **Upload**，选择一张 JPEG、PNG 或 WebP 格式的服装图片。确认选图后，应用会启动一次 30 秒的付费 Decart 试穿会话，并将图片和摄像头实时视频发送给该服务。如果出现登录页面，请输入访问密码。应用会复用站点的登录 Cookie，直到它过期。[试穿服务](https://try-on.apps.viceme.ai/)
