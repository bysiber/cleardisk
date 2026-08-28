# ClearDisk - Change Log

All notable changes to ClearDisk are documented here.

## [2.0.25] - 2026-08-28
### Changed
- Full-disk results now keep a shallow, memory-bounded tree. Deeper folders retain accurate totals and are scanned on demand when opened.
- Opening or returning from an on-demand folder uses a lightweight native loading state, while the detailed scanning view remains reserved for explicit Scan and Rescan actions.

### Fixed
- Full startup-disk scans no longer retain a node for every discovered file or accumulate previous snapshots across rescans, preventing memory usage from growing into multiple gigabytes.

## [2.0.2] - 2026-08-27
### Added
- Disk Space rows now provide dedicated **Reveal in Finder** and guarded **Move to Trash** actions, with confirmation and protected-location checks.
- Project build artifacts are included in the total reclaimable-space estimate while remaining review-only and never automatically selected.

### Changed
- Folder rows open with one click, and larger button-style navigation controls make moving through scanned folders easier.
- Opening the menu bar popover reuses fresh results instead of starting another expensive scan.
- Application cache names use a clearer singular **Cache** suffix where one is needed.

### Fixed
- Full startup-disk scans now recognize macOS APFS System/Data volume boundaries correctly instead of finishing early with empty results.
- **Scan All** preserves and publishes indexed totals for Desktop, Documents, Downloads, Applications, Library, Home and Temporary Files cards.
- Background free-space refreshes no longer make the Disk Space scanner appear to be running.

## [2.0.1] - 2026-08-26
### Changed
- App-cache rows now stay compact and omit implementation details intended for developer caches.
- Cleanup entry points use **Review Caches** and **Review Projects**, with calmer non-destructive styling before the user selects anything to clean.
- The Review workspace includes an explicit Safe cache category alongside Caution and Risky findings.
- Main workspace tabs are larger, individually separated, hover-responsive and anchored below the header so switching sections no longer moves the navigation vertically.

### Fixed
- Large Personal Files now uses a supported system icon instead of rendering with a missing symbol.

## [2.0.0] - 2026-08-26
### Added
- **Full disk space scanner** with startup-disk, Home, Desktop, Downloads, Documents, Applications, temporary-files and safe system-area entry points.
- **Interactive treemap and directory browser** with cancellable background scanning, live progress, folder navigation, tooltips and persistent small-item grouping controls.
- **Application cache discovery** alongside developer caches, including expanded AI-tool, browser, updater and package-manager coverage.
- **Signed in-app updates with Sparkle 2.** GitHub releases now publish a Developer ID signed, notarized universal DMG and an EdDSA-signed appcast automatically.

### Changed
- ClearDisk opens on Disk Space and keeps the existing cache cleaner as a dedicated workspace.
- Disk scans run outside the UI thread and publish incremental progress, preventing the popover from freezing during large scans.
- Temporary Files combines the current user's temporary directory, `/private/tmp` and `/private/var/tmp` without exposing the whole `/private` hierarchy or double-counting it.
- Cache summaries use the simpler Safe, Caution and Risky breakdown while preserving detailed cache groups below.
- Background full scans run every 30 minutes while lightweight free-space updates continue every 5 minutes.

### Fixed
- Large scans no longer stall near 99%, lock the interface or retain completed scan state unnecessarily.
- Disk categories no longer expose unsafe broad system roots or count `/var` and `/private/var` aliases twice.
- Group disclosure indicators now keep cache names aligned instead of shifting nested rows.

## [1.9.0] - 2026-08-06
### Added
- **Go build cache** (`~/Library/Caches/go-build`). This is `GOCACHE`, and it is usually several times larger than the module download cache that was already listed. Cleared by `go clean -cache`; the next build is slower, then it is fast again.
- **Android System Images and NDK** (`~/Library/Android/sdk/system-images`, `.../ndk`). The existing Android entry covered `~/.android/avd`, which is often empty while the SDK beside it holds several gigabytes. Both are listed per subdirectory and never as the whole SDK: deleting `~/Library/Android/sdk` would take `platform-tools` with it, and there is no `adb` without it. The three Android entries now share a group.
- **VS Code updater cache** (`~/Library/Caches/com.microsoft.VSCode.ShipIt`), a sibling of the VS Code cache directory that was already listed. Squirrel parks downloaded update payloads there and never prunes them.
- **pnpm cache** (`~/Library/Caches/pnpm`). Separate from the package store: `pnpm store path` resolves to `~/Library/pnpm/store`, while registry metadata and the dlx cache live under Caches. Neither covers the other.
- **rustup toolchains** (`~/.rustup/toolchains`), grouped with the other version managers rather than with Rust Cargo — these are the compilers themselves, and removing one uninstalls that toolchain.
- **node-gyp headers** (`~/Library/Caches/node-gyp`) and **TypeScript type acquisition** (`~/Library/Caches/typescript`), both of which keep one copy per version indefinitely.

### Fixed
- Repositories kept directly in the home directory were never scanned for project artifacts. Every scan root was a subdirectory of `~`, and none of them reached its siblings, so a project in `~/my-project` was invisible while the identical project in `~/Documents/my-project` was found.

  The home directory is scanned one level down, and deliberately never as a project itself. Handing `~` to the scanner directly would have been worse than the bug: several tools leave a stray `~/package.json` behind, which makes the whole home directory match the Node.js type — and `.cache` and `.expo` are on that type's artifact list. `~/.cache` is the shared cache for uv, Puppeteer, Prisma, Bazel and HuggingFace, not a build directory, and it would have been offered for deletion. Matching at `~` would also have stopped the walk there, so the projects this is meant to find would never have been reached.
- Artifacts reachable from more than one scan root are listed once. A duplicate row double-counted its size in the totals and made the second clean fail on an already-trashed path.

### Changed
- Total cache paths: 74.

## [1.8.4] - 2026-08-01
### Changed
- Risk levels for the AI tools now describe what deleting actually costs, rather than which app owns the directory.
- Cursor and Windsurf are marked risky and no longer called caches. Both entries cover the whole `~/Library/Application Support/<app>` directory, which for an AI editor is where chat history, workspace state and settings live.
- Ollama models are marked caution instead of risky. They are downloads that `ollama pull` restores, and treating them as risky hid the largest entry in the list from the default view.

## [1.8.3] - 2026-08-01
### Fixed
- Claude Code and Claude Desktop data was listed as a deletable cache (#27). Both entries covered `~/.claude` and `~/Library/Application Support/Claude` in full, where session transcripts, job state, file history, plugins and settings live, and claimed the contents would be re-created. They are now marked risky and their descriptions state that the deletion is permanent.
- Clean Safe Caches emptied caution entries as well as safe ones, so a single click reached Xcode Archives, Android emulators, editor workspace state and every language-version manager. It now cleans only the entries marked safe.

### Changed
- Universal binary for Apple Silicon and Intel.

## [1.8.2] - 2026-07-16
### Added
- Added signed app produced pipeline to avoid `xattr -cr ...` quirk
- Updated version derivation from scripts

## [1.8.1] - 2026-07-13
### Fixed
- **No menu bar icon; the app appears to do nothing** (#22, #16). `NSApplication.delegate` is a *weak* reference, and nothing else in the app retained `AppDelegate` — every other reference to it captured `self` weakly. Held only by a local in `main()`, ARC was free to release it after its last use, before or during `app.run()`, taking the status item and the popover with it. The process kept running (some users still saw notification banners) but there was no menu bar icon and clicks went nowhere. Whether it happened at all depended on the optimiser, which is why it reproduced on some Macs and not others. The delegate is now held for the life of the process.

## [1.8.0] - 2026-07-12
### Added
- **Project scanner expanded from 11 to 23 project types** — Python, CocoaPods, Carthage, Xcode, .NET/C#, Godot, Unity, Unreal, Haskell, Elixir, Zig, Crystal, plus the modern JS caches (`.next`, `.nuxt`, `.svelte-kit`, `.angular`, `.turbo`, `.vite`, `.yarn/cache`). A project now lists each of its caches as a separate row.
- **Cleanup history** — every cleaned project cache is logged (what, where, how big, when) and can be reviewed or cleared from the Projects tab.
- **Failed cleans are now reported.** If a directory cannot be moved to the Trash, the app says so — and offers to open Full Disk Access settings when the cause is permissions.

### Fixed
- **Phantom savings**: a clean whose `trashItem` failed still reported "Recovered X!", credited the savings and wrote a history entry, while the files were untouched on disk. Only bytes that actually reach the Trash are counted now, measured from disk rather than assumed.
- **Unclickable UI after reopening the popover**: presenting a `.sheet` from inside a `.transient` NSPopover strands SwiftUI's presentation state when the popover auto-closes on focus loss. The project sheets are drawn inside the popover now, and every modal is torn down when the popover closes.
- **Duplicate artifact rows**: a directory matching two project types (a Unity project is also a .NET project; a JS+Python monorepo shares `dist/`, `build/`, `coverage/`) was listed once per type, double-counting its size and failing the second clean. Each directory is surfaced once.
- **Data-loss guards**: `env/`, `venv/`, `.venv/` are only ever offered when a real virtualenv is proven (`pyvenv.cfg` / `bin/activate`), and Crystal's `lib/` only when a `shard.lock` proves `shards install` ran. Unity `Builds/` and Unreal `Saved/` are no longer touched — those are user output, not caches.
- The large-file scanner no longer looks inside media library packages (`.photoslibrary`, `.fcpbundle`, `.imovielibrary`, …), where deleting a single file corrupts the whole library.

### Changed
- The version is declared once, in `CHANGELOG.md`, baked into the bundle by `scripts/build_app.sh`, and read back at runtime.
- Project cache actions use the same trash icon as the Developer tab — they perform the same destructive action.

## [1.7.0] - 2026-03-18
### Added
- **Game Engines**: Unity Cache (Asset Store), Unity Hub Cache, Godot Export Templates, Godot Cache
- **Version Managers**: nvm Node Versions, pyenv Versions (with `caution` risk — reinstall with `pyenv install`), mise Installs
- **Python Ecosystem**: Poetry Cache (`~/Library/Caches/pypoetry`), pipenv Virtualenvs — merged from PR #13 by @IT-HONGREAT
- **JVM/Build Tools**: SBT/Ivy Cache (`~/.ivy2/cache`), Gradle Wrapper distributions (`~/.gradle/wrapper/dists`), Bazel Cache (`~/.cache/bazel`)
- **Cloud CLIs**: AWS CLI SSO cache (`~/.aws/sso/cache`)
- Total cache paths increased from 44 to 63

## [1.6.4] - 2026-03-05
### Added
- **Terraform/OpenTofu cache support** - Monitor `~/.terraform.d` plugin cache and per-project `.terraform` artifact directories (Issue #10, PR #11)
- Terraform added as project type for artifact scanning (`main.tf` marker, `.terraform` artifacts)
- Total cache paths increased from 43 to 44

## [1.6.3] - 2026-03-04
### Added
- **AI tools cache support** - Claude Desktop, Claude Code, Ollama Models, ChatGPT Desktop, Cursor, Windsurf
- **VS Code cache support** - VS Code Cache, CachedData, CachedExtensionVSIXs, Chromium Cache, Logs
- Total cache paths increased from 32 to 43

### Changed
- Refactored cache path definitions into single source of truth (no more duplication between devCachePaths and scanDevCaches)

### Fixed
- Menu bar icon/text visibility on macOS Tahoe (always use template mode)
- Tray shows free space instead of cleanable amount (was confusing on high usage)
- Stale tray values fixed with Combine observer
- Expand view title centered using ZStack overlay

## [1.6.2] - 2026-03-02
### Added
- **Ruby ecosystem cache support** - rbenv versions, mise rubies, RVM, Bundler cache (PR #6 by @benoittgt)
- **Expand/collapse view** - expand button next to tab bar hides header and summary card for full-height content list (Issue #8)
- Total cache paths increased from 28 to 32

### Changed
- Popover height increased from 540 to 700px for better content visibility

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
