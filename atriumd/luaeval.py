#!/usr/bin/env python3
"""Evaluate the Lua config with lupa instead of the vendored `lua` binary.

    python3 luaeval.py <config_dir> <user_config_path|"">

Prints exactly what `lua eval.lua <config_dir> <user>` prints — one JSON
object — so config.py can use either without caring which. This exists because
a plug-and-play install cannot assume a C compiler: `lupa` ships wheels for
every platform, the Lua source (eval.lua, default.lua) is unchanged, and the
result is byte-identical (tests/test_config.py checks that when both exist).

Run as a SUBPROCESS on purpose, like the binary: an infinite loop in somebody's
config.lua then hits the caller's timeout instead of hanging the daemon, and a
misbehaving script cannot touch the daemon's memory.
"""

import os
import sys


def main(argv):
    if len(argv) < 2:
        sys.stdout.write('{"ok":false,"error":"usage: luaeval.py <config_dir> <user_path>"}')
        return 0
    config_dir, user_path = argv[0], argv[1]
    try:
        try:
            from lupa import lua54 as lupa_mod        # match the vendored 5.4
        except ImportError:
            import lupa as lupa_mod
        LuaRuntime = lupa_mod.LuaRuntime
        LuaError = lupa_mod.LuaError
    except ImportError:
        sys.stdout.write('{"ok":false,"error":"neither the lua binary nor the lupa module is '
                         'available: pip install lupa, or run tools/build-lua.sh"}')
        return 0

    with open(os.path.join(config_dir, "eval.lua"), encoding="utf-8") as f:
        src = f.read()

    lua = LuaRuntime(unpack_returned_tuples=True)
    # eval.lua writes with io.write and leaves with os.exit(0) on a broken
    # config. Neither may touch this process: collect the output, turn the exit
    # into an error we recognise.
    lua.execute("""
        __out = {}
        io.write = function(...)
            for _, s in ipairs({...}) do __out[#__out + 1] = tostring(s) end
        end
        os.exit = function() error("__atrium_exit__", 0) end
    """)
    fn = lua.eval("function(...) " + src + "\nend")
    try:
        fn(config_dir, user_path)
    except LuaError as e:
        if "__atrium_exit__" not in str(e):
            sys.stdout.write('{"ok":false,"error":%s}' % _q("lua: " + str(e)))
            return 0
    out = lua.globals()["__out"]
    sys.stdout.write("".join(out[i] for i in range(1, len(out) + 1)))
    return 0


def _q(s):
    import json
    return json.dumps(s)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
