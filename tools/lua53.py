#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 drdecibel
"""Run a Lua file on Lua 5.3 through lupa, for machines without a lua5.3
binary (for example Windows). `pip install lupa`, then:

    python tools/lua53.py test/test_protocol.lua

Exits with the script's os.exit() status.
"""

import sys

import lupa.lua53 as lupa

lua = lupa.LuaRuntime()
status = {"code": 0}


def _exit(code=True):
    if code is True or code is None:
        status["code"] = 0
    elif code is False:
        status["code"] = 1
    else:
        status["code"] = int(code)
    raise SystemExit(status["code"])


lua.globals().os.exit = _exit

if sys.argv[1:2] == ["--syntax"]:
    # Compile only, like `luac -p`.
    load = lua.eval("function(src, name) local f, err = load(src, '@' .. name) return err end")
    bad = 0
    for path in sys.argv[2:]:
        err = load(open(path, encoding="utf-8").read(), path)
        if err:
            print(err)
            bad += 1
    sys.exit(1 if bad else 0)

for path in sys.argv[1:]:
    try:
        lua.execute(open(path, encoding="utf-8").read())
    except SystemExit:
        pass
    except lupa.LuaError as err:
        print(f"{path}: {err}")
        status["code"] = 1
    if status["code"]:
        sys.exit(status["code"])
