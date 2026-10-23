-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 drdecibel
--
-- One TCP connection per exchange: connect, negotiate a session if the
-- protocol needs one, optionally write DPs, read the full status, close.
-- Holding a connection open buys little at a 30 second poll and makes
-- recovery after Wi-Fi drops harder to reason about.
--
-- The protocol version is either fixed by the user or found by trying 3.3,
-- 3.4 and 3.5 in turn. A version is remembered once a device has answered
-- with it, and probing starts over after repeated failures.

local P = require("tuya.payload")

local VERSIONS = {
  ["3.3"] = require("tuya.v33"),
  ["3.4"] = require("tuya.v34"),
  ["3.5"] = require("tuya.v35"),
}
local PROBE_ORDER = {"3.3", "3.4", "3.5"}

local Client = {}
Client.__index = Client
Client.PORT = 6668
Client.VERSIONS = VERSIONS

local sequence = 0
local function next_seq()
  sequence = (sequence + 1) % 0x7FFFFFFF
  return sequence
end

--- opts: ip, local_key, device_id, version ("auto" or "3.x"), timeout,
--- tcp (socket factory, default cosock.socket.tcp), log.
function Client.new(opts)
  local self = setmetatable({}, Client)
  self.ip = opts.ip
  self.local_key = opts.local_key
  self.device_id = opts.device_id
  self.version = opts.version or "auto"
  self.timeout = opts.timeout or 5
  self.tcp = opts.tcp or require("cosock.socket").tcp
  self.log = opts.log
  self.learned = opts.learned
  return self
end

function Client:_debug(msg)
  if self.log then self.log.debug(msg) end
end

local function merge(into, dps)
  if type(dps) == "table" then
    for k, v in pairs(dps) do
      into[tostring(k)] = v
    end
  end
end

--- Runs one exchange with a specific protocol version.
--- Returns dps, nil, nil on success; nil, err, kind on failure, where kind is
--- "connect" (host unreachable: no point trying another version),
--- "proven" (device speaks this version but the exchange failed) or
--- "protocol" (no sign the device speaks this version).
function Client:_exchange(version, set_dps)
  local V = VERSIONS[version]
  local sock, err = self.tcp()
  if not sock then
    return nil, "socket create failed: " .. tostring(err), "connect"
  end
  sock:settimeout(self.timeout)
  local ok
  ok, err = sock:connect(self.ip, Client.PORT)
  if not ok then
    sock:close()
    return nil, "connect failed: " .. tostring(err), "connect"
  end

  local io = {
    send = function(bytes) return sock:send(bytes) end,
    recv = function(n) return sock:receive(n) end,
    next_seq = next_seq,
  }

  local function fail(msg, kind)
    sock:close()
    return nil, msg, kind
  end

  local key, proven
  key, err, proven = V.handshake(io, self.local_key)
  if not key then
    return fail(err, proven and "proven" or "protocol")
  end

  local status = {}
  local answered = proven

  -- Reads frames until one with `want` arrives. Status pushes (0x08) that
  -- arrive in between are merged, so nothing the device reports is lost.
  local function read_until(want, need_dps)
    for _ = 1, 6 do
      local reply, read_err = V.read(io, key)
      if not reply then
        return nil, read_err
      end
      answered = true
      local parsed, raw = P.decode(reply.text)
      if not parsed then
        if raw and raw:find("data unvalid", 1, true) then
          return nil, "device rejected the request (data unvalid)"
        end
        return nil, "reply was not JSON"
      end
      if parsed.dps then merge(status, parsed.dps) end
      if reply.command == want and (not need_dps or parsed.dps) then
        return true
      end
      if reply.command == P.COMMAND.STATUS and need_dps and parsed.dps then
        -- Some firmwares answer a query with a status push instead.
        return true
      end
    end
    return nil, "no reply to command " .. want
  end

  if set_dps and next(set_dps) then
    local cmd, plaintext = V.control_request(self.device_id, set_dps)
    ok, err = sock:send(V.encode(cmd, next_seq(), plaintext, key))
    if not ok then return fail("send failed: " .. tostring(err), answered and "proven" or "protocol") end
    ok, err = read_until(cmd, false)
    if not ok then return fail(err, answered and "proven" or "protocol") end
  end

  local cmd, plaintext = V.query_request(self.device_id)
  ok, err = sock:send(V.encode(cmd, next_seq(), plaintext, key))
  if not ok then return fail("send failed: " .. tostring(err), answered and "proven" or "protocol") end
  ok, err = read_until(cmd, true)
  if not ok then return fail(err, answered and "proven" or "protocol") end

  sock:close()
  return status
end

--- Writes `set_dps` (optional) and returns the device's full DP table.
--- Returns dps, version on success, or nil, error.
function Client:exchange(set_dps)
  if self.version ~= "auto" then
    local dps, err = self:_exchange(self.version, set_dps)
    if dps then return dps, self.version end
    return nil, err
  end

  if self.learned then
    local dps, err, kind = self:_exchange(self.learned, set_dps)
    if dps then return dps, self.learned end
    if kind ~= "protocol" then
      return nil, err
    end
    self:_debug("learned protocol " .. self.learned .. " failed (" .. tostring(err) .. "); probing again")
    self.learned = nil
  end

  local errors = {}
  for _, version in ipairs(PROBE_ORDER) do
    local dps, err, kind = self:_exchange(version, set_dps)
    if dps then
      self.learned = version
      return dps, version
    end
    errors[#errors + 1] = version .. ": " .. tostring(err)
    if kind == "connect" or kind == "proven" then
      if kind == "proven" then self.learned = version end
      return nil, err
    end
  end
  return nil, "no protocol version answered (" .. table.concat(errors, "; ") .. ")"
end

return Client
