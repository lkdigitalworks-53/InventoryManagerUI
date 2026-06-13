# Google Login on Android — Native Deep-Link (Auth-Code + PKCE) — Design Spec

**Date:** 2026-06-12
**Stream:** D, part 2 of 2 (the hard one; part 1 = staff add/invite/UID, already shipped)
**Bug addressed:** #7 — Google sign-in on Android hangs after account selection ("you're signing back in… → Continue → infinite loading / stays on Google's page").
**Platform:** Felgo + Qt 6.8.3, QML + C++. Mobile target = Android (iOS later); desktop keeps its current working flow.

---

## 1. Problem & Goal

**Confirmed by on-device logcat:** the app launches the Google auth URL into Chrome with
`response_type=id_token` and `redirect_uri=http://127.0.0.1:8585/auth` (the RFC 8252 *loopback*
pattern). After account selection there is **zero** activity for `127.0.0.1` / `8585` / `OAuthServer`
/ `tokenReceived` — the redirect **never returns to the app**. Google no longer honors the
implicit/loopback redirect from mobile Chrome, so it just sits on its own page. This is NOT a
server-timing or cleartext issue (the loopback server is never even contacted); it's that the flow
itself is wrong for a mobile app.

**Goal:** Google sign-in completes on Android using the **standard native-app flow** — an Android
OAuth client, a **custom-scheme deep-link** redirect, and **authorization-code + PKCE**. Desktop
keeps the existing loopback flow (which works there). Once the Google **id_token** is obtained, the
existing `AuthService.signInWithGoogleIdToken()` → Firebase path is reused unchanged.

**Non-goals:** changing the desktop loopback flow; changing the Firebase exchange / session handling;
iOS (same pattern will port later, separate client + scheme).

---

## 2. Architecture — loopback (desktop) vs deep-link (mobile)

```
Android:
  LoginPage._startGoogleSignIn()
    → verifier = PkceGenerator.newVerifier();  challenge = PkceGenerator.challenge(verifier)
    → Qt.openUrlExternally(authUrl):
        response_type=code, client_id=<ANDROID_CLIENT_ID>,
        redirect_uri=<REVERSED_CLIENT_ID>:/oauth2redirect,
        code_challenge=<challenge>, code_challenge_method=S256,
        scope="openid email profile", nonce=<random>, prompt=select_account
    → [Chrome] consent → Google 302 → "<REVERSED_CLIENT_ID>:/oauth2redirect?code=…"
    → Android intent-filter routes the custom scheme back into FelgoActivity
    → App.appLinkUrlReceived(url) → parse "code"
    → POST https://oauth2.googleapis.com/token
        { code, client_id, code_verifier, grant_type=authorization_code, redirect_uri }
        (PKCE → NO client secret) → returns id_token
    → AuthService.signInWithGoogleIdToken(id_token)         [UNCHANGED]

Desktop (unchanged):
    OAuthServer loopback (http://127.0.0.1:8585) + response_type=id_token → tokenReceived → same Firebase step
```

Branch on `Qt.platform.os` (`"android"`/`"ios"` → deep-link; else → loopback).

---

## 3. The three moving parts

### 3a. Google Cloud Console (user — full access confirmed)

1. APIs & Services → Credentials → **Create Credentials → OAuth client ID → Android**.
2. **Package name:** `com.lkdigitalworks.business.management.app`.
3. **SHA-1:** from the stable release keystore (the user signs with a keystore they control):
   `keytool -list -v -keystore <path-to.keystore> -alias <alias>` → copy the SHA1 line.
4. Save. Native Android clients use **PKCE and have no client secret**.
5. The new client id looks like `<NNN>-<hash>.apps.googleusercontent.com`. Its **reversed** form
   `com.googleusercontent.apps.<NNN>-<hash>` is the custom URI scheme; the redirect URI is
   `com.googleusercontent.apps.<NNN>-<hash>:/oauth2redirect`.

### 3b. AndroidManifest intent-filter (us)

Add to the existing `FelgoActivity` (already `launchMode="singleTop"`, `exported="true"`):
```xml
<intent-filter>
    <action android:name="android.intent.action.VIEW"/>
    <category android:name="android.intent.category.DEFAULT"/>
    <category android:name="android.intent.category.BROWSABLE"/>
    <data android:scheme="com.googleusercontent.apps.<ANDROID_CLIENT_ID>"/>
</intent-filter>
```
This makes Android route the redirect back into the running app (singleTop → no new task; delivered
via `onNewIntent` → Felgo `appLinkUrlReceived`).

### 3c. App code (us)

- **`PkceGenerator` C++ helper** (registered like `Clipboard`/`NativeFile`): QML has no SHA-256 or
  CSPRNG. Exposes:
  - `Q_INVOKABLE QString newVerifier()` — 43–128 char high-entropy unreserved string
    (`QRandomGenerator::system()`).
  - `Q_INVOKABLE QString challenge(QString verifier)` — base64url(SHA-256(verifier)) via
    `QCryptographicHash`, no padding.
- **`GoogleAuthService.qml`** (new singleton, `qml/model/`): owns the Android flow — build the auth
  URL, hold the PKCE verifier + nonce for the in-flight request, do the token POST, emit the
  resulting `id_token` (or an error). Keeps the OAuth mechanics out of `LoginPage`/`AuthService`.
- **`Main.qml`**: on Android, connect `App.onAppLinkUrlReceived` → if the URL matches the redirect
  scheme, hand the `code` to `GoogleAuthService` for the token exchange; route the resulting id_token
  to `AuthService.signInWithGoogleIdToken` (same path the loopback already uses).
- **`LoginPage.qml`**: `_startGoogleSignIn()` branches on `Qt.platform.os` — mobile uses
  `GoogleAuthService` + PKCE; desktop keeps `OAuthServer`. The existing overlay/`_googleFlowActive`
  UI stays; add handling so a cancel/return without a token clears the spinner.
- **Two constants** (Android client id + reversed-scheme) live in one place (e.g.
  `GoogleAuthService`), with a clear marker to paste the Console values. The manifest scheme must
  match the reversed-client-id constant exactly.

`AuthService.signInWithGoogleIdToken` and everything downstream (Firebase exchange, profile load,
onboarding) are **unchanged**.

---

## 4. Files touched

**Created:**
- `src/PkceGenerator.h`, `src/PkceGenerator.cpp` — PKCE verifier + S256 challenge.
- `qml/model/GoogleAuthService.qml` — Android auth-URL build + code→token exchange.

**Modified:**
- `CMakeLists.txt`, `main.cpp` — add + register `PkceGenerator`.
- `qml/model/qmldir` — register `GoogleAuthService` singleton.
- `android/AndroidManifest.xml` — custom-scheme intent-filter on `FelgoActivity`.
- `qml/pages/LoginPage.qml` — `Qt.platform.os` branch in `_startGoogleSignIn()`; cancel/return handling.
- `qml/Main.qml` — `App.onAppLinkUrlReceived` → `GoogleAuthService` → `AuthService.signInWithGoogleIdToken`.

**Verified, not modified:** `src/OAuthServer.*` (desktop loopback stays); `AuthService.signInWithGoogleIdToken`
and the Firebase path.

---

## 5. Verification

1. **`qmllint`** on changed QML; **C++ build** — `PkceGenerator` compiles + registers.
2. **Desktop regression:** Google sign-in still works via the existing loopback (proves the
   `Qt.platform.os` branch didn't disturb desktop).
3. **Android device (the real proof):** Google → Chrome → pick account → consent → **app
   foregrounds automatically and lands signed in** (no hang). logcat confirms `appLinkUrlReceived`
   fires with `com.googleusercontent.apps.…?code=…` and the token POST returns 200 with an id_token.
4. **Failure paths:** cancelling in Chrome / pressing back → the app returns to a usable login (no
   stuck spinner); a denied consent or token error shows a graceful message.

**Gated dependency:** the device test cannot pass until the Console Android client exists and its
client-id + reversed-scheme are pasted into the two constants and the manifest. The plan sequences
Console setup first.

---

## 6. Build sequence (preview — full plan via writing-plans)

1. **Console:** create the Android OAuth client (package + SHA-1); record client id + reversed scheme.
2. `PkceGenerator` C++ helper + register (build).
3. `GoogleAuthService.qml` (auth-URL build, token exchange, id_token signal) + qmldir; paste constants.
4. AndroidManifest intent-filter (reversed scheme).
5. `LoginPage` platform branch; `Main.qml` `appLinkUrlReceived` wiring.
6. Desktop regression, then Android device pass (§5).
