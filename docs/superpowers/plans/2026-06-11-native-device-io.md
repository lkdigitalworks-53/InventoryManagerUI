# Native Device I/O (Export, Gallery, Import) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make export, gallery photo pick, and file import work on Android/iOS by writing exports to app-private storage + sharing them, resolving `content://` URIs through one shared C++ helper, and using the native system file picker — removing the desktop-era URL/path text entry.

**Architecture:** A new `NativeFile` C++ class exposes `toReadablePath(uri)` that copies any `content://`/`file://`/path source into the app cache and returns a local file path. `StorageService` (photo) and the import flow both route picked URIs through it, so `ImageProcessor`/`XlsxService` keep receiving real file paths. `XlsxService::outputDir()` moves from public Downloads to `AppDataLocation`; the existing `NativeUtils.share` hands the file out via the declared `FileProvider`.

**Tech Stack:** Felgo + Qt 6.8.3, QML + C++. Verified APIs: `NativeUtils.displayFilePicker(title,…)` → `filePickerFinished(bool, QStringList)`; `displayImagePicker(title)` → `imagePickerFinished(bool, string)`; `share(text, url)`. C++ services registered as context properties in `main.cpp`.

**Spec:** `docs/superpowers/specs/2026-06-11-native-device-io-design.md`

---

## Verification model (read first)

No QML unit-test harness; this is native device behavior. "Tests" are concrete runnable checks:

1. **`qmllint`** on changed QML — no new hard `Error:` lines. Binary:
   `"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml <file>` (filter `grep -E '^Error:'`).
2. **C++ build** — the desktop build compiles with `NativeFile` and the app launches.
3. **Desktop run (regression):** export writes a valid `.xlsx` (now in AppDataLocation) that opens in
   Excel; photo + import flows still work (or degrade gracefully where a native picker is desktop-stubbed).
4. **Android device (the real proof, Task 7):** export → share sheet → file opens with rows; gallery
   pick → photo shows; camera still works; import → system picker → preview → apply; no URL/path UI.

Desktop CANNOT reproduce scoped-storage or content-URI behavior — the Android pass (Task 7) is
mandatory and only the user can run it.

---

## File Structure

**Created:**
- `src/NativeFile.h`, `src/NativeFile.cpp` — content-URI → readable-local-path helper.

**Modified:**
- `CMakeLists.txt` — add the two `NativeFile` sources to `qt_add_executable`.
- `main.cpp` — register `NativeFile` context property.
- `src/XlsxService.cpp` — `outputDir()` → `AppDataLocation`.
- `qml/model/StorageService.qml` — resolve photo source via `NativeFile.toReadablePath` before compress.
- `qml/components/PhotoSourceSheet.qml` — remove the URL row + the gallery desktop URL fallback.
- `qml/pages/ImportPreviewDialog.qml` — drop `pathPromptRequested`; keep `importFromUserPath` as the picker-fed load entry.
- `qml/Main.qml` — native file-picker `Connections`; delete `importPathPrompt` dialog + hookup; remove `importPathPrompt` from the back-router `dialogs` array; update export success copy.

---

### Task 1: `NativeFile` C++ helper (content-URI → readable path)

**Files:**
- Create: `src/NativeFile.h`, `src/NativeFile.cpp`
- Modify: `CMakeLists.txt`, `main.cpp`

- [ ] **Step 1: Create the header**

Create `src/NativeFile.h`:

```cpp
#pragma once

#include <QObject>
#include <QString>
#include <QUrl>

// NativeFile — resolves any picked source (Android content:// URI, file:// URL,
// or plain path) to a readable local filesystem path by copying it into the app
// cache when necessary. Lets ImageProcessor / XlsxService keep operating on real
// file paths instead of content URIs (which they cannot stat or open directly).
class NativeFile final : public QObject
{
    Q_OBJECT
    Q_DISABLE_COPY_MOVE(NativeFile)

public:
    explicit NativeFile(QObject *parent = nullptr);
    ~NativeFile() override = default;

    // Return a readable local file path for `uri`. For an already-local source
    // this returns its local path unchanged. For a content:// (or other
    // non-local) source it copies the bytes into the app cache and returns that
    // path. Returns an empty string on failure.
    Q_INVOKABLE QString toReadablePath(const QUrl &uri);

private:
    static QString cacheDir();
};
```

- [ ] **Step 2: Create the implementation**

Create `src/NativeFile.cpp`:

```cpp
#include "NativeFile.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QStandardPaths>

NativeFile::NativeFile(QObject *parent)
    : QObject(parent)
{
}

QString NativeFile::cacheDir()
{
    const QString base = QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
    QDir().mkpath(base);
    return base;
}

QString NativeFile::toReadablePath(const QUrl &uri)
{
    // Already a local file (file:// URL or a path that parsed as local) → use as-is.
    if (uri.isLocalFile()) {
        const QString local = uri.toLocalFile();
        return QFile::exists(local) ? local : QString();
    }

    const QString asString = uri.toString();

    // A bare filesystem path (no scheme) arrives as a relative QUrl — treat as local.
    if (uri.scheme().isEmpty()) {
        return QFile::exists(asString) ? asString : QString();
    }

    // content:// (Android) and any other non-local scheme Qt can open: copy the
    // bytes into the cache. Qt's Android backend maps content:// through the
    // ContentResolver, so QFile can read it directly.
    QFile in(asString);
    if (!in.open(QIODevice::ReadOnly))
        return {};

    // Preserve a sensible extension so downstream readers (image / xlsx) sniff
    // the type correctly. Fall back to .bin when none is present.
    QString suffix = QFileInfo(uri.path()).suffix();
    if (suffix.isEmpty())
        suffix = QStringLiteral("bin");

    const QString outPath = QStringLiteral("%1/picked_%2.%3")
        .arg(cacheDir())
        .arg(QString::number(QDateTime::currentMSecsSinceEpoch()))
        .arg(suffix);

    QFile out(outPath);
    if (!out.open(QIODevice::WriteOnly)) {
        in.close();
        return {};
    }

    // Stream-copy in chunks so large files don't spike memory.
    constexpr qint64 kChunk = 64 * 1024;
    while (!in.atEnd()) {
        const QByteArray buf = in.read(kChunk);
        if (buf.isEmpty()) break;
        if (out.write(buf) != buf.size()) {
            in.close();
            out.close();
            QFile::remove(outPath);
            return {};
        }
    }
    in.close();
    out.close();
    return outPath;
}
```

- [ ] **Step 3: Add the sources to CMakeLists.txt**

In `CMakeLists.txt`, the `qt_add_executable(appBusinessManagement ...)` block lists `src/*` files
explicitly. After the `src/XlsxService.cpp` line, add the two NativeFile lines so the block includes:

```cmake
    src/XlsxService.h
    src/XlsxService.cpp
    src/NativeFile.h
    src/NativeFile.cpp
```

- [ ] **Step 4: Register the context property in main.cpp**

In `main.cpp`, add the include near the other `src/` includes (after `#include "src/XlsxService.h"`):

```cpp
#include "src/NativeFile.h"
```

Then, after the `xlsxService` registration block (the three lines ending with
`setContextProperty(QStringLiteral("XlsxService"), xlsxService);`), add:

```cpp
    // Register the content-URI → readable-path helper (photo + import pickers).
    auto *nativeFile = new NativeFile(&app);
    engine.rootContext()->setContextProperty(QStringLiteral("NativeFile"), nativeFile);
```

- [ ] **Step 5: Build (desktop) to confirm it compiles + registers**

Build the desktop target via the project's configured build task. Expected: compiles with no errors;
app launches. (The property isn't consumed yet — this step only proves the class builds and registers.)

- [ ] **Step 6: Commit**

```bash
git add src/NativeFile.h src/NativeFile.cpp CMakeLists.txt main.cpp
git commit -m "feat(io): add NativeFile content-URI to readable-path helper"
```

---

### Task 2: Export to app-private storage

**Files:**
- Modify: `src/XlsxService.cpp`

- [ ] **Step 1: Change outputDir() to AppDataLocation**

In `src/XlsxService.cpp`, replace the body of `XlsxService::outputDir()` (currently uses
`QStandardPaths::DownloadLocation`) with:

```cpp
QString XlsxService::outputDir()
{
    // App-private storage: always writable with no permission on every Android
    // version (public Downloads is blocked by scoped storage on API 29+). The
    // file leaves the sandbox via NativeUtils.share() + the declared FileProvider.
    QString base = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    if (base.isEmpty())
        base = QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation);
    QDir().mkpath(base);
    return base;
}
```

(`QDir` and `QStandardPaths` are already included in XlsxService.cpp.)

- [ ] **Step 2: Build + desktop export regression**

Build + run desktop. Trigger an export (e.g. Inventory → Export → Excel). Expected: a toast reporting
success and a real `.xlsx` written under the app data dir that opens in Excel with all rows. (The
share call is guarded by `typeof NativeUtils.share` and is a no-op on desktop — that's fine.)

- [ ] **Step 3: Commit**

```bash
git add src/XlsxService.cpp
git commit -m "fix(io): export to app-private AppDataLocation (scoped-storage safe)"
```

---

### Task 3: Update export success copy (Main.qml)

**Files:**
- Modify: `qml/Main.qml`

The four exporters say "Saved to Downloads", which is no longer where the file lands. Update the copy
to describe the share-based flow.

- [ ] **Step 1: Products / Orders / Staff copy**

In `qml/Main.qml`, in `_exportProducts()` change `"Products exported. Saved to Downloads."` to
`"Products exported — choose where to save."`. In `_exportOrders()` change
`"Orders exported. Saved to Downloads."` to `"Orders exported — choose where to save."`. In
`_exportStaff()` change `"Staff exported. Saved to Downloads."` to
`"Staff exported — choose where to save."`.

- [ ] **Step 2: Analysis copy**

In `_exportSalesReport()` change
`qsTr("%1 exported. Saved to Downloads.").arg(payload.title || qsTr("Analysis"))` to
`qsTr("%1 exported — choose where to save.").arg(payload.title || qsTr("Analysis"))`.

- [ ] **Step 3: qmllint + commit**

Run: `"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml qml/Main.qml 2>&1 | grep -E '^Error:' || echo CLEAN`
Expected: CLEAN.
```bash
git add qml/Main.qml
git commit -m "fix(io): export success copy reflects share-based flow"
```

---

### Task 4: Gallery photo — resolve URI before compress

**Files:**
- Modify: `qml/model/StorageService.qml`

- [ ] **Step 1: Resolve the source through NativeFile**

In `qml/model/StorageService.qml`, in `uploadProductPhoto(productId, sourceUrl, callback)`, after the
existing empty-source guard (the block that callbacks `"Missing source"`) and BEFORE the
`var compressedUrl = ImageProcessor.compressForUpload(sourceUrl, 800, 75)` line, insert:

```qml
        // Picked images on Android arrive as content:// URIs that ImageProcessor
        // can't stat. Resolve to a readable local path first (passthrough for
        // already-local sources).
        var readable = NativeFile.toReadablePath(sourceUrl)
        if (!readable || readable.length === 0) {
            if (callback) callback(false, "", "Could not read the selected image")
            return
        }
```

Then change the compress line to use `readable`:

```qml
        var compressedUrl = ImageProcessor.compressForUpload(readable, 800, 75)
```

`NativeFile` resolves as a context property (no import needed — same as `ImageProcessor`/`XlsxService`
already used in this file). `compressForUpload` accepts a `QUrl`; a plain path string converts
implicitly, but to be explicit the engineer may wrap as `Qt.resolvedUrl` is NOT needed — pass the
string; Qt coerces the path to a local-file QUrl. (Verified: `ImageProcessor.compressForUpload`
already handles `source.isLocalFile()` false by treating the string as a path.)

- [ ] **Step 2: qmllint**

Run: `"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml qml/model/StorageService.qml 2>&1 | grep -E '^Error:' || echo CLEAN`
Expected: CLEAN.

- [ ] **Step 3: Commit**

```bash
git add qml/model/StorageService.qml
git commit -m "fix(io): resolve picked photo URI via NativeFile before compress"
```

---

### Task 5: Native file picker for import (Main.qml + ImportPreviewDialog)

**Files:**
- Modify: `qml/Main.qml`, `qml/pages/ImportPreviewDialog.qml`

Context: `importDlg.pickAndStart()` is called from OrdersPage/InventoryPage. Today it emits
`pathPromptRequested` → `importPathPrompt.open()` (a type-a-path dialog). Replace with the native
system file picker. `importFromUserPath(localPath)` STAYS (it opens the sheet + loads the file); it
will now be fed by the picker result.

- [ ] **Step 1: ImportPreviewDialog — pickAndStart triggers the native picker via a signal**

In `qml/pages/ImportPreviewDialog.qml`:

(a) Keep the `signal pathPromptRequested()` line REPLACED by a clearer name — change it to:
```qml
    signal filePickRequested()
```

(b) In `function pickAndStart()`, change the body from `pathPromptRequested()` to:
```qml
    function pickAndStart() {
        _readyRows = []; _issueRows = []; _fileName = ""
        filePickRequested()
    }
```

(c) Leave `importFromUserPath(rawPath)`, `_toFileUrl`, `_loadFile`, and everything else unchanged.

- [ ] **Step 2: Main.qml — drive the native picker, route the result**

In `qml/Main.qml`:

(a) Change the `importDlg` hookup from `onPathPromptRequested: importPathPrompt.open()` to:
```qml
        onFilePickRequested: {
            NativeUtils.filePickerFinished.connect(app._onImportFilePicked)
            NativeUtils.displayFilePicker(qsTr("Choose a spreadsheet"), "", "*/*")
        }
```

(b) Add the result handler as a function on the root App (place it next to the other import-related
code, e.g. just after the `importDlg { ... }` block). It disconnects itself so the one-shot connection
doesn't stack across repeated imports:
```qml
    function _onImportFilePicked(accepted, files) {
        NativeUtils.filePickerFinished.disconnect(app._onImportFilePicked)
        if (!accepted || !files || files.length === 0) return
        var local = NativeFile.toReadablePath(files[0])
        if (!local || local.length === 0) {
            successMessage = qsTr("Could not read the selected file")
            successToastTimer.restart()
            return
        }
        importDlg.importFromUserPath(local)
    }
```

(c) DELETE the entire `importPathPrompt` `QQC.Dialog { ... }` block (the dialog with `id:
importPathPrompt`, its `importPathField`, `onAccepted`/`onRejected`) and its explanatory comment
("Path-prompt is hoisted out of ImportPreviewDialog…").

- [ ] **Step 3: CRITICAL — remove `importPathPrompt` from the back-router dialogs array**

The Stream-A hardware-Back router in `Main.qml` has a `dialogs` array that lists `importPathPrompt`.
With the dialog deleted, that reference becomes a ReferenceError the moment Back is pressed. In the
`_handleBack()` function, remove `importPathPrompt,` from the `dialogs` array. The array's first line
currently reads:
```qml
        var dialogs = [photoSourceSheet, importPathPrompt, addProductDlg, editProductDlg,
```
Change it to:
```qml
        var dialogs = [photoSourceSheet, addProductDlg, editProductDlg,
```

- [ ] **Step 4: qmllint Main.qml + ImportPreviewDialog**

Run for each:
`"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml <file> 2>&1 | grep -E '^Error:' || echo CLEAN`
Expected: CLEAN for both. Also grep to confirm no stale references remain:
```bash
grep -n 'importPathPrompt\|pathPromptRequested' qml/Main.qml qml/pages/ImportPreviewDialog.qml || echo "(no stale refs)"
```
Expected: `(no stale refs)`.

- [ ] **Step 5: Commit**

```bash
git add qml/Main.qml qml/pages/ImportPreviewDialog.qml
git commit -m "feat(io): native file picker for import; drop type-a-path dialog"
```

---

### Task 6: Remove the desktop URL affordances from PhotoSourceSheet

**Files:**
- Modify: `qml/components/PhotoSourceSheet.qml`

- [ ] **Step 1: Remove the gallery desktop URL fallback**

In `qml/components/PhotoSourceSheet.qml`, the gallery `MouseArea.onClicked` has an `else` branch that
focuses `urlField`. Simplify it so it always uses the native picker:

Replace:
```qml
                onClicked: {
                    if (typeof NativeUtils !== "undefined" && NativeUtils.displayImagePicker) {
                        NativeUtils.imagePickerFinished.connect(root._onGalleryDone)
                        NativeUtils.displayImagePicker()
                        root.close()
                    } else {
                        urlField.placeholderText = "Paste a file:// path or http URL…"
                        urlField.forceActiveFocus()
                    }
                }
```
with:
```qml
                onClicked: {
                    if (typeof NativeUtils !== "undefined" && NativeUtils.displayImagePicker) {
                        NativeUtils.imagePickerFinished.connect(root._onGalleryDone)
                        NativeUtils.displayImagePicker(qsTr("Choose a photo"))
                        root.close()
                    }
                }
```

- [ ] **Step 2: Delete the "Paste URL" row**

Remove the entire `// Paste URL` `Rectangle { ... }` block (the one containing `id: urlCol`,
`id: urlField`, and the "Use" `QQC.Button`). It sits between the Gallery row and the Remove row. After
removal, the sheet's column is: handle → label → Camera → Gallery → Remove → trailing spacer.

- [ ] **Step 3: qmllint — confirm no dangling urlField references**

Run:
`"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml qml/components/PhotoSourceSheet.qml 2>&1 | grep -E '^Error:' || echo CLEAN`
Expected: CLEAN.
```bash
grep -n 'urlField\|urlCol' qml/components/PhotoSourceSheet.qml || echo "(no stale refs)"
```
Expected: `(no stale refs)` — confirms Step 1's fallback removal eliminated the last `urlField` use.

- [ ] **Step 4: Desktop sanity**

Build/run desktop. Open Add product → photo sheet shows Camera / Gallery (/ Remove) only — no URL row.
(On desktop the native pickers may be stubbed; the point of this step is that the sheet renders and
doesn't error from a removed id.)

- [ ] **Step 5: Commit**

```bash
git add qml/components/PhotoSourceSheet.qml
git commit -m "fix(io): remove desktop paste-URL affordance from photo sheet"
```

---

### Task 7: Android device verification (the real proof)

**Files:** none (device test); fixes fold back into Tasks 1–6.

- [ ] **Step 1: Clean Android rebuild + deploy**

Clean the Android build dir (Qt Creator → Build → Clean), then Rebuild + deploy. Expected: build +
deploy succeed (the new C++ `NativeFile` is compiled into the APK).

- [ ] **Step 2: Export pass**

On the device, export each kind: Inventory (products), Orders, Staff, and Analysis (Sales → Export).
For each: the success toast appears AND the Android share sheet opens; save to Drive/Files and confirm
the `.xlsx` opens with all rows. Expected: no "Export failed".

- [ ] **Step 3: Gallery + camera pass**

Add product → "Choose from gallery" → pick an image → it appears as the product photo (no "Source file
not found" / "Could not read the selected image"). Repeat "Take photo" with the camera → photo appears.
Edit an existing product's photo the same way.

- [ ] **Step 4: Import pass**

Inventory → Import → the system file picker opens → choose a previously-exported products `.xlsx` →
the preview sheet loads the rows → Import applies them. Repeat for Orders.

- [ ] **Step 5: Removed-affordance + permission check**

Confirm the photo sheet shows no "paste URL" row and import shows no type-a-path dialog. If the gallery
picker shows NO images (older Android), add `<uses-permission android:name="android.permission.READ_MEDIA_IMAGES"/>`
to the Android manifest (or the Felgo permissions mechanism) and re-test. Otherwise no permission change.

- [ ] **Step 6: Final commit (if device fixes were needed)**

```bash
git add -A
git commit -m "fix(io): device-verification adjustments for native I/O"
```
If no changes were needed, skip.

---

## Self-Review Notes

- **Spec coverage:**
  - §3 NativeFile helper → Task 1.
  - §4a export → AppDataLocation → Task 2; success copy → Task 3.
  - §4b gallery resolve-before-compress → Task 4.
  - §4c import native picker → Task 5.
  - §4d remove URL row + path dialog → Task 5 (path dialog) + Task 6 (URL row).
  - §5 permissions → Task 7 Step 5 (conditional READ_MEDIA_IMAGES).
  - §7 verification → each task's qmllint/build/desktop steps + Task 7 device pass.
- **Cross-cutting catch:** deleting `importPathPrompt` (Task 5 Step 2c) requires removing it from the
  Stream-A back-router `dialogs` array (Task 5 Step 3) or hardware Back throws a ReferenceError. Both
  are in the same task so they land together.
- **Placeholder scan:** none. Every code block is concrete; the only conditional is Task 7 Step 5's
  documented permission fallback (a real branch with a specific action).
- **Type/name consistency:** `NativeFile.toReadablePath(uri)` defined in Task 1 is called identically
  in Task 4 (photo) and Task 5 (import). `filePickRequested` (renamed from `pathPromptRequested`) is
  declared in ImportPreviewDialog (Task 5 Step 1) and consumed via `onFilePickRequested` in Main.qml
  (Task 5 Step 2). `importFromUserPath` is preserved as the load entry, now fed by the picker.
  `_onImportFilePicked(accepted, files)` matches the verified `filePickerFinished(bool, QStringList)`
  signal shape.
