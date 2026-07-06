pragma Singleton
import QtQuick

QtObject {
    id: root

    readonly property string apiKey: "AIzaSyAeA5Mb6ZmtKLOb3Oxw_n-dh62_qY0r4mA"
    readonly property string authBaseUrl: "https://identitytoolkit.googleapis.com/v1"
    readonly property string tokenBaseUrl: "https://securetoken.googleapis.com/v1"

    property bool busy: false
    property bool membersBusy: false
    property bool tenantCreateBusy: false
    property bool profileResolved: false
    property bool onboardingNeeded: false
    property int lastStatusCode: 0
    property string lastError: ""
    property var tenantMembers: []

    signal loginSucceeded()
    signal signupSucceeded()
    signal onboardingRequired()
    signal tenantContextReady(string tenantId, string role)
    signal tenantMembersLoaded()
    signal memberOperationSucceeded(string message)
    signal memberOperationFailed(string reason)
    signal authFailed(string reason)
    signal tokenRefreshed()
    signal signedOut()
    signal profileUpdated()
    signal passwordResetSent(string email)

    Component.onCompleted: {
        AuthStore.loadSession()
        if (AuthStore.isAuthenticated) {
            profileResolved = false
            onboardingNeeded = false
            _loadUserProfile()
        } else if (AuthStore.refreshToken && !AuthStore.idToken)
            refreshIdToken()
        else
            profileResolved = true
    }

    function _parseErrorReason() {
        try {
            var obj = JSON.parse(lastError)
            var raw = (obj && obj.error && obj.error.message) ? obj.error.message : lastError
            return _friendlyErrorMessage(raw)
        } catch (e) {
            return lastError
        }
    }

    // Map Firebase Identity Toolkit error codes to user-friendly messages.
    // Codes appear at the start of obj.error.message (e.g. "INVALID_PASSWORD : foo").
    function _friendlyErrorMessage(raw) {
        if (!raw) return raw
        var head = String(raw).split(":")[0].trim()
        switch (head) {
        case "INVALID_PASSWORD":
        case "INVALID_LOGIN_CREDENTIALS":
            return "Incorrect email or password."
        case "EMAIL_NOT_FOUND":
            return "No account exists with this email."
        case "USER_DISABLED":
            return "This account has been disabled."
        case "EMAIL_EXISTS":
            return "An account with this email already exists."
        case "WEAK_PASSWORD":
            return "Password is too weak. Use at least 6 characters."
        case "TOO_MANY_ATTEMPTS_TRY_LATER":
            return "Too many attempts. Please try again later."
        case "OPERATION_NOT_ALLOWED":
            return "Email/password sign-in is not enabled for this project."
        }
        return raw
    }

    // Look up which providers are registered for an email so the UI can guide
    // the user (e.g. "this account uses Google sign-in") before failed attempts.
    function checkEmailProviders(email, callback) {
        if (!email || email.length === 0) {
            if (callback) callback({ providers: [], registered: false })
            return
        }
        var url = authBaseUrl + "/accounts:createAuthUri?key=" + encodeURIComponent(apiKey)
        _postJson(url, {
            identifier: email,
            continueUri: "http://localhost"
        }, function(ok, data) {
            if (!ok || !data) {
                if (callback) callback({ providers: [], registered: false })
                return
            }
            if (callback) callback({
                providers: data.allProviders || [],
                registered: !!data.registered
            })
        })
    }

    function _postJson(url, body, callback) {
        var xhr = new XMLHttpRequest()
        var settled = false
        busy = true

        // 20s timeout fallback so a hung request never leaves the UI silent.
        var timer = Qt.createQmlObject(
            'import QtQuick; Timer { interval: 20000; running: true; repeat: false }',
            root, "AuthServiceTimeoutTimer")
        timer.triggered.connect(function() {
            if (settled) return
            settled = true
            busy = false
            lastStatusCode = 0
            lastError = "Request timed out"
            try { xhr.abort() } catch (e) {}
            console.warn("[AuthService] request timed out:", url)
            if (callback) callback(false, null)
        })

        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (settled) return
            settled = true
            timer.stop()
            busy = false
            lastStatusCode = xhr.status

            var ok = xhr.status >= 200 && xhr.status < 300
            if (!ok) {
                lastError = xhr.responseText || ("HTTP " + xhr.status)
                console.warn("[AuthService] request failed:", url, "status:", xhr.status, "body:", lastError)
                if (callback) callback(false, null)
                return
            }

            try {
                lastError = ""
                var data = xhr.responseText ? JSON.parse(xhr.responseText) : {}
                if (callback) callback(true, data)
            } catch (e) {
                lastError = String(e)
                console.warn("[AuthService] response parse error:", url, e)
                if (callback) callback(false, null)
            }
        }
        xhr.open("POST", url)
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.send(JSON.stringify(body || {}))
    }

    function _nowEpochSec() {
        return Math.floor(Date.now() / 1000)
    }

    function _applyAuthResult(data) {
        var expiresIn = parseInt(data.expiresIn || "3600", 10)
        AuthStore.applyAuth({
            uid: data.localId || "",
            email: data.email || "",
            displayName: data.displayName || "",
            photoUrl: data.photoUrl || "",
            idToken: data.idToken || "",
            refreshToken: data.refreshToken || "",
            expiresAtEpochSec: _nowEpochSec() + (isNaN(expiresIn) ? 3600 : expiresIn)
        })
    }

    function _loadMembership(tenantId, onDone) {
        if (!tenantId) {
            if (onDone) onDone(false)
            return
        }

        FirebaseService.get("tenants/" + tenantId + "/members/" + AuthStore.uid, function(ok, data) {
            if (!ok || !data) {
                if (onDone) onDone(false)
                return
            }

            AuthStore.applyTenantContext({
                tenantId: tenantId,
                tenantName: data.tenantName || AuthStore.tenantName,
                role: data.role || "staff"
            })
            // Backfill workspace name from canonical tenant doc when missing.
            if (!AuthStore.tenantName || AuthStore.tenantName.length === 0)
                _ensureTenantName(tenantId)
            loadTenantMembers()
            tenantContextReady(AuthStore.tenantId, AuthStore.role)
            if (onDone) onDone(true)
        })
    }

    function loadTenantMembers() {
        if (!AuthStore.isAuthenticated || !AuthStore.tenantId) {
            tenantMembers = []
            tenantMembersLoaded()
            return
        }

        membersBusy = true
        FirebaseService.get("tenants/" + AuthStore.tenantId + "/members", function(ok, data) {
            membersBusy = false
            if (!ok) {
                memberOperationFailed("Failed to load tenant members")
                return
            }

            tenantMembers = FirebaseService.toArray(data)
            tenantMembersLoaded()
        })
    }

    function _canAssignRole(targetRole) {
        if (AuthStore.role === "owner")
            return targetRole === "admin" || targetRole === "manager" || targetRole === "staff"
        if (AuthStore.role === "admin")
            return targetRole === "manager" || targetRole === "staff"
        return false
    }

    function _loadUserProfile() {
        profileResolved = false
        onboardingNeeded = false

        if (!AuthStore.uid) {
            onboardingNeeded = true
            profileResolved = true
            onboardingRequired()
            return
        }

        FirebaseService.get("users/" + AuthStore.uid, function(ok, data) {
            if (!ok || !data) {
                onboardingNeeded = true
                profileResolved = true
                onboardingRequired()
                return
            }

            AuthStore.applyAuth({
                email: data.email || AuthStore.email,
                displayName: data.displayName || AuthStore.displayName,
                photoUrl: data.photoUrl || AuthStore.photoUrl
            })

            AuthStore.updateProfile({
                phone: data.phone || "",
                address: data.address || "",
                city: data.city || "",
                country: data.country || "",
                postalCode: data.postalCode || ""
            })

            var tenantId = data.tenantId || ""
            var tenantName = data.tenantName || ""
            var role = data.role || ""

            if (!tenantId) {
                onboardingNeeded = true
                profileResolved = true
                onboardingRequired()
                return
            }

            AuthStore.applyTenantContext({ tenantId: tenantId, tenantName: tenantName, role: role })

            // If the user doc didn't carry a tenant name, fetch the canonical
            // tenant doc so the workspace name shows in the header.
            if (!tenantName || tenantName.length === 0)
                _ensureTenantName(tenantId)

            if (role && role.length > 0) {
                onboardingNeeded = false
                profileResolved = true
                loadTenantMembers()
                tenantContextReady(tenantId, role)
                return
            }

            _loadMembership(tenantId, function(found) {
                if (!found) {
                    onboardingNeeded = true
                    profileResolved = true
                    onboardingRequired()
                } else {
                    onboardingNeeded = false
                    profileResolved = true
                }
            })
        })
    }

    function _ensureTenantName(tenantId) {
        if (!tenantId) return
        FirebaseService.get("tenants/" + tenantId, function(ok, data) {
            if (!ok || !data) return
            var name = data.name || data.tenantName || ""
            if (name && name.length > 0) {
                AuthStore.applyTenantContext({
                    tenantId: AuthStore.tenantId,
                    tenantName: name,
                    role: AuthStore.role
                })
            }
        })
    }

    function signInWithEmail(email, password) {
        var url = authBaseUrl + "/accounts:signInWithPassword?key=" + encodeURIComponent(apiKey)
        _postJson(url, {
            email: email,
            password: password,
            returnSecureToken: true
        }, function(ok, data) {
            if (!ok) {
                authFailed(_parseErrorReason())
                return
            }
            _applyAuthResult(data)
            profileResolved = false
            onboardingNeeded = false
            _loadUserProfile()
            loginSucceeded()
        })
    }

    function signUpWithEmail(email, password, displayName) {
        var url = authBaseUrl + "/accounts:signUp?key=" + encodeURIComponent(apiKey)
        _postJson(url, {
            email: email,
            password: password,
            returnSecureToken: true
        }, function(ok, data) {
            if (!ok) {
                authFailed(_parseErrorReason())
                return
            }
            _applyAuthResult(data)
            if (displayName && displayName.length > 0)
                updateProfile(displayName)
            onboardingNeeded = true
            profileResolved = true
            signupSucceeded()
            onboardingRequired()
        })
    }

    function signInWithGoogleIdToken(googleIdToken) {
        console.log("[AuthService] exchanging Google id_token with Firebase…")
        var url = authBaseUrl + "/accounts:signInWithIdp?key=" + encodeURIComponent(apiKey)
        var body = {
            postBody: "id_token=" + encodeURIComponent(googleIdToken) + "&providerId=google.com",
            requestUri: "http://localhost",
            returnSecureToken: true,
            returnIdpCredential: true
        }

        _postJson(url, body, function(ok, data) {
            if (!ok) {
                console.warn("[AuthService] Google token exchange failed:", lastError)
                authFailed(_parseErrorReason())
                return
            }
            console.log("[AuthService] Google sign-in OK, loading profile for uid:", data.localId)
            var isNewUser = !!data.isNewUser
            _applyAuthResult(data)
            profileResolved = false
            onboardingNeeded = false
            _loadUserProfile()
            loginSucceeded()
            if (isNewUser)
                signupSucceeded()
        })
    }

    function sendPasswordResetEmail(email) {
        if (!email || email.trim().length === 0) {
            authFailed("Email is required")
            return
        }
        var url = authBaseUrl + "/accounts:sendOobCode?key=" + encodeURIComponent(apiKey)
        _postJson(url, {
            requestType: "PASSWORD_RESET",
            email: email.trim()
        }, function(ok, data) {
            if (!ok) {
                authFailed(_parseErrorReason())
                return
            }
            passwordResetSent(email.trim())
        })
    }

    function updateProfile(displayName) {
        if (!AuthStore.idToken) return
        var url = authBaseUrl + "/accounts:update?key=" + encodeURIComponent(apiKey)
        _postJson(url, {
            idToken: AuthStore.idToken,
            displayName: displayName,
            returnSecureToken: false
        }, function(ok, data) {
            if (ok && data && data.displayName) {
                AuthStore.applyAuth({ displayName: data.displayName })
            }
        })
    }

    function refreshIdToken() {
        if (!AuthStore.refreshToken || AuthStore.refreshToken.length === 0) {
            authFailed("Missing refresh token")
            return
        }
        var url = tokenBaseUrl + "/token?key=" + encodeURIComponent(apiKey)
        _postJson(url, {
            grant_type: "refresh_token",
            refresh_token: AuthStore.refreshToken
        }, function(ok, data) {
            if (!ok) {
                authFailed(_parseErrorReason())
                return
            }
            var expiresIn = parseInt(data.expires_in || "3600", 10)
            AuthStore.applyAuth({
                idToken: data.id_token || "",
                refreshToken: data.refresh_token || AuthStore.refreshToken,
                uid: data.user_id || AuthStore.uid,
                expiresAtEpochSec: _nowEpochSec() + (isNaN(expiresIn) ? 3600 : expiresIn)
            })
            profileResolved = false
            onboardingNeeded = false
            _loadUserProfile()
            tokenRefreshed()
        })
    }

    function ensureFreshToken() {
        if (!AuthStore.isAuthenticated) return
        var thresholdSec = 5 * 60
        if (AuthStore.expiresAtEpochSec <= (_nowEpochSec() + thresholdSec))
            refreshIdToken()
    }

    function setTenantContext(tenantId, tenantName, role) {
        AuthStore.applyTenantContext({
            tenantId: tenantId,
            tenantName: tenantName,
            role: role
        })
        onboardingNeeded = false
        profileResolved = true
        loadTenantMembers()
        tenantContextReady(AuthStore.tenantId, AuthStore.role)
    }

    function createTenantForCurrentUser(tenantName) {
        if (tenantCreateBusy || busy) {
            authFailed("Tenant setup already in progress")
            return
        }

        if (!AuthStore.isAuthenticated || !AuthStore.uid) {
            authFailed("Not authenticated")
            return
        }
        if (!tenantName || tenantName.trim().length === 0) {
            authFailed("Tenant name is required")
            return
        }

        if (AuthStore.tenantId && AuthStore.tenantId.length > 0) {
            tenantContextReady(AuthStore.tenantId, AuthStore.role || "owner")
            return
        }

        tenantCreateBusy = true
        busy = true

        var safeName = tenantName.trim()
        // Keep onboarding idempotent: retries for the same account target the same tenant doc.
        var tenantId = "t_" + AuthStore.uid
        var nowIso = new Date().toISOString()

        var tenantDoc = {
            tenantId: tenantId,
            name: safeName,
            ownerId: AuthStore.uid,
            plan: "free",
            createdAt: nowIso
        }

        var memberDoc = {
            uid: AuthStore.uid,
            role: "owner",
            email: AuthStore.email,
            displayName: AuthStore.displayName,
            tenantName: safeName,
            joinedAt: nowIso,
            status: "active"
        }

        var userDoc = {
            uid: AuthStore.uid,
            email: AuthStore.email,
            displayName: AuthStore.displayName,
            photoUrl: AuthStore.photoUrl,
            tenantId: tenantId,
            tenantName: safeName,
            role: "owner",
            tenants: [tenantId],
            // Owner profile details
            phone: "",
            address: "",
            city: "",
            country: "",
            postalCode: "",
            lastLoginAt: nowIso,
            createdAt: nowIso
        }

        FirebaseService.get("users/" + AuthStore.uid, function(okExisting, existingUser) {
            if (okExisting && existingUser && existingUser.tenantId) {
                AuthStore.applyTenantContext({
                    tenantId: existingUser.tenantId,
                    tenantName: existingUser.tenantName || safeName,
                    role: existingUser.role || "owner"
                })
                busy = false
                tenantCreateBusy = false
                loadTenantMembers()
                tenantContextReady(AuthStore.tenantId, AuthStore.role)
                return
            }

            FirebaseService.put("tenants/" + tenantId, tenantDoc, function(okTenant) {
                if (!okTenant) {
                    busy = false
                    tenantCreateBusy = false
                    authFailed("Failed to create tenant")
                    return
                }

                FirebaseService.put("users/" + AuthStore.uid, userDoc, function(okUser) {
                    if (!okUser) {
                        // Roll back partial onboarding writes.
                        FirebaseService.remove("tenants/" + tenantId, function() {})
                        busy = false
                        tenantCreateBusy = false
                        authFailed("Failed to persist user profile")
                        return
                    }

                    FirebaseService.put("tenants/" + tenantId + "/members/" + AuthStore.uid, memberDoc, function(okMember) {
                        if (!okMember) {
                            // Roll back partial onboarding writes.
                            FirebaseService.remove("users/" + AuthStore.uid, function() {})
                            FirebaseService.remove("tenants/" + tenantId, function() {})
                            busy = false
                            tenantCreateBusy = false
                            var membershipError = "Failed to create tenant membership. "
                            if (FirebaseService.lastStatusCode === 403)
                                membershipError += "(Firestore rules may not be deployed or are denying write access)"
                            else if (FirebaseService.lastStatusCode > 0)
                                membershipError += "(HTTP " + FirebaseService.lastStatusCode + ")"
                            if (FirebaseService.lastError && FirebaseService.lastError.length > 10)
                                membershipError += " Details: " + FirebaseService.lastError.substring(0, 200)
                            console.error("[AuthService] Membership creation failed:", membershipError)
                            authFailed(membershipError)
                            return
                        }

                        AuthStore.applyTenantContext({ tenantId: tenantId, tenantName: safeName, role: "owner" })
                        onboardingNeeded = false
                        profileResolved = true
                        busy = false
                        tenantCreateBusy = false
                        loadTenantMembers()
                        tenantContextReady(AuthStore.tenantId, AuthStore.role)
                    })
                })
            })
        })
    }

    function inviteMemberToCurrentTenant(uid, email, displayName, role) {
        if (!AuthStore.isAuthenticated || !AuthStore.uid) {
            authFailed("Not authenticated")
            return
        }
        if (!AuthStore.canInviteMembers) {
            authFailed("Only owner/admin can invite members")
            return
        }
        if (!AuthStore.tenantId) {
            authFailed("Tenant context missing")
            return
        }
        if (!uid || uid.trim().length === 0) {
            authFailed("Target user UID is required")
            return
        }

        var safeUid = uid.trim()
        var safeRole = role && role.length > 0 ? role : "staff"
        var safeEmail = email || ""
        var safeName = displayName || ""

        // Invites also go through the server-side function. The old client path
        // tried to write the invitee's users/{uid} doc with the OWNER's token,
        // which the Firestore rules always reject (a user may only write their
        // OWN users/ doc) — that was the perpetual "Failed to update user
        // profile for invite". The Admin SDK adds the tenant to the invitee's
        // tenants[] and writes the member doc atomically.
        Gateway.provisionMember({
            uid: safeUid,
            email: safeEmail,
            displayName: safeName,
            role: safeRole
        }, function(ok, data) {
            if (!ok || !data || !data.ok) {
                var reason = data && data.error ? data.error : "unknown"
                // Inviting needs the server-side function. Until it's deployed,
                // tell the user this feature is pending rather than showing a
                // raw failure — keeps the message honest and non-alarming.
                if (reason === "provisioning-unavailable") {
                    memberOperationFailed(_provisionErrorMessage(reason))
                    return
                }
                authFailed("Failed to invite member: " + _provisionErrorMessage(reason))
                memberOperationFailed("Failed to invite member: " + _provisionErrorMessage(reason))
                return
            }
            loadTenantMembers()
            memberOperationSucceeded("Member invited")
            tenantContextReady(AuthStore.tenantId, AuthStore.role)
        })
    }

    function updateMemberRole(uid, role) {
        if (!AuthStore.canInviteMembers) {
            memberOperationFailed("Only owner/admin can update roles")
            return
        }
        if (!uid) {
            memberOperationFailed("UID is required")
            return
        }
        if (!_canAssignRole(role)) {
            memberOperationFailed("Role assignment is not allowed")
            return
        }

        FirebaseService.get("tenants/" + AuthStore.tenantId + "/members/" + uid, function(ok, member) {
            if (!ok || !member) {
                memberOperationFailed("Member not found")
                return
            }
            if (member.role === "owner") {
                memberOperationFailed("Owner role cannot be modified")
                return
            }

            member.role = role
            FirebaseService.put("tenants/" + AuthStore.tenantId + "/members/" + uid, member, function(okWrite) {
                if (!okWrite) {
                    memberOperationFailed("Failed to update role")
                    return
                }
                loadTenantMembers()
                memberOperationSucceeded("Role updated")
            })
        })
    }

    function setMemberStatus(uid, status) {
        if (!AuthStore.canInviteMembers) {
            memberOperationFailed("Only owner/admin can update status")
            return
        }
        if (!uid) {
            memberOperationFailed("UID is required")
            return
        }

        FirebaseService.get("tenants/" + AuthStore.tenantId + "/members/" + uid, function(ok, member) {
            if (!ok || !member) {
                memberOperationFailed("Member not found")
                return
            }
            if (member.role === "owner") {
                memberOperationFailed("Owner status cannot be changed")
                return
            }

            member.status = status
            FirebaseService.put("tenants/" + AuthStore.tenantId + "/members/" + uid, member, function(okWrite) {
                if (!okWrite) {
                    memberOperationFailed("Failed to update status")
                    return
                }
                loadTenantMembers()
                memberOperationSucceeded("Status updated")
            })
        })
    }

    function removeMember(uid) {
        if (!AuthStore.canInviteMembers) {
            memberOperationFailed("Only owner/admin can remove members")
            return
        }
        if (!uid) {
            memberOperationFailed("UID is required")
            return
        }
        if (uid === AuthStore.uid) {
            memberOperationFailed("You cannot remove yourself")
            return
        }

        FirebaseService.get("tenants/" + AuthStore.tenantId + "/members/" + uid, function(ok, member) {
            if (!ok || !member) {
                memberOperationFailed("Member not found")
                return
            }
            if (member.role === "owner") {
                memberOperationFailed("Owner cannot be removed")
                return
            }

            FirebaseService.remove("tenants/" + AuthStore.tenantId + "/members/" + uid, function(okRemove) {
                if (!okRemove) {
                    memberOperationFailed("Failed to remove member")
                    return
                }
                loadTenantMembers()
                memberOperationSucceeded("Member removed")
            })
        })
    }

    function provisionStaffCredentials(displayName, email, password, phone, department, appRole, staffId) {
        if (!AuthStore.isAuthenticated || !AuthStore.uid) {
            authFailed("Not authenticated")
            return
        }
        if (!AuthStore.canInviteMembers) {
            authFailed("Only owner/admin can create staff login credentials")
            return
        }
        if (!AuthStore.tenantId) {
            authFailed("Tenant context missing")
            return
        }
        if (!email || email.indexOf("@") < 0) {
            authFailed("Valid staff email is required")
            return
        }
        if (!password || password.length < 6) {
            authFailed("Staff password must be at least 6 characters")
            return
        }

        var role = appRole && appRole.length > 0 ? appRole : "staff"
        var safeRole = role === "admin" || role === "manager" || role === "staff" ? role : "staff"

        // Provisioning runs server-side (Admin SDK). The function creates the
        // Auth account when the email is new, or attaches the EXISTING account
        // when it already exists — then writes users/{uid} (tenant context) and
        // the member doc in one transaction. This fixes the old client-only
        // path, which (a) couldn't write another user's users/{uid} doc under
        // the Firestore rules and (b) hard-failed on EMAIL_EXISTS, leaving the
        // staff member without workspace access.
        Gateway.provisionMember({
            email: email,
            displayName: displayName || "",
            password: password,
            role: safeRole
        }, function(ok, data) {
            if (!ok || !data || !data.ok) {
                var reason = data && data.error ? data.error : "unknown"
                // The staff RECORD is already saved (StaffStore added it before
                // this call). When login provisioning is simply unavailable
                // (no deployed Cloud Function yet), that's not a failure of the
                // add — surface it as a soft, non-blocking notice so the user
                // sees the member was added and that login access will follow.
                if (reason === "provisioning-unavailable") {
                    memberOperationSucceeded("Staff added. " + _provisionErrorMessage(reason))
                    return
                }
                authFailed("Failed to create staff credentials: " + _provisionErrorMessage(reason))
                return
            }
            // Stamp the auth uid back on the staff record so a later delete can
            // cascade to users/{uid} + members/{uid}.
            if (staffId && staffId.length > 0 && data.uid)
                StaffStore.setAppUid(staffId, data.uid)
            loadTenantMembers()
            var verb = data.created ? "created" : "linked"
            memberOperationSucceeded("Staff credentials " + verb + " for " + email)
        })
    }

    // Map a provisionMember error code to a user-facing message.
    function _provisionErrorMessage(code) {
        switch (code) {
        case "password-required":
            return "this email needs a password (min 6 characters) to create a login."
        case "user-not-found":
            return "no account exists for that user."
        case "role-not-allowed":
        case "not-authorized":
            return "you don't have permission to assign that role."
        case "no-tenant-context":
            return "your workspace context is missing — sign in again."
        case "not-signed-in":
            return "you're not signed in."
        case "provisioning-unavailable":
            return "Login access will be enabled once the server is set up."
        default:
            return "please try again."
        }
    }

    function signOut() {
        profileResolved = true
        onboardingNeeded = false
        AuthStore.clear()
        AuthStore.saveSession()
        // Clear activity log to prevent cross-tenant data leakage. The log is
        // an in-memory singleton with no tenant filtering — purging on sign-out
        // is the only way to prevent Tenant A's activities from appearing in
        // Tenant B's session.
        ActivityLog.clear()
        signedOut()
    }

    // Remove the current user from the active tenant's members collection,
    // then sign them out. Their `users/{uid}` document is intentionally left
    // alone — that record may carry ownership of other tenants. Owners cannot
    // self-leave (would orphan the workspace).
    function leaveCurrentTenant() {
        if (!AuthStore.isAuthenticated || !AuthStore.uid) {
            authFailed("Not authenticated")
            return
        }
        if (!AuthStore.tenantId || AuthStore.tenantId.length === 0) {
            authFailed("No active workspace")
            return
        }
        if (AuthStore.role === "owner") {
            authFailed("Owner cannot leave their own workspace")
            return
        }
        var tid = AuthStore.tenantId
        var uid = AuthStore.uid

        // Clear the tenant pointer on the user's OWN doc FIRST. Removing only
        // the member doc isn't enough: _loadUserProfile reads tenantId/role
        // from users/{uid} on the next login and would walk straight back into
        // the (now membership-less) workspace — showing no data. We read-modify
        // -write so other fields (and other-tenant ownership) are preserved.
        FirebaseService.get("users/" + uid, function(okGet, userDoc) {
            var doc = (okGet && userDoc) ? userDoc : {}
            doc.tenantId = ""
            doc.tenantName = ""
            doc.role = ""
            if (Array.isArray(doc.tenants))
                doc.tenants = doc.tenants.filter(function(t) { return t !== tid })
            doc.lastUpdatedAt = new Date().toISOString()

            FirebaseService.put("users/" + uid, doc, function(okUser) {
                if (!okUser) {
                    authFailed("Failed to leave workspace")
                    return
                }
                // Then remove the membership (rules allow self-delete of a
                // non-owner membership). Sign out regardless of this result —
                // the user doc no longer points here, so the workspace is left.
                FirebaseService.remove("tenants/" + tid + "/members/" + uid, function() {
                    signOut()
                })
            })
        })
    }

    // Cascade-cleanup for a staff member that had app-login credentials.
    // Deletes Firestore docs only — the Firebase Auth user account itself
    // requires Admin SDK / Cloud Function to remove.
    // TODO: trigger a Cloud Function from here to delete the auth account.
    function cleanupStaffAuthDocs(uid) {
        if (!uid || uid.length === 0) return
        if (!AuthStore.tenantId || AuthStore.tenantId.length === 0) return
        FirebaseService.remove("tenants/" + AuthStore.tenantId + "/members/" + uid, function(okMember) {
            if (!okMember) console.warn("[AuthService] Failed to remove member doc for", uid)
        })
        FirebaseService.remove("users/" + uid, function(okUser) {
            if (!okUser) console.warn("[AuthService] Failed to remove user doc for", uid)
        })
    }

    function updateUserProfile(phone, address, city, country, postalCode, tenantName) {
        if (!AuthStore.isAuthenticated || !AuthStore.uid) {
            authFailed("Not authenticated")
            return
        }

        var profileUpdate = {
            phone: phone || AuthStore.phone,
            address: address || AuthStore.address,
            city: city || AuthStore.city,
            country: country || AuthStore.country,
            postalCode: postalCode || AuthStore.postalCode,
            lastUpdatedAt: new Date().toISOString(),
            tenantName: tenantName
        }

        FirebaseService.get("users/" + AuthStore.uid, function(ok, existingUser) {
            if (!ok || !existingUser) {
                authFailed("User profile not found")
                return
            }

            var updatedDoc = existingUser
            updatedDoc.phone = phone || existingUser.phone
            updatedDoc.address = address || existingUser.address
            updatedDoc.city = city || existingUser.city
            updatedDoc.country = country || existingUser.country
            updatedDoc.postalCode = postalCode || existingUser.postalCode
            updatedDoc.lastUpdatedAt = new Date().toISOString()
            updatedDoc.tenantName = tenantName

            FirebaseService.put("users/" + AuthStore.uid, updatedDoc, function(ok) {
                if (!ok) {
                    authFailed("Failed to update profile")
                    return
                }
                AuthStore.updateProfile(profileUpdate)
                profileUpdated()
            })
        })
    }
    function updateTenantName(tenantName) {
        FirebaseService.get("tenants/" + AuthStore.tenantId, function(ok, tenantDoc) {
            if (!ok) {
                authFailed("Failed to get tenant info")
                return
            }
            var doc = {
                tenantId: tenantDoc.tenantId,
                name: tenantName,
                ownerId: tenantDoc.uid,
                plan: tenantDoc.plan,
                createdAt: tenantDoc.createdAt,
                updatedAt: new Date().toISOString()
            }
            console.log(" =========== doc: ", JSON.stringify(doc))
            FirebaseService.put("tenants/" + AuthStore.tenantId, doc, function(ok) {
                if (!ok) {
                    console.log(" =========== failed")
                    authFailed("Failed to update tenant name")
                    return
                }
                console.log(" =========== passed")
            })
        })
    }
}
