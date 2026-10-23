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

local function client_for(device)
  local r = rt(device)
  if r.client then return r.client end
  local p = device.preferences or {}
  if not discovery.is_configured(device) or p.localKey == constants.PLACEHOLDER_KEY then
    return nil, "not configured: enter IP address, device ID and local key in the device settings"
  end
  if #(p.localKey or "") ~= 16 then
    return nil, "the local key must be exactly 16 characters"
  end
  r.client = Client.new({
    ip = p.ipAddress,
    device_id = p.deviceId,
    local_key = p.localKey,
    version = p.protocolVersion or "auto",
    timeout = constants.TIMEOUT_SECONDS,
    learned = device:get_field(constants.FIELD.PROTOCOL),
    log = log,
  })
  return r.client
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

--- Writes `set_dps` (or nothing) and reports the resulting state. All calls
--- for one device run on its own thread, so they never overlap.
local function exchange(device, set_dps)
  local client, err = client_for(device)
  if not client then
    log.warn(device.label .. ": " .. err)
    device:offline()
    return false
  end

  local r = rt(device)
  local dps, version_or_err = client:exchange(set_dps)
  if not dps then
    r.failures = r.failures + 1
    log.warn(string.format("%s: exchange failed (%d in a row): %s", device.label, r.failures, tostring(version_or_err)))
    if r.failures >= constants.OFFLINE_AFTER then
      device:offline()
    end
    return false
  end

  if r.failures > 0 or not r.online then
    log.info(device.label .. ": connected with Tuya protocol " .. version_or_err)
  end
  r.failures = 0
  r.online = true
  if device:get_field(constants.FIELD.PROTOCOL) ~= version_or_err then
    device:set_field(constants.FIELD.PROTOCOL, version_or_err, {persist = true})
  end
  device:online()
  emit_state(device, dps)
  return true
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
  if not discovery.is_configured(device) then
    log.info(device.label .. ": added; open its settings and enter IP address, device ID and local key")
  end
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

local driver = Driver("arida-tuya-lan", {
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

driver:run()
