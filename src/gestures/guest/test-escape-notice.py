#!/usr/bin/env python3
"""Offline test of the guest's escape notifications (src/gestures/mac/test.sh):
the daemon's own handle() with evdev stubbed and notify-send replaced; the
hint file in a temp folder. No VM, no uinput. No notice when the escape combo
is used (user, 2026-10-12: "never a notice"):
  "S esc", "S esc ctrl-opt"                         -> nothing
  "S esc ctrl-opt-cmd"  (the old combo)             -> once per VM "New shortcut: ⌃⌥ Esc"
  "N <why>"             (Mac helpers up to 3.0.18)  -> nothing
"""
import importlib.machinery
import importlib.util
import os
import stat
import sys
import tempfile
import types


class _Codes:
    def __getattr__(self, name):
        return 0


evdev = types.ModuleType("evdev")
evdev.AbsInfo = object
evdev.UInput = object
evdev.ecodes = _Codes()
sys.modules["evdev"] = evdev
DAEMON = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "omacvm-gestures")


def load(hint_file):
    loader = importlib.machinery.SourceFileLoader("omacvm_gestures_daemon", DAEMON)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    g = importlib.util.module_from_spec(spec)
    loader.exec_module(g)
    g.ESC_HINT_FILE = hint_file
    g.notify = notify
    return g


class Held:
    def release(self):
        pass


shown = []
desktop = [True]


def notify(text, ms=2500):
    if not desktop[0]:
        return False
    shown.append((text, ms))
    return True


fails = 0


def check(ok, what):
    global fails
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    fails += 0 if ok else 1


def send(g, line):
    shown.clear()
    g.handle(line.split(), Held(), Held(), Held())
    return list(shown)


HINT = ("New shortcut: ⌃⌥ Esc (⌃⌥⌘ Esc goes away in a later version)", 8000)

tmp = tempfile.mkdtemp()
hint = os.path.join(tmp, "lib", "escape-hint-shown")
g = load(hint)
check(send(g, b"S esc") == [], "escape notice: a Mac helper before 3.0.0 ('S esc'): none")
check(send(g, b"S esc ctrl-opt") == [], "escape notice: 'S esc ctrl-opt': none")
check(send(g, b"S on") == [] and send(g, b"S off") == [], "escape notice: 'S on' / 'S off': none")
desktop[0] = False
check(send(g, b"S esc ctrl-opt-cmd") == [] and not os.path.exists(hint),
      "escape notice: the old combo before a desktop session: the hint is not used up")
desktop[0] = True
check(send(g, b"S esc ctrl-opt-cmd") == [HINT], "escape notice: the old combo: 'New shortcut: ⌃⌥ Esc' once")
check(os.path.exists(hint), "escape notice: ... remembered for this VM")
check(send(g, b"S esc ctrl-opt-cmd") == [], "escape notice: the old combo again: none")
g = load(hint)
check(send(g, b"S esc ctrl-opt-cmd") == [], "escape notice: after a daemon restart: not again")
check(send(g, b"S esc some-new-word") == [], "escape notice: a word from a newer helper: none")
locked = os.path.join(tmp, "locked")
os.mkdir(locked)
os.chmod(locked, stat.S_IRUSR | stat.S_IXUSR)
if os.access(locked, os.W_OK):
    print("skip  escape notice: an unwritable hint file (running as root)")
else:
    g = load(os.path.join(locked, "sub", "escape-hint-shown"))
    first, again = send(g, b"S esc ctrl-opt-cmd"), send(g, b"S esc ctrl-opt-cmd")
    check(first == [HINT] and again == [], "escape notice: hint file not writable: shown once while running, logged")
os.chmod(locked, stat.S_IRWXU)
check(all(send(g, w) == [] for w in (b"N space-shortcut-off", b"N space-unchanged", b"N no-spaces", b"N some-new-word")),
      "no way out (N <why> from a Mac helper up to 3.0.18): no notice")
os.environ["OMACVM_GUEST_OS"] = "ubuntu"
desktop[0] = True
g._capture_hint_at = None
capture = send(g, b"S on")
check(len(capture) == 1 and "Control + Option + Escape" in capture[0][0], "Ubuntu capture shows the way back to macOS")
check(send(g, b"S on") == [], "Ubuntu capture hint is throttled across focus changes")
check(send(g, b"S off") == [] and send(g, b"S esc ctrl-opt") == [], "Ubuntu release does not add notifications")
os.environ.pop("OMACVM_GUEST_OS", None)
sys.exit(1 if fails else 0)
