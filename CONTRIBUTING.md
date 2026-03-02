# Contributing to ClearDisk

Thank you for your interest in contributing to ClearDisk! Every contribution helps make this tool better for developers everywhere.

## Ways to Contribute

### Report Bugs
- Open an [issue](https://github.com/bysiber/cleardisk/issues/new?template=bug_report.md) with steps to reproduce
- Include your macOS version and ClearDisk version

### Suggest Features
- Open an [issue](https://github.com/bysiber/cleardisk/issues/new?template=feature_request.md) describing the feature
- Explain the use case and how it would help developers

### Add New Cache Types
ClearDisk supports 15+ cache types. If you know of a developer cache that's missing:
1. Fork the repo
2. Add the cache definition in the scanner module
3. Submit a PR with a description of the cache type and typical size

### Improve Documentation
- Fix typos, improve descriptions
- Add translations
- Improve the README

### Code Contributions
1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-feature`
3. Commit your changes: `git commit -m "Add my feature"`
4. Push to your fork: `git push origin feature/my-feature`
5. Open a Pull Request

## Development Setup

### Requirements
- macOS 14+ (Sonoma or later)
- Xcode 15+
- Swift 5.9+

### Build from Source
```bash
git clone https://github.com/bysiber/cleardisk.git
cd cleardisk
open ClearDisk.xcodeproj
```

Build and run with Cmd+R in Xcode.

## Code Style
- Follow Swift API Design Guidelines
- Use SwiftUI for all new UI components
- Keep functions small and focused
- Add comments for non-obvious logic

## Pull Request Guidelines
- Keep PRs focused on a single change
- Include a clear description of what changed and why
- Test on macOS 14+ before submitting
- Screenshots/GIFs welcome for UI changes

## Questions?
Open a [Discussion](https://github.com/bysiber/cleardisk/discussions) -- we're happy to help!
