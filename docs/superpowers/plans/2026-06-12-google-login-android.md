# Google Login on Android (Deep-Link + PKCE) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Google sign-in work on Android by replacing the broken loopback redirect with the standard native flow — an Android OAuth client, a custom-scheme deep-link redirect, and authorization-code + PKCE — while desktop keeps its working loopback flow.

**Architecture:** On Android, `LoginPage` launches Google with `response_type=code` + PKCE and a `com.googleusercontent.apps.<id>:/oauth2redirect` redirect. Android's intent-filter routes the redirect back into the app; `App.appLinkUrlReceived` delivers it; a new `GoogleAuthService` singleton exchanges the code (+ PKCE verifier) for an `id_token` and hands it to the existing `AuthService.signInWithGoogleIdToken()`. Desktop is unchanged (loopback). Branch on `Qt.platform.os`.

**Tech Stack:** Felgo + Qt 6.8.3, QML + C++. `PkceGenerator` (C++) uses `QRandomGenerator::system()` + `QCryptographicHash::Sha256` + base64url. Google OAuth 2.0 for Mobile/Native apps.

**Spec:** `docs/superpowers/specs/2026-06-12-google-login-android-design.md`

---

## Verification model (read first)

No QML unit-test harness; this is a native auth flow. "Tests" are concrete runnable checks:

1. **`qmllint`** on changed QML — no new hard `Error:` lines. Binary:
   `"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml <file>` (filter `grep -E '^Error:'`).
2. **C++ build** — `"C:/Felgo/Tools/CMake_64/bin/cmake.exe" --build --preset felgo-mingw-debug` compiles + links with `PkceGenerator`.
3. **Desktop regression** — Google sign-in still works via the existing loopback (proves the `Qt.platform.os` branch didn't disturb desktop). Desktop is the ONLY place the loopback path runs.
4. **Android device (the real proof, Task 7)** — Google → Chrome → consent → app foregrounds signed in; no hang. logcat shows `appLinkUrlReceived` with `com.googleusercontent.apps.…?code=…` and a 200 from the token endpoint.

**Gated dependency:** the Android device test cannot pass until the Console Android OAuth client exists (Task 1, user-performed) and its client-id + reversed-scheme are pasted into `GoogleAuthService.qml` (Task 3) and `AndroidManifest.xml` (Task 5). Tasks 2–6 build/compile without the real values (using clearly-marked placeholders), but Task 7 needs the real client.

---

## File Structure

**Created:**
- `src/PkceGenerator.h`, `src/PkceGenerator.cpp` — `newVerifier()` + `challenge(verifier)`.
- `qml/model/GoogleAuthService.qml` — Android auth-URL build + code→token exchange; emits `idTokenReady(idToken)` / `authError(reason)`.

**Modified:**
- `CMakeLists.txt`, `main.cpp` — add + register `PkceGenerator`.
- `qml/model/qmldir` — register `GoogleAuthService` singleton.
- `android/AndroidManifest.xml` — custom-scheme intent-filter on `FelgoActivity`.
- `qml/pages/LoginPage.qml` — `Qt.platform.os` branch in `_startGoogleSignIn()`; mobile cancel handling.
- `qml/Main.qml` — `App.onAppLinkUrlReceived` → `GoogleAuthService` → existing `googleSignInRequested` path.

**Verified, not modified:** `src/OAuthServer.*` (desktop loopback); `AuthService.signInWithGoogleIdToken` + Firebase path; `Main.qml`'s `onGoogleSignInRequested: logic.signInWithGoogleToken(...)` wiring.

---

### Task 1: Google Cloud Console — create the Android OAuth client (USER)

**Files:** none (Console config). This task is performed by the user; later tasks consume its outputs.

- [ ] **Step 1: Get the signing SHA-1 from the stable keystore**

Run (user, with their release keystore):
```bash
keytool -list -v -keystore <path-to-your.keystore> -alias <your-alias>
```
Copy the `SHA1:` fingerprint (form `AB:CD:…:EF`).
**Critical:** this must be the SAME keystore that signs the APK you deploy for the Task 7 device test. If the test build is signed with a different key (e.g. a debug key), Google rejects the redirect. If unsure which key signs the build, also register that key's SHA-1.

- [ ] **Step 2: Create the Android OAuth client**

Google Cloud Console → project `inventorymanager-48392` → APIs & Services → Credentials →
**Create Credentials → OAuth client ID → Application type: Android**.
- Name: e.g. "BusinessManagement Android"
- Package name: `com.lkdigitalworks.business.management.app`
- SHA-1: from Step 1.
- Create. (Native Android clients have **no client secret**.)

- [ ] **Step 3: Record the two values the code needs**

From the new client:
- **ANDROID_CLIENT_ID** = `<NNN>-<hash>.apps.googleusercontent.com`
- **REVERSED_CLIENT_ID** (custom scheme) = `com.googleusercontent.apps.<NNN>-<hash>`
- **REDIRECT_URI** = `com.googleusercontent.apps.<NNN>-<hash>:/oauth2redirect`

Keep these for Task 3 (constants) and Task 5 (manifest scheme). No commit (no repo change).

---

### Task 2: `PkceGenerator` C++ helper + register

**Files:**
- Create: `src/PkceGenerator.h`, `src/PkceGenerator.cpp`
- Modify: `CMakeLists.txt`, `main.cpp`

- [ ] **Step 1: Create `src/PkceGenerator.h`**

```cpp
#pragma once

#include <QObject>
#include <QString>

// PkceGenerator — RFC 7636 PKCE helpers for the native Google auth-code flow.
// QML has no CSPRNG or SHA-256, so generate the verifier + S256 challenge here.
class PkceGenerator final : public QObject
{
    Q_OBJECT
    Q_DISABLE_COPY_MOVE(PkceGenerator)

public:
    explicit PkceGenerator(QObject *parent = nullptr);
    ~PkceGenerator() override = default;

    // A high-entropy code_verifier: 64 chars from the unreserved set
    // [A-Z a-z 0-9 - . _ ~], per RFC 7636 §4.1.
    Q_INVOKABLE QString newVerifier();

    // base64url(SHA-256(verifier)) with no padding — the S256 code_challenge.
    Q_INVOKABLE QString challenge(const QString &verifier);
};
```

- [ ] **Step 2: Create `src/PkceGenerator.cpp`**

```cpp
#include "PkceGenerator.h"

#include <QCryptographicHash>
#include <QRandomGenerator>

PkceGenerator::PkceGenerator(QObject *parent)
    : QObject(parent)
{
}

QString PkceGenerator::newVerifier()
{
    static const char kUnreserved[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";
    constexpr int kLen = 64;
    constexpr int kSetSize = sizeof(kUnreserved) - 1;  // exclude trailing NUL

    QString out;
    out.reserve(kLen);
    for (int i = 0; i < kLen; ++i) {
        const quint32 r = QRandomGenerator::system()->bounded(kSetSize);
        out.append(QChar::fromLatin1(kUnreserved[r]));
    }
    return out;
}

QString PkceGenerator::challenge(const QString &verifier)
{
    const QByteArray digest =
        QCryptographicHash::hash(verifier.toUtf8(), QCryptographicHash::Sha256);
    // base64url, no padding (RFC 7636 §4.2).
    return QString::fromLatin1(
        digest.toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals));
}
```

- [ ] **Step 3: Add the sources to CMakeLists.txt**

In `CMakeLists.txt`, the `qt_add_executable(appBusinessManagement ...)` src list currently ends with:
```
    src/Clipboard.h
    src/Clipboard.cpp
```
Immediately AFTER `src/Clipboard.cpp`, add:
```
    src/PkceGenerator.h
    src/PkceGenerator.cpp
```

- [ ] **Step 4: Register the context property in main.cpp**

(a) After `#include "src/Clipboard.h"`, add:
```cpp
#include "src/PkceGenerator.h"
```

(b) After the Clipboard registration block (the two lines ending with
`setContextProperty(QStringLiteral("Clipboard"), clipboard);`), add:
```cpp

    // Register the PKCE helper (native Google auth-code flow on mobile).
    auto *pkceGenerator = new PkceGenerator(&app);
    engine.rootContext()->setContextProperty(QStringLiteral("PkceGenerator"), pkceGenerator);
```

- [ ] **Step 5: Build**

Run: `"C:/Felgo/Tools/CMake_64/bin/cmake.exe" --build --preset felgo-mingw-debug 2>&1 | tail -8`
Expected: compiles + links; `PkceGenerator.cpp.obj` built, executable linked, no errors.

- [ ] **Step 6: Commit**

```bash
git add src/PkceGenerator.h src/PkceGenerator.cpp CMakeLists.txt main.cpp
git commit -m "feat(auth): add PkceGenerator C++ helper (verifier + S256 challenge)"
```

---

### Task 3: `GoogleAuthService` singleton (auth-URL build + token exchange)

**Files:**
- Create: `qml/model/GoogleAuthService.qml`
- Modify: `qml/model/qmldir`

- [ ] **Step 1: Create `qml/model/GoogleAuthService.qml`**

Create the file. **Paste the Task 1 values into the two marked constants** (until then the device
test won't work, but the app builds and desktop is unaffected):

```qml
pragma Singleton
import QtQuick

// Native Google sign-in for mobile (Android/iOS): authorization-code + PKCE
// with a custom-scheme deep-link redirect. Desktop keeps the loopback flow in
// LoginPage/OAuthServer. This singleton owns the mobile flow: build the auth
// URL (holding the PKCE verifier + nonce for the in-flight request), then
// exchange the returned code for a Google id_token, which it emits for the
// existing AuthService.signInWithGoogleIdToken() step.
QtObject {
    id: root

    // ── PASTE FROM CONSOLE (Task 1) ──────────────────────────────────────────
    // Android OAuth client id and its reversed form (the custom URI scheme).
    // The reversedClientId here MUST equal the scheme in AndroidManifest.xml.
    readonly property string androidClientId: "PASTE_ANDROID_CLIENT_ID.apps.googleusercontent.com"
    readonly property string reversedClientId: "com.googleusercontent.apps.PASTE_ANDROID_CLIENT_ID"
    // ─────────────────────────────────────────────────────────────────────────

    readonly property string redirectUri: reversedClientId + ":/oauth2redirect"
    readonly property string scope: "openid email profile"
    readonly property string authEndpoint: "https://accounts.google.com/o/oauth2/v2/auth"
    readonly property string tokenEndpoint: "https://oauth2.googleapis.com/token"

    // In-flight request state.
    property string _verifier: ""
    property string _nonce: ""
    property bool busy: false

    signal idTokenReady(string idToken)
    signal authError(string reason)

    // Open the system browser to Google's consent page (auth-code + PKCE).
    function start() {
        _verifier = PkceGenerator.newVerifier()
        _nonce = _randomString(32)
        var challenge = PkceGenerator.challenge(_verifier)
        busy = true
        var url = authEndpoint
            + "?client_id=" + encodeURIComponent(androidClientId)
            + "&redirect_uri=" + encodeURIComponent(redirectUri)
            + "&response_type=code"
            + "&scope=" + encodeURIComponent(scope)
            + "&code_challenge=" + encodeURIComponent(challenge)
            + "&code_challenge_method=S256"
            + "&nonce=" + encodeURIComponent(_nonce)
            + "&prompt=select_account"
        Qt.openUrlExternally(url)
    }

    // True when `url` is our redirect coming back via App.appLinkUrlReceived.
    function isRedirect(url) {
        return String(url).indexOf(reversedClientId + ":") === 0
    }

    // Handle the redirect: parse ?code=… and exchange it for an id_token.
    function handleRedirect(url) {
        var code = _queryParam(String(url), "code")
        var err = _queryParam(String(url), "error")
        if (err.length > 0) {
            busy = false
            authError(err)
            return
        }
        if (code.length === 0) {
            busy = false
            authError("No authorization code in redirect")
            return
        }
        _exchangeCode(code)
    }

    function cancel() {
        busy = false
        _verifier = ""
        _nonce = ""
    }

    // ── internals ──
    function _exchangeCode(code) {
        var body = "code=" + encodeURIComponent(code)
            + "&client_id=" + encodeURIComponent(androidClientId)
            + "&code_verifier=" + encodeURIComponent(_verifier)
            + "&grant_type=authorization_code"
            + "&redirect_uri=" + encodeURIComponent(redirectUri)

        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            busy = false
            _verifier = ""
            _nonce = ""
            if (xhr.status < 200 || xhr.status >= 300) {
                console.warn("[GoogleAuth] token exchange failed", xhr.status, xhr.responseText)
                authError("HTTP " + xhr.status)
                return
            }
            try {
                var data = JSON.parse(xhr.responseText)
                if (data.id_token && data.id_token.length > 0)
                    idTokenReady(data.id_token)
                else
                    authError("No id_token in token response")
            } catch (e) {
                authError(String(e))
            }
        }
        xhr.open("POST", tokenEndpoint)
        xhr.setRequestHeader("Content-Type", "application/x-www-form-urlencoded")
        xhr.send(body)
    }

    function _queryParam(url, key) {
        // Works for both "?k=v" and "scheme:/path?k=v" forms.
        var q = url.indexOf("?")
        if (q < 0) return ""
        var pairs = url.substring(q + 1).split("&")
        for (var i = 0; i < pairs.length; ++i) {
            var kv = pairs[i].split("=")
            if (kv.length === 2 && decodeURIComponent(kv[0]) === key)
                return decodeURIComponent(kv[1].replace(/\+/g, " "))
        }
        return ""
    }

    function _randomString(n) {
        var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        var s = ""
        for (var i = 0; i < n; ++i)
            s += chars.charAt(Math.floor(Math.random() * chars.length))
        return s
    }
}
```

- [ ] **Step 2: Register the singleton in qmldir**

Append to `qml/model/qmldir`:
```
singleton GoogleAuthService 1.0 GoogleAuthService.qml
```

- [ ] **Step 3: qmllint**

Run: `"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml qml/model/GoogleAuthService.qml 2>&1 | grep -E '^Error:' || echo CLEAN`
Expected: CLEAN. (`PkceGenerator` is a context property; an "unqualified" note for it is acceptable.)

- [ ] **Step 4: Commit**

```bash
git add qml/model/GoogleAuthService.qml qml/model/qmldir
git commit -m "feat(auth): add GoogleAuthService (Android auth-code + PKCE flow)"
```

---

### Task 4: LoginPage — branch Google sign-in by platform

**Files:**
- Modify: `qml/pages/LoginPage.qml`

Context: `_startGoogleSignIn()` (currently loopback-only) and the `Connections { target: OAuthServer }`
block (lines ~49-59) and `_cancelGoogleFlow()` (~516). `googleSignInRequested(idToken)` is the signal
Main.qml already routes to Firebase — keep emitting it.

- [ ] **Step 1: Branch `_startGoogleSignIn()` for mobile**

Replace the existing `_startGoogleSignIn()` function with:
```qml
    function _startGoogleSignIn() {
        localError = ""
        var os = Qt.platform.os
        if (os === "android" || os === "ios") {
            // Native flow: custom-scheme deep link + auth-code/PKCE. Main.qml
            // listens on App.appLinkUrlReceived and routes the resulting token.
            _googleFlowActive = true
            GoogleAuthService.start()
            return
        }
        // Desktop: loopback (unchanged).
        if (!OAuthServer.start()) {
            localError = "Could not start local auth server."
            return
        }
        _googleFlowActive = true
        _googleNonce = _generateNonce()
        var url = "https://accounts.google.com/o/oauth2/v2/auth"
            + "?client_id=" + encodeURIComponent(_googleClientId)
            + "&redirect_uri=" + encodeURIComponent(OAuthServer.redirectUri())
            + "&response_type=id_token"
            + "&scope=" + encodeURIComponent(_googleScope)
            + "&nonce=" + encodeURIComponent(_googleNonce)
            + "&prompt=select_account"
        Qt.openUrlExternally(url)
    }
```

- [ ] **Step 2: Listen for the mobile flow result**

Add a second `Connections` block right after the existing `Connections { target: OAuthServer … }`
block (after line ~59):
```qml
    // Mobile (deep-link) Google flow results, from GoogleAuthService.
    Connections {
        target: GoogleAuthService
        function onIdTokenReady(idToken) {
            _googleFlowActive = false
            googleSignInRequested(idToken)
        }
        function onAuthError(reason) {
            _googleFlowActive = false
            localError = "Google sign-in failed: " + reason
        }
    }
```
(`GoogleAuthService` resolves via LoginPage's existing imports — verify `import "../model"` is present;
if not, add it. LoginPage references no model singletons today, so add `import "../model"` to the
import block.)

- [ ] **Step 3: Make cancel platform-aware**

Replace `_cancelGoogleFlow()` with:
```qml
    function _cancelGoogleFlow() {
        var os = Qt.platform.os
        if (os === "android" || os === "ios")
            GoogleAuthService.cancel()
        else
            OAuthServer.stop()
        _googleFlowActive = false
        _googleNonce = ""
    }
```

- [ ] **Step 4: qmllint**

Run: `"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml qml/pages/LoginPage.qml 2>&1 | grep -E '^Error:' || echo CLEAN`
Expected: CLEAN.

- [ ] **Step 5: Commit**

```bash
git add qml/pages/LoginPage.qml
git commit -m "feat(auth): LoginPage uses native PKCE flow on mobile, loopback on desktop"
```

---

### Task 5: AndroidManifest — custom-scheme intent-filter

**Files:**
- Modify: `android/AndroidManifest.xml`

- [ ] **Step 1: Add the deep-link intent-filter to FelgoActivity**

In `android/AndroidManifest.xml`, the `FelgoActivity` `<activity>` already has a MAIN/LAUNCHER
`<intent-filter>` (lines 6-9). Immediately AFTER that closing `</intent-filter>` (line 9) and before
the `<!-- Qt internal meta data -->` comment, add (replacing the scheme with the Task 1
REVERSED_CLIENT_ID):
```xml
            <intent-filter>
                <action android:name="android.intent.action.VIEW"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <category android:name="android.intent.category.BROWSABLE"/>
                <data android:scheme="com.googleusercontent.apps.PASTE_ANDROID_CLIENT_ID"/>
            </intent-filter>
```
The scheme MUST exactly equal `GoogleAuthService.reversedClientId` (Task 3).

- [ ] **Step 2: Sanity-check the XML is well-formed**

Run: `python -c "import xml.dom.minidom,sys; xml.dom.minidom.parse('android/AndroidManifest.xml'); print('XML OK')"`
Expected: `XML OK`. (Or any XML validator; the point is the new filter didn't break the manifest.)

- [ ] **Step 3: Commit**

```bash
git add android/AndroidManifest.xml
git commit -m "feat(auth): register Google OAuth custom-scheme deep link (Android)"
```

---

### Task 6: Main.qml — route the deep-link redirect to GoogleAuthService

**Files:**
- Modify: `qml/Main.qml`

Context: root is `App { id: app }`. Felgo provides `signal appLinkUrlReceived(url appLinkUrl)`. The
existing `loginPage` instance already has `onGoogleSignInRequested: … logic.signInWithGoogleToken(idToken)`
— that stays. We only need to feed `GoogleAuthService` the redirect so it can emit `idTokenReady`,
which `LoginPage` (Task 4) turns into `googleSignInRequested`.

- [ ] **Step 1: Handle `appLinkUrlReceived` on the App root**

In `qml/Main.qml`, add to the root `App { … }` (near the other top-level signal handlers, e.g. just
after `onBackButtonPressedGlobally: app._handleBack()`):
```qml
    // Google OAuth deep-link redirect (Android). Hand the custom-scheme URL to
    // GoogleAuthService, which exchanges the code for an id_token; LoginPage's
    // GoogleAuthService.onIdTokenReady then drives the existing Firebase step.
    onAppLinkUrlReceived: function(appLinkUrl) {
        if (GoogleAuthService.isRedirect(appLinkUrl))
            GoogleAuthService.handleRedirect(appLinkUrl)
    }
```
`GoogleAuthService` resolves via Main.qml's existing `import "model"`.

- [ ] **Step 2: qmllint**

Run: `"/c/Felgo/Felgo/mingw_64/bin/qmllint.exe" -I qml qml/Main.qml 2>&1 | grep -E '^Error:' || echo CLEAN`
Expected: CLEAN.

- [ ] **Step 3: Commit**

```bash
git add qml/Main.qml
git commit -m "feat(auth): route Google OAuth deep-link redirect to GoogleAuthService"
```

---

### Task 7: Verification (desktop regression + Android device)

**Files:** none (verification); fixes fold back into Tasks 2–6.

- [ ] **Step 1: Desktop regression**

Build/run desktop. Tap **Google** → the existing loopback flow runs (browser → `127.0.0.1` →
returns) → signed in. Confirms the `Qt.platform.os` branch left desktop intact.

- [ ] **Step 2: Confirm constants + scheme match before the device build**

Verify the value pasted in `GoogleAuthService.reversedClientId` (Task 3) is byte-identical to the
`<data android:scheme=…>` in the manifest (Task 5), and `androidClientId` matches the Console client.
A mismatch is the #1 cause of "redirect never returns".
```bash
grep -n 'reversedClientId\|androidClientId' qml/model/GoogleAuthService.qml
grep -n 'android:scheme' android/AndroidManifest.xml
```
Both schemes must read `com.googleusercontent.apps.<same id>`.

- [ ] **Step 3: Clean Android rebuild + deploy**

Clean + rebuild the Android target (compiles `PkceGenerator`, bundles the manifest filter) signed
with the keystore whose SHA-1 is registered in Console (Task 1). Deploy to the device.

- [ ] **Step 4: Android device pass (the real proof)**

Tap **Google** → Chrome opens → pick account → consent → **the app comes back to the foreground,
signed in** (no hang, no "create a workspace" unless genuinely a new user). Capture logcat and confirm:
- `appLinkUrlReceived` fires with a `com.googleusercontent.apps.…:/oauth2redirect?code=…` URL.
- A `POST oauth2.googleapis.com/token` returns 200 (no error toast).
- The app lands on the dashboard / onboarding per the account's tenant state.

- [ ] **Step 5: Failure-path checks**

- Tap Google → in Chrome, press back / cancel → return to the app → the spinner clears and login is
  usable again (no permanent "Waiting…").
- (If easy) deny consent → a graceful "Google sign-in failed" message, not a hang.

- [ ] **Step 6: Final commit (if device fixes were needed)**

```bash
git add -A
git commit -m "fix(auth): device-verification adjustments for Android Google login"
```
If no changes were needed, skip.

---

## Self-Review Notes

- **Spec coverage:** §2 flow → Tasks 3 (GoogleAuthService) + 4 (LoginPage branch) + 6 (Main routing);
  §3a Console → Task 1; §3b manifest intent-filter → Task 5; §3c PkceGenerator → Task 2,
  GoogleAuthService → Task 3, LoginPage/Main wiring → Tasks 4/6; §5 verification → Task 7. Desktop
  loopback + `signInWithGoogleIdToken` unchanged (honored — no task modifies them).
- **Placeholder scan:** the only literal placeholders are the Console-derived client-id/scheme, which
  are *intended* paste-points (clearly marked, sequenced after Task 1) — not unspecified work. Every
  code block is concrete.
- **Type/name consistency:** `PkceGenerator.newVerifier()`/`challenge()` (Task 2) called in
  GoogleAuthService (Task 3). `GoogleAuthService.start()/isRedirect()/handleRedirect()/cancel()` +
  signals `idTokenReady`/`authError` (Task 3) consumed in LoginPage (Task 4) and Main (Task 6).
  LoginPage keeps emitting `googleSignInRequested(idToken)` — the signal Main.qml already routes to
  `logic.signInWithGoogleToken` → `AuthService.signInWithGoogleIdToken` (unchanged). The manifest
  scheme (Task 5) == `reversedClientId` (Task 3), cross-checked in Task 7 Step 2.
- **Desktop safety:** every new behavior is behind `Qt.platform.os` mobile checks; desktop continues
  to use `OAuthServer`. Task 7 Step 1 is the regression guard.
