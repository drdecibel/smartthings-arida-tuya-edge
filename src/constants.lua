-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 drdecibel

local C = {}

C.PROFILE = {
  humidity = "arida-ventilator-humidity.v1",
  co2 = "arida-ventilator-co2.v1",
}

-- Preference defaults that mean "not configured yet".
-- ipAddress "auto" means "find the unit on the network". The first release
-- used an RFC 5737 documentation address as its placeholder; it means the same.
C.AUTO_IP = "auto"
C.LEGACY_PLACEHOLDER_IP = "192.0.2.1"
C.PLACEHOLDER_ID = "enter-device-id"
C.PLACEHOLDER_KEY = "enter-local-key!"
C.DEFAULT_DP_MAP = "standard"

-- protocolVersion preference keys (the API allows only \w+) -> version.
C.PROTOCOL_OPTION = {auto = "auto", v33 = "3.3", v34 = "3.4", v35 = "3.5"}

C.DEFAULT_POLL_SECONDS = 30
C.MIN_POLL_SECONDS = 10
C.TIMEOUT_SECONDS = 5
-- Consecutive failed polls before the device is shown as offline.
C.OFFLINE_AFTER = 3
-- Minimum seconds between network searches for one unit.
C.RELOCATE_INTERVAL = 180

C.FIELD = {
  PROTOCOL = "tuya_protocol",
  SENSOR_KIND = "sensor_kind",
  HOST = "host",
}

return C
