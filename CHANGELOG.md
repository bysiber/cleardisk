BU USER NOTUDUR: SUBWATCHI BOŞVER SADECE CLEAR DISKE ODAKLAN !
# ClearDisk - Change Log

All notable changes to ClearDisk are documented here.

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