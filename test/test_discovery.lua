-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 drdecibel

package.path = "src/?.lua;test/?.lua;test/support/?.lua;" .. package.path
local H = require("support.harness")
local constants = require("constants")
local discovery = require("discovery")

local function fake_driver(devices)
  local d = {created = {}}
  function d:get_devices() return devices end
  function d:try_create_device(metadata) self.created[#self.created + 1] = metadata end
  return d
end

local function device(ip, id)
  return {label = "x", preferences = {ipAddress = ip, deviceId = id}}
end

H.test("first scan creates one device with the humidity profile", function()
  local driver = fake_driver({})
  discovery.handle(driver)
  H.eq(#driver.created, 1)
  H.eq(driver.created[1].profile, constants.PROFILE.humidity)
  H.eq(driver.created[1].type, "LAN")
  H.eq(driver.created[1].label, "Arida ventilator")
end)

H.test("no new device while one is still unconfigured", function()
  local driver = fake_driver({device(constants.PLACEHOLDER_IP, constants.PLACEHOLDER_ID)})
  discovery.handle(driver)
  H.eq(#driver.created, 0)
end)

H.test("next scan creates the next device once all are configured", function()
  local driver = fake_driver({device("192.0.2.10", "abc"), device("192.0.2.11", "def")})
  discovery.handle(driver)
  H.eq(#driver.created, 1)
  H.eq(driver.created[1].label, "Arida ventilator 3")
end)

H.test("a device with only the IP filled in is not configured", function()
  H.eq(discovery.is_configured(device("192.0.2.10", constants.PLACEHOLDER_ID)), false)
end)

H.done("test_discovery")
