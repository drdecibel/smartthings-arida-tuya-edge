#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 drdecibel
"""Generate Tuya protocol test vectors with tinytuya, the reference
implementation, and write them to test/fixtures/vectors.lua.

The Lua tests then check that the driver produces byte-identical frames,
derives the same session keys and decodes what tinytuya encodes. Run with:

    pip install tinytuya
    python3 tools/gen-test-vectors.py

Every key and nonce is a fixed test value; nothing here comes from a device.
"""

import hmac
import json
from hashlib import sha256
from pathlib import Path

import tinytuya
from tinytuya.core import command_types as CT
from tinytuya.core import header as H
from tinytuya.core.crypto_helper import AESCipher
from tinytuya.core.message_helper import TuyaMessage, MessagePayload, pack_message

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "test" / "fixtures" / "vectors.lua"

LOCAL_KEY = b"0123456789abcdef"
DEVICE_ID = "testdevice0000000001"
LOCAL_NONCE = bytes(range(0x10, 0x20))
REMOTE_NONCE = bytes(range(0xA0, 0xB0))
GCM_IV = bytes(range(0x40, 0x4C))
STATUS = {"dps": {"1": True, "2": "ventilate", "3": 2, "103": True, "104": 70, "105": 64}}
STATUS_JSON = json.dumps(STATUS, separators=(",", ":")).encode()
CONTROL_JSON = b'{"protocol":5,"t":1700000000,"data":{"dps":{"1":true,"3":3}}}'
CONTROL33_JSON = b'{"devId":"testdevice0000000001","uid":"testdevice0000000001","t":"1700000000","dps":{"1":true}}'
RETCODE = b"\x00\x00\x00\x00"

vectors = {}


def device(version):
    d = tinytuya.Device(DEVICE_ID, "127.0.0.1", LOCAL_KEY.decode(), version=version)
    d.seqno = 1
    return d


def ecb(key, data, pad=True):
    return AESCipher(key).encrypt(data, use_base64=False, pad=pad)


# ---- 3.3 ------------------------------------------------------------------
d = device(3.3)
vectors["v33_control"] = d._encode_message(MessagePayload(CT.CONTROL, CONTROL33_JSON))
d.seqno = 2
vectors["v33_query"] = d._encode_message(MessagePayload(CT.DP_QUERY, b'{"gwId":"x"}'))
vectors["v33_query_plain"] = b'{"gwId":"x"}'
vectors["v33_control_plain"] = CONTROL33_JSON
# Device replies: retcode + clear version header + ciphertext, and bare ciphertext.
vectors["v33_reply_header"] = pack_message(TuyaMessage(
    7, CT.STATUS, 0, RETCODE + H.PROTOCOL_33_HEADER + ecb(LOCAL_KEY, STATUS_JSON), 0, True, H.PREFIX_55AA_VALUE, False))
vectors["v33_reply_plain"] = pack_message(TuyaMessage(
    8, CT.DP_QUERY, 0, RETCODE + ecb(LOCAL_KEY, STATUS_JSON), 0, True, H.PREFIX_55AA_VALUE, False))
vectors["status_json"] = STATUS_JSON

# ---- 3.4 ------------------------------------------------------------------
d = device(3.4)
d.local_nonce = LOCAL_NONCE
d.local_key = d.real_local_key
vectors["v34_start"] = d._encode_message(MessagePayload(CT.SESS_KEY_NEG_START, LOCAL_NONCE))

resp_plain = REMOTE_NONCE + hmac.new(LOCAL_KEY, LOCAL_NONCE, sha256).digest()
vectors["v34_resp"] = pack_message(TuyaMessage(
    1, CT.SESS_KEY_NEG_RESP, 0, RETCODE + ecb(LOCAL_KEY, resp_plain), 0, True, H.PREFIX_55AA_VALUE, False),
    hmac_key=LOCAL_KEY)

rkey = TuyaMessage(1, CT.SESS_KEY_NEG_RESP, 0, ecb(LOCAL_KEY, resp_plain), 0, True, H.PREFIX_55AA_VALUE, False)
d.seqno = 2
step3 = d._negotiate_session_key_generate_step_3(rkey)
assert step3, "tinytuya rejected the 3.4 handshake response"
vectors["v34_finish"] = d._encode_message(step3)
d._negotiate_session_key_generate_finalize()
session = d.local_key
vectors["v34_session_key"] = session

d.seqno = 3
vectors["v34_query"] = d._encode_message(MessagePayload(CT.DP_QUERY_NEW, b"{}"))
d.seqno = 4
vectors["v34_control"] = d._encode_message(MessagePayload(CT.CONTROL_NEW, CONTROL_JSON))
vectors["v34_control_plain"] = CONTROL_JSON
vectors["v34_reply"] = pack_message(TuyaMessage(
    9, CT.DP_QUERY_NEW, 0, RETCODE + ecb(session, STATUS_JSON), 0, True, H.PREFIX_55AA_VALUE, False),
    hmac_key=session)
vectors["v34_push"] = pack_message(TuyaMessage(
    10, CT.STATUS, 0, ecb(session, H.PROTOCOL_34_HEADER + STATUS_JSON), 0, True, H.PREFIX_55AA_VALUE, False),
    hmac_key=session)

# ---- 3.5 ------------------------------------------------------------------
d = device(3.5)
d.local_nonce = LOCAL_NONCE
d.local_key = d.real_local_key


def pack35(seq, cmd, payload, key, retcode=None):
    return pack_message(TuyaMessage(seq, cmd, retcode, payload, 0, True, H.PREFIX_6699_VALUE, GCM_IV), hmac_key=key)


vectors["v35_start"] = pack35(1, CT.SESS_KEY_NEG_START, LOCAL_NONCE, LOCAL_KEY)
vectors["v35_resp"] = pack35(1, CT.SESS_KEY_NEG_RESP, resp_plain, LOCAL_KEY, retcode=0)
rkey = TuyaMessage(1, CT.SESS_KEY_NEG_RESP, 0, resp_plain, 0, True, H.PREFIX_6699_VALUE, GCM_IV)
step3 = d._negotiate_session_key_generate_step_3(rkey)
assert step3, "tinytuya rejected the 3.5 handshake response"
vectors["v35_finish"] = pack35(2, CT.SESS_KEY_NEG_FINISH, step3.payload, LOCAL_KEY)
d._negotiate_session_key_generate_finalize()
session = d.local_key
vectors["v35_session_key"] = session
vectors["v35_query"] = pack35(3, CT.DP_QUERY_NEW, b"{}", session)
vectors["v35_control"] = pack35(4, CT.CONTROL_NEW, H.PROTOCOL_35_HEADER + CONTROL_JSON, session)
vectors["v35_reply"] = pack35(9, CT.DP_QUERY_NEW, STATUS_JSON, session, retcode=0)

vectors["local_key"] = LOCAL_KEY
vectors["local_nonce"] = LOCAL_NONCE
vectors["remote_nonce"] = REMOTE_NONCE
vectors["gcm_iv"] = GCM_IV
vectors["device_id"] = DEVICE_ID.encode()

lines = [
    "-- SPDX-License-Identifier: GPL-3.0-or-later",
    "-- Generated by tools/gen-test-vectors.py with tinytuya. Do not edit.",
    "-- Hex strings; every key and nonce is a fixed test value.",
    "return {",
]
for name in sorted(vectors):
    lines.append('  %s = "%s",' % (name, vectors[name].hex()))
lines.append("}")
OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_bytes(("\n".join(lines) + "\n").encode("utf-8"))
print(f"wrote {len(vectors)} vectors to {OUT.relative_to(ROOT)}")
