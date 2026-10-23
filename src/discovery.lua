-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 drdecibel
--
-- Tuya devices announce themselves with encrypted UDP broadcasts on ports
-- 6666/6667, but an Edge driver can only bind UDP port 0, so it cannot hear
-- them. Discovery therefore creates a blank device that the user fills in
-- from its settings (device ID and local key). The driver then finds the
-- unit's address itself (see locator.lua), so units can stay on DHCP.
--
-- "Scan nearby" creates one new device only when every existing device has
-- been configured, so repeated background scans never pile up blank tiles,
-- and adding the next unit is simply another scan.

local log = require("log")
local constants = require("constants")

local M = {}

function M.is_configured(device)
  local p = device.preferences or {}
  return p.deviceId ~= nil and p.deviceId ~= constants.PLACEHOLDER_ID
    and p.localKey ~= nil and p.localKey ~= constants.PLACEHOLDER_KEY
end

function M.handle(driver, _opts, _cons)
  local devices = driver:get_devices()
  for _, device in ipairs(devices) do
    if not M.is_configured(device) then
      log.info("Discovery: '" .. tostring(device.label) .. "' is not configured yet; not creating another device")
      return
    end
  end

  local n = #devices + 1
  local metadata = {
    type = "LAN",
    device_network_id = string.format("arida-tuya-%d-%04d", os.time(), math.random(0, 9999)),
    label = n == 1 and "Arida ventilator" or ("Arida ventilator " .. n),
    profile = constants.PROFILE.humidity,
    manufacturer = "Arida",
    model = "Base/Venti WiFi",
    vendor_provided_label = "Arida ventilator",
  }
  log.info("Discovery: creating '" .. metadata.label .. "'. Enter device ID and local key in its settings.")
  driver:try_create_device(metadata)
end

return M
