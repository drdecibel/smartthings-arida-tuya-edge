# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 drdecibel

LUA ?= lua5.3
LUAC ?= luac5.3
PYTHON ?= python3

.PHONY: check syntax test manifest privacy vectors build-only package create-channel enroll-channel assign-driver install logcat

# Everything that can be verified without a hub or a ventilator.
check: syntax test manifest privacy

syntax:
	find src test -name '*.lua' -print0 | xargs -0 -n1 $(LUAC) -p

test:
	$(LUA) test/test_protocol.lua
	$(LUA) test/test_client.lua
	$(LUA) test/test_model.lua
	$(LUA) test/test_discovery.lua
	$(LUA) test/test_locator.lua
	$(LUA) test/test_provision.lua

manifest:
	$(PYTHON) tools/check-manifest.py

privacy:
	sh tools/privacy-scan.sh

# Regenerate test/fixtures/vectors.lua with tinytuya (pip install tinytuya).
vectors:
	$(PYTHON) tools/gen-test-vectors.py

# Build the package without uploading it, into a directory outside the repo.
build-only:
	smartthings edge:drivers:package . --build-only ../arida-tuya-edge.zip

package:
	smartthings edge:drivers:package .

create-channel:
	smartthings edge:channels:create

enroll-channel:
	smartthings edge:channels:enroll

assign-driver:
	smartthings edge:channels:assign

install:
	smartthings edge:drivers:install

logcat:
	smartthings edge:drivers:logcat
