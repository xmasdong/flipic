<p align="center">
  <img src="docs/icon-256.png" width="128" height="128" alt="Flipic icon">
</p>

<h1 align="center">Flipic</h1>

<p align="center"><a href="README.md">简体中文</a> · <b>English</b></p>

<p align="center">
  A lightweight image viewer for macOS. Double-click one photo, then page through the whole folder with the arrow keys.<br>Formerly PixDeck; renamed Flipic in 0.5.0.
</p>

<p align="center">
  <a href="https://github.com/xmasdong/flipic/releases/latest/download/Flipic.dmg"><b>Download Flipic.dmg</b></a>
  ·
  <a href="https://flipic.app/en/">Website</a>
  ·
  <a href="https://github.com/xmasdong/flipic/releases">All releases</a>
</p>

<p align="center">
  <a href="https://github.com/xmasdong/flipic/releases/latest"><img src="https://img.shields.io/github/v/release/xmasdong/flipic?label=release&color=444" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-444" alt="macOS 13 or later">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-444" alt="MIT"></a>
</p>

![Flipic browsing a folder](docs/screenshot-browse.jpg)

Open a single image in Preview and that is all you get: to see the next one, you have to go back to Finder, select the whole set and open it again. Flipic is built for exactly this. Double-click any photo, press → and you are on the next one, across the entire folder. The download is 2.3 MB, the app makes no network connections by default, and there is no account to create.

## Install

1. Download [Flipic.dmg](https://github.com/xmasdong/flipic/releases/latest/download/Flipic.dmg)
2. Open the disk image and drag Flipic into Applications
3. The first time you launch it, macOS reminds you the app came from the internet; click Open

Requires macOS 13 Ventura or later, on Apple silicon or Intel. The app is signed with a Developer ID and notarized by Apple. Older versions are on the [Releases](https://github.com/xmasdong/flipic/releases) page.

To make Flipic your default viewer, open Settings (⌘,) and click Make Default Viewer under General; common image formats and camera RAW are set in one go. You can also Control-click an image in Finder, hold ⌥ and choose Always Open With › Flipic.

Then use it like Quick Look: select a photo in Finder, press ⌘↓ to open it, page with the arrow keys, and press Esc to close (turn on Esc Closes Window in Settings first). The Space key in Finder belongs to the system's Quick Look and can't be taken over by another app.

## Features

**Viewing**

- Culling: press P to mark the photos you want (a same-name RAW is marked too) and ⇧P to show only marked ones. Marks are a Finder tag named Flipic, so the photo files are not changed and the tag in the Finder sidebar lists them all, ready to select and drag.
- Filter by rating: View › Show by Rating shows N stars and up, and File › Export to Folder… (⇧⌘E) copies or moves the photos shown in one go, numbering name clashes and taking RAW rating sidecars along.
- Side-by-side compare: C for two photos, Shift-C for four, with zoom and position synced so you can check focus and expressions across a burst. Hold ⌥ to nudge one pane on its own, and Shift-L turns syncing off.
- The bottom toolbar can be turned off in Settings if you prefer shortcuts and menus.
- Open several windows at once: opening another photo from Finder while one is showing starts a new window (Settings can switch back to replacing it), and File › New Window is ⌘N.
- Page through every image in the folder with ← →, sorted by name, date taken, date modified, date created or file size. Your sort order is remembered.
- Press Space for a Quick Look style preview: the window wraps itself to the photo's aspect ratio. Press Space again to go back. Turn on wrapping when opening a photo in Settings and photos opened from Finder start this way, with every photo you page to wrapped as well.
- Rest the pointer on any detail and press 0 to zoom to 100% right there; press 0 again to go back. Swipe left or right with two fingers on the trackpad to change photos (left for the next one). Pinch to zoom on the trackpad; double-click also toggles between fit-to-window and 100%. Photos are decoded at screen size first, and the full-resolution original loads only when you zoom in far enough to need it, which keeps memory use low.
- Photos switch instantly when you page; if you like a crossfade, turn on Fade Between Photos in Settings.
- The scroll wheel zooms around the pointer by default. If you would rather flip photos with it, change it in Settings; ⌘ + scroll then zooms. If you reversed your wheel with a tool like Mos, you can reverse the zoom direction too, and paging can be reversed so a downward swipe goes back, like on a phone.
- Panning a zoomed photo stops at its edges, so no empty space slides in. Thumbnails come in small, medium, large and extra large.
- HDR photos (iPhone HEIC, JPEGs with a gain map and more) can be shown in HDR, with highlights brighter than regular white, as in Preview. Turn it on in Settings; it is off by default and needs macOS 14 and an HDR-capable display.
- Nothing but the photo by default. Press I for camera, lens, shutter speed, aperture, ISO, date taken, size, color depth, color profile and, when the photo has GPS data, the location, which opens in Maps; Esc closes it.

**Star ratings**

Press 1 to 5 to give a photo one to five stars; the Rating submenu in the right-click menu has No Rating to clear it. Rated photos show their stars at the bottom center of the window. Ratings are written as standard XMP: into the file itself for JPEG, HEIC and TIFF (metadata only, no recompression), and into a same-name .xmp sidecar for proprietary RAW formats such as Sony, Canon and Nikon, so the RAW file is never touched. Lightroom, Bridge and Capture One read them. A RAW and the JPEG with the same name are rated together.

**Culling (Cleanup Mode, Beta)**

After an event or a conference shoot with hundreds of frames, press ⇧⌘K. Flipic checks the whole folder on your Mac and sorts the results into four groups: similar bursts, exact duplicates, closed eyes, and blurry or out-of-focus shots. In every burst it suggests the sharpest frame where nobody is blinking as the keeper and checks the rest; for closed eyes, it outlines the face it flagged.

Nothing is deleted until you press Move to Trash, and ⌘Z puts the files back. A RAW file and the JPEG with the same name are treated as one photo. Detection can be wrong, so give the selection a quick look before you delete.

![Cleanup Mode](docs/shots/cleanup-en.webp)

**Batch tools and more**

- Convert a whole folder to JPEG, PNG or HEIC; converted files go into a subfolder and the originals stay untouched
- Batch rename
- Rotate and save back to the file; for JPEG and HEIC only the orientation tag changes, so there is no quality loss
- Slideshow with 1, 2, 3, 5 or 10 seconds per photo and a 0.5 to 3 second crossfade, set separately from paging; click the photo to pause and click again to resume, with paging and rating available while paused; the thumbnail strip and toolbar hide while you leave the mouse alone
- Export compressed copies, set as desktop picture, move to Trash

**Hand off to your editor**

Pick Photoshop, Lightroom, Capture One or any other app in Settings, then press ⌘E to open the current photo in it. If a RAW file with the same name sits next to the JPEG, the RAW is what gets opened. File › Open With and the right-click menu let you pick a different app on the fly.

To jump between your editor and Flipic, record a global shortcut in Settings › Shortcuts: press it in any app to bring Flipic to the front, and again to hide it.

**Settings and shortcuts**

Every setting lives in one window (⌘,): sorting, crossfade, slideshow interval, Esc behavior, photo editor, scroll wheel and default viewer. Every shortcut can be changed there, and combinations with ⌘ show up in the menus.

**Formats and languages**

JPEG, PNG, HEIC, WebP, animated GIF, TIFF, AVIF, JPEG XL (macOS 14 or later), PSD, TGA, OpenEXR and common camera RAW formats (ARW, CR2, CR3, NEF, RAF, DNG and more). Any other image format macOS can decode opens too. The interface is available in 14 languages and follows your system setting.

## Keyboard shortcuts

| Key | Action |
|---|---|
| ← → | Previous / next photo |
| ↑ ↓, scroll wheel | Zoom in / out (the wheel can be switched to paging) |
| Space | Preview fitted to the photo; press again to exit |
| 0 | Zoom to 100% at the pointer; press again to fit |
| Double-click | Fit to window / 100% |
| 1–5 | Rate one to five stars |
| I | Photo info panel (Esc also closes it) |
| Esc | Back to fit; with Esc Closes Window on in Settings, closes the window when fitted |
| T | Thumbnail strip |
| R / L | Rotate right / left |
| S | Slideshow |
| Return | Rename |
| ⌘S | Export a compressed copy |
| ⌘⌫ | Move to Trash |
| ⌘E | Edit in your photo editor |
| ⇧⌘K | Cleanup Mode |
| ⇧⌘C / ⇧⌘B | Batch convert / batch rename |
| ⌘, | Settings (change any shortcut here) |

## Pro

Viewing, rating, marking, filtering, exporting, side-by-side comparison and Cleanup Mode stay free, and all of that code is in this repository (MIT).

Flipic Pro adds batch tools for people who cull and edit a lot. It is a one-time purchase ($12.99), and every download includes a 14-day trial: before/after comparison (hold `\` to switch, split line, opacity), sort into subfolders by rating, and favorite folders on ⌥1–⌥9. Pro code is not in the public repository, so building from source gives you the free edition. See [flipic.app/en/pro](https://flipic.app/en/pro/).

## Privacy

Flipic makes no network connections by default, has no account and collects no data. It only reads the images you open. Only when you choose Check for Updates… or turn on automatic update checks in Settings does it fetch a version file (version.json) from the website, sending no data; only Update Now downloads the new version from GitHub Releases, checks its signature and Apple notarization, and replaces the app. Cleanup Mode keeps its analysis in `~/Library/Caches/Flipic` and never writes anything into your photo folders. Only when you rate a photo does Flipic write the rating into its metadata or a same-name .xmp file. All the code is in this repository, so you can check for yourself.

## Building from source

Flipic is written in Swift and AppKit with no third-party dependencies. You need macOS 13 or later and Xcode 15 or the Swift 5.9 command line tools.

```bash
git clone https://github.com/xmasdong/flipic.git
cd flipic
./build.sh                 # builds build/Flipic.app with an ad-hoc signature
open build/Flipic.app
```

To work in Xcode, install [XcodeGen](https://github.com/yonaskolb/XcodeGen) and run `xcodegen generate` to create the project.

Signed and notarized release builds come from `scripts/build_devid.sh`. Put your signing credentials in `scripts/devid.env`, following `scripts/devid.env.example`; that file is ignored by git.

### Code layout

```
Sources/Photoview/
  AppDelegate.swift            Menu bar and launch arguments
  ViewerViewController.swift   Main viewer: paging, prefetch, HUD, toolbar, export and batch tools
  ZoomableImageView.swift      Zoom, pan, gestures, keyboard and scroll wheel
  ImageLoader.swift            ImageIO downsampled decoding and memory-aware caches
  FolderModel.swift            File list and sorting
  Filmstrip.swift              Thumbnail strip
  ExifReader.swift             Photo info
  CleanupScanner.swift         Per-photo analysis for Cleanup Mode: sharpness, faces and eyes, feature prints, hashes
  CleanupResult.swift          Grouping, suggested keepers and default selection
  CleanupController.swift      Cleanup Mode interface
  SettingsWindowController.swift  Settings window
  Shortcuts.swift              Customizable shortcuts
  HotKey.swift                 Global shortcut to show / hide Flipic
  Rating.swift                 Star ratings (XMP)
  UpdateChecker.swift          Update check (off by default; fetches version.json from the website)
  Updater.swift                Update Now: download, verify signature and notarization, replace and relaunch
Resources/                     Info.plist, icon, strings for 14 languages
docs/                          Website (GitHub Pages)
scripts/                       Release packaging and test image generators
scripts/icon/                  Icon draft generator, the source photo for its skyline and the final icon
```

A few launch arguments help with debugging without touching the UI:

```bash
Flipic=build/Flipic.app/Contents/MacOS/Flipic
$Flipic --bench <folder>            # paging latency, memory, main-thread stalls
$Flipic --cleanup-report <folder>   # per-photo Cleanup Mode metrics and groups
```

## Contributing

Found a bug, something that feels off, or a feature you want? Open an [issue](https://github.com/xmasdong/flipic/issues). Pull requests are welcome, translations especially: every language other than Simplified Chinese can be improved by a native speaker.

## License

[MIT](LICENSE). Use, modify and redistribute it freely, in personal or commercial projects, as long as the copyright notice is kept.

---

The icon started as a draft from `scripts/icon/make_icon.py`, which traces the real skyline of a photo taken in Yangshuo, Guilin (Wikimedia Commons, CC0); the final artwork was illustrated over that draft.

Photos in the screenshots are from Wikimedia Commons, all CC0: Santorini by Aidan Meyer and Anthony Delanoix, Lake Bled by Aleš Krivec, Hallstatt by Fineas Anton and Martin Horák, Iceland by Alexandre Godreau, Yosemite by John Salzarulo, Yangshuo by Manon Boyer. The desktop is a built-in macOS wallpaper.
