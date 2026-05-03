pragma Singleton
import QtQuick 6.5

QtObject {
    id: root

    // Firebase Realtime Database REST API base URL
    readonly property string databaseUrl: "https://inventorymanager-48392-default-rtdb.asia-southeast1.firebasedatabase.app"

    // Network state
    property bool syncing: false
    property int pendingRequests: 0

    // ── Generic REST helpers using XMLHttpRequest ──

    // GET data from a Firebase path
    function get(path, callback) {
        var url = databaseUrl + "/" + path + ".json";
        var xhr = new XMLHttpRequest();
        pendingRequests++;
        syncing = true;
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            pendingRequests--;
            if (pendingRequests <= 0) { pendingRequests = 0; syncing = false; }
            if (xhr.status === 200) {
                try {
                    var data = JSON.parse(xhr.responseText);
                    callback(true, data);
                } catch(e) {
                    console.warn("[Firebase] Parse error for", path, ":", e);
                    callback(false, null);
                }
            } else {
                console.warn("[Firebase] GET failed", path, "status:", xhr.status);
                callback(false, null);
            }
        };
        xhr.open("GET", url);
        xhr.send();
    }

    // PUT (set) data at a Firebase path
    function put(path, data, callback) {
        var url = databaseUrl + "/" + path + ".json";
        var xhr = new XMLHttpRequest();
        pendingRequests++;
        syncing = true;
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            pendingRequests--;
            if (pendingRequests <= 0) { pendingRequests = 0; syncing = false; }
            var ok = xhr.status === 200;
            if (!ok) console.warn("[Firebase] PUT failed", path, "status:", xhr.status);
            if (callback) callback(ok);
        };
        xhr.open("PUT", url);
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.send(JSON.stringify(data));
    }

    // PATCH (update) data at a Firebase path
    function patch(path, data, callback) {
        var url = databaseUrl + "/" + path + ".json";
        var xhr = new XMLHttpRequest();
        pendingRequests++;
        syncing = true;
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            pendingRequests--;
            if (pendingRequests <= 0) { pendingRequests = 0; syncing = false; }
            var ok = xhr.status === 200;
            if (!ok) console.warn("[Firebase] PATCH failed", path, "status:", xhr.status);
            if (callback) callback(ok);
        };
        xhr.open("PATCH", url);
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.send(JSON.stringify(data));
    }

    // DELETE data at a Firebase path
    function remove(path, callback) {
        var url = databaseUrl + "/" + path + ".json";
        var xhr = new XMLHttpRequest();
        pendingRequests++;
        syncing = true;
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            pendingRequests--;
            if (pendingRequests <= 0) { pendingRequests = 0; syncing = false; }
            var ok = xhr.status === 200;
            if (!ok) console.warn("[Firebase] DELETE failed", path, "status:", xhr.status);
            if (callback) callback(ok);
        };
        xhr.open("DELETE", url);
        xhr.send();
    }

    // Convert Firebase object-of-objects to array
    function toArray(data) {
        if (data === undefined || data === null) return [];
        if (Array.isArray(data)) return data;
        var keys = Object.keys(data);
        var arr = [];
        for (var i = 0; i < keys.length; i++) {
            var v = data[keys[i]];
            if (v !== null && typeof v === "object") arr.push(v);
        }
        return arr;
    }
}
