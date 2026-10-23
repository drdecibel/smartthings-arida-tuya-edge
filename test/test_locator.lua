-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 drdecibel
--
-- Locating a unit by its key on a fake /24, so units can stay on DHCP.

package.path = "src/?.lua;test/?.lua;test/support/?.lua;" .. package.path
local H = require("support.harness")
local locator = require("locator")
local fake = require("support.fake_device")
local X = fake.X

fake.fix_randomness()

-- A device that accepts the connection but answers nothing, like a Tuya
-- device holding a different local key.
local function silent()
  local s = {}
  function s:settimeout() end
  function s:connect() return true end
  function s:send(b) return #b end
  function s:receive() return nil, "timeout" end
  function s:close() end
  return s
end

--- A fake network: ip -> socket factory. Other addresses time out.
local function network(hosts, stats)
  return function()
    local inner
    local s = {}
    function s:settimeout() end
    function s:connect(ip)
      stats.connects = (stats.connects or 0) + 1
      local factory = hosts[ip]
      if not factory then return nil, "timeout" end
      inner = factory()
      return inner:connect(ip)
    end
    function s:send(b) return inner:send(b) end
    function s:receive(n) return inner:receive(n) end
    function s:close() if inner then inner:close() end end
    return s
  end
end

local function sequential(tasks) for _, t in ipairs(tasks) do t() end end

local SPEC = {device_id = "testdevice0000000001", local_key = X.local_key, version = "auto"}

local function opts(tcp, now)
  return {tcp = tcp, parallel = sequential, now = function() return now or 1000 end}
end

H.test("prefix accepts IPv4 only", function()
  H.eq(locator.prefix("192.0.2.77"), "192.0.2.")
  H.eq(locator.prefix("auto"), nil)
  H.eq(locator.prefix("192.0.2.300"), nil)
  H.eq(locator.prefix(nil), nil)
end)

H.test("open_hosts finds every address with TCP 6668 open, sorted", function()
  locator.forget()
  local stats = {}
  local tcp = network({["192.0.2.200"] = silent, ["192.0.2.9"] = silent, ["192.0.2.35"] = silent}, stats)
  local hosts = locator.open_hosts({"192.0.2."}, opts(tcp))
  H.eq(table.concat(hosts, ","), "192.0.2.9,192.0.2.35,192.0.2.200")
  H.eq(stats.connects, 254)
end)

H.test("open_hosts reuses a recent scan and rescans once it is stale", function()
  locator.forget()
  local stats = {}
  local tcp = network({["192.0.2.9"] = silent}, stats)
  locator.open_hosts({"192.0.2."}, opts(tcp, 1000))
  locator.open_hosts({"192.0.2."}, opts(tcp, 1030))
  H.eq(stats.connects, 254, "cached within the window")
  locator.open_hosts({"192.0.2."}, opts(tcp, 1000 + locator.CACHE_SECONDS + 1))
  H.eq(stats.connects, 508, "rescanned after the window")
end)

H.test("locate picks the unit that holds our key, skipping a foreign device", function()
  locator.forget()
  local tcp = network({
    ["192.0.2.20"] = silent,                       -- someone else's Tuya light
    ["192.0.2.235"] = (fake.factory("3.5")),       -- our ventilator, new DHCP address
  }, {})
  local ip, dps, version = locator.locate({"192.0.2."}, SPEC, {}, opts(tcp))
  H.eq(ip, "192.0.2.235")
  H.eq(version, "3.5")
  H.eq(dps["105"], 64)
end)

H.test("addresses claimed by other units are not tried", function()
  locator.forget()
  local tcp = network({["192.0.2.235"] = (fake.factory("3.5"))}, {})
  local ip = locator.locate({"192.0.2."}, SPEC, {["192.0.2.235"] = true}, opts(tcp))
  H.eq(ip, nil)
end)

H.test("a learned protocol is tried first", function()
  locator.forget()
  local factory, state = fake.factory("3.4")
  local tcp = network({["192.0.2.50"] = factory}, {})
  local spec = {device_id = SPEC.device_id, local_key = X.local_key, version = "auto", learned = "3.4"}
  local ip, _, version = locator.locate({"192.0.2."}, spec, {}, opts(tcp))
  H.eq(ip, "192.0.2.50")
  H.eq(version, "3.4")
  -- One for the port scan, one for the 3.4 exchange. Probing from 3.3 would
  -- cost a third.
  H.eq(state.connections, 2, "connections to the unit")
end)

H.test("not found clears the cache so a unit that just came online is seen", function()
  locator.forget()
  local stats = {}
  local hosts = {["192.0.2.20"] = silent}
  local tcp = network(hosts, stats)
  H.eq(locator.locate({"192.0.2."}, SPEC, {}, opts(tcp)), nil)
  hosts["192.0.2.88"] = (fake.factory("3.3"))
  H.eq(locator.locate({"192.0.2."}, SPEC, {}, opts(tcp, 1001)), "192.0.2.88")
end)

H.done("test_locator")
