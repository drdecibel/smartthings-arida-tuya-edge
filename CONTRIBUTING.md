# Contributing

Bug reports, hardware test results and pull requests are welcome. Reports from
Arida models other than Base WiFi, and from other firmware versions, are
especially useful.

## Before opening an issue

- State the model (Base 110/160, Venti 110/160, humidity or CO₂ variant).
- State the Tuya protocol version the driver logged (`connected with Tuya protocol 3.x`).
- Run `smartthings edge:drivers:logcat` while reproducing the problem.
- If values look wrong, include the DP **mapping** from `devices.json` (codes and
  types only). It tells us how your firmware numbers its data points.

## Privacy

Never post a local key, device ID, IP address or an unedited `devices.json`.
Remove or mask `key`, `id`, `uuid`, `mac`, `ip` and any account fields.

`tools/privacy-scan.sh` runs on every push and fails the build if a tracked file
contains an address, MAC address, credential or account identifier.

## Running the checks

```sh
make check
```

That runs the Lua syntax check, all test suites, the manifest check and the
privacy scan. It needs a Lua 5.3 or 5.4 interpreter and python3-yaml; no hub
and no ventilator are involved. On Windows, `pip install lupa` and use
`python tools/lua53.py <file>` instead of `lua5.3`.

## Pull requests

1. Keep all communication local. Do not add cloud dependencies.
2. Do not log local keys, decrypted payloads or identifiers.
3. Protocol changes must keep the tinytuya vectors passing. If tinytuya's own
   behaviour is the reference for a change, extend `tools/gen-test-vectors.py`
   and regenerate with `make vectors`.
4. DP translation belongs in `src/arida.lua` with a test in `test/test_model.lua`.
5. Run `make check` before submitting.
6. Contributions are accepted under GPL-3.0-or-later.
