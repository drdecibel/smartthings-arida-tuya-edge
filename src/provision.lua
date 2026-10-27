-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 drdecibel
--
-- Key provisioning from a PC, so nobody has to type a local key on a phone.
--
-- The driver broadcasts a short request to UDP SETUP_PORT and listens for
-- replies on the same ephemeral socket, the way the Daikin driver discovers
-- adapters; the hub never has to bind a fixed port. tools/push-keys.py,
-- running on a PC, answers with the units from tinytuya's devices.json:
--
--   request  "ARIDA-TUYA-SETUP 1"
--   reply    {"arida_setup":1,"units":[{"id":..,"key":..,"name":..,"ip":..,"version":..}]}
--
-- Units are kept in the driver datastore on the hub, keyed by Tuya device
-- ID, and each gets a device whose network ID carries that ID. Keys never
-- leave the local network and are never logged.

local json = require("dkjson")

local M = {}

M.SETUP_PORT = 47811
M.REQUEST = "ARIDA-TUYA-SETUP 1"
M.BROADCAST = "255.255.255.255"
M.NETWORK_ID_PREFIX = "arida-tuya-id-"
M.LISTEN_SECONDS = 4

function M.network_id(tuya_id)
  return M.NETWORK_ID_PREFIX .. tuya_id
end

--- The Tuya device ID a provisioned device's network ID carries, or nil.
function M.tuya_id(network_id)
  if type(network_id) ~= "string" then return nil end
  if network_id:sub(1, #M.NETWORK_ID_PREFIX) ~= M.NETWORK_ID_PREFIX then return nil end
  return network_id:sub(#M.NETWORK_ID_PREFIX + 1)
end

local function valid_unit(u)
  return type(u) == "table" and type(u.id) == "string" and u.id:match("^[%w]+$") ~= nil
    and #u.id >= 10 and #u.id <= 40 and type(u.key) == "string" and #u.key == 16
end

--- Parses a reply. Returns a list of {id, key, name, ip, version} or nil, err.
--- Malformed units are dropped; the count of dropped units is returned second.
function M.parse_reply(text)
  local ok, msg = pcall(json.decode, text)
  if not ok or type(msg) ~= "table" or msg.arida_setup ~= 1 or type(msg.units) ~= "table" then
    return nil, "not an Arida setup reply"
  end
  local units, dropped = {}, 0
  for _, u in ipairs(msg.units) do
    if valid_unit(u) then
      units[#units + 1] = {
        id = u.id,
        key = u.key,
        name = type(u.name) == "string" and u.name:sub(1, 60) or nil,
        ip = type(u.ip) == "string" and u.ip or nil,
        version = (u.version == "3.3" or u.version == "3.4" or u.version == "3.5") and u.version or nil,
      }
    else
      dropped = dropped + 1
    end
  end
  return units, dropped
end

--- Broadcasts the request and collects replies for `seconds`. Returns a
--- list of units (deduplicated by id) and the number of PCs that answered.
--- opts.udp: socket factory (default cosock.socket.udp).
function M.request(seconds, opts)
  opts = opts or {}
  local udp_factory = opts.udp or require("cosock.socket").udp
  local log = opts.log
  local udp = udp_factory()
  if not udp then return {}, 0 end
  udp:setoption("broadcast", true)
  udp:setsockname("0.0.0.0", 0)
  udp:settimeout(seconds or M.LISTEN_SECONDS)

  local sent, err = udp:sendto(M.REQUEST, M.BROADCAST, M.SETUP_PORT)
  if not sent then
    if log then log.debug("Key setup broadcast failed: " .. tostring(err)) end
    udp:close()
    return {}, 0
  end

  local by_id, order, answers = {}, {}, 0
  while true do
    local data = udp:receivefrom()
    if not data then break end
    local units = M.parse_reply(data)
    if units then
      answers = answers + 1
      for _, u in ipairs(units) do
        if not by_id[u.id] then order[#order + 1] = u.id end
        by_id[u.id] = u
      end
    end
  end
  udp:close()

  local out = {}
  for i, id in ipairs(order) do out[i] = by_id[id] end
  return out, answers
end

-- Datastore ------------------------------------------------------------------

local function store(driver)
  local ds = driver.datastore
  if ds.units == nil then ds.units = {} end
  return ds
end

function M.lookup(driver, tuya_id)
  if not tuya_id then return nil end
  return store(driver).units[tuya_id]
end

--- True once any unit has been provisioned from a PC.
function M.any(driver)
  return next(store(driver).units) ~= nil
end

--- Saves units. Returns the ids that were new or whose key changed.
function M.save(driver, units)
  local ds = store(driver)
  local changed = {}
  for _, u in ipairs(units) do
    local old = ds.units[u.id]
    if not old or old.key ~= u.key or old.version ~= u.version then
      changed[#changed + 1] = u.id
    end
    ds.units[u.id] = {key = u.key, name = u.name, ip = u.ip, version = u.version}
  end
  -- Assigning a fresh table makes the datastore notice nested changes.
  local copy = {}
  for k, v in pairs(ds.units) do copy[k] = v end
  ds.units = copy
  if type(ds.save) == "function" then ds:save() end
  return changed
end

return M
