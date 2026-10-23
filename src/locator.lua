-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 drdecibel
--
-- Finds a ventilator's current IP address, so units can stay on DHCP.
--
-- A unit's identity is its Tuya device ID and local key, never its address.
-- Tuya announces devices with UDP broadcasts to ports 6666/6667, which an
-- Edge driver cannot reliably bind, so the locator instead:
--
--   1. connects to TCP 6668 on every address in the hub's /24 (and in the
--      /24 of the last known address), a few dozen at a time;
--   2. asks each host that accepts a status query with this unit's local
--      key. Every unit has its own key, so only the right one can answer;
--      other Tuya devices (lights, plugs) stay silent and are skipped.
--
-- The open-port list is shared between devices for a short while, so three
-- ventilators relocating after a router restart cost one scan, not three.

local log = require("log")
local Client = require("tuya.client")

local M = {}

M.PARALLEL = 32
M.CONNECT_TIMEOUT = 0.6
M.IDENTIFY_TIMEOUT = 2
M.CACHE_SECONDS = 60

local cache = {hosts = nil, at = 0, prefixes = ""}

--- "192.0.2.7" -> "192.0.2.", or nil for anything that isn't IPv4.
function M.prefix(ip)
  if type(ip) ~= "string" then return nil end
  local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  for _, n in ipairs({a, b, c, d}) do
    if tonumber(n) > 255 then return nil end
  end
  return a .. "." .. b .. "." .. c .. "."
end

--- Default parallel runner on cosock: runs every task, at most `limit` at a
--- time, and returns when all are done.
function M.cosock_parallel(tasks, limit)
  local cosock = require("cosock")
  local tx, rx = cosock.channel.new()
  local next_task, running = 1, 0
  local function start()
    local task = tasks[next_task]
    next_task = next_task + 1
    running = running + 1
    cosock.spawn(function()
      pcall(task)
      tx:send(true)
    end, "arida-scan")
  end
  while next_task <= #tasks and running < limit do start() end
  while running > 0 do
    rx:receive()
    running = running - 1
    if next_task <= #tasks then start() end
  end
end

--- Addresses in the given /24 prefixes with TCP 6668 open, sorted.
--- opts: tcp (socket factory), parallel (runner), now (clock).
function M.open_hosts(prefixes, opts)
  opts = opts or {}
  local tcp = opts.tcp or require("cosock.socket").tcp
  local parallel = opts.parallel or M.cosock_parallel
  local now = (opts.now or os.time)()

  table.sort(prefixes)
  local key = table.concat(prefixes, ",")
  if cache.hosts and cache.prefixes == key and now - cache.at < M.CACHE_SECONDS then
    return cache.hosts
  end

  local found, tasks = {}, {}
  for _, prefix in ipairs(prefixes) do
    for i = 1, 254 do
      local ip = prefix .. i
      tasks[#tasks + 1] = function()
        local sock = tcp()
        if not sock then return end
        sock:settimeout(M.CONNECT_TIMEOUT)
        if sock:connect(ip, Client.PORT) then found[#found + 1] = ip end
        sock:close()
      end
    end
  end
  parallel(tasks, M.PARALLEL)

  table.sort(found, function(a, b)
    return string.pack(">I4I4I4I4", a:match("(%d+)%.(%d+)%.(%d+)%.(%d+)")) <
      string.pack(">I4I4I4I4", b:match("(%d+)%.(%d+)%.(%d+)%.(%d+)"))
  end)
  cache = {hosts = found, at = now, prefixes = key}
  log.debug(string.format("Tuya scan: %d host(s) with TCP %d open", #found, Client.PORT))
  return found
end

function M.forget()
  cache = {hosts = nil, at = 0, prefixes = ""}
end

--- Finds which open host is this unit. `spec` holds device_id, local_key,
--- version and learned (see tuya.client); `skip` is a set of addresses
--- already claimed by other units. Returns ip, dps, version or nil.
function M.identify(hosts, spec, skip, opts)
  opts = opts or {}
  for _, ip in ipairs(hosts) do
    if not (skip and skip[ip]) then
      local client = Client.new({
        ip = ip, device_id = spec.device_id, local_key = spec.local_key,
        version = spec.version, learned = spec.learned,
        timeout = M.IDENTIFY_TIMEOUT, tcp = opts.tcp, log = opts.log,
      })
      local dps, version = client:exchange()
      if dps then return ip, dps, version end
    end
  end
  return nil
end

--- Scans and identifies in one go. `prefixes` must not be empty.
function M.locate(prefixes, spec, skip, opts)
  local hosts = M.open_hosts(prefixes, opts)
  local ip, dps, version = M.identify(hosts, spec, skip, opts)
  if not ip and #hosts > 0 then
    -- A unit that just came online may be missing from a cached scan.
    M.forget()
  end
  return ip, dps, version
end

return M
