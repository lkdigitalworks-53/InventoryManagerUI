#!/usr/bin/env bash
# Install the apt packages needed to run a REAL qmltestrunner in a Cloud sandbox
# session (as opposed to Taher's local Felgo/Qt toolchain, which this script
# doesn't touch and doesn't need to).
#
# Written 2026-08-30 (SKILLS Skill 54) after a session spent several rounds of
# install-run-read-the-next-missing-module to find this list by hand. Written
# down so the next Cloud session doesn't repeat that discovery process.
#
# What this gets you: a real `qmltestrunner` binary that compiles and runs the
# actual test suite in `tests/`, not a fake/simulated result. Confirmed (2026-08-30):
# 315 of 337 test files pass. The remaining ~22 fail at compile() with
# "Type AuthStore unavailable" — a known, pre-existing Qt-version API drift
# (this sandbox's apt-installable Qt is 6.4.2; CI runs 6.8; `AuthStore.qml`'s
# `import QtCore; Settings { ... }` isn't valid QML until a later 6.x minor).
# That floor is NOT a real signal — see AGENTS.md's Testing & QA Agent section
# and SKILLS Skill 47/54 before treating it as a regression.
#
# What this does NOT get you: the actual Felgo app build (needs Taher's Windows
# Felgo toolchain), or the Firebase Local Emulator Suite (its jar download needs
# storage.googleapis.com, which isn't in this sandbox's network allowlist —
# confirmed by an actual `firebase emulators:start` attempt, not assumed).
set -euo pipefail

# `apt-get update` exits non-zero if ANY configured repo fails, even when the
# repos we actually need succeed -- this sandbox has a pre-existing broken
# `deb.nodesource.com` entry (403, unrelated to Qt) that trips exactly this.
# Don't let that kill the script; `apt-get install` below will fail loudly and
# correctly on its own if a package we actually need truly isn't fetchable.
apt-get update -qq || true

apt-get install -y -qq \
    qt6-declarative-dev \
    qml6-module-qttest \
    qml6-module-qtquick \
    qml6-module-qtqml \
    qml6-module-qtquick-controls \
    qml6-module-qtqml-workerscript \
    qml6-module-qt-labs-platform \
    qml6-module-qt-labs-qmlmodels \
    qml6-module-qt-labs-folderlistmodel \
    qml6-module-qtquick-layouts \
    qml6-module-qtquick-dialogs \
    qml6-module-qtquick-shapes \
    qml6-module-qtqml-models \
    qml6-module-qtquick-window

echo "qmltestrunner installed at: $(dpkg -L qt6-declarative-dev-tools | grep qmltestrunner)"
echo ""
echo "Run the suite headless with, e.g.:"
echo "  cd \"$(dirname "$0")/..\""
echo '  QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests -platform offscreen'
echo ""
echo "Expect ~22 pre-existing compile() failures (Type AuthStore unavailable) unrelated to your"
echo "diff -- see SKILLS Skill 47/54 before treating that floor as a regression."
