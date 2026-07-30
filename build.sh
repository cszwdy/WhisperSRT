#!/bin/bash
# Build WhisperSRT macOS app
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="WhisperSRT"
BUILD_DIR="$PROJECT_DIR/.build"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"

echo "==> Compiling with swiftc..."
mkdir -p "$BUILD_DIR" "$PROJECT_DIR/.tmp/module-cache"

SOURCES=("$PROJECT_DIR/Sources/$APP_NAME"/*.swift)

xcrun swiftc \
    -o "$BUILD_DIR/$APP_NAME" \
    -module-name "$APP_NAME" \
    -Xcc "-fmodules-cache-path=$PROJECT_DIR/.tmp/module-cache" \
    -framework SwiftUI \
    -framework AppKit \
    -framework UniformTypeIdentifiers \
    "${SOURCES[@]}"

echo "==> Creating .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Generate app icon
if command -v iconutil &>/dev/null; then
    ICONSET="$PROJECT_DIR/.tmp/AppIcon.iconset"
    mkdir -p "$ICONSET"

    swiftc -o "$PROJECT_DIR/.tmp/genicon" -framework AppKit - <<'SWIFTEOF' 2>/dev/null || true
import AppKit
let s: CGFloat = 512, img = NSImage(size: NSSize(width: s, height: s))
img.lockFocus()
let r = NSRect(x: 0, y: 0, width: s, height: s)
let p = NSBezierPath(roundedRect: r, xRadius: s*0.2, yRadius: s*0.2)
NSColor(red: 0.15, green: 0.38, blue: 0.90, alpha: 1).setFill(); p.fill()
let t = "W" as NSString
let a: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: s*0.6), .foregroundColor: NSColor.white]
let ts = t.size(withAttributes: a)
t.draw(at: NSPoint(x: (s-ts.width)/2, y: (s-ts.height)/2 - 10), withAttributes: a)
let cr = NSRect(x: s*0.66, y: s*0.14, width: s*0.26, height: s*0.26)
NSColor(red: 0.25, green: 0.55, blue: 0.95, alpha: 1).setFill()
NSBezierPath(ovalIn: cr).fill()
img.unlockFocus()
if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
    let bmp = NSBitmapImageRep(cgImage: cg)
    if let d = bmp.representation(using: .png, properties: [:]) {
        try? d.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.arguments[1] + "/icon_512x512.png"))
    }
}
SWIFTEOF

    if [ -f "$PROJECT_DIR/.tmp/genicon" ]; then
        "$PROJECT_DIR/.tmp/genicon" "$ICONSET"
        cp "$ICONSET/icon_512x512.png" "$ICONSET/icon_256x256@2x.png"
        iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null || true
    fi
fi

echo "==> ✅ App bundle created at: $APP_BUNDLE"
echo "==> Run: open '$APP_BUNDLE'"
