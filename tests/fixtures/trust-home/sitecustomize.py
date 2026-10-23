"""Test-only python startup hook (hk 1894), loaded through PYTHONPATH.

bin/wrk and bin/arbiter decide their trust paths from the passwd home of the
current uid, which a test cannot change and must not touch. A test that runs
the real binaries outside WRK_TEST_MODE puts this directory first on PYTHONPATH
and sets:

  TRUST_FAKE_HOME      a temp dir answered as the passwd home (pwd.getpwuid)
  TRUST_TRIPWIRE_LOG   a file; every touch of the real passwd home's inbox,
                       arbiter data dir or ~/.local/bin is appended and raises

Neither variable exists in production code: the binaries still read
pwd.getpwuid(os.getuid()).pw_dir and nothing else. Without both variables this
file does nothing.
"""
import os
import sys

_FAKE_HOME = os.environ.get("TRUST_FAKE_HOME", "")
_LOG = os.environ.get("TRUST_TRIPWIRE_LOG", "")

if _FAKE_HOME or _LOG:
    _LIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib")
    sys.path.insert(0, _LIB)
    try:
        import trust_tripwire

        trust_tripwire.install(log=_LOG or None, fake_home=_FAKE_HOME or None)
    finally:
        sys.path.remove(_LIB)
