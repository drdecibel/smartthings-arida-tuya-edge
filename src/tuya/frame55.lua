-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 drdecibel
--
-- The 0x000055AA frame used by Tuya protocols 3.1 to 3.4.
--
--   4  prefix    0x000055AA
--   4  sequence
--   4  command
--   4  length    bytes after this field: payload + check + suffix
--   N  payload   device->client frames may start with a clear 4-byte retcode
--   4 / 32       CRC32 (3.3) or HMAC-SHA256 (3.4) over prefix..payload
--   4  suffix    0x0000AA55

local crypto = require("tuya.crypto")
local CRC32 = require("tuya.crc32")

local F = {}

F.PREFIX = 0x000055AA
F.SUFFIX = 0x0000AA55
F.HEADER_LEN = 16
-- Anything larger is a desynchronised stream, not a real Tuya frame.
F.MAX_LENGTH = 4096

--- Builds a frame. With `hmac_key` the check is HMAC-SHA256 (3.4),
--- otherwise CRC32 (3.3).
function F.pack(seq, command, payload, hmac_key)
  local check_len = hmac_key and 32 or 4
  local head = string.pack(">I4I4I4I4", F.PREFIX, seq & 0xFFFFFFFF, command, #payload + check_len + 4)
  local body = head .. payload
  local check
  if hmac_key then
    check = crypto.hmac_sha256(hmac_key, body)
  else
    check = string.pack(">I4", CRC32.compute(body))
  end
  return body .. check .. string.pack(">I4", F.SUFFIX)
end

--- Reads one complete frame with `recv(n)`. Returns the bytes or nil, error.
function F.read(recv)
  local header, err = recv(F.HEADER_LEN)
  if not header then
    return nil, "receive failed: " .. tostring(err)
  end
  local prefix, _, _, length = string.unpack(">I4I4I4I4", header)
  if prefix ~= F.PREFIX then
    return nil, string.format("unexpected frame prefix 0x%08X", prefix)
  end
  if length < 8 or length > F.MAX_LENGTH then
    return nil, "implausible frame length " .. length
  end
  local rest
  rest, err = recv(length)
  if not rest then
    return nil, "receive failed: " .. tostring(err)
  end
  return header .. rest
end

--- Splits a frame. Returns {seq, command, retcode, payload, check_ok}, or
--- nil, error. The retcode is detected the way tinytuya does it: a leading
--- big-endian word below 256 that is not the start of a version header.
function F.unpack(frame, hmac_key)
  if #frame < F.HEADER_LEN + 8 then
    return nil, "frame too short"
  end
  local prefix, seq, command, length = string.unpack(">I4I4I4I4", frame)
  if prefix ~= F.PREFIX then
    return nil, string.format("unexpected frame prefix 0x%08X", prefix)
  end
  local check_len = hmac_key and 32 or 4
  if #frame < F.HEADER_LEN + length or length < check_len + 4 then
    return nil, "frame truncated"
  end
  local body_end = F.HEADER_LEN + length - check_len - 4
  local body = frame:sub(1, body_end)
  local check = frame:sub(body_end + 1, body_end + check_len)
  local check_ok
  if hmac_key then
    check_ok = crypto.hmac_sha256(hmac_key, body) == check
  else
    check_ok = string.pack(">I4", CRC32.compute(body)) == check
  end

  local payload = body:sub(F.HEADER_LEN + 1)
  local retcode
  if #payload >= 4 and payload:sub(1, 1) ~= "3" and (string.unpack(">I4", payload) & 0xFFFFFF00) == 0 then
    retcode = string.unpack(">I4", payload)
    payload = payload:sub(5)
  end
  return {seq = seq, command = command, retcode = retcode, payload = payload, check_ok = check_ok}
end

return F
