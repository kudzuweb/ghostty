// NoDoz, the pieces that were NOT ported into Ghostty's Sleep Guard.
//
// Sleep Guard (macos/Sources/Features/SleepGuard/SleepGuard.swift) took NoDoz's pmse
// read/flip code, icons and menu. What is left here is the standalone-app scaffolding:
// the "Start at login" LaunchAgent code, the standalone app entry point, and the build
// step that renders the Dock icon. It is kept, commented out, in case NoDoz is revived
// as its own app. This folder is outside macos/Sources, so Xcode neither compiles nor
// bundles it. NoDoz.icns / NoDoz.png beside it are the built Dock icon (sun / moon).
// Source: ~/Documents/Projects/mac-tools/nodoz (NoDoz.swift, build.sh) and _lib.

// ---- Login item (from NoDoz.swift) ----
// // MARK: - Launch at login
// //
// // A LaunchAgent rather than SMAppService: it needs no code signature and no automation
// // permission, so it keeps working on a managed Mac and on a locally built app.
//
// enum LoginItem {
//     static var plistURL: URL {
//         FileManager.default.homeDirectoryForCurrentUser
//             .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
//     }
//
//     static var isEnabled: Bool {
//         FileManager.default.fileExists(atPath: plistURL.path)
//     }
//
//     static func enable() {
//         let appPath = Bundle.main.bundlePath
//         let plist: [String: Any] = [
//             "Label": launchAgentLabel,
//             // -g keeps the app from stealing focus at login.
//             "ProgramArguments": ["/usr/bin/open", "-g", appPath],
//             "RunAtLoad": true,
//             // Quitting from the menu should stay quit until the next login.
//             "KeepAlive": false,
//         ]
//         let dir = plistURL.deletingLastPathComponent()
//         try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
//         guard let data = try? PropertyListSerialization.data(
//             fromPropertyList: plist, format: .xml, options: 0) else { return }
//         try? data.write(to: plistURL)
//         _ = runStatus("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
//     }
//
//     static func disable() {
//         _ = runStatus("/bin/launchctl", ["bootout", "gui/\(getuid())/\(launchAgentLabel)"])
//         try? FileManager.default.removeItem(at: plistURL)
//     }
// }
//

// ---- Standalone app entry point (from NoDoz.swift; AppDelegate there also owned the status item) ----
// let launchAgentLabel = "com.mauria.nodoz"
// Menu items it added: "Start at login" (toggleLoginItem) and "Quit" (NSApp.terminate).
// let app = NSApplication.shared
// let delegate = AppDelegate()
// app.delegate = delegate
// app.setActivationPolicy(.regular)
// app.run()

// ---- Icon render step (from build.sh): ☀️/🌙 emoji to .iconset to .icns ----
//   swift render-emoji-icon.swift "☀️/🌙" "$BUILD/icon.iconset"
//   iconutil -c icns "$BUILD/icon.iconset" -o "$BUILD/icon.icns"
// render-emoji-icon.swift:
// #!/usr/bin/env swif
// // Renders one emoji character to every standard .iconset PNG size, for tools that want an
// // emoji as their Dock icon instead of custom artwork — easy to tell apart at a glance in a
// // Dock full of other people's icons.
// //
// // Usage: render-emoji-icon.swift <emoji> <out-iconset-dir>
// import AppKi
//
// let args = CommandLine.arguments
// guard args.count == 3 else {
//     FileHandle.standardError.write(
//         "usage: render-emoji-icon.swift <emoji> <out-iconset-dir>\n".data(using: .utf8)!)
//     exit(2)
// }
// let emoji = args[1]
// let outDir = args[2]
// try? FileManager.default.createDirectory(
//     atPath: outDir, withIntermediateDirectories: true)
//
// let sizes: [Int: [String]] = [
//     16: ["icon_16x16.png"],
//     32: ["icon_16x16@2x.png", "icon_32x32.png"],
//     64: ["icon_32x32@2x.png"],
//     128: ["icon_128x128.png"],
//     256: ["icon_128x128@2x.png", "icon_256x256.png"],
//     512: ["icon_256x256@2x.png", "icon_512x512.png"],
//     1024: ["icon_512x512@2x.png"],
// ]
//
// func render(_ emoji: String, size: Int) -> Data? {
//     let dim = CGFloat(size)
//     // Render straight into a bitmap of the exact target pixel size — lockFocus on an
//     // NSImage instead would draw at the screen's backing scale (2x on Retina), so a
//     // "512" file would come out 1024px, silently wrong for iconutil.
//     guard let rep = NSBitmapImageRep(
//         bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
//         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
//         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
//         let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
//
//     NSGraphicsContext.saveGraphicsState()
//     NSGraphicsContext.current = ctx
//
//     // Apple Color Emoji tops out well below 1024px, so this upscales at the larges
//     // sizes — soft but still identifiable, and that trade is the point: a real emoji
//     // glyph beats a crisper abstract shape for telling tools apart at a glance.
//     //
//     // Measure at a reference size and scale to fit, rather than assuming one square
//     // glyph — the string can be several characters wide (e.g. "☀️ / 🌙").
//     let reference: CGFloat = 200
//     let refFont = NSFont(name: "Apple Color Emoji", size: reference) ?? NSFont.systemFont(ofSize: reference)
//     let refSize = NSAttributedString(string: emoji, attributes: [.font: refFont]).size()
//     let scale = (dim * 0.86) / max(refSize.width, refSize.height)
//     let fontSize = reference * scale
//
//     let font = NSFont(name: "Apple Color Emoji", size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
//     let str = NSAttributedString(string: emoji, attributes: [.font: font])
//     let strSize = str.size()
//     str.draw(at: NSPoint(x: (dim - strSize.width) / 2, y: (dim - strSize.height) / 2))
//
//     NSGraphicsContext.restoreGraphicsState()
//     return rep.representation(using: .png, properties: [:])
// }
//
// for size in sizes.keys.sorted() {
//     guard let png = render(emoji, size: size) else {
//         FileHandle.standardError.write("render failed at \(size)px\n".data(using: .utf8)!)
//         exit(1)
//     }
//     for name in sizes[size]! {
//         try png.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
//     }
// }
