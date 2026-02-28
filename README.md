# ClearDisk

**Your Mac is hiding 50–500 GB of developer caches. ClearDisk finds them in seconds.**

A free, open-source macOS menu bar app that monitors and cleans developer caches — Xcode, npm, Homebrew, Docker, pip, Cargo, Go, Gradle, and more. 590 KB. Zero dependencies. No data collection. No analytics. No network access. Ever.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License: MIT](https://img.shields.io/badge/License-MIT-green)
![Size](https://img.shields.io/badge/Size-590%20KB-brightgreen)

<!-- 
## Screenshots

TODO: Add screenshots
Screenshot 1: Hero card showing cleanable space
Screenshot 2: Developer tab with cache list
Screenshot 3: Overview with category bars
-->

---

## Why ClearDisk?

Your Mac's SSD is full of developer caches you forgot about. Xcode DerivedData alone can eat 200 GB. Add npm, Homebrew, Docker, pip, and Cargo — and you're losing hundreds of gigabytes to files that can be safely rebuilt.

**Existing tools don't solve this:**
- **DaisyDisk** ($10) — shows what's big, but doesn't know what's *safe to delete*
- **DevCleaner for Xcode** (1,500 ⭐) — only cleans Xcode. Ignores npm, pip, brew, Docker, Go, Cargo, Gradle
- **CleanMyMac** ($40/yr) — bloated, expensive, trust issues
- **SquirrelDisk** — dead (3 years, no updates)

ClearDisk scans **15 developer cache paths** in one tool. Lives in your menu bar. Alerts you when disk gets full.

## Features

- **15 Developer Caches** — Xcode (DerivedData, Archives, Simulators, Caches), CocoaPods, Carthage, Homebrew, npm, Yarn, pip, Gradle, Docker, Composer, Go modules, Rust Cargo
- **Hero Dashboard** — Big, clear display of total cleanable space with breakdown by dev caches and trash
- **Menu Bar Monitor** — Always-on disk usage display. Changes color at 80%/90% thresholds. Shows cleanable amount when disk is stressed
- **Risk Levels** — 🟢 Safe (rebuilds with a command), 🟡 Caution (large re-download needed), 🔴 Risky (may contain irreplaceable data)
- **Safe Delete** — Files go to Trash, not permanent delete. You can always recover
- **Visual Category Bars** — Color-coded proportional bars showing what's eating your disk
- **Recovery Tracking** — "Recovered 12.4 GB!" banner after cleanup + cumulative "Total saved: 123 GB" counter
- **Storage Forecast** — Predicts when your disk will be full based on usage trends (linear regression, 90-day history)
- **Smart Suggestions** — Age-based recommendations ("Not used for 90 days — safe to clean")
- **Smart Notifications** — Alerts at 80% and 90% disk usage, no spam
- **Onboarding** — First-launch welcome screen with permission status checking
- **100% Private** — No data collection. No analytics. No network access. Source code is open — verify yourself

## Comparison

| Feature | ClearDisk | DevCleaner | DaisyDisk | CleanMyMac |
|---------|-----------|------------|-----------|------------|
| Xcode cleanup | ✅ | ✅ | ❌ | ✅ |
| npm/pip/brew/docker/go/cargo | ✅ | ❌ | ❌ | Partial |
| Menu bar monitor | ✅ | ❌ | ❌ | ❌ |
| Risk levels | ✅ | ❌ | ❌ | ❌ |
| Storage forecast | ✅ | ❌ | ❌ | ❌ |
| Safe delete (Trash) | ✅ | ❌ | N/A | ❌ |
| Price | Free | Free | $10 | $40/yr |
| Open source | ✅ | ✅ | ❌ | ❌ |
| Privacy | No data | No data | Unknown | Telemetry |

## Installation

### Download

1. Download the latest release from [Releases](../../releases)
2. Unzip and drag `ClearDisk.app` to Applications
3. First launch — remove quarantine flag:
   ```bash
   xattr -cr /Applications/ClearDisk.app
   ```
4. Double-click to open (or Right-click → Open)

> **Why?** ClearDisk is not code-signed yet ($99/yr Apple Developer fee). The `xattr` command removes macOS Gatekeeper quarantine. You can verify the source code yourself — it's fully open.
> 
> Homebrew Cask install coming soon: `brew install --cask cleardisk`

### Build from Source

```bash
git clone https://github.com/bysiber/cleardisk.git
cd cleardisk
swift build -c release
bash build_app.sh
open ClearDisk.app
```

Requires macOS 14+ and Xcode Command Line Tools.

## How It Works

ClearDisk scans **known developer cache directories** on a 5-minute interval:

```
~/Library/Developer/Xcode/DerivedData     → 🟢 Safe
~/Library/Developer/Xcode/Archives        → 🟡 Caution
~/Library/Developer/CoreSimulator/Devices  → 🟡 Caution
~/Library/Caches/CocoaPods                → 🟢 Safe
~/Library/Caches/Homebrew                 → 🟢 Safe
~/.npm/_cacache                           → 🟢 Safe
~/Library/Caches/pip                      → 🟢 Safe
~/Library/Containers/com.docker.docker    → 🔴 Risky
~/.cargo/registry                         → 🟢 Safe
~/go/pkg/mod/cache                        → 🟢 Safe
...and 5 more
```

It only looks at these specific paths — no full disk scan, no file indexing, no background processes.

When you clean, files are **moved to Trash** (not permanently deleted). You can recover them anytime before emptying Trash.

## Privacy & Trust

- **Zero network access** — the app never connects to the internet
- **Zero telemetry** — no analytics, no crash reports, no usage data
- **Zero background processes** — only scans when the popover is open or on a 5-min timer
- **Open source** — read every line of code yourself
- **Safe delete** — everything goes to Trash first

## Tech Stack

- Swift + SwiftUI
- macOS 14+ (Sonoma)
- SPM (Swift Package Manager)
- No external dependencies
- ~500 lines of code total

## Contributing

Issues and PRs welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## License

[MIT](LICENSE) — Kadir Can Ozden
