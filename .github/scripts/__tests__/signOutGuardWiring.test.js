'use strict';

// Main.qml, SignOutSheet.qml and BottomSheet.qml cannot be instantiated under qmltestrunner
// (Felgo, no App context), so the sign-out guard's wiring is pinned here by reading the source.
// The decisions themselves live in qml/helper/SignOutGuard.js and are tested in
// tests/tst_SignOutGuard.qml.
//
// Three kinds of rule:
//   1. Routing: every UI path to sign out / leave goes through app.askLeave, and the list of
//      signOut() call sites is exactly the two known ones, so a NEW caller fails CI instead of
//      silently skipping the warning.
//   2. Sheet: Stay is the easy choice, the double-tap guard on the destructive button, the live
//      bindings, the title that follows the live count.
//   3. Store contract: QML does not fail at load when a singleton member is missing (it reads as
//      undefined), so a renamed OutboxStore.revision would leave the sheet silently stale.
//      Each member the sheet and the helper read is checked to exist.
// Design: docs/superpowers/specs/2026-10-26-signout-guard-design.md
// Plan:   docs/superpowers/test-plans/2026-10-26-signout-guard-test-plan.md

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '..', '..', '..');
const read = (...p) => fs.readFileSync(path.join(REPO, ...p), 'utf8');

// Body of `function <name>(...) { ... }` by brace matching; '' when absent.
function bodyOf(src, name) {
  const at = src.indexOf(`function ${name}(`);
  if (at < 0) return '';
  const open = src.indexOf('{', at);
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++;
    if (src[i] === '}' && --depth === 0) return src.slice(open + 1, i);
  }
  return '';
}

// Source with // comments removed, so prose that mentions a call cannot satisfy a rule.
const code = (src) => src.split('\n').map((l) => l.replace(/\/\/.*$/, '')).join('\n');

// Relative path -> source for every .qml / .js under qml/ (and any extra files a test injects).
function walk(dir, out) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) walk(full, out);
    else if (/\.(qml|js)$/.test(e.name)) out[path.relative(REPO, full).split(path.sep).join('/')] = fs.readFileSync(full, 'utf8');
  }
  return out;
}

// Files (sorted, one entry per hit) that call signOut(). Comments and the definition are skipped.
function signOutCallSites(files) {
  const hits = [];
  for (const [rel, src] of Object.entries(files)) {
    for (const line of src.split('\n')) {
      const code = line.replace(/\/\/.*$/, '');
      if (/function signOut\(/.test(code)) continue;
      if (/\bsignOut\(/.test(code)) hits.push(rel);
    }
  }
  return hits.sort();
}

// Every occurrence of `needle` in `src` must sit inside a `proceed: function() {` closure that
// opens on the same line or within the 160 characters before it.
function allInsideProceed(src, needle) {
  let at = src.indexOf(needle);
  if (at < 0) return false;
  while (at >= 0) {
    if (!/proceed:\s*function\(\)/.test(src.slice(Math.max(0, at - 160), at))) return false;
    at = src.indexOf(needle, at + needle.length);
  }
  return true;
}

// Returns the list of broken wiring rules (empty = wired). `s` = sources by key.
function problems(s) {
  const out = [];
  const main = s.main;
  const sheet = s.sheet;

  // ---- routing (Main.qml) ----
  if (!/SignOutSheet\s*\{\s*id:\s*signOutSheet\s*\}/.test(main)) out.push('sheet-declared');
  const ask = code(bodyOf(main, 'askLeave'));
  const first = ask.split('\n').map((l) => l.trim()).find((l) => l.length > 0) || '';
  if (first !== 'if (signOutSheet.pendingCount() > 0) {') out.push('askLeave-pending-first');
  if (!ask.includes('signOutSheet.ask({ leaving: opts.leaving === true, proceed: opts.proceed })')) out.push('askLeave-sheet-ask');
  if (!/else if \(opts\.title\)/.test(ask) || !/onConfirm: opts\.proceed/.test(ask)) out.push('askLeave-plain-confirm');
  if (!/else \{\s*opts\.proceed\(\)\s*\}/.test(ask)) out.push('askLeave-no-title-proceeds');
  if (!/var dialogs = \[signOutSheet,/.test(main)) out.push('back-list-first');
  if (/confirmDlg\.ask\(\{\s*title:\s*(qsTr\()?"(Sign out\?|Leave workspace\?)"/.test(main)) out.push('no-direct-confirm');
  if (!/onSignOutRequested:\s*\{[^}]*?app\.askLeave\(\{\s*title:\s*"Sign out\?"/s.test(main)) out.push('entry-profile-signout');
  if (!/onLeaveWorkspaceRequested:\s*\{[^}]*?app\.askLeave\(\{\s*leaving:\s*true,/s.test(main)) out.push('entry-leave');
  if (!/onSignOutRequested:\s*app\.askLeave\(\{\s*proceed:\s*function\(\)\s*\{\s*logic\.signOutRequested\(\)\s*\}\s*\}\)/.test(main)) out.push('entry-tenant-setup');
  if (!allInsideProceed(main, 'logic.signOutRequested()')) out.push('signout-only-in-proceed');
  if (!allInsideProceed(main, 'AuthService.leaveCurrentTenant()')) out.push('leave-only-in-proceed');
  const cleared = code(bodyOf(main, 'onSignedOut'));
  if (!cleared.includes('Gateway.clear()') || !cleared.includes('PhotoQueue.clear()')) out.push('premise-onSignedOut-clears-queues');

  // ---- every signOut() caller is known ----
  const sites = signOutCallSites(s.files);
  if (JSON.stringify(sites) !== JSON.stringify(['qml/Main.qml', 'qml/model/AuthService.qml'])) out.push('signout-call-sites');
  if (s.native.some((src) => /signOut/.test(src))) out.push('native-signout');

  // ---- sheet ----
  if (!sheet.includes('import "../helper/SignOutGuard.js" as SignOutGuard')) out.push('sheet-import');
  if (!/property int _outboxWatcher: OutboxStore\.revision/.test(sheet)) out.push('watch-outbox-revision');
  if (!/property int _inFlightWatcher: OutboxStore\.inFlightCount/.test(sheet)) out.push('watch-inflight');
  if (!/property int _photoWatcher: PhotoQueue\.revision/.test(sheet)) out.push('watch-photo-revision');
  if (!/secondaryColor: Constants\.danger/.test(sheet)) out.push('secondary-red');
  if (!/onPrimaryClicked: close\(\)/.test(sheet)) out.push('primary-is-stay');
  if (!/onClosed: root\._proceed = null/.test(sheet)) out.push('closed-drops-proceed');
  if (!/onSecondaryClicked:\s*\{\s*var go = root\._proceed\s*root\._proceed = null\s*if \(go\) go\(\)\s*\}/.test(sheet)) out.push('double-tap-guard');
  if (!/sheetTitle: root\._guard\.count > 0/.test(sheet)) out.push('title-follows-count');
  if (!/secondaryAction: root\._guard\.count > 0/.test(sheet)) out.push('button-follows-count');
  if (!/Accessible\.name: row\.modelData\.title \+ " " \+ row\.modelData\.detail \+ " " \+ row\.modelData\.stateLabel/.test(sheet)) out.push('row-accessible-name');
  if (!/text: row\.modelData\.stateLabel/.test(sheet)) out.push('state-in-words');

  // ---- BottomSheet ----
  if (!/property color secondaryColor: Constants\.textPrimary/.test(s.bottom)) out.push('bottom-default-colour');
  if (!/textColor: root\.secondaryColor/.test(s.bottom)) out.push('bottom-binds-colour');

  // ---- BottomSheet footer floor (PR #167 device test: "Stay signed in" showed as "S...") ----
  // PrimaryButton reports no label width, so the footer gives the primary button a floor of its own
  // label width (SheetFooter.primaryFloor). The pieces below must stay together: the import, the
  // inputs, both Layout properties, and TextMetrics measuring the font PrimaryButton really draws.
  const bottom = code(s.bottom);
  if (!bottom.includes('import "../helper/SheetFooter.js" as SheetFooter')) out.push('footer-import');
  if (!/SheetFooter\.primaryFloor\(\s*primaryMetrics\.advanceWidth,\s*primaryButton\.leftPadding \+ primaryButton\.rightPadding,\s*footerRow\.width\)/.test(bottom)) out.push('footer-floor-inputs');
  if (!/PrimaryButton \{\s*id: primaryButton[^}]*?Layout\.minimumWidth: root\._primaryFloor/s.test(bottom)) out.push('footer-floor-min');
  if (!/PrimaryButton \{\s*id: primaryButton[^}]*?Layout\.preferredWidth: root\._primaryFloor/s.test(bottom)) out.push('footer-floor-preferred');
  if (!/RowLayout \{\s*id: footerRow\b/.test(bottom)) out.push('footer-row-id');
  const fontOf = (m) => (m ? `${(/font\.pixelSize:\s*([^\n]+)/.exec(m[1]) || [])[1]}|${/font\.bold:\s*true/.test(m[1])}` : '');
  const metrics = /TextMetrics \{([^}]*)\}/.exec(bottom);
  const drawn = /id: titleText([^}]*)\}/.exec(code(s.primary));
  if (!metrics || !drawn || !/^sp\(.*\)\|true$/.test(fontOf(metrics)) || fontOf(metrics) !== fontOf(drawn)) out.push('footer-metrics-font');
  if (!metrics || !/text: root\.primaryAction/.test(metrics[1])) out.push('footer-metrics-text');
  if (!/^\.pragma library/.test(s.footer)) out.push('footer-lib');
  if (!/function primaryFloor\(labelWidth, padding, rowWidth\)/.test(s.footer)) out.push('footer-signature');

  // ---- store contract (a missing singleton member reads as undefined at runtime, no load error) ----
  if (!/property int revision: 0/.test(s.outbox)) out.push('store-outbox-revision');
  if (!/readonly property int inFlightCount:/.test(s.outbox)) out.push('store-outbox-inFlightCount');
  if (!/function isInFlight\(requestId\)/.test(s.outbox)) out.push('store-outbox-isInFlight');
  if (!/property var items: \[\]/.test(s.outbox)) out.push('store-outbox-items');
  if (!/property int revision: 0/.test(s.photo)) out.push('store-photo-revision');
  if (!/property var items: \[\]/.test(s.photo)) out.push('store-photo-items');
  if (!/function getById\(productId\)/.test(s.inventory)) out.push('store-inventory-getById');
  if (!/opType: call\.opType,/.test(s.outbox) || !/ops: call\.ops \|\| \[\],/.test(s.outbox)) out.push('store-outbox-item-shape');
  for (const st of ['enqueued', 'uploading', 'retrying', 'failed']) {
    if (!s.photo.includes(`"${st}"`)) out.push(`store-photo-state-${st}`);
  }
  if (!/function isParkedItem\(it\)/.test(s.stuck)) out.push('store-stuck-isParkedItem');
  return out;
}

function sources() {
  const files = walk(path.join(REPO, 'qml'), {});
  const native = [];
  for (const dir of ['src']) {
    const full = path.join(REPO, dir);
    if (!fs.existsSync(full)) continue;
    for (const e of fs.readdirSync(full, { withFileTypes: true })) {
      if (e.isFile() && /\.(cpp|h|mm)$/.test(e.name)) native.push(fs.readFileSync(path.join(full, e.name), 'utf8'));
    }
  }
  native.push(read('main.cpp'));
  return {
    main: read('qml', 'Main.qml'),
    sheet: read('qml', 'pages', 'SignOutSheet.qml'),
    bottom: read('qml', 'components', 'BottomSheet.qml'),
    primary: read('qml', 'components', 'PrimaryButton.qml'),
    footer: read('qml', 'helper', 'SheetFooter.js'),
    outbox: read('qml', 'model', 'OutboxStore.qml'),
    photo: read('qml', 'model', 'PhotoQueue.qml'),
    inventory: read('qml', 'model', 'InventoryStore.qml'),
    stuck: read('qml', 'helper', 'StuckWrites.js'),
    files,
    native,
  };
}

const real = sources();

// ---- happy ----
test('happy: the real sources have every piece of the sign-out guard wiring', () => {
  assert.deepEqual(problems(real), []);
});

test('happy: the helper is a QML library and the sheet is built from BottomSheet', () => {
  const helper = read('qml', 'helper', 'SignOutGuard.js');
  assert.ok(helper.startsWith('.pragma library'));
  assert.match(real.sheet, /\nBottomSheet \{\s*\n\s*id: root/);
});

test('happy: the call-site scan finds exactly Main.qml and AuthService.qml', () => {
  assert.deepEqual(signOutCallSites(real.files), ['qml/Main.qml', 'qml/model/AuthService.qml']);
});

test('happy: the three helpers the sheet reads are in the helper imports of SignOutGuard.js', () => {
  const helper = read('qml', 'helper', 'SignOutGuard.js');
  assert.match(helper, /\.import "DescribeItem\.js" as DescribeItem/);
  assert.match(helper, /\.import "StuckWrites\.js" as StuckWrites/);
});

// ---- negative: a new caller is reported ----
test('negative: a new page that calls signOut() directly is reported', () => {
  const files = Object.assign({}, real.files, {
    'qml/pages/Evil.qml': 'Item { onClicked: AuthService.signOut() }\n',
  });
  assert.deepEqual(problems(Object.assign({}, real, { files })), ['signout-call-sites']);
});

test('negative: a comment that mentions signOut() is not a call site', () => {
  const files = Object.assign({}, real.files, {
    'qml/pages/Doc.qml': '// never call AuthService.signOut() from here\nItem {}\n',
  });
  assert.deepEqual(problems(Object.assign({}, real, { files })), []);
});

test('negative: a missing call site (Main.qml no longer signs out) is reported', () => {
  const files = Object.assign({}, real.files);
  files['qml/Main.qml'] = files['qml/Main.qml'].replace('AuthService.signOut()', 'void 0');
  assert.deepEqual(problems(Object.assign({}, real, { files })), ['signout-call-sites']);
});

test('negative: native code that signs out is reported', () => {
  assert.deepEqual(problems(Object.assign({}, real, { native: ['void f() { signOut(); }'] })), ['native-signout']);
});

// ---- negative: each rule fires when its text is changed ----
// [file key, rule, from, to]. `from` must exist in the real source, so no mutant is vacuous.
const MUTANTS = [
  ['main', 'sheet-declared', 'SignOutSheet { id: signOutSheet }', 'Item { id: signOutSheet }'],
  ['main', 'askLeave-pending-first', 'if (signOutSheet.pendingCount() > 0) {', 'if (false) {'],
  ['main', 'askLeave-sheet-ask', 'signOutSheet.ask({ leaving: opts.leaving === true, proceed: opts.proceed })', 'signOutSheet.ask({})'],
  ['main', 'askLeave-plain-confirm', 'onConfirm: opts.proceed })', 'onConfirm: function() {} })'],
  ['main', 'askLeave-no-title-proceeds', '} else {\n            opts.proceed()\n        }', '} else {\n        }'],
  ['main', 'back-list-first', 'var dialogs = [signOutSheet, ', 'var dialogs = ['],
  ['main', 'no-direct-confirm', 'app.askLeave({\n                title: "Sign out?",', 'confirmDlg.ask({\n                title: "Sign out?",'],
  ['main', 'entry-leave', 'app.askLeave({\n                leaving: true,', 'app.askLeave({\n                leaving: false,'],
  ['main', 'entry-tenant-setup', 'onSignOutRequested: app.askLeave({ proceed: function() { logic.signOutRequested() } })', 'onSignOutRequested: logic.signOutRequested()'],
  ['main', 'premise-onSignedOut-clears-queues', '            PhotoQueue.clear()\n', ''],
  ['sheet', 'sheet-import', 'import "../helper/SignOutGuard.js" as SignOutGuard', ''],
  ['sheet', 'watch-outbox-revision', 'property int _outboxWatcher: OutboxStore.revision', 'property int _outboxWatcher: 0'],
  ['sheet', 'watch-inflight', 'property int _inFlightWatcher: OutboxStore.inFlightCount', 'property int _inFlightWatcher: 0'],
  ['sheet', 'watch-photo-revision', 'property int _photoWatcher: PhotoQueue.revision', 'property int _photoWatcher: 0'],
  ['sheet', 'secondary-red', 'secondaryColor: Constants.danger', 'secondaryColor: Constants.textPrimary'],
  ['sheet', 'primary-is-stay', 'onPrimaryClicked: close()', 'onPrimaryClicked: root._proceed()'],
  ['sheet', 'closed-drops-proceed', 'onClosed: root._proceed = null', 'onClosed: {}'],
  ['sheet', 'double-tap-guard', '        root._proceed = null\n        if (go) go()', '        if (go) go()'],
  ['sheet', 'title-follows-count', 'sheetTitle: root._guard.count > 0', 'sheetTitle: true'],
  ['sheet', 'button-follows-count', 'secondaryAction: root._guard.count > 0', 'secondaryAction: true'],
  ['sheet', 'state-in-words', 'text: row.modelData.stateLabel', 'text: ""'],
  ['bottom', 'bottom-default-colour', 'property color secondaryColor: Constants.textPrimary', 'property color secondaryColor: Constants.danger'],
  ['bottom', 'bottom-binds-colour', 'textColor: root.secondaryColor', 'textColor: Constants.textPrimary'],
  ['bottom', 'footer-import', 'import "../helper/SheetFooter.js" as SheetFooter', ''],
  ['bottom', 'footer-floor-inputs', 'primaryMetrics.advanceWidth, primaryButton', 'primaryMetrics.width, primaryButton'],
  ['bottom', 'footer-floor-inputs', 'primaryButton.leftPadding + primaryButton.rightPadding', 'primaryButton.leftPadding'],
  ['bottom', 'footer-floor-inputs', ', footerRow.width)', ', width)'],
  ['bottom', 'footer-floor-min', 'Layout.minimumWidth: root._primaryFloor', 'Layout.minimumWidth: 0'],
  ['bottom', 'footer-floor-preferred', 'Layout.preferredWidth: root._primaryFloor', 'Layout.preferredWidth: 0'],
  ['bottom', 'footer-row-id', 'id: footerRow', 'id: footerRow2'],
  ['bottom', 'footer-metrics-font', 'font.pixelSize: sp(Constants.fsBodyLg)\n            font.bold: true\n            text: root.primaryAction', 'font.pixelSize: sp(Constants.fsBody)\n            font.bold: true\n            text: root.primaryAction'],
  ['bottom', 'footer-metrics-font', 'font.pixelSize: sp(Constants.fsBodyLg)\n            font.bold: true\n            text: root.primaryAction', 'font.pixelSize: sp(Constants.fsBodyLg)\n            text: root.primaryAction'],
  ['bottom', 'footer-metrics-text', 'text: root.primaryAction\n        }\n\n        ColumnLayout', 'text: root.secondaryAction\n        }\n\n        ColumnLayout'],
  ['primary', 'footer-metrics-font', 'font.pixelSize: sp(Constants.fsBodyLg)', 'font.pixelSize: sp(Constants.fsBody)'],
  ['primary', 'footer-metrics-font', 'font.bold: true\n            elide: Text.ElideRight', 'elide: Text.ElideRight'],
  ['footer', 'footer-lib', '.pragma library', '// not a library'],
  ['footer', 'footer-signature', 'function primaryFloor(labelWidth, padding, rowWidth)', 'function primaryFloor(labelWidth, padding)'],
  ['outbox', 'store-outbox-revision', 'property int revision: 0', 'property int rev: 0'],
  ['outbox', 'store-outbox-inFlightCount', 'readonly property int inFlightCount:', 'readonly property int inFlight:'],
  ['outbox', 'store-outbox-isInFlight', 'function isInFlight(requestId)', 'function inFlight(requestId)'],
  ['outbox', 'store-outbox-item-shape', 'opType: call.opType,', 'type: call.opType,'],
  ['photo', 'store-photo-revision', 'property int revision: 0', 'property int rev: 0'],
  ['photo', 'store-photo-state-retrying', '"retrying"', '"backoff"'],
  ['inventory', 'store-inventory-getById', 'function getById(productId)', 'function byId(productId)'],
  ['stuck', 'store-stuck-isParkedItem', 'function isParkedItem(it)', 'function isParked2(it)'],
];

for (const [key, rule, from, to] of MUTANTS) {
  test(`negative: changing "${rule}" is reported`, () => {
    assert.ok(real[key].includes(from), `mutant text not found in ${key}: ${from}`);
    const mutated = Object.assign({}, real, { [key]: real[key].split(from).join(to) });
    assert.ok(problems(mutated).includes(rule), `${rule} not reported`);
  });
}

// ---- edge ----
test('edge: allInsideProceed rejects a direct call and accepts a closure', () => {
  assert.equal(allInsideProceed('x\nlogic.signOutRequested()', 'logic.signOutRequested()'), false);
  assert.equal(allInsideProceed('proceed: function() { logic.signOutRequested() }', 'logic.signOutRequested()'), true);
  assert.equal(allInsideProceed('nothing here', 'logic.signOutRequested()'), false);
});

test('edge: allInsideProceed checks every occurrence, not only the first', () => {
  const src = 'proceed: function() { logic.signOutRequested() }\n\n\n\n' + 'x'.repeat(200) + '\nlogic.signOutRequested()';
  assert.equal(allInsideProceed(src, 'logic.signOutRequested()'), false);
});

test('edge: bodyOf returns empty for a missing function and balances nested braces', () => {
  assert.equal(bodyOf('no functions here', 'askLeave'), '');
  assert.equal(bodyOf('function f(a) { if (a) { return 1 } return 2 } tail', 'f').trim(), 'if (a) { return 1 } return 2');
});

test('edge: a BottomSheet without the TextMetrics block is reported, not thrown on', () => {
  const noMetrics = real.bottom.replace(/\s*TextMetrics \{[^}]*\}/, '');
  assert.notEqual(noMetrics, real.bottom);
  const out = problems(Object.assign({}, real, { bottom: noMetrics }));
  assert.ok(out.includes('footer-metrics-font'));
  assert.ok(out.includes('footer-metrics-text'));
});

test('edge: prose that mentions the floor in a comment does not satisfy the rules', () => {
  const stripped = real.bottom.replace('import "../helper/SheetFooter.js" as SheetFooter', '// import "../helper/SheetFooter.js" as SheetFooter');
  assert.ok(problems(Object.assign({}, real, { bottom: stripped })).includes('footer-import'));
});

test('regression: the premise holds, PrimaryButton still has no implicit label width', () => {
  // If PrimaryButton ever reports its own label width the floor becomes redundant (harmless):
  // revisit then. Until that, the anchored Text is the reason the floor exists.
  assert.match(real.primary, /id: titleText\s*\n\s*anchors\.fill: parent/);
});

// ---- monkey: random single-token damage to Main.qml / SignOutSheet.qml is caught or harmless ----
test('monkey: deleting any one line of askLeave is reported (seeded)', () => {
  const body = bodyOf(real.main, 'askLeave');
  const lines = body.split('\n').filter((l) => l.trim().length > 0);
  // Each statement line of the chokepoint carries one rule; removing a line that holds a
  // `signOutSheet`, `opts.title` or `opts.proceed` token must be reported.
  let caught = 0;
  let relevant = 0;
  for (const line of lines) {
    if (!/signOutSheet|opts\.title|opts\.proceed|confirmDlg/.test(line)) continue;
    relevant++;
    const mutated = Object.assign({}, real, { main: real.main.replace(line, '') });
    if (problems(mutated).length > 0) caught++;
  }
  assert.ok(relevant >= 4, 'expected several rule-bearing lines');
  assert.equal(caught, relevant);
});
