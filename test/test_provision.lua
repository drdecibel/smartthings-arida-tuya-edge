-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 drdecibel
--
-- Key provisioning from a PC (tools/push-keys.py) and device creation.

package.path = "src/?.lua;test/?.lua;test/support/?.lua;" .. package.path
local H = require("support.harness")
local provision = require("provision")
local discovery = require("discovery")
local constants = require("constants")

local KEY_A = "0123456789abcdef"
local KEY_B = "fedcba9876543210"

local function reply(units)
  local parts = {}
  for _, u in ipairs(units) do
    local fields = {}
    for k, v in pairs(u) do fields[#fields + 1] = string.format('"%s":"%s"', k, v) end
    parts[#parts + 1] = "{" .. table.concat(fields, ",") .. "}"
  end
  return '{"arida_setup":1,"units":[' .. table.concat(parts, ",") .. "]}"
end

--- A fake UDP socket factory. `replies` are returned, in order, by
--- receivefrom after the request was broadcast.
local function udp_with(replies, stats)
  return function()
    local queue = {}
    local s = {}
    function s:setoption() end
    function s:setsockname() return true end
    function s:settimeout() end
    function s:sendto(data, host, port)
      stats.sent = {data = data, host = host, port = port}
      for i, r in ipairs(replies) do queue[i] = r end
      return #data
    end
    function s:receivefrom()
      local r = table.remove(queue, 1)
      if r then return r, "192.0.2.50", provision.SETUP_PORT end
      return nil, "timeout"
    end
    function s:close() stats.closed = true end
    return s
  end
end

local function fake_driver(devices)
  local d = {created = {}, datastore = {}, devices = devices or {}}
  function d:get_devices() return self.devices end
  function d:try_create_device(metadata)
    self.created[#self.created + 1] = metadata
    self.devices[#self.devices + 1] = {device_network_id = metadata.device_network_id, label = metadata.label, preferences = {}}
  end
  return d
end

H.test("network ids carry the Tuya device id", function()
  H.eq(provision.network_id("bfabc123def4567890xy"), "arida-tuya-id-bfabc123def4567890xy")
  H.eq(provision.tuya_id("arida-tuya-id-bfabc123def4567890xy"), "bfabc123def4567890xy")
  H.eq(provision.tuya_id("arida-tuya-1792768284-2944"), nil, "blank devices carry none")
end)

H.test("reply parsing keeps valid units and drops malformed ones", function()
  local units, dropped = provision.parse_reply(reply({
    {id = "bfabc123def4567890xy", key = KEY_A, name = "Bad", ip = "192.0.2.7", version = "3.5"},
    {id = "short", key = KEY_A},
    {id = "bfabc123def4567890zz", key = "too-short"},
  }))
  H.eq(#units, 1)
  H.eq(dropped, 2)
  H.eq(units[1].version, "3.5")
  H.eq(provision.parse_reply('{"hello":1}'), nil)
  H.eq(provision.parse_reply("garbage"), nil)
end)

H.test("request broadcasts to the setup port and merges replies", function()
  local stats = {}
  local udp = udp_with({
    reply({{id = "bfabc123def4567890xy", key = KEY_A}}),
    "not json",
    reply({{id = "bfabc123def4567890xy", key = KEY_B}, {id = "bf00000000000000000z", key = KEY_A}}),
  }, stats)
  local units, answers = provision.request(1, {udp = udp})
  H.eq(stats.sent.data, provision.REQUEST)
  H.eq(stats.sent.host, "255.255.255.255")
  H.eq(stats.sent.port, provision.SETUP_PORT)
  H.eq(answers, 2)
  H.eq(#units, 2)
  H.eq(units[1].key, KEY_B, "later reply wins")
  H.truthy(stats.closed, "socket closed")
end)

H.test("provision creates one device per unit, named from devices.json", function()
  local driver = fake_driver()
  local udp = udp_with({reply({
    {id = "bfc0000000000000000001", key = KEY_A, name = "Small Ventilator 1.2"},
    {id = "bf90000000000000000002", key = KEY_B, name = "Small Ventilator 1.2 2"},
  })}, {})
  H.eq(discovery.provision(driver, nil, {udp = udp, seconds = 1}), 2)
  H.eq(#driver.created, 2)
  H.eq(driver.created[1].label, "Small Ventilator 1.2")
  H.eq(driver.created[1].device_network_id, "arida-tuya-id-bfc0000000000000000001")
  H.eq(driver.created[2].profile, constants.PROFILE.humidity)
  H.eq(provision.lookup(driver, "bf90000000000000000002").key, KEY_B)
  H.truthy(discovery.is_configured(driver.devices[1], driver), "configured without settings")
end)

H.test("a second push creates nothing and reports only changed keys", function()
  local driver = fake_driver()
  local first = {reply({{id = "bfc0000000000000000001", key = KEY_A}, {id = "bf90000000000000000002", key = KEY_B}})}
  discovery.provision(driver, nil, {udp = udp_with(first, {}), seconds = 1})
  local changed = {}
  local second = {reply({{id = "bfc0000000000000000001", key = KEY_B}, {id = "bf90000000000000000002", key = KEY_B}})}
  discovery.provision(driver, function(d) changed[#changed + 1] = d.device_network_id end,
    {udp = udp_with(second, {}), seconds = 1})
  H.eq(#driver.created, 2, "no duplicates")
  H.eq(#changed, 1)
  H.eq(changed[1], "arida-tuya-id-bfc0000000000000000001")
end)

H.test("once keys were pushed, a scan without the PC adds no blank tile", function()
  local driver = fake_driver()
  discovery.provision(driver, nil, {udp = udp_with({reply({{id = "bfc0000000000000000001", key = KEY_A}})}, {}), seconds = 1})
  H.eq(#driver.created, 1)
  -- Later "Scan nearby" for some other device; the script is not running.
  local real_request = provision.request
  provision.request = function() return {}, 0 end
  discovery.handle(driver)
  provision.request = real_request
  H.eq(#driver.created, 1, "no blank device")
end)

H.test("no PC answering creates nothing from provisioning", function()
  local driver = fake_driver()
  H.eq(discovery.provision(driver, nil, {udp = udp_with({}, {}), seconds = 1}), 0)
  H.eq(#driver.created, 0)
end)

H.done("test_provision")
