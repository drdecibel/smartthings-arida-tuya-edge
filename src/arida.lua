-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 drdecibel
--
-- Translation between Arida's Tuya data points and SmartThings state. Pure
-- functions with no SmartThings dependencies, so they can be tested off-hub.
--
-- Data points, from the Tuya cloud model of the Arida Venti 160 (product
-- npf4762xatmaw29g) and reports from the humidity-sensor variant, which uses
-- 103-105 for humidity instead of CO2:
--
--   1    switch          bool
--   2    mode            enum  supply | exhaust | ventilate
--   3    fan_speed       value 1-3
--   15   light           bool  panel indicator light
--   22   countdown_set   enum  cancel | 1h .. 6h (switches the unit off)
--   23   countdown_left  value minutes left on the timer (read only)
--   21   temp_current    value °C (read only)
--   103  sensor control  bool  humidity (or CO2) control on/off
--   104  threshold       value %RH 50-95, or ppm 400-2000 on CO2 units
--   105  sensor value    value %RH, or ppm on CO2 units (read only)
--   106  filter          bool  filter needs cleaning (read only)
--   107  powerful        bool  boost: maximum speed for 30 minutes
--
-- Every DP number can be overridden with the "DP map" preference, in case a
-- firmware numbers them differently.

local M = {}

M.DEFAULT_DP = {
  switch = 1,
  mode = 2,
  speed = 3,
  light = 15,
  timer = 22,
  timer_left = 23,
  temperature = 21,
  sensor_control = 103,
  threshold = 104,
  sensor = 105,
  filter = 106,
  boost = 107,
}

M.MIN_SPEED = 1
M.MAX_SPEED = 3

-- Tuya mode value -> label shown in SmartThings.
M.MODES = {
  {value = "ventilate", label = "Varmegjenvinning"},
  {value = "supply", label = "Tilluft"},
  {value = "exhaust", label = "Avtrekk"},
}

-- Off-timer values the Base WiFi accepts (the Venti goes up to 12h).
M.TIMER_VALUES = {cancel = true, ["1h"] = true, ["2h"] = true, ["3h"] = true,
  ["4h"] = true, ["5h"] = true, ["6h"] = true}

M.THRESHOLD_RANGE = {
  humidity = {min = 50, max = 95, step = 1},
  co2 = {min = 400, max = 2000, step = 10},
}

--- Parses "name=dp, name=dp" into a full map, starting from the defaults.
--- Unknown names and malformed entries are ignored and returned as warnings.
function M.parse_dp_map(text)
  local map = {}
  for k, v in pairs(M.DEFAULT_DP) do map[k] = v end
  local warnings = {}
  if type(text) ~= "string" then return map, warnings end
  for entry in text:gmatch("[^,;%s]+") do
    local name, dp = entry:match("^([%a_]+)=(%d+)$")
    if name and M.DEFAULT_DP[name] then
      map[name] = tonumber(dp)
    else
      warnings[#warnings + 1] = entry
    end
  end
  return map, warnings
end

--- Tuya mode value for a mode value or a label, or nil if unknown.
function M.mode_for_label(label)
  for _, m in ipairs(M.MODES) do
    if m.label == label or m.value == label then return m.value end
  end
  return nil
end

--- Humidity units report 0-100 %RH; CO2 units report and accept ppm in the
--- hundreds. Returns "humidity", "co2" or nil when the DPs are absent.
function M.sensor_kind(dps, map)
  local value = dps[tostring(map.sensor)]
  local threshold = dps[tostring(map.threshold)]
  if math.type(value) == nil and math.type(threshold) == nil then
    return nil
  end
  if (math.type(value) and value > 100) or (math.type(threshold) and threshold > 100) then
    return "co2"
  end
  return "humidity"
end

local function get(dps, dp)
  return dps[tostring(dp)]
end

--- Reads the speed DP, which is an integer on known firmware. String enums
--- ("1"/"low") are accepted in case a variant uses one.
local SPEED_WORDS = {low = 1, mid = 2, middle = 2, medium = 2, high = 3}
function M.decode_speed(raw)
  if math.type(raw) then return raw end
  if type(raw) == "string" then
    return tonumber(raw) or SPEED_WORDS[raw:lower()]
  end
  return nil
end

--- Converts a DP table into the SmartThings state the driver reports. Only
--- DPs present in `dps` produce fields, so a partial push updates only what
--- it carries.
function M.to_state(dps, map, kind)
  local s = {}
  local power = get(dps, map.switch)
  if type(power) == "boolean" then s.switch = power and "on" or "off" end

  -- The ventilation mode capability uses Tuya's own values; its
  -- presentation shows them as Varmegjenvinning / Tilluft / Avtrekk.
  local mode = get(dps, map.mode)
  if type(mode) == "string" then s.mode = mode end

  local speed = M.decode_speed(get(dps, map.speed))
  if speed then s.speed = speed end
  if s.switch == "off" then
    s.fan_speed = 0
  elseif speed then
    s.fan_speed = speed
  end

  local light = get(dps, map.light)
  if type(light) == "boolean" then s.light = light and "on" or "off" end

  local timer = get(dps, map.timer)
  if type(timer) == "string" then s.timer = timer end

  local timer_left = get(dps, map.timer_left)
  if math.type(timer_left) then s.timer_left = timer_left end

  local temperature = get(dps, map.temperature)
  if math.type(temperature) then s.temperature = temperature end

  local control = get(dps, map.sensor_control)
  if type(control) == "boolean" then s.sensor_control = control and "on" or "off" end

  local sensor = get(dps, map.sensor)
  if math.type(sensor) then
    if kind == "co2" then s.co2 = sensor else s.humidity = sensor end
  end

  local threshold = get(dps, map.threshold)
  if math.type(threshold) then s.threshold = threshold end

  local filter = get(dps, map.filter)
  if type(filter) == "boolean" then s.filter = filter and "replace" or "normal" end

  local boost = get(dps, map.boost)
  if type(boost) == "boolean" then s.boost = boost and "on" or "off" end

  return s
end

--- DP ids present in `dps` that the map does not cover, for diagnostics.
function M.unmapped(dps, map)
  local known = {}
  for _, dp in pairs(map) do known[tostring(dp)] = true end
  local out = {}
  for k, v in pairs(dps) do
    if not known[tostring(k)] then out[#out + 1] = tostring(k) .. "=" .. tostring(v) end
  end
  table.sort(out)
  return out
end

local function clamp(n, lo, hi)
  if n < lo then return lo end
  if n > hi then return hi end
  return n
end

-- Command builders. Each returns a DP table to write.

function M.switch_dps(map, on)
  return {[tostring(map.switch)] = on}
end

--- SmartThings fanSpeed 0 means off; anything above the top speed is clamped.
function M.fan_speed_dps(map, speed)
  speed = math.floor(tonumber(speed) or 0)
  if speed <= 0 then
    return {[tostring(map.switch)] = false}
  end
  return {[tostring(map.switch)] = true, [tostring(map.speed)] = clamp(speed, M.MIN_SPEED, M.MAX_SPEED)}
end

function M.mode_dps(map, label)
  local value = M.mode_for_label(label)
  if not value then return nil end
  return {[tostring(map.mode)] = value}
end

function M.sensor_control_dps(map, on)
  return {[tostring(map.sensor_control)] = on}
end

function M.light_dps(map, on)
  return {[tostring(map.light)] = on}
end

--- Returns nil for a value the unit does not accept.
function M.timer_dps(map, value)
  if not M.TIMER_VALUES[value] then return nil end
  return {[tostring(map.timer)] = value}
end

function M.boost_dps(map, on)
  return {[tostring(map.boost)] = on}
end

--- Clamps and rounds a threshold to the unit's range. Returns nil for 0 or
--- an empty preference, which means "leave the device's setting alone".
function M.threshold_dps(map, kind, value)
  value = tonumber(value)
  if not value or value <= 0 then return nil end
  local r = M.THRESHOLD_RANGE[kind or "humidity"]
  value = clamp(math.floor(value / r.step + 0.5) * r.step, r.min, r.max)
  return {[tostring(map.threshold)] = math.tointeger(value)}
end

return M
