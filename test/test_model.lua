-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 drdecibel
--
-- Arida data point translation.

package.path = "src/?.lua;test/?.lua;test/support/?.lua;" .. package.path
local H = require("support.harness")
local arida = require("arida")

local MAP = arida.parse_dp_map(nil)

-- Status reported by a Venti 160 with CO2 sensor (tuya-local issue 2829).
local VENTI_CO2 = {["1"] = true, ["2"] = "supply", ["3"] = 2, ["9"] = false, ["15"] = false, ["20"] = 12,
  ["21"] = 1, ["22"] = "cancel", ["23"] = 0, ["101"] = false, ["102"] = true, ["103"] = false,
  ["104"] = 1000, ["105"] = 651, ["106"] = false, ["107"] = false}

local HUMIDITY = {["1"] = true, ["2"] = "ventilate", ["3"] = 3, ["103"] = true, ["104"] = 70, ["105"] = 64}

H.test("default DP map", function()
  H.same(MAP, arida.DEFAULT_DP)
end)

H.test("DP map overrides and warnings", function()
  local map, warnings = arida.parse_dp_map("sensor=110, threshold=111;bogus=3 nonsense")
  H.eq(map.sensor, 110)
  H.eq(map.threshold, 111)
  H.eq(map.switch, 1)
  H.eq(#warnings, 2)
end)

H.test("sensor kind: CO2 when readings exceed 100, humidity otherwise", function()
  H.eq(arida.sensor_kind(VENTI_CO2, MAP), "co2")
  H.eq(arida.sensor_kind(HUMIDITY, MAP), "humidity")
  H.eq(arida.sensor_kind({["1"] = true}, MAP), nil)
end)

H.test("humidity unit state", function()
  local s = arida.to_state(HUMIDITY, MAP, "humidity")
  H.eq(s.switch, "on")
  H.eq(s.mode, "ventilate")
  H.eq(s.fan_speed, 3)
  H.eq(s.humidity, 64)
  H.eq(s.co2, nil)
  H.eq(s.threshold, 70)
  H.eq(s.sensor_control, "on")
end)

H.test("CO2 unit state", function()
  local s = arida.to_state(VENTI_CO2, MAP, "co2")
  H.eq(s.mode, "supply")
  H.eq(s.co2, 651)
  H.eq(s.humidity, nil)
  H.eq(s.filter, "normal")
  H.eq(s.boost, "off")
  H.eq(s.temperature, 1)
end)

H.test("fan speed reads 0 while switched off", function()
  local s = arida.to_state({["1"] = false, ["3"] = 2}, MAP, "humidity")
  H.eq(s.fan_speed, 0)
  H.eq(s.speed, 2)
end)

H.test("partial pushes only produce the fields they carry", function()
  H.same(arida.to_state({["105"] = 55}, MAP, "humidity"), {humidity = 55})
end)

H.test("unknown mode values pass through unchanged", function()
  H.eq(arida.to_state({["2"] = "auto"}, MAP, "humidity").mode, "auto")
end)

H.test("string speed values are understood", function()
  H.eq(arida.decode_speed("2"), 2)
  H.eq(arida.decode_speed("high"), 3)
  H.eq(arida.decode_speed(true), nil)
end)

H.test("fan speed commands", function()
  H.same(arida.fan_speed_dps(MAP, 0), {["1"] = false})
  H.same(arida.fan_speed_dps(MAP, 2), {["1"] = true, ["3"] = 2})
  H.same(arida.fan_speed_dps(MAP, 4), {["1"] = true, ["3"] = 3}, "clamped")
end)

H.test("mode commands accept labels and raw values", function()
  H.same(arida.mode_dps(MAP, "Avtrekk"), {["2"] = "exhaust"})
  H.same(arida.mode_dps(MAP, "ventilate"), {["2"] = "ventilate"})
  H.eq(arida.mode_dps(MAP, "Turbo"), nil)
end)

H.test("switch, sensor control and boost commands", function()
  H.same(arida.switch_dps(MAP, true), {["1"] = true})
  H.same(arida.sensor_control_dps(MAP, false), {["103"] = false})
  H.same(arida.boost_dps(MAP, true), {["107"] = true})
end)

H.test("threshold is clamped to the unit's range", function()
  H.same(arida.threshold_dps(MAP, "humidity", 70), {["104"] = 70})
  H.same(arida.threshold_dps(MAP, "humidity", 30), {["104"] = 50})
  H.same(arida.threshold_dps(MAP, "humidity", 120), {["104"] = 95})
  H.same(arida.threshold_dps(MAP, "co2", 1004), {["104"] = 1000})
  H.eq(arida.threshold_dps(MAP, "humidity", 0), nil, "0 leaves the device alone")
  H.eq(math.type(arida.threshold_dps(MAP, "co2", 805)["104"]), "integer")
end)

H.test("unmapped DPs are listed for diagnostics", function()
  local extra = arida.unmapped(VENTI_CO2, MAP)
  H.eq(table.concat(extra, ","), "101=false,102=true,20=12,9=false")
end)

-- Live status from an Arida Base WiFi (protocol 3.5).
local BASE = {["1"] = true, ["2"] = "ventilate", ["3"] = 1, ["15"] = false, ["22"] = "2h", ["23"] = 95,
  ["101"] = true, ["102"] = false, ["103"] = true, ["104"] = 85, ["105"] = 50, ["106"] = false}

H.test("Base WiFi: panel light, timer and time left", function()
  local s = arida.to_state(BASE, MAP, "humidity")
  H.eq(s.light, "off")
  H.eq(s.timer, "2h")
  H.eq(s.timer_left, 95)
  H.eq(s.threshold, 85)
  H.eq(s.humidity, 50)
  H.eq(s.temperature, nil, "no temperature sensor")
  H.eq(s.boost, nil, "no boost")
end)

H.test("panel light and timer commands", function()
  H.same(arida.light_dps(MAP, true), {["15"] = true})
  H.same(arida.timer_dps(MAP, "3h"), {["22"] = "3h"})
  H.same(arida.timer_dps(MAP, "cancel"), {["22"] = "cancel"})
  H.eq(arida.timer_dps(MAP, "12h"), nil, "the Base accepts at most 6h")
  H.eq(arida.timer_dps(MAP, "soon"), nil)
end)

H.done("test_model")
