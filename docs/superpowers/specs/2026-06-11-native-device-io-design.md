# Native Device I/O — Export, Gallery Picker, File Import — Design Spec

**Date:** 2026-06-11
**Stream:** C (third of four — Android bug batch)
**Bugs addressed:** #4 (export fails: "no data"/"Export failed" on Android), #5 (gallery photo picker broken on Android; import has no native file picker; remove desktop-only URL/path entry)
**Platform:** Felgo + Qt 6.8.3, QML + C++. Target = mobile (Android primary; iOS shares the same code paths). Desktop must keep working.

---

## 1. Problem & Goal

Three native-I/O failures on Android, all confirmed by reading the code:

- **#4 Export** — `XlsxService::outputDir()` writes to `QStandardPaths::DownloadLocation` (public
  `/Download`). Android 10+ **scoped storage** forbids direct writes there, so `doc.saveAs(path)`
  returns false → `write*()` returns `""` → QML shows "Export failed." The user confirmed data IS
  visible on-screen, so this is a **write-location** failure, not empty data.
- **#5a Gallery** — `displayImagePicker` returns a **`content://` URI**;
  `ImageProcessor::compressForUpload` does `QFile::exists()` on that string and bails with
  "Source file not found." Content URIs are not filesystem paths.
- **#5b Import** — there is no native picker today; `importPathPrompt` is a **type-a-file-path**
  text dialog (desktop-era).
- **#5c** — remove the desktop-only "paste URL" row (PhotoSourceSheet) and the type-a-path import
  dialog.

**Goal:** export always succeeds and hands off via the system share sheet; the gallery picker and a
real system file picker work on Android/iOS; URL/path text entry is removed. Use **app-private
storage + share + system pickers** so NO broad storage permission is needed. Desktop keeps working.

**Non-goals:** Firebase Storage upload (still stubbed/local); multi-file import; cloud export.

---

## 2. Confirmed APIs (verified in the local Felgo install + source)

- `NativeUtils.displayImagePicker(title)` → signal `imagePickerFinished(bool accepted, string path)`.
- `NativeUtils.displayCameraPicker()` → signal `cameraPickerFinished(bool accepted, string path)`.
- `NativeUtils.displayFilePicker(title, path, filter, …)` → signal
  `filePickerFinished(bool accepted, QStringList files)`.
- `NativeUtils.share(text, url)` — system share sheet (routes via the manifest's
  `${applicationId}.fileprovider`, already declared).
- C++ services are registered as context properties in `main.cpp` (`OAuthServer`, `ImageProcessor`,
  `XlsxService`) — `NativeFile` will follow the same pattern.

---

## 3. Architecture — one shared content-URI helper

A new small C++ class isolates ALL `content://` handling in one tested place:

```cpp
// src/NativeFile.h / .cpp — registered as context property "NativeFile" in main.cpp
class NativeFile final : public QObject {
    Q_OBJECT
    Q_DISABLE_COPY_MOVE(NativeFile)
public:
    explicit NativeFile(QObject *parent = nullptr);
    // Copy any URI (content://, file://, plain path) into the app cache and
    // return a readable local file path (empty on failure). For already-local
    // sources this is effectively a passthrough/normalize.
    Q_INVOKABLE QString toReadablePath(const QUrl &uri);
};
```

Implementation: if the URI is already a local file, return its local path. Otherwise open it with
`QFile`/`QIODevice` (Qt's Android backend resolves `content://` via the ContentResolver), copy bytes
to `QStandardPaths::CacheLocation/import_<timestamp>.<ext>`, return that path. Empty string on
failure.

**Why a shared helper:** both the gallery photo (#5a) and the import file (#5b) need the exact same
"resolve any URI to a readable file" step. One helper keeps `ImageProcessor` and `XlsxService` pure
(they keep receiving real file paths) and gives one place to get content-URI handling right.

---

## 4. Fixes

### 4a. #4 Export → app-private storage + share

`XlsxService::outputDir()` changes from `DownloadLocation` to `QStandardPaths::AppDataLocation`
(fallback `AppLocalDataLocation`) — always writable, no permission, all Android versions + desktop.
The existing `NativeUtils.share("", url)` calls in `Main.qml` (`_exportProducts/_exportOrders/
_exportStaff` + analysis) carry the file out of the sandbox via the declared `FileProvider`. Update
the success copy from "Saved to Downloads" to "Exported — choose where to save" (accurate to the new
flow). On desktop, share may be unavailable — keep the existing `typeof NativeUtils.share` guard; the
file still lands in AppDataLocation and the toast reports the path.

### 4b. #5a Gallery photo → resolve URI before compress

In `StorageService.uploadProductPhoto(productId, sourceUrl, cb)`, resolve the source first:
`var readable = NativeFile.toReadablePath(sourceUrl)`; if empty → `cb(false, "", "Could not read
selected image")`; else pass `readable` into `ImageProcessor.compressForUpload(readable, …)`.
`ImageProcessor` is unchanged (still receives a real path). Camera path benefits too (its result may
also be a content URI on some devices).

### 4c. #5b Import → native file picker

Replace the `importPathPrompt` text dialog with a native picker. `ImportPreviewDialog.pickAndStart()`
triggers `NativeUtils.displayFilePicker(qsTr("Choose a spreadsheet"), "", "*/*")`. A `Connections`
target on `NativeUtils` handles `filePickerFinished(accepted, files)`: on accept, take `files[0]`,
run it through `NativeFile.toReadablePath(...)`, then the existing
`importDlg.importFromUserPath(localPath)` → `XlsxService.readWorkbook(...)` pipeline (unchanged).
The picker connection lives in `Main.qml` (where importDlg is hosted) to match the existing
import wiring, replacing the `onPathPromptRequested` hookup.

### 4d. #5c Remove desktop affordances

- `PhotoSourceSheet.qml` — delete the "Use an image URL or path" row (the `urlField` + "Use" button
  block) and its handlers. Keep camera + gallery + remove.
- `Main.qml` — delete the `importPathPrompt` `QQC.Dialog` and the `onPathPromptRequested:
  importPathPrompt.open()` hookup.
- `ImportPreviewDialog.qml` — drop the `pathPromptRequested` signal and the `importFromUserPath`
  path-typing entry point is replaced by the picker result; keep `importFromUserPath(localPath)` as
  the load entry (now fed by the picker, not a text box).

---

## 5. Permissions & manifest

Design avoids broad storage permission by construction:
- **Gallery:** `displayImagePicker` uses the Android Photo Picker (no runtime permission on Android
  13+); Felgo handles older-device media permission. Verify Felgo auto-inserts `READ_MEDIA_IMAGES`
  from `displayImagePicker` usage; if the device shows no images, add `READ_MEDIA_IMAGES` explicitly
  to the manifest.
- **Export/share:** AppDataLocation write + `FileProvider` share need no permission.
- **Import:** `displayFilePicker` uses the system document picker — no storage permission.

The manifest's `%%INSERT_PERMISSIONS` placeholder is populated by Felgo from API usage; the plan
verifies the resulting permission set on-device and adds `READ_MEDIA_IMAGES` only if gallery access
fails.

---

## 6. Files touched

**Created:**
- `src/NativeFile.h`, `src/NativeFile.cpp` — content-URI → readable-path helper.

**Modified:**
- `main.cpp` — register `NativeFile` as a context property (same pattern as `ImageProcessor`/
  `XlsxService`).
- `CMakeLists.txt` — add `src/NativeFile.h src/NativeFile.cpp` to `qt_add_executable` (the `src/*`
  files are listed explicitly there, not globbed).
- `src/XlsxService.cpp` — `outputDir()` → AppDataLocation.
- `qml/model/StorageService.qml` — resolve source via `NativeFile.toReadablePath` before compress.
- `qml/components/PhotoSourceSheet.qml` — remove the URL row.
- `qml/pages/ImportPreviewDialog.qml` — drop `pathPromptRequested`; picker feeds `importFromUserPath`.
- `qml/Main.qml` — native file picker `Connections`; remove `importPathPrompt` dialog + hookup;
  update export success copy.

**Verified, not modified:** `ImageProcessor.cpp` core (keeps receiving a real path); QXlsx; the
`FileProvider` manifest entry (already present).

---

## 7. Verification

1. **`qmllint`** on changed QML — no new hard `Error:` lines.
2. **C++ build** — `NativeFile` compiles + registers; app launches with the context property.
3. **Desktop run (regression):** export writes a valid `.xlsx` to AppDataLocation that opens in
   Excel with all rows; removing the photo URL row + import path dialog doesn't break the photo/
   import flows on desktop (file picker / image picker work or degrade gracefully).
4. **Android device (the real proof):**
   - **Export:** products / orders / staff / analysis each export → share sheet appears → saved file
     opens with all rows. No "Export failed."
   - **Gallery:** Add/Edit product → Choose from gallery → pick image → compresses, persists, shows
     as the product photo (no "Source file not found").
   - **Camera:** still works (content-URI helper didn't regress it).
   - **Import:** Inventory/Orders → Import → system file picker → pick `.xlsx` → preview loads → apply.
   - **Removed affordances:** no "paste URL" row; no type-a-path dialog.

Desktop CANNOT reproduce the scoped-storage or content-URI behavior — Android device test is
mandatory and only the user can run it.

---

## 8. Build sequence (preview — full plan via writing-plans)

1. `NativeFile` C++ class + register in main.cpp + CMake sources; build.
2. `XlsxService::outputDir()` → AppDataLocation; desktop export regression.
3. `StorageService` resolves photo source via `NativeFile`; (camera/gallery unchanged otherwise).
4. Import native file picker in Main.qml + `ImportPreviewDialog` wiring; remove path prompt.
5. Remove PhotoSourceSheet URL row; update export success copy.
6. Android device pass (§7.4); add `READ_MEDIA_IMAGES` only if gallery fails.
