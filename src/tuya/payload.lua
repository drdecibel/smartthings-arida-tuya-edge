-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 drdecibel
--
-- JSON payload helpers shared by the protocol versions.

local json = require("dkjson")

local M = {}

M.COMMAND = {
  SESS_KEY_NEG_START = 0x03,
  SESS_KEY_NEG_RESP = 0x04,
  SESS_KEY_NEG_FINISH = 0x05,
  CONTROL = 0x07,
  STATUS = 0x08,
  HEART_BEAT = 0x09,
  DP_QUERY = 0x0a,
  CONTROL_NEW = 0x0d,
  DP_QUERY_NEW = 0x10,
}

--- Commands sent without the clear "3.x" + 12 zero byte version header.
M.NO_VERSION_HEADER = {
  [M.COMMAND.SESS_KEY_NEG_START] = true,
  [M.COMMAND.SESS_KEY_NEG_RESP] = true,
  [M.COMMAND.SESS_KEY_NEG_FINISH] = true,
  [M.COMMAND.HEART_BEAT] = true,
  [M.COMMAND.DP_QUERY] = true,
  [M.COMMAND.DP_QUERY_NEW] = true,
}

function M.version_header(version)
  return version .. string.rep("\0", 12)
end

--- Removes a leading "3.x" version header if present.
function M.strip_version_header(data)
  if #data >= 15 and data:match("^3%.%d") then
    return data:sub(16)
  end
  return data
end

--- Encodes a DP table. DP ids are always JSON object keys, never array
--- indexes, so they are converted to strings first.
function M.encode_dps(dps)
  local out = {}
  for k, v in pairs(dps) do
    out[tostring(k)] = v
  end
  return out
end

function M.encode(tbl)
  return json.encode(tbl)
end

--- Parses a decrypted payload. Returns the table, or nil and the raw text.
--- The DP table may be at .dps or, for 3.4/3.5 pushes, at .data.dps.
function M.decode(text)
  if text == nil or text == "" then
    return {}
  end
  local ok, parsed = pcall(json.decode, text)
  if not ok or type(parsed) ~= "table" then
    return nil, text
  end
  if parsed.dps == nil and type(parsed.data) == "table" and type(parsed.data.dps) == "table" then
    parsed.dps = parsed.data.dps
  end
  return parsed
end

return M
