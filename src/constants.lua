-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 drdecibel

local C = {}

C.PROFILE = {
  humidity = "arida-ventilator-humidity.v1",
  co2 = "arida-ventilator-co2.v1",
}

-- Preference defaults that mean "not configured yet". The IP is from the
-- RFC 5737 documentation range, so it can never be a real device.
C.PLACEHOLDER_IP = "192.0.2.1"
C.PLACEHOLDER_ID = "enter-device-id"
C.PLACEHOLDER_KEY = "enter-local-key!"
C.DEFAULT_DP_MAP = "standard"

C.DEFAULT_POLL_SECONDS = 30
C.MIN_POLL_SECONDS = 10
C.TIMEOUT_SECONDS = 5
-- Consecutive failed polls before the device is shown as offline.
C.OFFLINE_AFTER = 3

C.FIELD = {
  PROTOCOL = "tuya_protocol",
  SENSOR_KIND = "sensor_kind",
}

return C
