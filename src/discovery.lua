-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 drdecibel
--
-- "Scan nearby" asks a PC running tools/push-keys.py for the ventilators'
-- device IDs and local keys (see provision.lua) and creates one device per
-- unit. The driver then finds each unit's address itself (see locator.lua),
-- so nothing has to be typed and the units can stay on DHCP.
--
-- Without the script, discovery falls back to creating one blank device to
-- be filled in from its settings, and only when every existing device is
-- configured, so repeated background scans never pile up blank tiles.

local log = require("log")
local constants = require("constants")
local provision = require("provision")

local M = {}

local function prefs_configured(device)
  local p = device.preferences or {}
  return p.deviceId ~= nil and p.deviceId ~= constants.PLACEHOLDER_ID
    and p.localKey ~= nil and p.localKey ~= constants.PLACEHOLDER_KEY
end

--- A device is configured by its settings or by keys pushed from a PC.
function M.is_configured(device, driver)
  if prefs_configured(device) then return true end
  local id = provision.tuya_id(device.device_network_id)
  return id ~= nil and driver ~= nil and provision.lookup(driver, id) ~= nil
end

local function find_device(driver, network_id)
  for _, device in ipairs(driver:get_devices()) do
    if device.device_network_id == network_id then return device end
  end
  return nil
end

--- Asks for keys and creates a device for each new unit. Calls
--- on_changed(device) for existing devices whose key changed. Returns the
--- number of units received.
function M.provision(driver, on_changed, opts)
  opts = opts or {}
  local units, answers = provision.request(opts.seconds, {udp = opts.udp, log = log})
  if answers == 0 then return 0 end
  local changed = {}
  for _, id in ipairs(provision.save(driver, units)) do changed[id] = true end
  log.info(string.format("Key setup: received %d ventilator(s) from %d PC(s)", #units, answers))

  for i, u in ipairs(units) do
    local network_id = provision.network_id(u.id)
    local existing = find_device(driver, network_id)
    if existing then
      if changed[u.id] and on_changed then on_changed(existing) end
    else
      local label = u.name or ("Arida ventilator " .. i)
      log.info("Key setup: creating '" .. label .. "'")
      driver:try_create_device({
        type = "LAN",
        device_network_id = network_id,
        label = label,
        profile = constants.PROFILE.humidity,
        manufacturer = "Arida",
        model = "Base/Venti WiFi",
        vendor_provided_label = "Arida ventilator",
      })
    end
  end
  return #units
end

local function create_blank(driver)
  local devices = driver:get_devices()
  for _, device in ipairs(devices) do
    if not M.is_configured(device, driver) then
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
  log.info("Discovery: no key setup answered; creating '" .. metadata.label
    .. "'. Run tools/push-keys.py on a PC, or enter device ID and local key in its settings.")
  driver:try_create_device(metadata)
end

function M.handle(driver, _opts, _cons)
  if M.provision(driver, driver.on_keys_changed) > 0 then return end
  create_blank(driver)
end

return M
