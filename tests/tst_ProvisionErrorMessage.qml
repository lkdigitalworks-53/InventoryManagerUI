import QtQuick
import QtTest
import "../qml/model"

// S2f-7: provisionMember answers 409 `member-exists` when the target is already a member (it only
// adds members; changing an existing member goes through Team Members). This pins the user-facing
// text for every code the endpoint or the Gateway can return, so a new code cannot fall through to
// the generic "please try again" unnoticed.
//
// NOT RUN IN THIS SANDBOX (no Qt toolchain, project convention): CI's qml-tests job is the oracle.
TestCase {
    name: "ProvisionErrorMessage"

    function test_memberExists_pointsToTeamMembers() {
        var msg = AuthService._provisionErrorMessage("member-exists")
        verify(msg.indexOf("already on your team") >= 0, msg)
        verify(msg.indexOf("Team Members") >= 0, msg)
    }

    function test_everyKnownCodeHasItsOwnMessage() {
        var codes = ["password-required", "user-not-found", "role-not-allowed", "not-authorized",
                     "no-tenant-context", "member-exists", "not-signed-in", "provisioning-unavailable"]
        var fallback = AuthService._provisionErrorMessage("some-code-nobody-handles")
        compare(fallback, "please try again.")
        var seen = ({})
        for (var i = 0; i < codes.length; ++i) {
            var m = AuthService._provisionErrorMessage(codes[i])
            verify(m.length > 0, codes[i])
            verify(m !== fallback, codes[i] + " fell through to the default")
            verify(!seen[m] || codes[i] === "not-authorized" || codes[i] === "role-not-allowed",
                   codes[i] + " shares its text with another code")
            seen[m] = true
        }
    }

    function test_roleNotAllowedAndNotAuthorizedShareText() {
        compare(AuthService._provisionErrorMessage("role-not-allowed"), AuthService._provisionErrorMessage("not-authorized"))
    }

    function test_unknownOrEmptyCodeFallsBack() {
        compare(AuthService._provisionErrorMessage(""), "please try again.")
        compare(AuthService._provisionErrorMessage(undefined), "please try again.")
        compare(AuthService._provisionErrorMessage("unknown"), "please try again.")
    }
}
