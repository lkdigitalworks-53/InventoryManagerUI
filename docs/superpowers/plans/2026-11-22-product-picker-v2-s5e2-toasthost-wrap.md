# Product picker v2, slice S5e-2: the toast pill wraps (KNOWN-ISSUES 26)

**Date:** 2026-11-22. **Branch:** `feat/2026-11-22-picker-s5e2-toasthost-wrap`, cut from `main` @ `4217032` (#213 S5e-1 merged). **Test plan:** `test-plans/2026-11-03-product-picker-v2-test-plan.md` (S5e-2 rows, checks 151 to 160). **Carried items:** KNOWN-ISSUES 26 (closed here), the two toast notes at the top of KNOWN-ISSUES (the `y` binding, the pill over a sheet footer), new 103 to 106.

## 0. Where the roadmap stands (read from the repo and the GitHub API, 2026-11-22)
S1 to S5e-1 are merged (#185, #187, #194, #196, #200, #202, #206, #210, #213). Open PRs: #212 (NO2, the atomic-operations roadmap), #211 (docs, CA questions), #178 (deps), #39, #29: none touches the picker. Left in the picker roadmap: **S5e-2 (this)**, S5e-3 (font scale and both themes, the other unnamed buttons KI 97, KI 70 a and b), S5e-4 (curated device pass, KI 29 decided with a number). S5e-2 is the next item because S5e-1 listed it as its own PR, "with a device check", and it needs no decision from Taher to start.

## 1. The fault (source only; no build, no device)
`ToastHost.pill` was one `Text`: no `wrapMode`, no `elide`, fixed 40 dp high, width = text width capped at the layer minus 40 dp. About 40 to 44 characters fit on a 360 dp phone at 13 sp; anything longer is drawn wider than the pill and cut at both screen edges. 42 `Toast.show` calls exist; 11 literals are 80 to 134 characters (conflict, import, restore messages: "...Please re-check and re-import them.", "...restored with the latest version"). The action half of those sentences, at the end, is the half that was lost. `OrdersStore` even embeds a `\n`.

## 2. Options and decisions (defaults taken, veto in the PR)
**S5e2-D1. How does the resting position follow the taller pill?** (a) KI 26's own recipe: raise `slideUp.to` by the extra height. (b) A progress property `rise` (0 parked, 1 resting) that the slides animate; `y` is derived from it, the pill's height and the layer height (`TL.pillY`). For (a): a smaller diff. Against (a): `to` is read once, when the animation starts, and a Qt `Text` may lay itself out a frame later than the property change, so the height read at that moment can be the PREVIOUS toast's; the pill would then rest at the wrong height for the whole 5 to 10 s. I could not check Qt's timing without a build, and "cannot check" is the reason to pick the design that does not depend on it. (b) also removes the standing lead at the top of KNOWN-ISSUES (the animation fights a `y` binding when the layer changes height: keyboard, rotation), because nothing animates `y` any more and `rise` has no binding. Cost of (b): a new property, one pure function, and the existing source tests had to learn the new shape. **Taken: (b).**

**S5e2-D2. How is the pill's width known?** (a) A hidden, unwrapped copy of the text (`measure`): its `implicitWidth` is the one-line width, KI 26's own recipe. (b) One `Text` and its `contentWidth` after wrapping: no second item. (c) `TextMetrics.advanceWidth`: wrong for a message with `\n` (it adds the lines up). Against (b): whether `contentWidth` of a wrapped text is the widest line or the item width is the kind of thing I would be guessing; if it were the item width every toast would be full width, a visible regression for "Saved". The copy costs one invisible item. **Taken: (a).** The copy must never wrap or take a width (it would become a binding loop with the pill width); `TS-12` pins that.

**S5e2-D3. One-pixel slack.** `(w + pad) - pad` can come out a rounding error under `w`, and a one-line message would drop its last word to a second line for no reason. The pill is `ceil(w) + 1 + pad` wide, so the text is 1 to 2 px roomier than its own single line. `TLY-05` runs 4000 random widths and paddings to prove it.

**S5e2-D4. Wrap mode.** `Text.Wrap` (break at a space when there is one, anywhere when there is not) against `WordWrap` (spaces only): a long unbroken name or an id would overflow with `WordWrap`. **Taken: `Wrap`.**

**S5e2-D5. How many lines, and what happens past that?** Six, then an ellipsis. The longest message today is 134 characters: 4 lines at the normal font, 5 at 1.3x (`TS-15` estimates this with the real sums and a 0.52 em glyph). Four would cut it at 1.3x; unlimited lets a runaway server error text cover the screen. Cost of the cap: a very long text is cut and the visible text is no longer the whole message (TalkBack should still read the whole `text`, device check 157). Past 2.0x font scale a 134-character message needs 7 lines and loses its end: written down, KNOWN-ISSUES 103. **Taken: 6.**

**S5e2-D6. Reading time.** A fixed 5 s was set for one short line. Four lines in 5 s is faster than people read, and the wrapped text is only useful if it can be read. `dismissMs` = 2000 ms + 60 ms per character, never under 5000 and never over 10000: 44 characters or fewer stay at 5 s, 80 characters 6.8 s, 134 characters 10 s. Against: a toast that stays 10 s covers more of a sheet's footer (the standing note at the top of KNOWN-ISSUES) and cannot be dismissed (KNOWN-ISSUES 104). Alternatives: keep 5 s (cuts the reading time of the very messages this slice fixes), or a flat 8 s for everything (slows the short ones for no reason). **Taken: scaled, one constant to change if you dislike it.**

**S5e2-D7. Which way does a taller pill grow?** Upward, bottom edge fixed where it was (70 dp above the layer bottom). Growing downward would push it into the tab bar. `TLY-10` pins that a one-line pill rests exactly where it did before (`layer height - 110 dp` for its top edge); `TLY-11` pins the bottom edge for every height.

**S5e2-D8. What stays as it was.** The pill's look (colour, radius, font, fade), its position policy (110 dp clearance), the Overlay move (PR #190, 2026-11-09), `Toast.show` and its 42 callers, and the S3 `skippedNote` shortening in `NewOrderPicker.js` (tested, names cut at 12; it can now be longer, KNOWN-ISSUES 105, but changing it is a feature, not this slice). Only that file's stale comment ("one line that does not wrap") is updated.

## 3. Scope
In: `qml/helper/ToastLayout.js` (new, pure), `qml/components/ToastHost.qml`, one comment in `qml/helper/NewOrderPicker.js`. Tests: `functions/test/toastLayout.test.js` (+ derived twin `tests/tst_ToastLayout.qml`, registered in `pickerTwin.js`), `functions/test/toastHostLayer.test.js` (extended). Out (written down, not done): live announcement of a toast to TalkBack (KNOWN-ISSUES 106), tap to dismiss (104), moving the pill off a sheet footer, a longer `skippedNote`, font-scale pass (S5e-3).

## 4. Tests
- `toastLayout.test.js` **TLY-01..14**: constants; width (short, capped, junk, slack, narrow layer); height floor and growth; dismiss time (boundaries 5000, 5060, 6800, 9980, 10000, monotone, whole ms, non-text); resting place equals the old one; bottom edge fixed for heights 40 to 200; follows a changed layer height at four slide positions (the old `y` lead); rise clamped; 6000-round seeded monkey over density 0.75 to 4, widths, heights, messages.
- `toastHostLayer.test.js` **TL-8, TL-9, TS-8..TS-15** added to the 18 that were there: dismiss time set per toast and not left over; ignored toast leaves it; slides animate `rise` and never `y`; `y` only from `TL.pillY`; width and height from `TL`; text wraps, caps lines, elides, centres; the measure copy is hidden, unwrapped, and nothing in the loop reads a size it feeds; one interval write; every `TL.*` the file calls exists; the longest message fits the cap at 1x and 1.3x. TS-5 and TS-7 now find the pill's `z` by search, not by line position (properties moved above it for the lint order).
- 32 hand mutants (helper arithmetic, constants, every line of the QML shape), 32 killed.
- QML twin `tst_ToastLayout.qml` runs the same 14 bodies in the real QML engine in CI.
- **Not covered, said plainly:** that the text really wraps and the pill really grows (the engine, a device); Qt's layout timing of `contentHeight`; how the pill looks over each sheet; TalkBack reading the whole text. Those are checks 151 to 160.

## 5. Lint
`qt_qml_lint.py` on `ToastHost.qml` against `main`: one new finding, BND-2 on `pillText.text = msg` (line 39). False positive: the linter flags any imperative `.text =` once ANY `text:` binding exists in the file, and `measure` now has `text: pillText.text`; `pillText` itself has no binding to destroy. One real finding (ORD-1, property after assignment) was fixed. `ToastLayout.js`: JS-1 (`var`) on every line, the convention of every pragma-library helper here (`PickerSpeech.js` too).

## 6. Advice (the part Taher asked for)
1. **Run a device pass before S5e-3.** The S5e-1 plan counted 150 written device checks with none of S5c to S5e-1 run; the toast is the one control every screen shares, so a mistake here shows everywhere. Checks 151 to 160 take about 10 minutes. The conflict toast needs two sessions on one product; the import toast needs a file with bad rows.
2. **Do not make the toast longer than it needs to be.** The wrap is a safety net; the better fix for an 134-character message is a shorter message. Several of the eleven long ones repeat the same sentence ("updated elsewhere... restored with the latest version"); a pass over the wording is cheaper than another layout slice. Not done here.
3. **S5e-3 and S5e-4 can wait for the device pass;** the atomic-operations roadmap (NO2, PR #212) is independent and is waiting on you, not on code.

## 7. Questions for Taher (none block the merge)
- **Q1.** Scaled reading time up to 10 s (D6): accept, or keep 5 s? Recommendation: accept; one constant.
- **Q2.** Six lines at most (D5): accept? Recommendation: accept.
- **Q3.** A toast cannot be dismissed early (104): worth a tap-to-dismiss slice? Recommendation: not now; wait for the device pass.

## 8. Result (2026-11-22)
Functions 2220/2220 (main @ `4217032` measured 2196: +14 TLY, +10 in `toastHostLayer`), scripts 1199/1199. 32 hand mutants, 32 killed. Lint: see section 5. **CI on PR #214 head `b109b7e`: QML 3357, Functions 2220, Rules 129, E2E 124 = 5830/5830, all green; PR mergeable, state clean.** The QML number includes the new twin `tst_ToastLayout` running in the real QML engine.
