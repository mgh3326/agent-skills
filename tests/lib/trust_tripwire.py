"""Test-only tripwire (hk 1894): fail when a test resolves a path under the real
passwd home's trust locations.

The trust-bearing operations of bin/wrk and bin/arbiter take their events inbox,
the arbiter DB and the handoffkeep binary from <passwd home>/work/herdr-inbox,
<passwd home>/.local/share/arbiter and <passwd home>/.local/bin. A test must
never read or write those: the decision function is unit-tested with a fake home
passed in, and the real-binary tests run with a fake passwd home (see
tests/fixtures/trust-home/sitecustomize.py). This module makes that rule fail
loudly instead of by convention.

install() patches the stat, open, listing and rename families of os, builtins
and io, and subprocess.Popen, so any call whose path (lexically normalized, never
resolved, so the guard itself touches nothing) lies under a trust location is
recorded and raises AssertionError before the real call runs. The locations are
taken under the passwd home as spelled and through realpath, so a symlinked home
cannot be reached under its other name. With fake_home it also makes
pwd.getpwuid(<own uid>) answer fake_home as the home directory.
"""
import builtins
import io
import os
import pwd
import subprocess
import sys

TRIP_RELATIVE = ("work/herdr-inbox", ".local/share/arbiter", ".local/bin")

_state = {"originals": [], "trips": [], "roots": (), "log": None}


def real_home():
    return _state.get("real_home") or pwd.getpwuid(os.getuid()).pw_dir


def trust_roots():
    home = real_home()
    homes = [home]
    if os.path.realpath(home) != home:
        homes.append(os.path.realpath(home))
    return tuple(os.path.join(form, rel) for form in homes for rel in TRIP_RELATIVE)


def trips():
    return list(_state["trips"])


def _record(kind, path):
    line = "TRIPWIRE: %s touched %s (under the real passwd home trust locations)" % (kind, path)
    _state["trips"].append(line)
    log = _state["log"]
    if log:
        try:
            handle = _state["open"](log, "a", encoding="utf-8")
            with handle:
                handle.write(line + "\n")
        except OSError:
            pass
    return line


def _check(kind, path):
    if isinstance(path, bytes):
        path = os.fsdecode(path)
    if not isinstance(path, (str, os.PathLike)):
        return
    text = os.path.abspath(os.fspath(path))
    for root in _state["roots"]:
        if text == root or text.startswith(root + "/"):
            raise AssertionError(_record(kind, text))


def _wrap(owner, name, count):
    original = getattr(owner, name)

    def wrapper(*args, **kwargs):
        for value in args[:count]:
            _check(name, value)
        return original(*args, **kwargs)

    wrapper.__name__ = name
    setattr(owner, name, wrapper)
    _state["originals"].append((owner, name, original))


def install(log=None, fake_home=None, home=None):
    """home overrides the passwd home the locations are taken from (tests only)."""
    if _state["originals"]:
        raise RuntimeError("trust tripwire already installed")
    _state["real_home"] = home or pwd.getpwuid(os.getuid()).pw_dir
    _state["roots"] = trust_roots()
    _state["trips"] = []
    _state["log"] = log
    _state["open"] = builtins.open
    for owner, name, count in (
        (os, "stat", 1), (os, "lstat", 1), (os, "readlink", 1), (os, "listdir", 1),
        (os, "scandir", 1), (os, "open", 1), (os, "access", 1), (os, "mkdir", 1),
        (os, "rename", 2), (os, "replace", 2), (os, "remove", 1), (os, "unlink", 1),
        (os, "rmdir", 1), (os, "link", 2), (os, "symlink", 2), (os, "chmod", 1),
        (builtins, "open", 1), (io, "open", 1),
    ):
        _wrap(owner, name, count)
    original_init = subprocess.Popen.__init__

    def popen_init(self, args, *rest, **kwargs):
        first = args if isinstance(args, (str, bytes, os.PathLike)) else (args[0] if args else None)
        if first is not None:
            _check("subprocess.Popen", first)
        executable = kwargs.get("executable")
        if executable is not None:
            _check("subprocess.Popen", executable)
        return original_init(self, args, *rest, **kwargs)

    subprocess.Popen.__init__ = popen_init
    _state["originals"].append((subprocess.Popen, "__init__", original_init))
    if fake_home:
        real_getpwuid = pwd.getpwuid

        def getpwuid(uid):
            entry = real_getpwuid(uid)
            if uid != os.getuid():
                return entry
            fields = list(entry)
            fields[5] = fake_home
            return pwd.struct_passwd(fields)

        pwd.getpwuid = getpwuid
        _state["originals"].append((pwd, "getpwuid", real_getpwuid))


def uninstall():
    while _state["originals"]:
        owner, name, original = _state["originals"].pop()
        setattr(owner, name, original)
    _state["roots"] = ()
    _state["log"] = None
    _state.pop("real_home", None)
