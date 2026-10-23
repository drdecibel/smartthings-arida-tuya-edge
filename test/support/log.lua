-- SPDX-License-Identifier: GPL-3.0-or-later
-- Stand-in for the SmartThings `log` module. Messages are kept for assertions.
local log = {messages = {}}
for _, level in ipairs({"trace", "debug", "info", "warn", "error"}) do
  log[level] = function(msg) log.messages[#log.messages + 1] = level .. ": " .. tostring(msg) end
end
return log
