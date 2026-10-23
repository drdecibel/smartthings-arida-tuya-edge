# Security policy

## Reporting a vulnerability

Do not open a public issue for a vulnerability that exposes credentials, private network information or unauthorized device control. Contact the repository owner privately through their published GitHub contact method.

## Local keys

The Tuya **local key** is the only secret that protects a ventilator on your network. Anyone with it, and access to your LAN, can control the unit.

- The driver stores it as a SmartThings preference of type password and never logs it.
- Never paste a local key, device ID or `devices.json` into an issue, a log excerpt or a pull request.
- If a key has been exposed, remove the unit from Smart Life and add it again. Tuya then issues a new key.

## Local-network considerations

Tuya protocol 3.3 uses AES-128-ECB with a static key; 3.4 and 3.5 add per-connection session keys. Use the ventilators only on a trusted home network or an isolated IoT VLAN, and keep the hub and the units on networks that can reach each other on TCP 6668.

This driver:

- communicates only with the IP address configured for each device;
- never contacts the Tuya cloud;
- does not log keys, decrypted payloads or complete frames;
- does not embed device IDs, keys or addresses (`tools/privacy-scan.sh` enforces this in CI).
