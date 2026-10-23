#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 drdecibel
#
# Fails if a tracked file contains something that looks like private network,
# device or account information. Documentation addresses from RFC 5737 and the
# placeholder MAC addresses used by the tests are allowed.

set -eu

cd "$(dirname "$0")/.."

status=0

report() {
  status=1
  printf '\n%s\n' "$1"
  printf '%s\n' "$2"
}

files=$(git ls-files | grep -v '^LICENSE$')

# Real looking IPv4 addresses. RFC 5737 documentation ranges, the unspecified
# address, the local broadcast address and loopback are expected.
hits=$(printf '%s\n' "$files" | xargs grep -nIE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' 2>/dev/null |
  grep -vE '\b(192\.0\.2\.[0-9]{1,3}|198\.51\.100\.[0-9]{1,3}|203\.0\.113\.[0-9]{1,3}|255\.255\.255\.255|0\.0\.0\.0|127\.0\.0\.1)\b' || true)
[ -n "$hits" ] && report "Possible private IP address:" "$hits"

# MAC addresses, with or without separators.
hits=$(printf '%s\n' "$files" | xargs grep -nIE '\b([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b|\b[0-9A-F]{12}\b' 2>/dev/null |
  grep -vE '\b(AABBCCDDEEFF|FFEEDDCCBBAA)\b' || true)
[ -n "$hits" ] && report "Possible MAC address:" "$hits"

# Credentials and tokens.
hits=$(printf '%s\n' "$files" | xargs grep -nIE 'Bearer [A-Za-z0-9._-]{16,}|(ssid|password|passwd|client_secret|access_token|refresh_token|api[_-]?key)[[:space:]]*[:=][[:space:]]*[^[:space:]"'"'"',)]+' 2>/dev/null |
  grep -vE '(placeholder|example|<|\$\{|xxx|XXX)' || true)
[ -n "$hits" ] && report "Possible credential:" "$hits"

# SmartThings account, hub, location, driver and channel identifiers.
hits=$(printf '%s\n' "$files" | xargs grep -nIE '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b' 2>/dev/null || true)
[ -n "$hits" ] && report "Possible SmartThings or device UUID:" "$hits"

if [ "$status" -eq 0 ]; then
  echo "Privacy scan: no private network, device or account data found."
fi

exit "$status"
