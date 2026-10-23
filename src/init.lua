-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 drdecibel
--
-- SmartThings Edge driver for Arida Base/Venti WiFi room ventilators, which
-- use a Tuya Wi-Fi module. All communication is local (TCP 6668).

local capabilities = require("st.capabilities")
local Driver = require("st.driver")
local log = require("log")

local arida = require("arida")
local constants = require("constants")
local discovery = require("discovery")
local Client = require("tuya.client")
local locator = require("locator")
local provision = require("provision")

math.randomseed(os.time())

-- Per-device runtime state that cannot live in device fields (functions,
-- timers). Keyed by device.id.
local runtime = {}

local function rt(device)
  local r = runtime[device.id]
  if not r then
    r = {failures = 0}
    runtime[device.id] = r
  end
  return r
end

local function dp_map(device)
  local text = (device.preferences or {}).dpMap
  if text == constants.DEFAULT_DP_MAP then text = nil end
  local map, warnings = arida.parse_dp_map(text)
  if #warnings > 0 then
    log.warn(device.label .. ": ignoring unknown DP map entries: " .. table.concat(warnings, ", "))
  end
  return map
end

-- Assigned once the driver is built; relocation needs the other devices.
local driver

local function override_ip(device)
  local ip = (device.preferences or {}).ipAddress
  if ip == constants.AUTO_IP or ip == constants.LEGACY_PLACEHOLDER_IP then return nil end
  return locator.prefix(ip) and ip or nil
end

--- The address to talk to: the user's override, else the last one found.
local function current_host(device)
  return override_ip(device) or device:get_field(constants.FIELD.HOST)
end

--- What identifies the unit: device ID and local key, from the device
--- settings if filled in, else as pushed from a PC (provision.lua).
--- Returns spec or nil, err.
local function spec_for(device)
  local p = device.preferences or {}
  local spec
  if p.deviceId and p.deviceId ~= constants.PLACEHOLDER_ID
      and p.localKey and p.localKey ~= constants.PLACEHOLDER_KEY then
    spec = {device_id = p.deviceId, local_key = p.localKey}
  else
    local id = provision.tuya_id(device.device_network_id)
    local unit = id and provision.lookup(driver, id)
    if not unit then
      return nil, "not configured: run tools/push-keys.py on a PC and tap Scan nearby, "
        .. "or enter device ID and local key in the device settings"
    end
    spec = {device_id = id, local_key = unit.key, hint_ip = unit.ip, hint_version = unit.version}
  end
  if #spec.local_key ~= 16 then
    return nil, "the local key must be exactly 16 characters"
  end
  spec.version = constants.PROTOCOL_OPTION[p.protocolVersion] or "auto"
  spec.learned = device:get_field(constants.FIELD.PROTOCOL) or spec.hint_version
  return spec
end

local function client_for(device)
  local r = rt(device)
  if r.client then return r.client end
  local spec, err = spec_for(device)
  if not spec then return nil, err end
  local host = current_host(device) or spec.hint_ip
  if not host then return nil, "address not known yet" end
  r.client = Client.new({
    ip = host,
    device_id = spec.device_id,
    local_key = spec.local_key,
    version = spec.version,
    timeout = constants.TIMEOUT_SECONDS,
    learned = spec.learned,
    log = log,
  })
  return r.client
end

--- The hub's /24. Read from the driver environment, or else from the local
--- address the OS picks for a UDP "connection", which sends no packet.
local function hub_prefix()
  local info = driver and driver.environment_info
  local prefix = locator.prefix(info and info.hub_ipv4)
  if prefix then return prefix end
  local ok, ip = pcall(function()
    local udp = require("cosock.socket").udp()
    udp:setpeername(constants.LEGACY_PLACEHOLDER_IP, 9)
    local addr = udp:getsockname()
    udp:close()
    return addr
  end)
  return ok and locator.prefix(ip) or nil
end

--- Looks for the unit on the local network, as the Daikin driver does after a
--- DHCP change. Rate limited, because a unit that is switched off at the wall
--- would otherwise trigger a scan on every poll. Returns dps, version or nil.
local function relocate(device, reason)
  local r = rt(device)
  local now = os.time()
  if r.last_scan and now - r.last_scan < constants.RELOCATE_INTERVAL then return nil end
  r.last_scan = now

  local spec = spec_for(device)
  if not spec then return nil end

  -- Search the hub's /24, plus the /24 of any address a ventilator has had.
  local prefixes, seen = {}, {}
  local function add(prefix)
    if prefix and not seen[prefix] then
      seen[prefix] = true
      prefixes[#prefixes + 1] = prefix
    end
  end
  add(hub_prefix())
  for _, d in ipairs(driver:get_devices()) do
    add(locator.prefix(d:get_field(constants.FIELD.HOST)))
  end
  if #prefixes == 0 then
    log.warn(device.label .. ": cannot search for the ventilator: hub address unknown; set its IP address in the settings")
    return nil
  end

  -- Addresses that belong to the other ventilators are not tried.
  local skip = {}
  for _, other in ipairs(driver:get_devices()) do
    if other.id ~= device.id then
      local host = other:get_field(constants.FIELD.HOST)
      if host then skip[host] = true end
    end
  end

  log.info(device.label .. ": searching the local network for the ventilator (" .. reason .. ")")
  local ip, dps, version = locator.locate(prefixes, spec, skip, {log = log})
  if not ip then
    log.warn(device.label .. ": ventilator not found on the local network; retrying in "
      .. constants.RELOCATE_INTERVAL .. " s")
    return nil
  end
  if ip ~= device:get_field(constants.FIELD.HOST) then
    log.info(device.label .. ": ventilator found at a new local address")
    device:set_field(constants.FIELD.HOST, ip, {persist = true})
  end
  r.client = nil
  r.last_scan = nil
  return dps, version
end

local function emit_supported_modes(device)
  local labels = arida.supported_mode_labels()
  device:emit_event(capabilities.mode.supportedModes(labels, {visibility = {displayed = false}}))
end

--- Switches between the humidity and CO2 profiles when the device's sensor
--- turns out to differ from the profile in use.
local function ensure_profile(device, kind)
  if not kind or device:get_field(constants.FIELD.SENSOR_KIND) == kind then return end
  device:set_field(constants.FIELD.SENSOR_KIND, kind, {persist = true})
  log.info(device.label .. ": sensor is " .. kind .. "; using profile " .. constants.PROFILE[kind])
  device:try_update_metadata({profile = constants.PROFILE[kind]})
end

local function emit_state(device, dps)
  local map = dp_map(device)
  local kind = arida.sensor_kind(dps, map) or device:get_field(constants.FIELD.SENSOR_KIND) or "humidity"
  ensure_profile(device, arida.sensor_kind(dps, map))
  local s = arida.to_state(dps, map, kind)

  if s.switch then device:emit_event(capabilities.switch.switch(s.switch)) end
  if s.fan_speed then device:emit_event(capabilities.fanSpeed.fanSpeed(s.fan_speed)) end
  if s.mode then device:emit_event(capabilities.mode.mode(s.mode)) end
  if s.temperature then
    device:emit_event(capabilities.temperatureMeasurement.temperature({value = s.temperature, unit = "C"}))
  end
  if s.humidity then
    device:emit_event(capabilities.relativeHumidityMeasurement.humidity(s.humidity))
  end
  if s.co2 then
    device:emit_event(capabilities.carbonDioxideMeasurement.carbonDioxide({value = s.co2, unit = "ppm"}))
  end
  if s.filter then device:emit_event(capabilities.filterStatus.filterStatus(s.filter)) end
  if s.sensor_control then
    device:emit_component_event(device.profile.components.sensorControl, capabilities.switch.switch(s.sensor_control))
  end
  if s.boost and device.profile.components.boost then
    device:emit_component_event(device.profile.components.boost, capabilities.switch.switch(s.boost))
  end
  if s.threshold then
    rt(device).threshold = s.threshold
  end

  local extra = arida.unmapped(dps, map)
  if #extra > 0 then
    log.debug(device.label .. ": unmapped DPs " .. table.concat(extra, ", "))
  end
end

local function on_failure(device, err)
  local r = rt(device)
  r.failures = r.failures + 1
  log.warn(string.format("%s: exchange failed (%d in a row): %s", device.label, r.failures, tostring(err)))
  if r.failures >= constants.OFFLINE_AFTER then
    device:offline()
  end
  return false
end

local function on_success(device, dps, version)
  local r = rt(device)
  if r.failures > 0 or not r.online then
    log.info(device.label .. ": connected with Tuya protocol " .. version)
  end
  r.failures = 0
  r.online = true
  if device:get_field(constants.FIELD.PROTOCOL) ~= version then
    device:set_field(constants.FIELD.PROTOCOL, version, {persist = true})
  end
  device:online()
  emit_state(device, dps)
  return true
end

--- Writes `set_dps` (or nothing) and reports the resulting state. All calls
--- for one device run on its own thread, so they never overlap.
---
--- Without a user-set IP address the unit is found by searching the network,
--- both the first time and whenever the last known address stops answering.
local function exchange(device, set_dps)
  local spec, spec_err = spec_for(device)
  if not spec then
    log.warn(device.label .. ": " .. spec_err)
    device:offline()
    return false
  end

  local client = client_for(device)
  local dps, version_or_err
  if client then
    dps, version_or_err = client:exchange(set_dps)
    if dps then
      -- Remember a first-guess address once it has answered with our key.
      if not override_ip(device) and device:get_field(constants.FIELD.HOST) ~= client.ip then
        device:set_field(constants.FIELD.HOST, client.ip, {persist = true})
      end
      return on_success(device, dps, version_or_err)
    end
    if override_ip(device) then return on_failure(device, version_or_err) end
  end

  local found_dps, found_version = relocate(device, client and "no answer at the last known address" or "first connection")
  if not found_dps then
    return on_failure(device, version_or_err or "address not known yet")
  end
  if set_dps then
    -- The search only read the status; apply the write at the new address.
    client = client_for(device)
    dps, version_or_err = client:exchange(set_dps)
    if not dps then return on_failure(device, version_or_err) end
    return on_success(device, dps, version_or_err)
  end
  return on_success(device, found_dps, found_version)
end

local function stop_polling(device)
  local r = rt(device)
  if r.timer then
    device.thread:cancel_timer(r.timer)
    r.timer = nil
  end
end

local function start_polling(device)
  stop_polling(device)
  local interval = tonumber((device.preferences or {}).pollInterval) or constants.DEFAULT_POLL_SECONDS
  if interval < constants.MIN_POLL_SECONDS then interval = constants.MIN_POLL_SECONDS end
  rt(device).timer = device.thread:call_on_schedule(interval, function()
    exchange(device)
  end, "poll")
end

-- Lifecycle ------------------------------------------------------------------

local function device_init(_driver, device)
  emit_supported_modes(device)
  start_polling(device)
  device.thread:call_with_delay(1, function() exchange(device) end)
end

local function device_added(_driver, device)
  emit_supported_modes(device)
  if not discovery.is_configured(device, driver) then
    log.info(device.label .. ": added; run tools/push-keys.py on a PC and tap Scan nearby, "
      .. "or enter device ID and local key in its settings")
  end
end

--- Called when a PC pushes a new key for an existing device.
local function keys_changed(device)
  rt(device).client = nil
  rt(device).last_scan = nil
  device.thread:call_with_delay(0, function() exchange(device) end)
end

local CONNECTION_PREFS = {"ipAddress", "deviceId", "localKey", "protocolVersion"}

local function info_changed(_driver, device, _event, args)
  local old = (args and args.old_st_store and args.old_st_store.preferences) or {}
  local new = device.preferences or {}

  for _, name in ipairs(CONNECTION_PREFS) do
    if old[name] ~= new[name] then
      rt(device).client = nil
      device:set_field(constants.FIELD.PROTOCOL, nil, {persist = true})
      break
    end
  end
  if old.pollInterval ~= new.pollInterval then
    start_polling(device)
  end

  local set_dps
  if old.sensorThreshold ~= new.sensorThreshold then
    local kind = device:get_field(constants.FIELD.SENSOR_KIND) or "humidity"
    set_dps = arida.threshold_dps(dp_map(device), kind, new.sensorThreshold)
  end
  device.thread:call_with_delay(0, function() exchange(device, set_dps) end)
end

local function device_removed(_driver, device)
  stop_polling(device)
  runtime[device.id] = nil
end

-- Commands -------------------------------------------------------------------

local function send(device, dps)
  if dps then exchange(device, dps) end
end

local function component_switch(on)
  return function(_driver, device, command)
    local map = dp_map(device)
    if command.component == "sensorControl" then
      send(device, arida.sensor_control_dps(map, on))
    elseif command.component == "boost" then
      send(device, arida.boost_dps(map, on))
    else
      send(device, arida.switch_dps(map, on))
    end
  end
end

local function set_fan_speed(_driver, device, command)
  send(device, arida.fan_speed_dps(dp_map(device), command.args.speed))
end

local function set_mode(_driver, device, command)
  local dps = arida.mode_dps(dp_map(device), command.args.mode)
  if not dps then
    log.warn(device.label .. ": unknown mode " .. tostring(command.args.mode))
    return
  end
  send(device, dps)
end

local function refresh(_driver, device)
  exchange(device)
end

driver = Driver("arida-tuya-lan", {
  discovery = discovery.handle,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    infoChanged = info_changed,
    removed = device_removed,
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = component_switch(true),
      [capabilities.switch.commands.off.NAME] = component_switch(false),
    },
    [capabilities.fanSpeed.ID] = {
      [capabilities.fanSpeed.commands.setFanSpeed.NAME] = set_fan_speed,
    },
    [capabilities.mode.ID] = {
      [capabilities.mode.commands.setMode.NAME] = set_mode,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh,
    },
  },
  supported_capabilities = {
    capabilities.switch,
    capabilities.fanSpeed,
    capabilities.mode,
    capabilities.relativeHumidityMeasurement,
    capabilities.carbonDioxideMeasurement,
    capabilities.temperatureMeasurement,
    capabilities.filterStatus,
    capabilities.refresh,
  },
})

driver.on_keys_changed = keys_changed

-- Ask for keys once after start-up, so units appear right after installing
-- the driver while tools/push-keys.py is running, without a scan.
driver:call_with_delay(3, function()
  discovery.provision(driver, keys_changed)
end, "key setup")

driver:run()
