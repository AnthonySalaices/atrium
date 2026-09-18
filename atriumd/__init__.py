"""atriumd — the Atrium host daemon and CLI, as an installable package.

The modules in here import each other by bare name (`import agents`) because
the daemon grew up as a directory of scripts and still runs that way from a
checkout. Installed as a package, that only keeps working if this directory is
on sys.path — so the package puts itself there. Deliberate, and documented here
so nobody "fixes" the imports one by one.
"""
import os as _os
import sys as _sys

_here = _os.path.dirname(_os.path.abspath(__file__))
if _here not in _sys.path:
    _sys.path.insert(0, _here)
