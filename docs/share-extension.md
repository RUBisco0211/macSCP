# Finder Share Extension (preview)

## Workflow

Select one or more files/folders in Finder → **Share → MacSCP**. The extension prepares a private temporary copy, opens the containing MacSCP app, and presents a connection picker using the existing `ConnectionRowView`. Choose a connection, authenticate as usual, browse the remote destination, and click **Upload to This Folder**. Both steps show the selected files and folders. Clicking the upload button starts immediately, with no second confirmation dialog.

The normal remote browser, breadcrumb navigation, transfer popover, cancellation controls and authentication are reused. SFTP and S3 connections are supported; the app does not run the `scp` command.

## Build and enable

1. Open `macSCP.xcodeproj`. Set the **same development team** for `macSCP` and `MacSCPShareExtension` (or pass `DEVELOPMENT_TEAM=YOUR_TEAM_ID` to `xcodebuild`).
2. Both targets use the build setting `SHARE_APP_GROUP_IDENTIFIER`, defaulting to `$(DEVELOPMENT_TEAM).com.macscp.macSCP.shared`. Keep the entitlement and the expanded `ShareAppGroupIdentifier` Info.plist value identical in both targets. The main app remains non-sandboxed; the extension is sandboxed and has user-selected read access only, not network or Keychain access.
3. Build/run the **macSCP** scheme. Its build dependency embeds `MacSCPShareExtension.appex` in `macSCP.app/Contents/PlugIns`.
4. If MacSCP is missing from Finder's share menu, enable it in System Settings → General → Login Items & Extensions → Sharing (the location/name varies by macOS version), or Finder's sharing-menu customization panel. Launch the built app once. Avoid keeping several installed copies enabled simultaneously.

Example local build:

```sh
xcodebuild -project macSCP.xcodeproj -scheme macSCP \
  -configuration Debug -derivedDataPath .build/DerivedData \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID build
open .build/DerivedData/Build/Products/Debug/macSCP.app
```

A build with `CODE_SIGNING_ALLOWED=NO` can check compilation, but is **not** a valid Finder-extension smoke test. The existing unsigned DMG/release workflow is not proof of a working extension; release distribution must sign the app and embedded extension with the same appropriate identity and validate the shared-container entitlement. This preview does not change release publishing or create a PR.

## File and transfer semantics

- Between 1 and 1,000 selected top-level items; files and directories may be mixed.
- A selected directory `Photos` becomes `destination/Photos`, preserving hidden files and empty directories. Directory enumeration is not controlled by the remote browser's hidden-file toggle.
- Symbolic links and special files are rejected rather than followed. Duplicate top-level names in a selection are rejected rather than silently colliding.
- Existing directories merge. File/directory type conflicts fail. An inline notice above the upload controls warns that matching files are overwritten; failed/cancelled uploads are not transactional and can leave partial content. Existing SFTP replacement does not preserve the old file on failure.
- Destination is captured when the upload button is clicked; later navigation does not move the remainder of the batch.
- Each selected top-level file/directory has one transfer row. Directory progress aggregates its file bytes. Preparation has an indeterminate indicator and cancellation.
- Cancel All stops the remainder of the batch; individual cancellation stops that top-level item. Cancellation waits for active I/O and cleanup and is not necessarily instantaneous.
- Successful batches remove their staged sources. Failed/cancelled attempts retain sources for retry in the same window. Retrying the whole batch may overwrite items that already succeeded; the inline overwrite notice remains visible.
- Cancel or closing the share window stops readers before deleting temporary data. Closing while transfers run asks for confirmation. Transfers do not continue after the window closes; app termination/crash does not provide resumable uploads.

## Cross-process handoff

The extension has no connection database, password, secret key or SSH session. It reads Finder's `public.file-url` providers, retains access while copying in the background, and writes a versioned manifest plus payload to the App Group's `ShareRequests` directory. Requests are atomically published using a UUID directory; the URL `macscp://share/<uuid>` contains only that ID, never credentials or an external file path. `NSWorkspace` explicitly opens the containing app bundle, not an arbitrary installed URL handler.

The app validates the URL and manifest and deduplicates requests in-process. Connection selection preserves App Lock, biometric checks and existing credential prompts. Share requests are never auto-uploaded on launch or restoration.

This preview stages file contents rather than relying on transferable security-scoped bookmarks. This costs temporary disk space approximately equal to the selected contents and can take time for large or cloud-backed folders. Resource forks, Finder tags and other extended metadata are not uploaded. Keep enough free space. Temporary requests older than seven days are reclaimed at app startup, including interrupted preparations; successful completion, explicit cancellation and closing normally clean up immediately.

## Validation checklist

Automated tests cover staged-copy publication and cleanup, malformed/path-escaping manifests, strict URL parsing, recursive upload plans, hidden/empty directories, symbolic links, conflicts, fixed destinations, aggregation, cancellation, connection teardown and failed-batch results.

Before release, manually validate on macOS 15 and a current macOS:

- Finder single file, multi-file, folder, empty folder, mixed selection and Unicode names.
- App cold start, already running, locked, repeated URL and two separate share requests.
- Password/private-key SFTP and S3, missing credentials and authentication cancellation.
- Destination navigation during transfer, nested merges, overwrite/type conflicts and permissions.
- Preparing cancellation, current-item cancellation, Cancel All, retry, close while connecting/uploading and temporary-file cleanup.
- Large and cloud-backed sources, insufficient disk space, network interruption and app termination.
- Signed Release archive/DMG: embedded extension, entitlement agreement, Finder discovery and cold-start handoff on a clean machine.
