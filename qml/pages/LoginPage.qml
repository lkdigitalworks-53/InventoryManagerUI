import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"

Item {
    id: root

    signal signInRequested(string email, string password)
    signal signUpRequested(string name, string email, string password)
    signal googleSignInRequested(string googleIdToken)
    signal forgotPasswordRequested(string email)

    property bool busy: false
    // Server-side errors flow in here from Main.qml as a binding;
    // never assign to this from inside LoginPage or the binding breaks.
    property string errorMessage: ""
    // Client-side messages (validation, provider hints, etc.) — assigning to
    // this is safe because nothing else binds to it.
    property string localError: ""
    readonly property string _displayedError: localError.length > 0 ? localError : errorMessage

    // Live form-validity flag bound directly to the field text properties.
    // Reading them via flat expressions ensures QML auto-tracks every
    // dependency on every evaluation. (A JS function call in `enabled:`,
    // or a block expression with early returns, can drop dependencies and
    // leave the button stuck at its initial value.)
    readonly property bool _emailValid: emailField
        ? FormValidator.emailRegex.test((emailField.text || "").trim())
        : false
    readonly property bool _passwordValid: passwordField
        ? (passwordField.text || "").length >= 6
        : false
    readonly property bool _nameValid: !_signupMode || (nameField
        ? (nameField.text || "").trim().length >= 2
        : false)
    readonly property bool _confirmValid: !_signupMode || (confirmField && passwordField
        ? confirmField.text === passwordField.text
        : false)
    readonly property bool _formValid: _emailValid && _passwordValid && _nameValid && _confirmValid

    // OAuth Configuration
    readonly property string _googleClientId: "219471233608-hmdnvfkntl7e5cqv5rdg2f544bupsto4.apps.googleusercontent.com"
    readonly property string _googleScope: "openid email profile"

    property bool _googleFlowActive: false
    property string _googleNonce: ""
    property bool _signupMode: false

    // Connect to the local OAuth server for Google sign-in callbacks.
    Connections {
        target: OAuthServer
        function onTokenReceived(idToken) {
            _googleFlowActive = false
            googleSignInRequested(idToken)
        }
        function onServerError(message) {
            _googleFlowActive = false
            localError = "Google sign-in failed: " + message
        }
    }

    // Background gradient
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#f0f9ff" }
            GradientStop { position: 1.0; color: "#e0e7ff" }
        }
    }

    // Scrollable container so the card stays usable on short windows.
    Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: width
        contentHeight: Math.max(height, card.height + 80)
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        // Only enable scrolling when content overflows. Otherwise Flickable's
        // grab handler can intercept button clicks before the QQC.Button
        // press handler sees them — manifests as "button click does nothing".
        interactive: contentHeight > height

        Rectangle {
            id: card
            width: Math.min(parent.width - 40, 440)
            height: formCol.implicitHeight + 40
            radius: 14
            color: "#ffffff"
            border.color: Constants.borderColor
            border.width: 1
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: Math.max(40, (parent.height - height) / 2)

            // Soft shadow via stacked rectangle
            Rectangle {
                anchors.fill: parent
                anchors.topMargin: 4
                anchors.bottomMargin: -4
                radius: parent.radius
                color: "#10000000"
                z: -1
            }

            ColumnLayout {
                id: formCol
                anchors.fill: parent
                anchors.margins: 20
                spacing: 14

                // Brand mark
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4

                    Rectangle {
                        Layout.alignment: Qt.AlignHCenter
                        width: 44; height: 44; radius: 12
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: Constants.primaryBlue }
                            GradientStop { position: 1.0; color: Constants.primaryPurple }
                        }
                        Text {
                            anchors.centerIn: parent
                            text: "BM"
                            color: "#ffffff"
                            font.bold: true
                            font.pixelSize: 16
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        Layout.topMargin: 6
                        horizontalAlignment: Text.AlignHCenter
                        text: _signupMode ? "Create your account" : "Welcome back"
                        font.pixelSize: 22
                        font.bold: true
                        color: "#111827"
                    }

                    Text {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        text: _signupMode
                            ? "Set up your business workspace in minutes"
                            : "Sign in to your business workspace"
                        font.pixelSize: 12
                        color: "#6b7280"
                        wrapMode: Text.Wrap
                    }
                }

                // Sign-in / Sign-up tabs
                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 4
                    spacing: 0

                    Repeater {
                        model: [
                            { key: false, label: "Sign in" },
                            { key: true,  label: "Sign up" }
                        ]
                        delegate: Item {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 38
                            property bool active: _signupMode === modelData.key

                            Text {
                                anchors.centerIn: parent
                                text: modelData.label
                                color: parent.active ? Constants.primaryBlue : "#6b7280"
                                font.pixelSize: 14
                                font.bold: parent.active
                            }

                            Rectangle {
                                anchors.bottom: parent.bottom
                                width: parent.width
                                height: parent.active ? 2 : 1
                                color: parent.active ? Constants.primaryBlue : Constants.borderColor
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                enabled: !root.busy && !root._googleFlowActive
                                onClicked: {
                                    if (_signupMode !== modelData.key) {
                                        _signupMode = modelData.key
                                        root.localError = ""
                                        root._clearFieldErrors()
                                    }
                                }
                            }
                        }
                    }
                }

                // Google sign-in button
                QQC.Button {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 46
                    enabled: !root.busy && !root._googleFlowActive

                    contentItem: RowLayout {
                        spacing: 10
                        Item { Layout.fillWidth: true }
                        Rectangle {
                            width: 22; height: 22; radius: 4
                            color: "#ffffff"
                            Text {
                                anchors.centerIn: parent
                                text: "G"
                                color: "#1f2937"
                                font.bold: true
                                font.pixelSize: 14
                            }
                        }
                        Text {
                            text: root._googleFlowActive
                                ? "Waiting for browser…"
                                : (_signupMode ? "Sign up with Google" : "Continue with Google")
                            color: "#ffffff"
                            font.bold: true
                            font.pixelSize: 14
                            elide: Text.ElideRight
                        }
                        Item { Layout.fillWidth: true }
                    }

                    background: Rectangle {
                        radius: 8
                        color: parent.enabled
                            ? (parent.pressed ? "#111827" : (parent.hovered ? "#374151" : "#1f2937"))
                            : "#9ca3af"
                        Behavior on color { ColorAnimation { duration: 120 } }
                    }

                    onClicked: _startGoogleSignIn()
                }

                // OR divider
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    Rectangle { Layout.fillWidth: true; height: 1; color: Constants.borderColor }
                    Text { text: "OR"; color: "#9ca3af"; font.pixelSize: 11; font.bold: true }
                    Rectangle { Layout.fillWidth: true; height: 1; color: Constants.borderColor }
                }

                // Full Name (signup only)
                AuthTextField {
                    id: nameField
                    Layout.fillWidth: true
                    visible: _signupMode
                    label: "Full Name"
                    placeholderText: "Jane Doe"
                    onTextChanged: errorText = ""
                    onAccepted: emailField.inputItem.forceActiveFocus()
                }

                AuthTextField {
                    id: emailField
                    Layout.fillWidth: true
                    label: "Email"
                    placeholderText: "you@company.com"
                    inputMethodHints: Qt.ImhEmailCharactersOnly | Qt.ImhNoAutoUppercase
                    onTextChanged: errorText = ""
                    onAccepted: passwordField.inputItem.forceActiveFocus()
                }

                AuthPasswordField {
                    id: passwordField
                    Layout.fillWidth: true
                    label: "Password"
                    placeholderText: _signupMode ? "Choose a strong password" : "Enter your password"
                    trailingLinkText: _signupMode ? "" : "Forgot?"
                    showStrength: _signupMode
                    strengthScore: _signupMode ? _passwordCheck.score : 0
                    strengthLabel: _signupMode ? _passwordCheck.label : ""
                    onTextChanged: errorText = ""
                    onTrailingLinkClicked: forgotPasswordRequested(emailField.text.trim())
                    onAccepted: {
                        if (_signupMode) confirmField.inputItem.forceActiveFocus()
                        else _submit()
                    }
                }

                AuthPasswordField {
                    id: confirmField
                    Layout.fillWidth: true
                    visible: _signupMode
                    label: "Confirm password"
                    placeholderText: "Re-enter your password"
                    onTextChanged: errorText = ""
                    onAccepted: _submit()
                }

                // Inline error
                Rectangle {
                    Layout.fillWidth: true
                    visible: root._displayedError.length > 0
                    radius: 8
                    color: "#fef2f2"
                    border.color: "#fecaca"
                    border.width: 1
                    implicitHeight: errTxt.implicitHeight + 16

                    Text {
                        id: errTxt
                        anchors.fill: parent
                        anchors.margins: 8
                        text: "⚠  " + root._displayedError
                        color: "#b91c1c"
                        font.pixelSize: 12
                        wrapMode: Text.Wrap
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                // Submit button
                AuthPrimaryButton {
                    Layout.fillWidth: true
                    text: _signupMode
                        ? (root.busy ? "Creating account…" : "Create account")
                        : (root.busy ? "Signing in…" : "Sign in")
                    loading: root.busy && !_googleFlowActive
                    enabled: !root.busy && !_googleFlowActive && root._formValid
                    onClicked: _submit()
                }

                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: "🔒 Your sign-in is secure and encrypted"
                    color: "#9ca3af"
                    font.pixelSize: 10
                }
            }
        }
    }

    // Post-OAuth progress overlay — visible while the Google flow is active
    // (browser open) OR while a sign-in callback is being processed by Firebase.
    Rectangle {
        anchors.fill: parent
        visible: _googleFlowActive
        color: "#80000000"
        z: 10

        MouseArea { anchors.fill: parent }  // swallow clicks behind overlay

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(parent.width - 40, 360)
            height: overlayCol.implicitHeight + 32
            radius: 12
            color: "#ffffff"

            ColumnLayout {
                id: overlayCol
                anchors.fill: parent
                anchors.margins: 16
                spacing: 10

                QQC.BusyIndicator {
                    Layout.alignment: Qt.AlignHCenter
                    running: true
                    implicitWidth: 36
                    implicitHeight: 36
                }

                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: "Waiting for Google sign-in…"
                    font.pixelSize: 14
                    font.bold: true
                    color: "#111827"
                }

                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: "Complete sign-in in your browser. We'll bring you back here automatically."
                    color: "#6b7280"
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                }

                AuthSecondaryButton {
                    Layout.fillWidth: true
                    Layout.topMargin: 6
                    text: "Cancel"
                    onClicked: _cancelGoogleFlow()
                }
            }
        }
    }

    // Computed password strength (signup only). Bound to passwordField.text so
    // we don't have to subscribe through an alias chain at construction time.
    readonly property var _passwordCheck: _signupMode && passwordField.text.length > 0
        ? FormValidator.validatePassword(passwordField.text)
        : ({ score: 0, label: "" })

    // Helper Functions
    function _formIsValid() {
        if (FormValidator.validateEmail(emailField.text).length > 0) return false
        if (!passwordField.text || passwordField.text.length < 6) return false
        if (_signupMode) {
            if (!nameField.text || nameField.text.trim().length < 2) return false
            if (passwordField.text !== confirmField.text) return false
        }
        return true
    }

    function _clearFieldErrors() {
        nameField.errorText = ""
        emailField.errorText = ""
        passwordField.errorText = ""
        confirmField.errorText = ""
    }

    function _validateAndShowErrors() {
        _clearFieldErrors()
        var valid = true

        if (_signupMode) {
            var nameErr = FormValidator.validateRequired(nameField.text, "Full name", 2)
            if (nameErr.length > 0) { nameField.errorText = nameErr; valid = false }
        }

        var emailErr = FormValidator.validateEmail(emailField.text)
        if (emailErr.length > 0) { emailField.errorText = emailErr; valid = false }

        var pwd = FormValidator.validatePassword(passwordField.text)
        if (pwd.error.length > 0) { passwordField.errorText = pwd.error; valid = false }

        if (_signupMode) {
            var confirmErr = FormValidator.validateConfirm(passwordField.text, confirmField.text)
            if (confirmErr.length > 0) { confirmField.errorText = confirmErr; valid = false }
        }

        return valid
    }

    function _submit() {
        console.log("[LoginPage] _submit called. busy=", root.busy,
                    "googleFlow=", root._googleFlowActive,
                    "signupMode=", _signupMode)
        if (root.busy || root._googleFlowActive) {
            console.log("[LoginPage] _submit aborted: busy or oauth flow active")
            return
        }
        if (!_validateAndShowErrors()) {
            console.log("[LoginPage] _submit aborted: validation failed")
            return
        }
        // Clear our own client-side message; the server-side errorMessage
        // binding from Main.qml will repaint on its own when authFailed fires.
        root.localError = ""

        var email = emailField.text.trim()
        if (_signupMode) {
            console.log("[LoginPage] emitting signUpRequested for", email)
            signUpRequested(nameField.text.trim(), email, passwordField.text)
            return
        }

        // Skip the provider pre-check — it added latency and an extra failure
        // mode without much benefit. Firebase already gives us a clear error
        // (mapped via _friendlyErrorMessage) when password sign-in is blocked.
        console.log("[LoginPage] emitting signInRequested for", email)
        signInRequested(email, passwordField.text)
    }

    function _startGoogleSignIn() {
        if (!OAuthServer.start()) {
            localError = "Could not start local auth server."
            return
        }
        localError = ""
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

    function _cancelGoogleFlow() {
        OAuthServer.stop()
        _googleFlowActive = false
        _googleNonce = ""
    }

    function _generateNonce() {
        var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        var nonce = ""
        for (var i = 0; i < 32; ++i) {
            nonce += chars.charAt(Math.floor(Math.random() * chars.length))
        }
        return nonce
    }
}
