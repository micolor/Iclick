# Contract: IClick App-Extension Communication Protocol

> **SUPERSEDED.** The DistributedNotificationCenter protocol described below is no longer
> implemented. It is kept as historical context only.
>
> The current design has two one-way channels:
>
> 1. **Extension → App (actions)**: a Unix domain socket at
>    `~/Library/Group Containers/group.33WRMMC62L.cn.anwen.IClick/ipc.sock`, owned by the
>    main app. The app reads `LOCAL_PEERPID`, then uses
>    `SecCodeCopyGuestWithAttributes` + `SecCodeCopySigningInformation` to require the peer's
>    signing identifier to be `cn.anwen.IClick.FinderSyncExt` and its Team ID to be
>    `33WRMMC62L`. Every action carries a `messageID`; the app acks before executing and
>    dedupes repeats. See `IClick/Shared/LocalIPC.swift`.
> 2. **App → Extension (configuration)**: no notification channel. The app writes
>    `SharedSettings-snapshot.plist` into the App Group container and increments
>    `ICLICK_CONFIG_VERSION`. The extension compares the snapshot's version each time it
>    builds a menu and reloads on change. See `SharedSettings.snapshotDictionary()` /
>    `FinderSyncExt.syncFromSnapshotIfNewer()`.
>
> `MessagePayload` in `IClick/Shared/Messager.swift` remains the shared Codable shape for
> action messages.

## Overview (historical)
This document defines the communication protocol between the IClick main application and its FinderSync extension using DistributedNotificationCenter.

## Communication Channels (historical)

### Channel: "IClick.MessageFromFinder"
- **Direction**: Extension → Main App
- **Purpose**: Messages sent from the Finder extension to the main application
- **Payload Structure**:
  ```json
  {
    "action": "string",
    "target": ["string"],
    "trigger": "string"
  }
  ```
- **Actions**:
  - "open": Open a file/folder with an external application
  - "actioning": Perform a context menu action (copy path, delete, etc.)
  - "Create File": Create a new file of a specific type
  - "common-dirs": Open a common directory
  - "heartbeat": Check if extension is running

### Channel: "IClick.MessageFromApp"
- **Direction**: Main App → Extension  
- **Purpose**: Messages sent from the main application to the extension
- **Payload Structure**:
  ```json
  {
    "action": "string", 
    "target": ["string"],
    "data": "object"
  }
  ```
- **Actions**:
  - "update-menu": Update available context menu options
  - "config-changed": Notify extension of configuration changes
  - "running": Report active directories the extension should monitor

## Message Schema

### MessagePayload
- **action**: String (required) - The type of action to perform
- **target**: Array of Strings (required) - Paths or identifiers the action applies to
- **trigger**: String (optional) - Context of how the action was triggered (e.g., "ctx-container", "ctx-items")
- **data**: Object (optional) - Additional payload data for the action

## Error Handling
- Invalid message formats should be logged but ignored
- Unknown actions should be logged as warnings
- Communication timeouts should be handled gracefully with fallback behavior

## Security Considerations
- Messages should be validated before processing
- File paths should be checked for security (e.g., no traversal outside allowed directories)
- User permissions should be verified before performing file operations

## Versioning
- This contract version: 1.0.0
- Backward compatibility should be maintained for minor version changes
- Major version changes may introduce breaking changes that require both app and extension updates