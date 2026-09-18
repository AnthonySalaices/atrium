# Releasing the host package

`pip install atrium` installs the **host side** only: the daemon, the CLI and the Lua config
files. The headset app is an APK built separately (`tools/build-apk.sh`) and distributed
separately — nothing in this document touches it.

Publishing is a manual step on purpose. Everything below up to `twine upload` can be repeated
safely as often as you like; the upload itself is irreversible — PyPI never lets a version number
be reused, even after a delete.

## The version has exactly one home

`pyproject.toml`'s `version` field. Nothing else in the tree hard-codes it, so a bump is a
one-line change and there is no second place to forget. `pip show atrium` is how you read it
back from an install.

Semantics, given what this is:

| change | bump |
|---|---|
| wire protocol, config keys removed or renamed, CLI subcommand removed | minor, and say so in the release notes — the headset app and the daemon must agree |
| new config keys with defaults, new subcommands, new host features | minor |
| fixes that need no config or client change | patch |

⚠️ **A client that is older than the daemon is the normal case** — an APK sideloaded weeks ago
against a daemon updated this morning. Anything that changes what the client is *sent* is a
compatibility decision, not a refactor.

## Pre-flight

```bash
python3 -m unittest discover -s tests        # everything, no headset, no daemon
python3 tools/keys-smoke.py                  # typing path, needs a daemon on 7570
python3 tools/switch-smoke.py                # session switching
python3 tools/pin-smoke.py                   # geometry pinning and the cropped view
```

Then, because this repo is public and the daemon is the most work-revealing service on a host:

```bash
git diff origin/main | grep -i -E "hostname|192\.168|10\.|token|\.local"   # expect nothing
```

Check that `config/default.lua` still documents every key `atriumd/config.py` validates, and that
`README.md`'s command list matches `atrium --help`.

## Build

Use a throwaway virtualenv; nothing here should be installed system-wide.

```bash
python3 -m venv /tmp/rel && /tmp/rel/bin/pip install build twine
rm -rf dist
/tmp/rel/bin/python -m build .          # sdist + wheel into dist/
/tmp/rel/bin/python -m twine check dist/*
```

`build` fetches `hatchling` into an isolated environment itself — it does not need to be
installed. Both artifacts should appear:

```
dist/atrium-X.Y.Z-py3-none-any.whl
dist/atrium-X.Y.Z.tar.gz
```

### Verify the wheel before anyone else gets it

```bash
python3 -m venv /tmp/fresh && /tmp/fresh/bin/pip install dist/*.whl
/tmp/fresh/bin/atrium doctor
/tmp/fresh/bin/atrium preset list        # proves the Lua files came along
```

⚠️ **The Lua config files are force-included into the wheel** (`[tool.hatch.build.targets.wheel.force-include]`)
because they live at the repo root for humans to read. If `preset list` or `doctor` cannot
evaluate a config from a clean install, that mapping is what broke — the daemon looks for them
next to `config.py`.

⚠️ **`import atriumd` inside the package is the package, not `atriumd.py`.** `cli.py` loads the
daemon module by path for exactly this reason; a "tidy-up" that turns it into a normal import
works in a checkout and fails from a wheel.

## Publish

```bash
/tmp/rel/bin/python -m twine upload -r testpypi dist/*    # rehearsal
/tmp/rel/bin/python -m twine upload dist/*                # the real thing
```

A PyPI API token goes in `~/.pypirc` (mode 600) or `TWINE_PASSWORD`, with
`TWINE_USERNAME=__token__`. ⛔ Never commit one, and never paste one into a terminal being
streamed to a headset.

## After

```bash
git tag -a vX.Y.Z -m "atrium X.Y.Z" && git push origin vX.Y.Z
```

Then write the GitHub release notes against that tag, calling out anything a sideloaded APK needs
to be rebuilt for, and bump `version` in `pyproject.toml` to the next patch with a `.dev0` suffix
so a checkout is never mistaken for a release.
