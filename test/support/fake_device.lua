-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 drdecibel
--
-- A fake Tuya device behind a fake cosock TCP socket. It answers from the
-- tinytuya-generated vectors, so the client is exercised against frames the
-- reference implementation produced, not against this driver's own encoder.

local crypto = require("tuya.crypto")
local F = require("tuya.frame55")
local vectors = require("fixtures.vectors")

local X = {}
for k, v in pairs(vectors) do X[k] = crypto.unhex(v) end

local M = {X = X}

local function frame_command(bytes)
  if string.unpack(">I4", bytes) == 0x6699 then
    return string.unpack(">I4", bytes, 11)
  end
  return string.unpack(">I4", bytes, 9)
end

-- Device behaviours keyed by the protocol it speaks. Each maps a received
-- command to the bytes to send back (nil = stay silent, like a real device
-- that cannot decrypt a frame).
local BEHAVIOUR = {
  ["3.3"] = function(cmd, state)
    if cmd == 0x0a then return X.v33_reply_plain end
    if cmd == 0x07 then
      state.writes = state.writes + 1
      return X.v33_reply_header -- status push, then the control ack
        .. F.pack(1, 0x07, "\0\0\0\0")
    end
  end,
  ["3.4"] = function(cmd, state)
    if cmd == 0x03 then return X.v34_resp end
    if cmd == 0x05 then state.handshakes = state.handshakes + 1 return nil end
    if cmd == 0x10 then return X.v34_reply end
    if cmd == 0x0d then
      state.writes = state.writes + 1
      return X.v34_push .. F.pack(1, 0x0d, "\0\0\0\0", X.v34_session_key)
    end
  end,
  ["3.5"] = function(cmd, state)
    if cmd == 0x03 then return X.v35_resp end
    if cmd == 0x05 then state.handshakes = state.handshakes + 1 return nil end
    if cmd == 0x10 then return X.v35_reply end
  end,
}

--- Whether a device speaking `version` can authenticate `bytes`. A device
--- stays silent on anything else, which is what real devices do.
function M.accepts(version, bytes)
  local is6699 = string.unpack(">I4", bytes) == 0x6699
  if version == "3.5" or is6699 then return is6699 and version == "3.5" end
  if version == "3.3" then
    local m = F.unpack(bytes)
    return m ~= nil and m.check_ok
  end
  for _, key in ipairs({X.local_key, X.v34_session_key}) do
    local m = F.unpack(bytes, key)
    if m and m.check_ok then return true end
  end
  return false
end

--- Returns a socket factory for a device speaking `version`, and its state.
--- `opts.unreachable` makes connect fail.
function M.factory(version, opts)
  opts = opts or {}
  local state = {connections = 0, handshakes = 0, writes = 0, received = {}}
  local function tcp()
    local inbox = ""
    local sock = {}
    function sock:settimeout() end
    function sock:connect()
      if opts.unreachable then return nil, "No route to host" end
      state.connections = state.connections + 1
      return true
    end
    function sock:send(bytes)
      state.received[#state.received + 1] = bytes
      if not M.accepts(version, bytes) then return #bytes end
      local reply = BEHAVIOUR[version](frame_command(bytes), state)
      if reply then inbox = inbox .. reply end
      return #bytes
    end
    function sock:receive(n)
      if #inbox < n then return nil, "timeout" end
      local out = inbox:sub(1, n)
      inbox = inbox:sub(n + 1)
      return out
    end
    function sock:close() end
    return sock
  end
  return tcp, state
end

--- Makes crypto.random_bytes return the fixed nonce, then the fixed IV.
function M.fix_randomness()
  crypto.random_bytes = function(n)
    if n == 16 then return X.local_nonce end
    if n == 12 then return X.gcm_iv end
    return string.rep("\0", n)
  end
end

return M
