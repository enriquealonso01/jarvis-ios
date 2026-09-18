# App Icon & Launch Screen (backlog #9)

## What ships
- `ios/JarvisApp/Assets.xcassets/AppIcon.appiconset/icon-1024.png` — single-size
  1024×1024 icon (modern single-size format; Xcode generates all masks).
  Design: arc-reactor mark — near-black background (#0A0B0F), gold (#FFC759)
  concentric rings, 12 tick marks, white-hot core. No text, no edge clipping
  (all content ~85px+ inside the safe margin; iOS applies corner masking).
- `Assets.xcassets/AccentColor.colorset` — JARVIS gold (srgb 1.0/0.78/0.35),
  wired via `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`.
- `Assets.xcassets/LaunchBackground.colorset` (#0A0B0F) +
  `Assets.xcassets/LaunchReactor.imageset` (reactor mark, 512px centered on a
  transparent 1024 canvas) — used by the Info.plist `UILaunchScreen` dict:
  ```xml
  UILaunchScreen: { UIColorName: LaunchBackground, UIImageName: LaunchReactor,
                    UIImageRespectsSafeAreaInsets: true }
  ```
  This is the modern (iOS 14+) plist-based launch screen: zero-launch storyboard
  not needed, no white flash, dark from first frame.

## Regenerating the icon
The icon was generated on the JARVIS box with Pillow (radial rings + ticks +
glow). To tweak: edit `scripts/gen_app_icon.py` (kept for reproducibility) and
run `python3 scripts/gen_app_icon.py`, then re-verify with the vision tool.

## Enrique-side
Nothing manual — the icon/launch screen ship with the next Xcode build
(`xcodegen` regenerates the project; asset catalog is a normal folder source).
