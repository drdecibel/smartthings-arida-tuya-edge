-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 drdecibel
--
-- Tuya local protocol 3.3: 0x55AA frames with CRC32, payload AES-128-ECB
-- with the local key. Commands other than queries carry a clear "3.3" + 12
-- zero byte header in front of the ciphertext. Replies may carry it too.

local crypto = require("tuya.crypto")
local F = require("tuya.frame55")
local P = require("tuya.payload")

local V = {NAME = "3.3"}

function V.encode(command, seq, plaintext, key)
  local data = crypto.ecb_encrypt(key, plaintext)
  if not P.NO_VERSION_HEADER[command] then
    data = P.version_header(V.NAME) .. data
  end
  return F.pack(seq, command, data)
end

--- Reads and decrypts one frame. Returns {command, retcode, text} or nil, err.
function V.read(io, key)
  local frame, err = F.read(io.recv)
  if not frame then return nil, err end
  local msg
  msg, err = F.unpack(frame)
  if not msg then return nil, err end
  local data = P.strip_version_header(msg.payload)
  local text = ""
  if #data > 0 then
    text, err = crypto.ecb_decrypt(key, data)
    if not text then return nil, err end
  end
  return {command = msg.command, retcode = msg.retcode, text = text}
end

--- 3.3 has no session: the local key is used for every frame.
function V.handshake(_io, key)
  return key, nil, false
end

function V.query_request(device_id)
  local t = tostring(os.time())
  return P.COMMAND.DP_QUERY, P.encode({gwId = device_id, devId = device_id, uid = device_id, t = t})
end

function V.control_request(device_id, dps)
  local t = tostring(os.time())
  return P.COMMAND.CONTROL, P.encode({devId = device_id, uid = device_id, t = t, dps = P.encode_dps(dps)})
end

return V
