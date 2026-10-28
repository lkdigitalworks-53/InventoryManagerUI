const fs = require('fs'), cp = require('child_process'), path = require('path');
const os = require('os');
const SP = fs.mkdtempSync(path.join(os.tmpdir(), 'access-state-mut-'));
const SHIM = path.join(__dirname, 'qtest-shim.cjs');
// Usage (from the repo root): node scripts/probes/access-state-mutants.cjs
// Every mutant of qml/helper/AccessState.js must turn tests/tst_AccessState.qml red (run by the shim).
// Known equivalent mutant: dropping `doc === null` in classify (null.status throws, the catch returns
// the same `unverified`); the explicit check stays for readability and to avoid exception-driven flow.
const src = fs.readFileSync('qml/helper/AccessState.js', 'utf8');
const M = [
  // roles
  ['["owner", "admin", "manager", "staff"]', '["owner", "admin", "manager", "staff", "viewer"]'],
  ['["owner", "admin", "manager", "staff"]', '["owner", "admin", "manager"]'],
  ['return VALID_ROLES.indexOf(role) >= 0', 'return typeof role === "string"'],
  ['return VALID_ROLES.indexOf(role) >= 0', 'return VALID_ROLES.indexOf(role) > 0'],
  ['return VALID_ROLES.indexOf(role) >= 0', 'return VALID_ROLES.indexOf(String(role)) >= 0'],
  // blocked states
  ['state === STATE_REMOVED || state === STATE_SUSPENDED\n        || state === STATE_ROLE || state === STATE_UNVERIFIED', 'state === STATE_REMOVED || state === STATE_SUSPENDED\n        || state === STATE_ROLE'],
  ['state === STATE_REMOVED || state === STATE_SUSPENDED\n        || state === STATE_ROLE || state === STATE_UNVERIFIED', 'state === STATE_SUSPENDED\n        || state === STATE_ROLE || state === STATE_UNVERIFIED'],
  // classify
  ['if (status === 404) return { state: STATE_REMOVED }', ''],
  ['if (status === 404) return { state: STATE_REMOVED }', 'if (status === 403) return { state: STATE_REMOVED }'],
  ['if (status === 404) return { state: STATE_REMOVED }', 'if (status == 404) return { state: STATE_REMOVED }'],
  ['if (ok !== true) return', 'if (!ok) return'],
  ['if (ok !== true) return', 'if (false) return'],
  ['doc === null || typeof doc !== "object" || Array.isArray(doc)', 'typeof doc !== "object" || Array.isArray(doc)'],
  ['doc === null || typeof doc !== "object" || Array.isArray(doc)', 'doc === null || Array.isArray(doc)'],
  ['doc === null || typeof doc !== "object" || Array.isArray(doc)', 'doc === null || typeof doc !== "object"'],
  ['if (doc.status !== "active")', 'if (doc.status != "active")'],
  ['if (doc.status !== "active")', 'if (!doc.status)'],
  ['if (doc.status !== "active")', 'if (doc.status === "suspended")'],
  ['if (!isValidRole(doc.role)) return { state: STATE_ROLE }', ''],
  ['return { state: STATE_OK, role: doc.role }', 'return { state: STATE_OK, role: "staff" }'],
  ['return { state: STATE_OK, role: doc.role }', 'return { state: STATE_OK }'],
  ['} catch (e) {\n        return { state: STATE_UNVERIFIED }', '} catch (e) {\n        return { state: STATE_OK, role: "owner" }'],
  // outcome
  ['state === STATE_OK && isValidRole(cls.role)', 'state === STATE_OK'],
  ['state === STATE_OK && isValidRole(cls.role)', 'isValidRole(cls.role)'],
  ['return { action: "enter", role: cls.role, verified: true }', 'return { action: "enter", role: cls.role, verified: false }'],
  ['return { action: "enter", role: cls.role, verified: true }', 'return { action: "enter", role: heldRole, verified: true }'],
  ['if (state === STATE_REMOVED || state === STATE_SUSPENDED || state === STATE_ROLE)\n        return { action: "block", reason: state }', ''],
  ['state === STATE_REMOVED || state === STATE_SUSPENDED || state === STATE_ROLE)', 'state === STATE_REMOVED || state === STATE_SUSPENDED)'],
  ['state === STATE_REMOVED || state === STATE_SUSPENDED || state === STATE_ROLE)', 'state === STATE_REMOVED || state === STATE_ROLE)'],
  ['return { action: "block", reason: state }', 'return { action: "block", reason: STATE_UNVERIFIED }'],
  ['if (isValidRole(heldRole)) return { action: "enter", role: heldRole, verified: false }', ''],
  ['if (isValidRole(heldRole)) return { action: "enter", role: heldRole, verified: false }', 'if (heldRole) return { action: "enter", role: heldRole, verified: false }'],
  ['role: heldRole, verified: false }', 'role: heldRole, verified: true }'],
  ['return { action: "block", reason: STATE_UNVERIFIED }\n}', 'return { action: "enter", role: "staff", verified: false }\n}'],
  ['(cls && typeof cls === "object") ? cls.state : ""', 'cls.state'],
  // copy
  ['var MAX_NAME = 60', 'var MAX_NAME = 61'], ['var MAX_NAME = 60', 'var MAX_NAME = 59'],
  ['var FALLBACK_NAME = "this shop"', 'var FALLBACK_NAME = "the shop"'],
  ['if (typeof name !== "string") return FALLBACK_NAME', 'if (!name) return FALLBACK_NAME'],
  ['.replace(/[\\u0000-\\u001f\\u007f]+/g, " ")', ''],
  ['.replace(/\\s+/g, " ")', ''],
  ['.trim()\n    if (s.length === 0)', '\n    if (s.length === 0)'],
  ['if (s.length === 0) return FALLBACK_NAME', ''],
  ['s.length > MAX_NAME ?', 's.length >= MAX_NAME ?'],
  ['s.slice(0, MAX_NAME - 1).trim() + "\\u2026"', 's.slice(0, MAX_NAME)'],
  ['title: "Your access was removed"', 'title: "Your access is removed"'],
  ['"You are no longer a member of "', '"You are not a member of "'],
  [' + " Ask the shop owner to add you again."', ''],
  ['title: "Your access is suspended"', 'title: "Your access was suspended"'],
  ['is suspended or inactive. You cannot see or change shop data until the shop owner or an admin restores it. "', 'is suspended. You cannot see or change shop data until the shop owner or an admin restores it. "'],
  ['title: "Your role is not valid"', 'title: "Your role is invalid"'],
  ['Ask the shop owner or an admin to fix your role.', 'Ask the shop owner.'],
  ['title: "Could not check your access"', 'title: "Could not verify your access"'],
  ['Check your internet connection and try again.', 'Try again.'],
  ['var KEPT = "Changes that were not sent yet stay on this phone until you sign out."', 'var KEPT = ""'],
  ['return { title: "", body: "" }', 'return { title: "Error", body: "" }'],
];
let killed = 0, survived = [];
M.forEach(([a, b], i) => {
  if (!src.includes(a)) { console.log('VACUOUS mutant', i, JSON.stringify(a)); survived.push(`${i}: vacuous`); return; }
  const f = path.join(SP, 'mut.js'); fs.writeFileSync(f, src.replace(a, b));
  const r = cp.spawnSync('node', [SHIM, 'tests/tst_AccessState.qml', f, 'AS']);
  if (r.status !== 0) killed++; else survived.push(`${i}: ${JSON.stringify(a)} -> ${JSON.stringify(b)}`);
});
console.log(`mutants killed ${killed}/${M.length}`); survived.forEach(s => console.log('  SURVIVED', s));
const rest = survived.filter(x => !/doc === null/.test(x));
process.exit(rest.length ? 1 : 0);
