-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 drdecibel
--
-- Tuya local protocol 3.5. Adapted from the ST-SmartHome Tuya 3.5 module
-- (MIT, see LICENSE-ST-SmartHome), which was verified against real devices.
--
-- Frame (big-endian):
--   4 prefix 0x00006699, 2 zero, 4 sequence, 4 command,
--   4 length = 12 (IV) + ciphertext + 16 (tag),
--   12 IV, N ciphertext, 16 GCM tag, 4 suffix 0x00009966
-- AES-128-GCM; the additional authenticated data is the 14 header bytes
-- after the prefix. The session handshake mirrors 3.4, except that the
-- session key is GCM(local key, IV = local nonce[1..12], local XOR remote).

local crypto = require("tuya.crypto")
local GCM = require("tuya.gcm")
local P = require("tuya.payload")

local V = {NAME = "3.5"}

local PREFIX = 0x00006699
local SUFFIX = 0x00009966
local HEADER_LEN = 18

function V.encode(command, seq, plaintext, key)
  if not P.NO_VERSION_HEADER[command] then
    plaintext = P.version_header(V.NAME) .. plaintext
  end
  local iv = crypto.random_bytes(12)
  local header = string.pack(">I4I2I4I4I4", PREFIX, 0, seq & 0xFFFFFFFF, command, 12 + #plaintext + 16)
  local ciphertext, tag = GCM.encrypt(key, iv, plaintext, header:sub(5))
  return header .. iv .. ciphertext .. tag .. string.pack(">I4", SUFFIX)
end

local function decode(frame, key)
  if #frame < HEADER_LEN + 28 + 4 then
    return nil, "3.5 frame too short"
  end
  local _, _, _, command, length = string.unpack(">I4I2I4I4I4", frame)
  local body = frame:sub(HEADER_LEN + 1, HEADER_LEN + length)
  local plaintext, err = GCM.decrypt(key, body:sub(1, 12), body:sub(13, #body - 16),
    frame:sub(5, HEADER_LEN), body:sub(#body - 15))
  if not plaintext then
    return nil, "3.5 decrypt failed: " .. tostring(err)
  end
  return command, plaintext
end

function V.read(io, key)
  local header, err = io.recv(HEADER_LEN)
  if not header then return nil, "receive failed: " .. tostring(err) end
  if string.unpack(">I4", header) ~= PREFIX then
    return nil, "not a 3.5 frame"
  end
  local length = string.unpack(">I4", header, 15)
  if length < 28 or length > 4096 then
    return nil, "implausible frame length " .. length
  end
  local rest
  rest, err = io.recv(length + 4)
  if not rest then return nil, "receive failed: " .. tostring(err) end

  local command, plaintext = decode(header .. rest, key)
  if not command then return nil, plaintext end

  local retcode
  if #plaintext >= 4 and plaintext:sub(1, 1) ~= "{" and plaintext:sub(1, 3) ~= "3.5"
      and command ~= P.COMMAND.SESS_KEY_NEG_RESP then
    retcode = string.unpack(">I4", plaintext)
    plaintext = plaintext:sub(5)
  end
  return {command = command, retcode = retcode, text = P.strip_version_header(plaintext)}
end

function V.handshake(io, local_key)
  local local_nonce = crypto.random_bytes(16)
  local ok, err = io.send(V.encode(P.COMMAND.SESS_KEY_NEG_START, io.next_seq(), local_nonce, local_key))
  if not ok then
    return nil, "3.5 handshake send failed: " .. tostring(err), false
  end

  local reply
  reply, err = V.read(io, local_key)
  if not reply then
    return nil, "3.5 handshake: " .. tostring(err), false
  end
  if reply.command ~= P.COMMAND.SESS_KEY_NEG_RESP then
    return nil, string.format("3.5 handshake: unexpected command 0x%02x", reply.command), false
  end
  local text = reply.text
  if #text == 52 then
    text = text:sub(5) -- retcode
  end
  if #text < 48 then
    return nil, "3.5 handshake: short response (" .. #text .. " bytes)", false
  end
  local remote_nonce = text:sub(1, 16)
  if text:sub(17, 48) ~= crypto.hmac_sha256(local_key, local_nonce) then
    return nil, "3.5 handshake: device HMAC did not verify (wrong local key?)", false
  end

  ok, err = io.send(V.encode(P.COMMAND.SESS_KEY_NEG_FINISH, io.next_seq(),
    crypto.hmac_sha256(local_key, remote_nonce), local_key))
  if not ok then
    return nil, "3.5 handshake finish failed: " .. tostring(err), true
  end

  return V.session_key(local_key, local_nonce, remote_nonce), nil, true
end

function V.session_key(local_key, local_nonce, remote_nonce)
  local key = GCM.encrypt(local_key, local_nonce:sub(1, 12), crypto.xor16(local_nonce, remote_nonce))
  return key:sub(1, 16)
end

function V.query_request(_device_id)
  return P.COMMAND.DP_QUERY_NEW, "{}"
end

function V.control_request(_device_id, dps)
  return P.COMMAND.CONTROL_NEW, P.encode({protocol = 5, t = os.time(), data = {dps = P.encode_dps(dps)}})
end

return V
