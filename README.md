<p align="center">
  <!-- Replace with actual app icon: <img src="assets/icon.png" width="128" height="128" alt="ClearDisk icon"> -->
  <img src="https://github.com/bysiber/cleardisk/raw/main/assets/icon.png" width="128" height="128" alt="ClearDisk">
</p>

<h1 align="center">ClearDisk</h1>

<p align="center">
  <strong>Your Mac is hiding 50–500 GB of developer caches.<br>ClearDisk finds them in seconds.</strong>
</p>

<p align="center">
  <a href="https://github.com/bysiber/cleardisk/releases/latest"><img src="https://img.shields.io/github/v/release/bysiber/cleardisk?color=blue&label=Download" alt="Latest Release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-5.9-F05138" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/Size-590%20KB-brightgreen" alt="Size: 590 KB">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green" alt="MIT License"></a>
  <a href="https://github.com/bysiber/cleardisk/stargazers"><img src="https://img.shields.io/github/stars/bysiber/cleardisk?style=social" alt="Stars"></a>
</p>

<br>

<p align="center">
  <!-- Replace with actual screenshot/GIF: <img src="assets/demo.gif" width="420" alt="ClearDisk demo"> -->
  <img src="https://github.com/bysiber/cleardisk/raw/main/assets/screenshot.png" width="420" alt="ClearDisk screenshot">
</p>

<p align="center">
  <em>Free · Open Source · 590 KB · No data collection · Files go to Trash (always recoverable)</em>
</p>

---

## Install

**Download:** Grab the latest `.dmg` from [**Releases**](https://github.com/bysiber/cleardisk/releases/latest) → drag to Applications → done.

<!-- **Homebrew:** `brew install --cask cleardisk` *(coming soon)* -->

<details>
<summary>First launch: unsigned app note</summary>

ClearDisk is not code-signed ($99/yr Apple Developer fee). After installing, run once in Terminal:

```bash
xattr -cr /Applications/ClearDisk.app
```

This removes the macOS Gatekeeper quarantine flag. The entire source code is open — verify every line yourself.

</details>

<details>
<summary>Build from source</summary>

```bash
git clone https://github.com/bysiber/cleardisk.git
cd cleardisk
bash build_app.sh
cp -R ClearDisk.app /Applications/
xattr -cr /Applications/ClearDisk.app
open /Applications/ClearDisk.app
```

Requires macOS 14+ (Apple Silicon) and Xcode Command Line Tools (`xcode-select --install`).

</details>

---

## Who Is This For?

You need ClearDisk if…

- 💾 **Your Mac says "Disk Full"** — but you have nothing obvious to delete
- 🧹 **You use Xcode + npm + Docker + more** — and need ONE tool to clean them all
- 🛡️ **You don't trust $40/yr cleanup apps** — with your filesystem and data
- ⚡ **You want always-on monitoring** — not a tool you have to remember to run

---

## Features

🔍 **28 Cache Paths, One Click** — Xcode, npm, Homebrew, pip, Cargo, Docker, Gradle, Go, Conda, Maven, CocoaPods, Composer, Flutter, JetBrains, and more. All in a single scan.

📦 **Project Artifact Scanner** — Finds stale `node_modules/`, `target/`, `.build/`, `vendor/` across your projects. Detects 11 project types. Sorted by staleness — oldest first.

🟢🟡🔴 **Risk Levels** — Every cache is color-coded. Green = safe to delete (rebuilds automatically). Yellow = caution (large re-download). Red = risky (may contain data). You decide.

📊 **Menu Bar Dashboard** — Lives in your menu bar. Shows disk usage at a glance. Changes color at 80%/90% thresholds. Click to see the full breakdown.

🔮 **Storage Forecast** — Predicts when your disk will be full based on 90-day usage trends. Know before it's too late.

<details>
<summary><strong>All Features</strong></summary>

- **Cache Descriptions** — Every cache shows a human-readable explanation so you know exactly what you're deleting
- **DerivedData Project Breakdown** — Shows which projects live inside DerivedData (e.g. "MyApp: 2.3 GB, Backend: 1.1 GB")
- **Xcode Running Check** — Warns you if Xcode is running before cleaning Xcode caches
- **Safe Delete** — Files go to Trash, not permanent delete. Always recoverable
- **Hero Dashboard** — Total cleanable space at a glance with breakdown by dev caches, project artifacts, and trash
- **Visual Category Bars** — Color-coded proportional bars showing what's eating your disk
- **Recovery Tracking** — "Recovered 12.4 GB!" banner after cleanup + cumulative "Total saved" counter
- **Smart Suggestions** — Age-based recommendations ("Not used for 90 days — safe to clean")
- **Smart Notifications** — Alerts at 80% and 90% disk usage, no spam
- **100% Private** — No data collection. No analytics. No network access. Zero telemetry. Open source.

</details>

---

## What Gets Cleaned

| Category | Caches | Risk | Typical Size |
|----------|--------|------|-------------|
| **Xcode** | DerivedData, Archives, Simulators, Device Support, Previews, Logs, Caches, Products | 🟢🟡 | 10–200 GB |
| **Package Managers** | npm, Homebrew, pip, Cargo, CocoaPods, Carthage, pnpm, Bun, Yarn, Conda, Composer, Flutter/Pub, Gems | 🟢 | 5–50 GB |
| **Build Tools** | Gradle, Maven, Swift PM, Go modules | 🟢 | 2–20 GB |
| **Containers** | Docker data | 🔴 | 10–100 GB |
| **IDEs** | JetBrains, Android emulators | 🟢🟡 | 2–30 GB |
| **Project Artifacts** | node_modules, target/, .build/, build/, vendor/ (11 types) | 🟢 | 5–100 GB |

---

## Comparison

| | ClearDisk | DevCleaner | npkill | kondo | mac-cleanup | DaisyDisk | CleanMyMac |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| **Native macOS GUI** | ✅ | ✅ | ❌ CLI | ❌ CLI | ❌ CLI | ✅ | ✅ |
| **Menu bar monitor** | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Xcode cleanup** | ✅ 9 paths | ✅ 6 paths | ✅ | ✅ | ✅ | ❌ | ✅ |
| **npm/pip/brew/go/cargo** | ✅ | ❌ | Partial | ❌ | ✅ | ❌ | Partial |
| **Docker/Gradle/Maven** | ✅ | ❌ | ❌ | ❌ | Partial | ❌ | ❌ |
| **Project artifacts** | ✅ 11 types | ❌ | ✅ | ✅ | ❌ | ❌ | ❌ |
| **Risk levels** | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Storage forecast** | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Safe delete (Trash)** | ✅ | ❌ | ❌ `rm -rf` | ❌ `rm -rf` | ❌ `rm -rf` | N/A | ❌ |
| **Cache paths** | 28 | 6 | 50+ | 24 types | 42 | 0 | — |
| **Price** | **Free** | Free | Free | Free | Free | $10 | $40/yr |
| **Open source** | ✅ MIT | ✅ GPL-3 | ✅ MIT | ✅ MIT | ✅ Apache-2 | ❌ | ❌ |

---

## How It Works

ClearDisk scans **known developer cache directories** every 5 minutes. No full disk scan, no file indexing.

When you clean, files are **moved to Trash** — not permanently deleted. You can recover them anytime.

<details>
<summary>All 28 scanned paths</summary>

```
~/Library/Developer/Xcode/DerivedData           🟢 Safe
~/Library/Developer/Xcode/Archives              🟡 Caution
~/Library/Developer/CoreSimulator/Devices        🟡 Caution
~/Library/Developer/Xcode/Products              🟢 Safe
~/Library/Developer/Xcode/iOS DeviceSupport     🟢 Safe
~/Library/Logs/CoreSimulator                    🟢 Safe
~/Library/Developer/Xcode/UserData/Previews     🟢 Safe
~/Library/Developer/CoreSimulator/Caches        🟢 Safe
~/Library/Caches/org.swift.swiftpm              🟢 Safe
~/Library/Caches/CocoaPods                      🟢 Safe
~/Library/Caches/Homebrew                       🟢 Safe
~/.npm/_cacache                                 🟢 Safe
~/Library/pnpm/store                            🟢 Safe
~/.bun/install/cache                            🟢 Safe
~/Library/Caches/pip                            🟢 Safe
~/.conda/pkgs                                   🟢 Safe
~/.gradle/caches                                🟢 Safe
~/.m2/repository                                🟢 Safe
~/.android/avd                                  🟡 Caution
~/Library/Containers/com.docker.docker          🔴 Risky
~/.pub-cache                                    🟢 Safe
~/.cache/JetBrains                              🟢 Safe
~/.gem                                          🟢 Safe
~/Library/Caches/Yarn                           🟢 Safe
~/.cache/go-build                               🟢 Safe
~/go/pkg/mod                                    🟢 Safe
~/.cargo/registry                               🟢 Safe
~/.composer/cache                               🟢 Safe
```

</details>

---

## Privacy & Trust

| | |
|---|---|
| 🔒 **Zero network access** | The app never connects to the internet |
| 📊 **Zero telemetry** | No analytics, no crash reports, no usage data |
| 🗑️ **Safe delete only** | Everything goes to Trash — always recoverable |
| 📖 **Fully open source** | Read every line of code yourself |
| ⚡ **590 KB, no dependencies** | Pure Swift + SwiftUI. Nothing bundled |

---

## Tech Stack

Swift · SwiftUI · macOS 14+ (Sonoma) · SPM · No external dependencies · ~2,000 lines of code

## Contributing

Issues and PRs welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## License

[MIT](LICENSE) — Kadir Can Ozden
