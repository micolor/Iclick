# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

IClick is a macOS desktop application that extends Finder's context menu with custom functionality. It's a menu bar application that adds various right-click actions to macOS Finder, built with Swift 6.2+ and SwiftUI.

**Key Technologies:**
- Swift 6.2+ (required)
- SwiftUI (all UI components)
- AppKit (system integration only, no UI)
- plist-backed `SharedSettings` (persistence — see `IClick/Shared/StringExtension.swift`)
- FinderSync framework (Finder extension)
- App Group Unix domain socket IPC (extension → app actions, with peer signature checks)
- App Group config snapshot (app → extension configuration)
- Xcode 16+ (required for development)

## Architecture

IClick follows a dual-process architecture:

### 1. Main Application (`IClick/`)
- SwiftUI-based menu bar application
- Manages global settings and state via `AppState.swift`
- Provides settings interface (Settings window)
- Handles file operations triggered from context menu
- Entry point: [IClickApp.swift](IClick/IClickApp.swift)

### 2. FinderSync Extension (`FinderSyncExt/`)
- Runs as a separate process, injected into Finder
- Injects custom context menu items into Finder
- Sends actions to the main app via `LocalIPC` (Unix socket + peer signature validation)
- Reads configuration from the App Group snapshot; watches `configVersion` per menu build
- Entry point: [FinderSyncExt.swift](FinderSyncExt/FinderSyncExt.swift)

### 3. Communication Layer
- **Extension → App**: `LocalIPCServer` / `LocalIPCClient`
  ([LocalIPC.swift](IClick/Shared/LocalIPC.swift)); the app accepts only a peer whose
  signing identifier is `cn.anwen.IClick.FinderSyncExt` and Team ID is `33WRMMC62L`.
- **App → Extension**: no notification channel. The app writes
  `SharedSettings-snapshot.plist` in the App Group container and increments
  `ICLICK_CONFIG_VERSION`; the extension reloads when it sees a newer version.
- `MessagePayload` (in [Messager.swift](IClick/Shared/Messager.swift)) is the shared
  Codable message shape for IPC.
- Historical protocol notes: [specs/001-macos-app-macos/contracts/app-extension-communication.md](specs/001-macos-app-macos/contracts/app-extension-communication.md)
  (superseded by LocalIPC + snapshot).

### 4. State Management
- **AppState**: Centralized `ObservableObject` managing all app state
  - Apps: External applications that can open files
  - Dirs: Permissive directories (no security bookmarks — the app is non-sandboxed)
  - Actions: Custom context menu actions
  - NewFiles: File templates for creation
  - CommonDirs: Quick access folders
- Persistence: a single plist at `~/Library/Application Support/IClick/SharedSettings.plist`,
  read/written through `SharedSettings`. There is no App Group and no SwiftData layer.
- Location: [AppState.swift](IClick/AppState.swift)

### 5. Data Models
All models are in [IClick/Model/](IClick/Model/):
- `RCBase.swift`: The `RCBase` protocol plus `OpenWithApp`, `PermissiveDir`, `NewFile`, `CommonDir`, `RCAction`
- `Models.swift` / `ModelContainer.swift`: empty placeholders — the SwiftData layer was removed
  (nothing ever queried it, and container creation failure was a `fatalError` on the launch path)

## Build and Development Commands

### Building
```bash
# Build the project
xcodebuild -project IClick.xcodeproj -scheme IClick -destination 'platform=macOS'

# Build for release
xcodebuild -project IClick.xcodeproj -scheme IClick -configuration Release
```

### Running
- Open `IClick.xcodeproj` in Xcode 16+
- Select the IClick scheme
- Press Cmd+R to build and run
- The FinderSync extension will be automatically registered

### Testing
```bash
# Run tests (if test targets exist)
xcodebuild test -project IClick.xcodeproj -scheme IClick -destination 'platform=macOS'
```

### Linting
```bash
# Run SwiftLint (if configured)
swiftlint
```

## Key Development Patterns

### Adding New Context Menu Actions

1. Define/update the action in [RCBase.swift](IClick/Model/RCBase.swift) (`RCAction`)
2. Add to `RCAction.all` static property
3. Handle action in [IClickApp.swift](IClick/IClickApp.swift) in `actionHandler()` method
4. Extension receives action via menu callback and sends message to main app

### Adding New File Templates

1. Add to `NewFile` in [RCBase.swift](IClick/Model/RCBase.swift)
2. Add template file to [Assets.xcassets](IClick/Assets.xcassets/)
3. Handle creation in [IClickApp.swift](IClick/IClickApp.swift) in `createFile()` method

### Inter-Process Communication

When adding new message types:
1. Define `MessagePayload` structure in [Messager.swift](IClick/Shared/Messager.swift)
2. Register message handler in appropriate init method
3. Update contract documentation in [specs/001-macos-app-macos/contracts/app-extension-communication.md](specs/001-macos-app-macos/contracts/app-extension-communication.md)

### File Access

The main app is **not sandboxed**, so it touches the filesystem directly — there are no
security-scoped bookmarks (`bookmarkData` / `startAccessingSecurityScopedResource`) anywhere
anymore. The FinderSync extension *is* sandboxed, so it never does file I/O itself; it sends a
message and lets the main app act.

Destructive operations must stay recoverable:
- Deleting moves to the Trash (`FileManager.trashItem`), never `removeItem`
- Check `Utils.isProtectedFolder` before deleting
- Filenames built from user-editable templates must be sanitized (no `/`, `:`, or `..`)

See `deleteFolderFile()` and `doCreateFile()` in [IClickApp.swift](IClick/IClickApp.swift).

## Important Constraints

### IClick Constitution Requirements
- **MUST use Swift 6.2 syntax** - no older Swift patterns
- **MUST use SwiftUI for all UI** - no AppKit UI components
- **AppKit usage limited to system integration only** (e.g., NSWorkspace, NSPasteboard, file operations)
- **Target macOS 15 Sequoia and above only**

### Extension Development
- Extension runs in separate process with limited memory
- Must handle `isHostAppOpen` state - don't block if main app not available
- Liveness is a local `NSWorkspace.runningApplications` query; there is no heartbeat
- Configuration comes from the App Group snapshot; bump `configVersion` when it changes
- The extension target deliberately excludes app-only `Shared/*.swift` files
  (`Updater`, `UpdaterView`, `LaunchAtLogin`, `Extension+`) so it does not link SwiftUI
- See [FinderSyncExt.swift](FinderSyncExt/FinderSyncExt.swift)

### Logging
- Use `@AppLog` property wrapper for structured logging
- Logs use `os.log` framework
- Category parameter should describe the subsystem
- Example: `@AppLog(category: "AppState") private var logger`

### Data Persistence
- Everything goes through `SharedSettings` ([StringExtension.swift](IClick/Shared/StringExtension.swift)),
  a plist at `~/Library/Application Support/IClick/SharedSettings.plist`
- **Single writer**: only the main app writes. `SharedSettings.set`/`save` are no-ops when
  `isExtension` is true; the extension reads the App Group snapshot and adopts it into
  memory on launch (`adoptSnapshotIfNeeded`). Never let the extension write this file.
- Migrations (`migrateFromLegacyIfNeeded`) must **fill missing keys only, never overwrite**,
  and must read their sentinel with `object(forKey:)` — `string(forKey:)` returns nil for a `Bool`
- `AppState.load()` decodes each section independently; a corrupt section must never fall back to
  defaults *and save*, or it will erase the user's data

## Directory Structure

```
IClick/
├── IClick/                        # Main application target
│   ├── IClickApp.swift           # App entry point & AppDelegate
│   ├── AppState.swift            # Global state management
│   ├── Model/                    # Data models (RCBase.swift; Models.swift is a stub)
│   ├── Settings/                 # Settings views (UI)
│   ├── Shared/                   # Utilities & services
│   ├── Assets.xcassets/          # Images, templates, icons
│   └── Resources/                # Localization files
├── FinderSyncExt/                # Finder extension target
│   ├── FinderSyncExt.swift       # Extension main file
│   └── MenuItemClickable.swift   # Menu item handlers
├── specs/                        # Feature specifications & contracts
└── IClick.xcodeproj             # Xcode project
```

## Common Issues

### Extension Not Loading
- Ensure extension is enabled in System Settings → General → Login Items & Extensions → Finder Extensions
- Check that `FIFinderSyncController.default().directoryURLs` is `["/"]`
- Verify the App Group snapshot exists and carries a recent `ICLICK_CONFIG_VERSION`
- Verify `ipc.sock` exists and the app log shows the peer's bundle/team on connect

### Context Menu Shows Up Twice
- Two `FinderSyncExt` processes are running. This is a LaunchServices registration problem,
  usually caused by stale copies of the app (old `build/` output, xcarchive, old DerivedData).
- `lsregister -dump | grep -i iclick` to see every registered copy, `lsregister -u <path>` the
  stale ones, then `lsregister -f -R -trusted /Applications/Iclick.app`
- Kill leftover processes and relaunch Finder afterwards

### Config Changes Not Reaching the Extension
- The extension is a read-only consumer; it only sees what the app wrote into the snapshot
- `SharedSettings.set` does not bump the version by itself — call `appState.sync()` (or
  `notifyConfigChanged()`) after writing, or the menu keeps showing stale data
- `notifyConfigChanged()` is debounced (80 ms) and only bumps `ICLICK_CONFIG_VERSION`;
  the extension notices the higher version on its next menu build and reloads the snapshot
- `submenu_icon_*` / `submenu_name_*` come from the same snapshot, so they need the bump too

### SwiftUI Views Not Updating
- Ensure `@MainActor` annotation when updating `@Published` properties
- Use `@StateObject` instead of `@ObservedObject` for view-owned objects
- Remember `AppState.shared` is a singleton - use `@StateObject` appropriately

## Documentation References

- **Feature Specifications**: [specs/001-macos-app-macos/](specs/001-macos-app-macos/)
- **Development Guidelines**: [QWEN.md](QWEN.md)
- **Communication Protocol**: [specs/001-macos-app-macos/contracts/app-extension-communication.md](specs/001-macos-app-macos/contracts/app-extension-communication.md)
- **Data Model**: [specs/001-macos-app-macos/data-model.md](specs/001-macos-app-macos/data-model.md)
