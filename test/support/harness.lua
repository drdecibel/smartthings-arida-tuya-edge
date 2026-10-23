-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 drdecibel
--
-- Minimal test harness. Run test files from the repository root:
--   lua5.3 test/test_protocol.lua


local H = {passed = 0, failed = 0}

local function show(v)
  if type(v) == "string" and v:find("[^%g ]") then
    return "<" .. #v .. " bytes " .. (v:gsub(".", function(c) return string.format("%02x", c:byte()) end)):sub(1, 64) .. ">"
  end
  return tostring(v)
end

function H.test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    H.passed = H.passed + 1
  else
    H.failed = H.failed + 1
    print("FAIL " .. name .. "\n     " .. tostring(err))
  end
end

function H.eq(actual, expected, what)
  if actual ~= expected then
    error((what or "value") .. ": expected " .. show(expected) .. ", got " .. show(actual), 2)
  end
end

function H.truthy(v, what)
  if not v then error((what or "value") .. " was " .. tostring(v), 2) end
end

function H.same(actual, expected, what)
  for k, v in pairs(expected) do
    if actual[k] ~= v then
      error((what or "table") .. "[" .. tostring(k) .. "]: expected " .. show(v) .. ", got " .. show(actual[k]), 2)
    end
  end
  for k in pairs(actual) do
    if expected[k] == nil then
      error((what or "table") .. " has unexpected key " .. tostring(k), 2)
    end
  end
end

function H.done(suite)
  print(string.format("%s: %d passed, %d failed", suite, H.passed, H.failed))
  if H.failed > 0 then os.exit(1) end
end

return H
