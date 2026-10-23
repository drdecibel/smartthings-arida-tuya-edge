-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 drdecibel
--
-- Byte-string crypto helpers shared by the Tuya 3.3, 3.4 and 3.5 codecs.
-- The SmartThings Edge runtime ships no AES or SHA-256, so everything here is
-- pure Lua 5.3. AES encryption uses the table-driven block function from
-- gcm.lua; AES decryption uses lua-lockbox. SHA-256 and HMAC are derived from
-- the ST-SmartHome Tuya 3.5 module (MIT, see LICENSE-ST-SmartHome).

local GCM = require("tuya.gcm")

-- Only lua-lockbox's raw AES block functions are bundled (MIT, see
-- src/lockbox/LICENSE); ECB mode is done here, as the Tuya protocol requires.
local AES128 = require("lockbox.cipher.aes128")
local Array = require("lockbox.util.array")

local M = {}

function M.pkcs7_pad(data)
  local pad = 16 - (#data % 16)
  return data .. string.rep(string.char(pad), pad)
end

--- Removes PKCS7 padding. Malformed padding is left in place, as tinytuya
--- does with verify_padding=False.
function M.pkcs7_unpad(data)
  local n = #data
  if n == 0 then return data end
  local pad = string.byte(data, n)
  if pad < 1 or pad > 16 or pad > n then return data end
  for i = n - pad + 1, n do
    if string.byte(data, i) ~= pad then return data end
  end
  return data:sub(1, n - pad)
end

--- AES-128-ECB. `pad` defaults to true.
function M.ecb_encrypt(key, data, pad)
  assert(#key == 16, "AES key must be 16 bytes")
  if pad ~= false then data = M.pkcs7_pad(data) end
  assert(#data % 16 == 0, "ECB input must be a multiple of 16 bytes")
  local out = {}
  for i = 1, #data, 16 do
    out[#out + 1] = GCM._aes_block(key, data:sub(i, i + 15))
  end
  return table.concat(out)
end

--- AES-128-ECB decryption followed by PKCS7 unpadding. Returns nil, error if
--- the input is not a whole number of blocks.
function M.ecb_decrypt(key, data)
  assert(#key == 16, "AES key must be 16 bytes")
  if #data % 16 ~= 0 then
    return nil, "ciphertext length " .. #data .. " is not a multiple of 16"
  end
  local key_array = Array.fromString(key)
  local out = {}
  for i = 1, #data, 16 do
    out[#out + 1] = Array.toString(AES128.decrypt(key_array, Array.fromString(data:sub(i, i + 15))))
  end
  return M.pkcs7_unpad(table.concat(out))
end

local K256 = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function rotr(x, n)
  return ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF
end

function M.sha256(msg)
  local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
  local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  local len = #msg
  msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64) .. string.pack(">I8", len * 8)
  local w = {}
  for chunk = 1, #msg, 64 do
    for i = 1, 16 do
      w[i] = string.unpack(">I4", msg, chunk + (i - 1) * 4)
    end
    for i = 17, 64 do
      local a, b = w[i - 15], w[i - 2]
      local s0 = rotr(a, 7) ~ rotr(a, 18) ~ (a >> 3)
      local s1 = rotr(b, 17) ~ rotr(b, 19) ~ (b >> 10)
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF
    end
    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for i = 1, 64 do
      local S1 = rotr(e, 6) ~ rotr(e, 11) ~ rotr(e, 25)
      local ch = (e & f) ~ (~e & g)
      local t1 = (h + S1 + ch + K256[i] + w[i]) & 0xFFFFFFFF
      local S0 = rotr(a, 2) ~ rotr(a, 13) ~ rotr(a, 22)
      local maj = (a & b) ~ (a & c) ~ (b & c)
      local t2 = (S0 + maj) & 0xFFFFFFFF
      h, g, f, e, d, c, b, a = g, f, e, (d + t1) & 0xFFFFFFFF, c, b, a, (t1 + t2) & 0xFFFFFFFF
    end
    h0, h1, h2, h3 = (h0 + a) & 0xFFFFFFFF, (h1 + b) & 0xFFFFFFFF, (h2 + c) & 0xFFFFFFFF, (h3 + d) & 0xFFFFFFFF
    h4, h5, h6, h7 = (h4 + e) & 0xFFFFFFFF, (h5 + f) & 0xFFFFFFFF, (h6 + g) & 0xFFFFFFFF, (h7 + h) & 0xFFFFFFFF
  end
  return string.pack(">I4I4I4I4I4I4I4I4", h0, h1, h2, h3, h4, h5, h6, h7)
end

function M.hmac_sha256(key, msg)
  if #key > 64 then key = M.sha256(key) end
  key = key .. string.rep("\0", 64 - #key)
  local ipad, opad = {}, {}
  for i = 1, 64 do
    local b = string.byte(key, i)
    ipad[i] = string.char(b ~ 0x36)
    opad[i] = string.char(b ~ 0x5C)
  end
  return M.sha256(table.concat(opad) .. M.sha256(table.concat(ipad) .. msg))
end

function M.xor16(a, b)
  local a1, a2 = string.unpack(">i8i8", a)
  local b1, b2 = string.unpack(">i8i8", b)
  return string.pack(">i8i8", a1 ~ b1, a2 ~ b2)
end

--- Random bytes for nonces and GCM IVs. Replaceable for tests.
M.random_bytes = function(n)
  local t = {}
  for i = 1, n do
    t[i] = string.char(math.random(0, 255))
  end
  return table.concat(t)
end

function M.hex(s)
  return (s:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
end

function M.unhex(h)
  return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end))
end

return M
