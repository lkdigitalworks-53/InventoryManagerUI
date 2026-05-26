import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts

import "../components"
import "../helper"

// Mobile-first auth page. Mirrors the prototype:
//   • Fluid gradient blob background
//   • Brand mark (indigo→violet→pink conic)
//   • Sign in / Sign up tab pair
//   • OAuth row, "or" divider, fields, primary CTA
//   • Forgot link, secure-sign-in caption
Item {
    id: root
    clip: true   // keep decorative blobs from painting outside the page

    signal signInRequested(string email, string password)
    signal signUpRequested(string name, string email, string password)
    signal googleSignInRequested(string googleIdToken)
    signal forgotPasswordRequested(string email)

    property bool busy: false
    property string errorMessage: ""
    property string localError: ""
    readonly property string _displayedError: localError.length > 0 ? localError : errorMessage

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

    readonly property string _googleClientId: "219471233608-hmdnvfkntl7e5cqv5rdg2f544bupsto4.apps.googleusercontent.com"
    readonly property string _googleScope: "openid email profile"

    property bool _googleFlowActive: false
    property string _googleNonce: ""
    property bool _signupMode: false

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

    // ── Background: app surface + fluid blobs ─────────────────────────────
    Rectangle {
        anchors.fill: parent
        color: Constants.appBg
    }

    // Indigo blob — top-left
    Rectangle {
        id: blob1
        z: -1
        width: dp(220); height: dp(220); radius: dp(110)
        x: -dp(70); y: -dp(70)
        color: Constants.brand1
        opacity: 0.40
        SequentialAnimation on x {
            loops: Animation.Infinite
            NumberAnimation { from: -dp(70); to: -dp(30); duration: 6000; easing.type: Easing.InOutQuad }
            NumberAnimation { from: -dp(30); to: -dp(70); duration: 6000; easing.type: Easing.InOutQuad }
        }
    }
    // Pink blob — middle-right
    Rectangle {
        z: -1
        width: dp(200); height: dp(200); radius: dp(100)
        x: parent.width - dp(140); y: parent.height * 0.30
        color: Constants.brand3
        opacity: 0.30
        SequentialAnimation on y {
            loops: Animation.Infinite
            NumberAnimation { from: parent ? parent.height * 0.30 : 200;
                              to: parent ? parent.height * 0.40 : 260;
                              duration: 7000; easing.type: Easing.InOutQuad }
            NumberAnimation { from: parent ? parent.height * 0.40 : 260;
                              to: parent ? parent.height * 0.30 : 200;
                              duration: 7000; easing.type: Easing.InOutQuad }
        }
    }
    // Cyan blob — bottom-left
    Rectangle {
        z: -1
        width: dp(180); height: dp(180); radius: dp(90)
        x: parent.width * 0.20; y: parent.height - dp(90)
        color: Constants.brand4
        opacity: 0.25
    }

    // ── Auth card ─────────────────────────────────────────────────────────
    QQC.ScrollView {
        id: authScroll
        anchors.fill: parent
        clip: true
        QQC.ScrollBar.horizontal.policy: QQC.ScrollBar.AlwaysOff

        ColumnLayout {
            id: scrollCol
            // Bind to the ScrollView's available width — never overflow / clip.
            width: authScroll.availableWidth
            spacing: dp(Constants.space5)

            Item { Layout.preferredHeight: dp(Constants.space7); Layout.fillWidth: true }

            // Brand mark
            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                width: dp(72); height: dp(72); radius: dp(22)
                gradient: Gradient {
                    orientation: Gradient.Vertical
                    GradientStop { position: 0.0; color: Constants.brand1 }
                    GradientStop { position: 0.55; color: Constants.brand2 }
                    GradientStop { position: 1.0; color: Constants.brand3 }
                }
                Text {
                    anchors.centerIn: parent
                    text: "BM"
                    color: Constants.textOnBrand
                    font.bold: true
                    font.pixelSize: sp(22)
                    font.letterSpacing: 0.5
                }
            }

            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: _signupMode ? "Create account" : "Welcome back"
                font.pixelSize: sp(28)
                font.bold: true
                font.letterSpacing: -0.5
                color: Constants.textPrimary
            }

            Text {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space5)
                Layout.rightMargin: dp(Constants.space5)
                horizontalAlignment: Text.AlignHCenter
                text: _signupMode
                    ? "Start your 14-day free trial. No card needed."
                    : "Sign in to your workspace."
                font.pixelSize: sp(Constants.fsBodyLg)
                color: Constants.textSecondary
                wrapMode: Text.Wrap
            }

            // Sign-in / Sign-up tabs (segmented pill)
            Item {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: Math.min(scrollCol.width - dp(Constants.space5 * 2), dp(320))
                Layout.preferredHeight: dp(40)
                Layout.topMargin: dp(Constants.space2)

                Rectangle {
                    anchors.fill: parent
                    radius: dp(Constants.radiusPill)
                    color: Constants.cardBg
                    border.color: Constants.borderColor
                    border.width: 1

                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: dp(4)
                        spacing: dp(4)
                        Repeater {
                            model: [
                                { key: false, label: "Sign in" },
                                { key: true,  label: "Sign up" }
                            ]
                            delegate: Item {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                readonly property bool isOn: _signupMode === modelData.key

                                Rectangle {
                                    anchors.fill: parent
                                    radius: dp(Constants.radiusPill)
                                    visible: parent.isOn
                                    gradient: Gradient {
                                        orientation: Gradient.Horizontal
                                        GradientStop { position: 0.0; color: Constants.brand1 }
                                        GradientStop { position: 1.0; color: Constants.brand2 }
                                    }
                                }
                                Text {
                                    anchors.centerIn: parent
                                    text: modelData.label
                                    color: parent.isOn ? Constants.textOnBrand : Constants.textSecondary
                                    font.pixelSize: sp(Constants.fsBody)
                                    font.bold: true
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
                }
            }

            // Form fields container
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: dp(Constants.space5)
                Layout.rightMargin: dp(Constants.space5)
                spacing: dp(Constants.space3)

                AuthTextField {
                    id: nameField
                    Layout.fillWidth: true
                    visible: _signupMode
                    label: "Full name"
                    placeholderText: "Alex Chen"
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
                    placeholderText: _signupMode ? "At least 8 characters" : "••••••••"
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
                    radius: dp(12)
                    color: Constants.cancelledFill
                    border.color: Qt.rgba(0.93, 0.27, 0.27, 0.25)
                    border.width: 1
                    implicitHeight: errTxt.implicitHeight + dp(16)

                    Text {
                        id: errTxt
                        anchors.fill: parent
                        anchors.margins: dp(10)
                        text: "⚠  " + root._displayedError
                        color: Constants.cancelledText
                        font.pixelSize: sp(Constants.fsSmall)
                        wrapMode: Text.Wrap
                        verticalAlignment: Text.AlignVCenter
                    }
                }

                // Submit button
                PrimaryButton {
                    Layout.fillWidth: true
                    Layout.topMargin: dp(Constants.space2)
                    text: _signupMode
                        ? (root.busy ? "Creating account…" : "Create account")
                        : (root.busy ? "Signing in…" : "Sign in")
                    loading: root.busy && !_googleFlowActive
                    enabled: !root.busy && !_googleFlowActive && root._formValid
                    onClicked: _submit()
                }

                // OR divider
                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: dp(Constants.space2)
                    spacing: dp(Constants.space3)
                    Rectangle { Layout.fillWidth: true; height: 1; color: Constants.borderColor }
                    Text { text: "or continue with"; color: Constants.textMuted; font.pixelSize: sp(Constants.fsSmall) }
                    Rectangle { Layout.fillWidth: true; height: 1; color: Constants.borderColor }
                }

                // OAuth row
                RowLayout {
                    Layout.fillWidth: true
                    spacing: dp(Constants.space2)

                    GhostButton {
                        Layout.fillWidth: true
                        text: root._googleFlowActive ? "Waiting…" : "Google"
                        enabled: !root.busy && !root._googleFlowActive
                        onClicked: _startGoogleSignIn()
                    }

                    GhostButton {
                        Layout.fillWidth: true
                        text: "Apple"
                        enabled: false  // hooked up later — currently stubbed
                    }
                }

                Text {
                    Layout.fillWidth: true
                    Layout.topMargin: dp(Constants.space3)
                    horizontalAlignment: Text.AlignHCenter
                    text: "🔒 Your sign-in is secure and encrypted"
                    color: Constants.textMuted
                    font.pixelSize: sp(Constants.fsCaption)
                }
            }

            Item { Layout.preferredHeight: dp(Constants.space7); Layout.fillWidth: true }
        }
    }

    // OAuth progress overlay
    Rectangle {
        anchors.fill: parent
        visible: _googleFlowActive
        color: Constants.overlay
        z: 100

        MouseArea { anchors.fill: parent }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(parent.width - dp(40), dp(360))
            height: overlayCol.implicitHeight + dp(32)
            radius: dp(Constants.radiusLg)
            color: Constants.cardBg

            ColumnLayout {
                id: overlayCol
                anchors.fill: parent
                anchors.margins: dp(Constants.space4)
                spacing: dp(Constants.space3)

                QQC.BusyIndicator {
                    Layout.alignment: Qt.AlignHCenter
                    running: true
                    implicitWidth: dp(36)
                    implicitHeight: dp(36)
                }

                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: "Waiting for Google sign-in…"
                    font.pixelSize: sp(Constants.fsBodyLg)
                    font.bold: true
                    color: Constants.textPrimary
                }

                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: "Complete sign-in in your browser. We'll bring you back here automatically."
                    color: Constants.textSecondary
                    font.pixelSize: sp(Constants.fsSmall)
                    wrapMode: Text.Wrap
                }

                GhostButton {
                    Layout.fillWidth: true
                    Layout.topMargin: dp(Constants.space2)
                    text: "Cancel"
                    onClicked: _cancelGoogleFlow()
                }
            }
        }
    }

    readonly property var _passwordCheck: _signupMode && passwordField.text.length > 0
        ? FormValidator.validatePassword(passwordField.text)
        : ({ score: 0, label: "" })

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
        if (root.busy || root._googleFlowActive) return
        if (!_validateAndShowErrors()) return
        root.localError = ""

        var email = emailField.text.trim()
        if (_signupMode) {
            signUpRequested(nameField.text.trim(), email, passwordField.text)
            return
        }
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
