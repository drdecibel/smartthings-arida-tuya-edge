-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 drdecibel
--
-- Client tests: full exchanges with fake devices that answer with
-- tinytuya-generated frames, including protocol auto-detection.

package.path = "src/?.lua;test/?.lua;test/support/?.lua;" .. package.path
local H = require("support.harness")
local Client = require("tuya.client")
local fake = require("support.fake_device")
local X = fake.X

fake.fix_randomness()

local EXPECTED = {["1"] = true, ["2"] = "ventilate", ["3"] = 2, ["103"] = true, ["104"] = 70, ["105"] = 64}

local function client(version, tcp, learned)
  return Client.new({
    ip = "192.0.2.10", local_key = X.local_key, device_id = "testdevice0000000001",
    version = version, tcp = tcp, learned = learned,
  })
end

for _, version in ipairs({"3.3", "3.4", "3.5"}) do
  H.test("fixed " .. version .. ": status query", function()
    local tcp = fake.factory(version)
    local dps, used = client(version, tcp):exchange()
    H.truthy(dps, "dps")
    H.eq(used, version)
    H.same(dps, EXPECTED, "dps")
  end)

  H.test("auto: detects " .. version, function()
    local tcp, state = fake.factory(version)
    local c = client("auto", tcp)
    local dps, used = c:exchange()
    H.truthy(dps, "dps")
    H.eq(used, version)
    H.eq(c.learned, version, "learned")
    H.same(dps, EXPECTED, "dps")

    -- The next exchange goes straight to the learned version.
    local before = state.connections
    H.truthy(c:exchange(), "second exchange")
    H.eq(state.connections - before, 1, "connections for second exchange")
  end)
end

H.test("3.4 write: sends CONTROL_NEW, merges the push, then queries", function()
  local tcp, state = fake.factory("3.4")
  local dps = client("3.4", tcp):exchange({["3"] = 3})
  H.truthy(dps, "dps")
  H.eq(state.writes, 1, "writes")
  H.eq(state.handshakes, 1, "handshakes")
  H.same(dps, EXPECTED, "dps")
end)

H.test("3.3 write: sends CONTROL and accepts a push before the ack", function()
  local tcp, state = fake.factory("3.3")
  local dps = client("3.3", tcp):exchange({["1"] = false})
  H.truthy(dps, "dps")
  H.eq(state.writes, 1, "writes")
end)

H.test("unreachable host fails fast without probing other versions", function()
  local tcp = fake.factory("3.4", {unreachable = true})
  local dps, err = client("auto", tcp):exchange()
  H.eq(dps, nil)
  H.truthy(err:find("connect failed"), err)
end)

H.test("wrong version fixed by the user fails with that version's error", function()
  local tcp = fake.factory("3.4")
  local dps, err = client("3.3", tcp):exchange()
  H.eq(dps, nil)
  H.truthy(err:find("timeout"), err)
end)

H.test("a stale learned version is re-probed", function()
  local tcp = fake.factory("3.5")
  local c = client("auto", tcp, "3.3")
  local dps, used = c:exchange()
  H.truthy(dps, "dps")
  H.eq(used, "3.5")
end)

-- A device cannot authenticate frames made with the wrong key and stays
-- silent, so every version is tried and the error lists them all.
H.test("wrong local key: every version is tried and reported", function()
  local tcp, state = fake.factory("3.4")
  local c = Client.new({ip = "192.0.2.10", local_key = "fedcba9876543210", device_id = "x", version = "auto", tcp = tcp})
  local dps, err = c:exchange()
  H.eq(dps, nil)
  H.truthy(err:find("no protocol version answered", 1, true), err)
  H.eq(state.connections, 3, "connections")
  H.eq(c.learned, nil, "learned")
end)

H.done("test_client")
