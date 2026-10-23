-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 drdecibel
--
-- Tuya local protocol 3.4, written to match jasonacox/tinytuya and checked
-- against frames it generates (see test/test_protocol.lua).
--
-- Same 0x55AA frame as 3.3, but:
--   * the check is HMAC-SHA256 (32 bytes) keyed with the current key;
--   * the "3.4" version header is put in front of the plaintext and
--     encrypted with it, not sent in the clear;
--   * every connection starts with a session key negotiation:
--       -> 0x03 local nonce (16)                       ECB(local key)
--       <- 0x04 remote nonce (16) || HMAC(local key, local nonce)
--       -> 0x05 HMAC(local key, remote nonce)          no reply
--     session key = ECB(local key, local nonce XOR remote nonce), unpadded;
--   * queries are 0x10 "{}"; writes are 0x0d {"protocol":5,"t":..,"data":{"dps":..}}.

local crypto = require("tuya.crypto")
local F = require("tuya.frame55")
local P = require("tuya.payload")

local V = {NAME = "3.4"}

function V.encode(command, seq, plaintext, key)
  if not P.NO_VERSION_HEADER[command] then
    plaintext = P.version_header(V.NAME) .. plaintext
  end
  return F.pack(seq, command, crypto.ecb_encrypt(key, plaintext), key)
end

function V.read(io, key)
  local frame, err = F.read(io.recv)
  if not frame then return nil, err end
  local msg
  msg, err = F.unpack(frame, key)
  if not msg then return nil, err end
  if not msg.check_ok then
    return nil, "3.4 HMAC did not verify"
  end
  local text = ""
  if #msg.payload > 0 then
    text, err = crypto.ecb_decrypt(key, msg.payload)
    if not text then return nil, err end
    text = P.strip_version_header(text)
  end
  return {command = msg.command, retcode = msg.retcode, text = text}
end

--- Negotiates the session key. Returns key, nil, true on success, or nil,
--- error, proven. `proven` is true once the device has shown it holds this
--- local key, which settles that it speaks 3.4.
function V.handshake(io, local_key)
  local local_nonce = crypto.random_bytes(16)
  local ok, err = io.send(V.encode(P.COMMAND.SESS_KEY_NEG_START, io.next_seq(), local_nonce, local_key))
  if not ok then
    return nil, "3.4 handshake send failed: " .. tostring(err), false
  end

  local reply
  reply, err = V.read(io, local_key)
  if not reply then
    return nil, "3.4 handshake: " .. tostring(err), false
  end
  if reply.command ~= P.COMMAND.SESS_KEY_NEG_RESP then
    return nil, string.format("3.4 handshake: unexpected command 0x%02x", reply.command), false
  end
  if #reply.text < 48 then
    return nil, "3.4 handshake: short response (" .. #reply.text .. " bytes)", false
  end
  local remote_nonce = reply.text:sub(1, 16)
  if reply.text:sub(17, 48) ~= crypto.hmac_sha256(local_key, local_nonce) then
    return nil, "3.4 handshake: device HMAC did not verify (wrong local key?)", false
  end

  ok, err = io.send(V.encode(P.COMMAND.SESS_KEY_NEG_FINISH, io.next_seq(),
    crypto.hmac_sha256(local_key, remote_nonce), local_key))
  if not ok then
    return nil, "3.4 handshake finish failed: " .. tostring(err), true
  end

  return V.session_key(local_key, local_nonce, remote_nonce), nil, true
end

function V.session_key(local_key, local_nonce, remote_nonce)
  return crypto.ecb_encrypt(local_key, crypto.xor16(local_nonce, remote_nonce), false)
end

function V.query_request(_device_id)
  return P.COMMAND.DP_QUERY_NEW, "{}"
end

function V.control_request(_device_id, dps)
  return P.COMMAND.CONTROL_NEW, P.encode({protocol = 5, t = os.time(), data = {dps = P.encode_dps(dps)}})
end

return V
