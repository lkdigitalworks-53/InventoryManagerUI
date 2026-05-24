pragma Singleton

import QtQuick

QtObject {
    readonly property var emailRegex: /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/

    function validateEmail(value) {
        if (!value || value.length === 0)
            return "Email is required"
        if (!emailRegex.test(value.trim()))
            return "Enter a valid email address"
        return ""
    }

    function validateRequired(value, label, minLen) {
        var minimum = minLen || 1
        if (!value || value.trim().length < minimum)
            return (label || "Field") + " is required"
        return ""
    }

    // Returns { error, score (0..4), label }
    function validatePassword(value, minLen) {
        var minimum = minLen || 6
        var result = { error: "", score: 0, label: "Too short" }
        if (!value || value.length === 0) {
            result.error = "Password is required"
            return result
        }
        if (value.length < minimum) {
            result.error = "Password must be at least " + minimum + " characters"
            return result
        }

        var classes = 0
        if (/[a-z]/.test(value)) classes++
        if (/[A-Z]/.test(value)) classes++
        if (/[0-9]/.test(value)) classes++
        if (/[^A-Za-z0-9]/.test(value)) classes++

        if (value.length >= 12 && classes >= 3) {
            result.score = 4; result.label = "Strong"
        } else if (value.length >= 10 && classes >= 3) {
            result.score = 3; result.label = "Good"
        } else if (value.length >= 8 && classes >= 2) {
            result.score = 2; result.label = "Fair"
        } else {
            result.score = 1; result.label = "Weak"
        }
        return result
    }

    function validateConfirm(password, confirm) {
        if (!confirm || confirm.length === 0)
            return "Confirm your password"
        if (password !== confirm)
            return "Passwords do not match"
        return ""
    }
}
