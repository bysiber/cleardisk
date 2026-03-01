BU USER NOTUDUR: SUBWATCHI BOŞVER SADECE CLEAR DISKE ODAKLAN !
# ClearDisk - Change Log

All notable changes to ClearDisk are documented here.

## [1.6.1] - 2026-03-02
### Added
- **Premium dark app icon** — Custom-designed icon with dark gradient, disk symbol, emerald progress arc, and sparkle effect
- **Screenshot showcase** — Professional card-deck style showcase with labeled screenshots in README
- **Animated HD banner** — Added to GitHub README header

### Changed
- Removed "path not readable — sizes may be incomplete" warning from UI (silently handled)
- SEO-optimized GitHub topics (20 tags for better discoverability)
- Updated repo description for better attention capture

### Removed
- QA.md purged from repository history

## [1.6.0] - 2026-03-02
### Added
- **Clean Caches Screen** — Dedicated sub-screen with Safe Only / All (Including Risky) mode toggle. Shows full cache list, risky warning details, and one-tap clean button
- **Clean Projects Screen** — Dedicated sub-screen with checkbox selection, Select All / Deselect All, filter by staleness (>30 days), and "Remove Selected" with total size
- **Project Sort Options** — Sort project artifacts by Size (default), Date, or Name in the Projects tab

### Changed
- **Hero Card Redesign** — Now shows total reclaimable space (caches + projects + risky + trash) with a color-coded segmented breakdown bar. Two action buttons: "Clean Caches" and "Clean Projects"
- Developer tab simplified — buttons removed from header (moved to hero card sub-screens)
- DMG now includes Applications shortcut for drag-to-install

## [1.5.0] - 2026-03-02
### Added
- **Project Artifacts Scanner** — New "Projects" tab finds stale `node_modules`, `target/`, `.build/`, `build/`, `vendor/` directories inside your project folders. Inspired by kondo (2,200⭐) and npkill (9,100⭐)
- **11 Project Types Detected**: Node.js, Rust, Swift PM, Go, Gradle, Gradle (Kotlin), Maven, PHP/Composer, Ruby, Flutter/Dart, CMake
- **Stale Detection**: Projects not modified for 30+ days are flagged with an orange warning
- **Individual Cleanup**: Trash any project's build artifacts with one click
- **Hub Card**: Hero card now shows project artifact total alongside dev caches and trash

### Changed
- Tab bar now has 4 tabs: Developer, Projects, Overview, Large Files
- Clean confirmation dialog shows project type and path details

## [1.4.0] - 2026-03-02
### Added
- **Cache Descriptions**: Every cache item now shows a human-readable description explaining what it is and whether it's safe to delete (inspired by npkill's 301-line description file)
- **DerivedData Project Breakdown**: Xcode DerivedData entry now shows which projects are inside (e.g. "MyApp: 2.3 GB, OtherApp: 1.1 GB") by reading each subfolder's `info.plist → WorkspacePath` (technique from DevCleaner)
- **Xcode Running Check**: When cleaning Xcode-related caches, a warning appears if Xcode is currently running ("Close Xcode first for best results")
- **Competitor Analysis**: 5 open-source competitors analyzed (DevCleaner, XcodeCleaner-SwiftUI, kondo, npkill, mac-cleanup-py) — insights applied to ClearDisk

### Changed
- Each cache row now has a subtle description line below the path
- Confirmation dialogs now include Xcode running warning when applicable
- Tooltips on path line show full cache description on hover

## [1.3.0] - 2026-03-01
### Added
- **Hero Dashboard**: Big, bold cleanable space display (28pt font) with dev cache + trash breakdown
- **Quick Action Bar**: "Clean X safe caches (Y GB)" one-click button in hero card
- **Visual Category Bars**: Color-coded proportional bars in Overview tab (each category gets unique color)
- **Recovery Banner**: Green "Recovered X GB!" banner appears for 5 seconds after any cleanup
- **Cumulative Savings**: Persistent "Total saved: X GB" counter in footer (survives app restart)
- **Onboarding Screen**: First-launch welcome overlay with feature list and notification permission status
- **Permission Checking**: Tracks notification permission state and inaccessible cache paths
- **Permission Banner**: Warning banner when notifications are denied or paths unreadable
- **Bundle Guard**: App no longer crashes when run via `swift run` (gracefully disables notifications)

### Changed
- Overview tab: categories now show proportional color bars instead of plain text rows
- Hero card replaced the small "X cleanable" row with a prominent dashboard
- Footer shows "Total saved" when user has cleaned anything, version number otherwise
- `build_app.sh` now uses relative path (works from any directory)

## [1.2.0] - 2026-02-28
### Added
- **Safe Delete (Trash)**: All cache cleaning now moves files to Trash instead of permanent delete
  - Users can recover files for 30 days before Trash is emptied
  - Fallback to removeItem only if trashItem fails (permission issue)
  - "Empty Trash" still permanently deletes (as expected)
- **Risk Levels**: Each developer cache now has a risk indicator
  - 🟢 Safe — can be rebuilt with a single command (DerivedData, npm, pip, brew, etc.)
  - 🟡 Caution — may need large re-download (Xcode Archives, Simulators)
  - 🔴 Risky — may contain irreplaceable data (Docker data)
  - Risk emoji shown next to each cache name in UI
  - Confirmation dialogs now show risk description
  - "Clean All" dialog warns about risky caches
- **MIT License** added
- **README.md** with feature comparison, installation, privacy statement
- **QA.md** rewritten from 10 professional perspectives (551 lines of research-backed analysis)
- Binary size: 590KB

## [1.1.0] - 2026-02-28
### Added
- **Storage Forecast**: Tracks disk usage over time and predicts "disk full in X days" using linear regression
  - Snapshots stored in UserDefaults (max 90 days, one per hour)
  - Shows forecast in header: red warning ≤7 days, orange ≤30 days, info >30 days
  - Shows "collecting data..." message while building initial dataset
  - Daily growth rate displayed (bytes/day)
- **Smart Suggestions**: Age-based cleanup recommendations for each dev cache
  - "Not used for X days" badge on each cache entry
  - ⚠️ red suggestion for caches >90 days old and >1GB
  - 💡 yellow suggestion for caches >60 days old
  - Suggestions only appear when actionable
- Binary size: 585KB

## [1.0.0] - 2026-02-28
### Added
- **Smart menu bar icon**: Color changes based on disk usage (normal=template, ≥80%=orange, ≥90%=red)
- **Smart menu bar text**: Shows free space normally, shows cleanable amount with ♻️ when disk ≥80%
- **macOS notifications**: Alert when disk reaches 80% or 90%, with cleanable amount in notification
- **"Total Cleanable" summary card**: Green card showing total cleanable space (dev caches + trash) at top of popover
- **"Clean All" button**: One-click button to clean all developer caches at once (with confirmation dialog)
- Large file threshold lowered to 100MB (was 500MB) — catches more files

### Fixed
- Event monitor memory leak — global monitor now properly removed when popover closes
- Notification spam prevention — only notifies once per threshold crossing, resets when usage drops below 75%

### Changed
- Popover height increased to 540px (from 520px) to accommodate cleanable summary
- Binary size: 503KB (was 450KB due to UserNotifications framework)

## [0.1.0] - 2026-02-28
### Initial Release
- Menu bar app with storage percentage icon
- Disk space overview with category breakdown (10 directories)
- Developer cache scanner (15 paths: Xcode DerivedData, Simulators, Archives, CocoaPods, Carthage, Homebrew, npm, Yarn, pip, Gradle, Docker, Composer, Go modules, Rust Cargo)
- Large file finder (>500MB in Downloads/Documents/Desktop/Movies)
- Quick cleanup actions: clean dev cache, empty trash, reveal in Finder
- 3 tabs: Overview, Developer, Large Files
- Color-coded storage bar (blue/orange/red by usage level)
- Confirmation alerts before destructive actions
- Version: 450KB binary, macOS 14+, LSUIElement=true (menu bar only)

### Known Limitations (v0.1.0)
- No smart alerts or notifications (**fixed in v1.0**)
- No total cleanable summary (**fixed in v1.0**)
- No "clean all" option (**fixed in v1.0**)
- Large file threshold too high at 500MB (**fixed in v1.0**)
- Event monitor memory leak (**fixed in v1.0**)

### Roadmap (from QA.md research)
- v1.1: Storage forecast (disk full prediction), smart suggestions based on file age
- NOT planned: Sunburst/treemap (DaisyDisk niche), auto scheduler (trust issue), duplicate finder (crowded space)

BU USER NOTUDUR: SUBWATCHI BOŞVER SADECE CLEAR DISKE ODAKLAN !