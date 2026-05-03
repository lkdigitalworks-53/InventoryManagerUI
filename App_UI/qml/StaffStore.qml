pragma Singleton
import QtQuick 6.5

QtObject {
    id: root

    property var staff: [
        { staffId: "STF-001", name: "Alice Johnson",  role: "Manager",              department: "Operations", email: "alice.j@company.com",  phone: "+1 (555) 123-4567", joinDate: "2023-01-15", status: "active",   salary: 75000 },
        { staffId: "STF-002", name: "Bob Smith",      role: "Sales Representative", department: "Sales",      email: "bob.s@company.com",    phone: "+1 (555) 234-5678", joinDate: "2023-03-22", status: "active",   salary: 55000 },
        { staffId: "STF-003", name: "Carol White",    role: "Inventory Specialist",  department: "Warehouse",  email: "carol.w@company.com",  phone: "+1 (555) 345-6789", joinDate: "2023-05-10", status: "active",   salary: 48000 },
        { staffId: "STF-004", name: "David Lee",      role: "Customer Support",      department: "Support",    email: "david.l@company.com",  phone: "+1 (555) 456-7890", joinDate: "2023-07-01", status: "active",   salary: 45000 },
        { staffId: "STF-005", name: "Emma Davis",     role: "Accountant",            department: "Finance",    email: "emma.d@company.com",   phone: "+1 (555) 567-8901", joinDate: "2024-08-15", status: "active",   salary: 60000 },
        { staffId: "STF-006", name: "Frank Wilson",   role: "Sales Associate",       department: "Sales",      email: "frank.w@company.com",  phone: "+1 (555) 678-9012", joinDate: "2024-01-10", status: "on_leave", salary: 50000 }
    ]

    property var activities: [
        { text: "Frank Wilson is on leave",              time: "2 days ago",   color: "#f59e0b" },
        { text: "Emma Davis joined Finance department",  time: "3 months ago", color: "#22c55e" },
        { text: "David Lee joined Support team",         time: "5 months ago", color: "#22c55e" },
        { text: "Alice Johnson promoted to Manager",     time: "6 months ago", color: "#8b5cf6" }
    ]

    function _clone() {
        var a = [];
        for (var i = 0; i < staff.length; ++i) {
            var s = staff[i];
            a.push({ staffId: s.staffId, name: s.name, role: s.role, department: s.department,
                      email: s.email, phone: s.phone, joinDate: s.joinDate, status: s.status, salary: s.salary });
        }
        return a;
    }

    function totalStaff() { return staff.length; }

    function activeCount() {
        var c = 0;
        for (var i = 0; i < staff.length; ++i)
            if (staff[i].status === "active") c++;
        return c;
    }

    function onLeaveCount() {
        var c = 0;
        for (var i = 0; i < staff.length; ++i)
            if (staff[i].status === "on_leave") c++;
        return c;
    }

    function departments() {
        var deps = {};
        for (var i = 0; i < staff.length; ++i)
            deps[staff[i].department] = (deps[staff[i].department] || 0) + 1;
        return deps;
    }

    function departmentCount() {
        return Object.keys(departments()).length;
    }

    function departmentList() {
        var deps = departments();
        var arr = [];
        var keys = Object.keys(deps);
        for (var i = 0; i < keys.length; ++i)
            arr.push({ name: keys[i], count: deps[keys[i]] });
        return arr;
    }

    function initials(name) {
        if (!name) return "";
        var parts = name.trim().split(/\s+/);
        var result = "";
        for (var i = 0; i < Math.min(parts.length, 2); ++i)
            result += parts[i].charAt(0).toUpperCase();
        return result;
    }

    function nextStaffId() {
        var max = 0;
        for (var i = 0; i < staff.length; ++i) {
            var num = parseInt(String(staff[i].staffId).split('-')[1]);
            if (!isNaN(num) && num > max) max = num;
        }
        return 'STF-' + String(max + 1).padStart(3, '0');
    }

    function addStaff(name, email, phone, role, department, joinDate, status, salary) {
        var id = nextStaffId();
        var iso = Qt.formatDate(joinDate, 'yyyy-MM-dd');
        var arr = _clone();
        arr.push({ staffId: id, name: name, role: role, department: department,
                   email: email, phone: phone, joinDate: iso, status: status, salary: salary });
        staff = arr;

        var acts = [];
        for (var i = 0; i < activities.length; ++i)
            acts.push({ text: activities[i].text, time: activities[i].time, color: activities[i].color });
        acts.unshift({ text: name + " joined " + department + " department", time: "Just now", color: "#22c55e" });
        activities = acts;
    }
}
