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

    // ── Google OAuth client (iOS type) ───────────────────────────────────────
    // Uses an *iOS* OAuth client, not Android: Google rejects custom-scheme
    // browser redirects for Android clients ("Custom URI scheme is not supported
    // on Android or Chrome apps"), but accepts them for iOS clients. The browser
    // auth-code flow is validated by PKCE, so it works from Android Chrome too.
    // The reversedClientId here MUST equal the scheme in AndroidManifest.xml.
    readonly property string androidClientId: "219471233608-vque5f2bc586h09hpjcbnjm05cu1c7qa.apps.googleusercontent.com"
    readonly property string reversedClientId: "com.googleusercontent.apps.219471233608-vque5f2bc586h09hpjcbnjm05cu1c7qa"
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
