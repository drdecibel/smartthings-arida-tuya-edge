# Arida Ventilator (Tuya LAN) for SmartThings

[![Validate driver](https://github.com/drdecibel/smartthings-arida-tuya-edge/actions/workflows/validate.yml/badge.svg)](https://github.com/drdecibel/smartthings-arida-tuya-edge/actions/workflows/validate.yml)
[![License: GPL v3+](https://img.shields.io/badge/License-GPL%20v3%2B-blue.svg)](LICENSE)

> Community project. Not affiliated with, endorsed by or supported by Arida, Tuya, Samsung or SmartThings.

Copyright © 2026 [drdecibel](https://github.com/drdecibel).

A SmartThings Edge driver for **Arida Base WiFi** and **Arida Venti WiFi** room
ventilators (heat-recovery wall fans sold in Norway). They contain a Tuya Wi-Fi module
and are normally used with the Smart Life app. This driver controls them directly
over the local network (Tuya local protocol, TCP 6668). It needs no cloud
connection at runtime, works when the internet is down and responds immediately.
The Smart Life app keeps working alongside it.

## Project status

| | |
|---|---|
| Driver version | 0.3.0 |
| Automated checks | 61 tests on Lua 5.3, CI on Lua 5.3/5.4 |
| Protocol verification | Tuya 3.3, 3.4 and 3.5 frames, handshakes and session keys are byte-identical to [tinytuya](https://github.com/jasonacox/tinytuya) (reference vectors in `test/fixtures`) |
| Verified on hardware | **Not yet.** First hardware test pending |

The data points come from the Tuya cloud model of the Arida Venti 160 and from
reports by owners of the humidity-sensor variant. See [Data points](#data-points). If your unit
numbers them differently, the **DP map** setting overrides them without a new driver.

## What you get in SmartThings

| SmartThings | Tuya DP | Notes |
|---|---|---|
| Switch | 1 | On/off |
| Fan speed | 3 | 1–3. Fan speed 0 turns the unit off |
| Mode | 2 | Varmegjenvinning (`ventilate`), Tilluft (`supply`), Avtrekk (`exhaust`) |
| Relative humidity | 105 | Humidity variant (Base WiFi) |
| Carbon dioxide | 105 | CO₂ variant (Venti CO₂). The profile switches automatically |
| Temperature | 21 | Only if the unit reports it |
| Filter status | 106 | `replace` when the filter needs cleaning |
| Component **Fuktstyring** / **CO₂-styring** | 103 | Sensor-controlled ventilation on/off |
| Component **Boost** | 107 | Maximum speed for 30 minutes |
| Setting **Terskel** | 104 | Humidity (50–95 %) or CO₂ (400–2000 ppm) threshold. 0 = leave as is |

Everything can be used in Routines, for example "boost when bathroom humidity > 70 %".

## Setup

### 1. Get the device ID and local key

Tuya encrypts local traffic with a per-device **local key**. You get it once from Tuya's
developer cloud. After that the driver never contacts the cloud.

1. Create a free account at [iot.tuya.com](https://iot.tuya.com). Create a *Cloud project* (Smart Home, data
   centre **Central Europe** for Norway). Link your Smart Life app account under
   *Devices → Link App Account* by scanning the QR code in the app.
2. On a PC on the same network:

   ```sh
   pip install tinytuya
   python -m tinytuya wizard
   ```

   Enter the project's Access ID/Secret when asked. The wizard writes `devices.json` with
   each unit's `id`, `key`, `ip`, `version` and its DP `mapping`.
No fixed IP or DHCP reservation is needed: the driver finds each unit itself (see
[Addresses and DHCP](#addresses-and-dhcp)).

> The local key changes if a unit is removed and re-added in Smart Life. Run the wizard
> again in that case.

Optional: check that a unit answers locally before involving SmartThings:

```sh
python -m tinytuya scan
```

### 2. Install the driver

The driver is not yet published to a channel. Install it with the [SmartThings CLI](https://github.com/SmartThingsCommunity/smartthings-cli):

```sh
smartthings edge:channels:create
smartthings edge:channels:enroll
smartthings edge:drivers:package .
smartthings edge:channels:assign
smartthings edge:drivers:install
```

### 3. Add the ventilators (no typing)

From the repository folder on the PC that has `devices.json`:

```sh
python tools/push-keys.py
```

Leave it running and choose **Add device → Scan nearby** in the SmartThings app. The hub asks on
the local network, the script answers with each ventilator's device ID and local key, and one
device per ventilator appears, named as in Smart Life. The driver also asks once whenever it
starts, so installing or updating the driver while the script runs works too. If Windows Firewall
asks, allow Python on private networks.

The keys are stored on the hub only. The script never prints them, sends only ventilators (use
`--all` for other Tuya devices), and answers only the hub the SmartThings CLI knows (`--hub IP`
to choose). After re-pairing a unit in Smart Life, run the wizard and the script again; the
driver picks up the new key.

Without a PC, enter **Device ID** and **Local key** in the device's settings in the phone app
instead. Settings win over pushed keys.

## Addresses and DHCP

As with the Daikin driver, a unit's identity is not its IP address. Here it is the Tuya device ID and
local key, so the units can stay on ordinary DHCP:

1. When a unit has no known address, or stops answering at it, the driver connects to TCP 6668
   on every address in the hub's /24, 32 at a time (a few seconds).
2. It asks each open host for its status using this unit's local key. Every unit has its own key,
   so only the right ventilator can answer; other Tuya devices stay silent and are skipped.
3. The address is remembered and used until it stops answering. A unit that cannot be found is
   searched for again at most every 3 minutes.

Typing an address into **IP-adresse** pins the unit to it and turns the search off. The search
covers the hub's own /24 only; put the units on the same subnet as the hub.

## Data points

From the Tuya cloud model of product `npf4762xatmaw29g` (Arida Venti 160 / Small Ventilator 2.0),
see [tuya-local #2829](https://github.com/make-all/tuya-local/issues/2829). The Base WiFi
(`sryya13xip27w2nv`, "Small Ventilator 1.2", protocol 3.5) reports the same numbers locally:
1, 2, 3, 15, 22, 23, 101–106, with 103–105 for humidity. Its cloud model lists only some of them.

| DP | Code | Type | Used |
|---|---|---|---|
| 1 | `switch` | bool | ✔ |
| 2 | `mode` | enum supply/exhaust/ventilate | ✔ |
| 3 | `fan_speed` | 1–3 | ✔ |
| 9 | `anion` | bool | logged |
| 15 | `light` | bool | logged |
| 20 | `temp_set` | 10–29 °C (free cooling) | logged |
| 21 | `temp_current` | °C | ✔ |
| 22 / 23 | `countdown_set` / `countdown_left` | timer | logged |
| 24 | `fault` | bitmap | logged |
| 101 | `link` | bool | logged |
| 102 | `free_cooling` | bool | logged |
| 103 | `co2_switch` / humidity control | bool | ✔ |
| 104 | threshold | ppm or %RH | ✔ (setting) |
| 105 | sensor value | ppm or %RH | ✔ |
| 106 | `filter` | bool | ✔ |
| 107 | `powerful` | bool | ✔ |

The humidity variant reuses 103–105 for humidity instead of CO₂. The driver tells them apart by
the values: anything above 100 is ppm. DPs the driver doesn't use are written to the log at
debug level (`smartthings edge:drivers:logcat`). If your `devices.json` mapping differs, set
**DP-oppsett** to, for example, `sensor=105,threshold=104,sensor_control=103`. Valid names:
`switch mode speed temperature sensor_control threshold sensor filter boost`.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `ventilator not found on the local network` | Unit off Wi-Fi or powered off, wrong local key/device ID, or the unit is on another subnet/VLAN than the hub |
| Offline, log says `connect failed` | A pinned **IP-adresse** is wrong. Set it back to `auto` |
| `no protocol version answered` | Wrong local key or device ID (most common), or the unit was re-paired |
| `HMAC did not verify` | Wrong local key |
| Works, then stops after re-pairing in Smart Life | New local key: run the wizard again |
| Values look wrong | DP numbering differs: compare with `devices.json` and set **DP-oppsett** |

Tuya modules accept only a few simultaneous local connections. Close other local clients,
such as Home Assistant's tuya-local or a running `tinytuya` monitor, if connections fail.

## Development

```sh
make check        # syntax, tests, manifest and privacy scan (needs lua5.3)
make vectors      # regenerate protocol vectors with tinytuya
make build-only   # package without uploading
```

Without a native Lua 5.3 (for example on Windows): `pip install lupa`, then
`python tools/lua53.py test/test_protocol.lua`.

Layout:

- `src/tuya/` – Tuya local protocol: `v33.lua`, `v34.lua`, `v35.lua`, framing, crypto, `client.lua`
- `src/arida.lua` – DP ↔ SmartThings translation (pure, tested)
- `src/init.lua` – driver: lifecycle, polling, commands
- `src/discovery.lua` – "Scan nearby" creates one blank device at a time
- `src/locator.lua` – finds a unit's current address by its key (DHCP support)
- `src/provision.lua`, `tools/push-keys.py` – keys from `devices.json` to the hub, no typing

## Acknowledgements

- [tinytuya](https://github.com/jasonacox/tinytuya) (MIT): reference implementation of the Tuya local protocol and source of the test vectors
- [make-all/tuya-local](https://github.com/make-all/tuya-local): Arida Venti DP mapping and owner reports
- [ST-SmartHome/smartthings-drivers](https://github.com/ST-SmartHome/smartthings-drivers) (MIT): pure-Lua AES-GCM, CRC32 and the protocol 3.5 handshake, see `src/tuya/LICENSE-ST-SmartHome`
- [lua-lockbox](https://github.com/somesocks/lua-lockbox) (MIT): AES block cipher, see `src/lockbox/LICENSE`
- [dkjson](http://dkolf.de/src/dkjson-lua.fsl/) (MIT): JSON for the off-hub tests (the hub provides its own)

## License

GPL-3.0-or-later. See [LICENSE](LICENSE) and [COPYRIGHT](COPYRIGHT). Bundled third-party
files keep their MIT licences.
