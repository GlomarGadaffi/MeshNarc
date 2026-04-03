# MeshNarc
Passive Meshtastic packet capture to BigQuery. LilyGo T-SIM7080G-S3 in CLIENT_MUTE mode uplinks all received mesh traffic over Hologram cellular MQTT; a Python subscriber decodes protobuf and streams to BQ. Drop it somewhere with power and forget about it.
# meshnarc

Passive Meshtastic packet capture to BigQuery. Drop a LilyGo with a Hologram SIM somewhere with power, walk away, query the mesh from BQ.

## Why this works

Meshtastic firmware already has MQTT gateway mode. The T-SIM7080G-S3 already has a Cat-M1/NB-IoT modem. Hologram already sells the SIM. You don't write custom firmware or AT commands — you configure what's already there and put a subscriber on the other end that decodes protobuf and streams to BQ.

The node is set to `CLIENT_MUTE`: receives everything, rebroadcasts nothing. Ghost mode. It decrypts traffic using the well-known default channel key (`AQ==`, which is just `0x01` expanded to AES-256), then ships plaintext protobuf over cellular MQTT. Any channel with a PSK you don't have stays opaque — you see the envelope but not the payload.

## Architecture

```
LilyGo T-SIM7080G-S3          anywhere with internet
┌──────────────────────┐       ┌─────────────────────┐
│ SX1262 LoRa (capture)│       │ meshnarc_sub.py     │
│ ESP32-S3 (Meshtastic │       │ MQTT subscribe      │
│   MQTT gateway mode) │       │ protobuf decode     │
│ SIM7080G ─── Hologram├──────▶│ AES-256-CTR decrypt │
│              cellular │ MQTT │ BQ streaming insert │
└──────────────────────┘       └────────┬────────────┘
                                        │
                                        ▼
                                    BigQuery
                                 meshnarc.packets
```

No serial cable. No companion Pi tethered to the radio. The subscriber runs on glolab, a VM, wherever — it just needs to reach the MQTT broker and BQ.

## What's in here

```
meshnarc_sub.py      MQTT subscriber → protobuf decode → BQ insert
configure_node.sh    Meshtastic CLI commands to set up the LilyGo
bq_schema.sql        Table + views (recent_nodes, messages, positions)
meshnarc.service     systemd unit for the subscriber
deploy.sh            Install deps, copy files, apply BQ schema
requirements.txt     Python deps (5 packages, all platform SDKs)
```

## Setup

### 1. Flash the LilyGo

Meshtastic web flasher: https://flasher.meshtastic.org — board is `LilyGo T-SIM7080G-S3`, latest stable firmware. Nothing custom.

### 2. Hologram SIM

Get one from https://hologram.io, activate it. APN is `hologram`. The SIM7080G handles Cat-M1/NB-IoT negotiation — Hologram's auto-APN usually works, but Meshtastic wants it set explicitly.

Cost: ~$0.40/month device fee + $0.60/MB. MQTT packets are 100-300 bytes. Even a loud mesh won't hit 1 MB/month. Budget $1-2/month.

### 3. Configure the node

Plug in the LilyGo via USB and run:

```bash
./configure_node.sh your-broker.example.com mqttuser mqttpass 29.6516 -82.3248
```

This sets:
- **Role**: `CLIENT_MUTE` — passive receive, no rebroadcast
- **MQTT**: enabled, pointed at your broker, uplink on channel 0, downlink off
- **APN**: `hologram`
- **Position**: fixed to your capture site
- **Identity**: owner "meshnarc", short "NARC"

To capture channels beyond the default LongFast:

```bash
meshtastic --ch-add "SomeChannel"
meshtastic --ch-set psk "base64key==" --ch-index 1
meshtastic --ch-set uplink_enabled true --ch-index 1
```

You need the PSK. No PSK, no decrypt — you'll get the packet envelope but the payload stays opaque.

### 4. MQTT broker

You need a broker the LilyGo can reach over the internet. Two options:

**Self-hosted mosquitto** — if you have a box with a public IP or a VPS:

```bash
sudo apt install mosquitto
cat << 'EOF' | sudo tee /etc/mosquitto/conf.d/meshnarc.conf
listener 1883
allow_anonymous false
password_file /etc/mosquitto/passwd
EOF
sudo mosquitto_passwd -c /etc/mosquitto/passwd meshnarc
sudo systemctl enable --now mosquitto
```

Note: glolab is on Tailscale. The ESP32 can't run Tailscale. If your broker is only reachable via Tailscale, the LilyGo can't reach it. You need either a public-facing broker or a port forward.

**HiveMQ Cloud** — free tier, zero ops, 100 connections, 10 GB/month. More than enough. https://www.hivemq.com/mqtt-cloud-broker/

### 5. BigQuery

```bash
bq mk --dataset meshnarc
bq query --use_legacy_sql=false < bq_schema.sql
```

The schema includes three views:
- `recent_nodes` — 24h activity summary per node (packet count, avg RSSI/SNR, last position)
- `messages` — decoded text messages
- `positions` — position history for mapping

Table is partitioned by `rx_timestamp` date, clustered on `source_protocol`, `port_num`, `from_id`.

### 6. Run the subscriber

```bash
pip install -r requirements.txt --break-system-packages

export GOOGLE_APPLICATION_CREDENTIALS=/path/to/sa-key.json

python meshnarc_sub.py \
    --broker your-broker.example.com \
    --username meshnarc \
    --password changeme \
    --topic "msh/US/2/e/#" \
    --project your-gcp-project \
    --lat 29.6516 --lon -82.3248 \
    -v
```

The `#` wildcard subscribes to all channels and all gateway nodes. Narrow with `msh/US/2/e/LongFast/#` if you only want the default channel.

For persistent operation:

```bash
sudo cp meshnarc.service /etc/systemd/system/
# edit the Environment= lines in the unit first
sudo systemctl daemon-reload
sudo systemctl enable --now meshnarc
```

### 7. Verify

```bash
# Watch raw MQTT traffic
mosquitto_sub -h your-broker -u meshnarc -P password -t "msh/#" -v

# Check BQ
bq query 'SELECT rx_timestamp, from_id, port_num, payload_json
           FROM meshnarc.packets ORDER BY rx_timestamp DESC LIMIT 10'
```

## How decryption works

Meshtastic uses AES-256-CTR. The nonce is `packet_id (4 bytes LE) + from_node (4 bytes LE) + 8 zero bytes`. The default channel key `AQ==` is `0x01`, which the firmware expands to 32 bytes by repeating.

The subscriber tries all known keys against each encrypted packet. Pass additional channel keys with `--extra-keys`:

```bash
python meshnarc_sub.py --extra-keys "1:base64ChannelKey==" "2:anotherKey=="
```

The index is the Meshtastic channel index. If no key works, the packet is logged as `decrypt_fail` in stats and dropped — you see it existed but not what it said.

## MQTT topic structure

Meshtastic publishes to:

```
msh/{region}/{channel_id}/e/{channel_name}/{gateway_node_id}
```

The `/e/` means encrypted (which is all traffic — even the "unencrypted" default channel uses AES with the well-known key). Payloads are protobuf `ServiceEnvelope` containing a `MeshPacket`.

## MeshCore

MeshCore is a different protocol on the same LoRa hardware. It has no MQTT gateway mode in firmware. Capturing MeshCore requires a second radio running MeshCore firmware with serial output to a companion host — back to the tethered-Pi architecture.

The BQ schema has `source_protocol` ready for it. The subscriber has the column. But the capture path is a different hardware problem. If you want both protocols, you need two radios.

## What this doesn't do

- **Active participation.** The node never transmits mesh packets. It's receive-only.
- **Custom firmware.** Everything here uses stock Meshtastic firmware and configuration.
- **Channel discovery.** You need the PSK for any channel beyond the default. There's no way to brute-force Meshtastic channel keys from RF alone — AES-256 is AES-256.
- **Real-time alerting.** This is a capture-and-query system. For alerts, add a Cloud Function trigger on BQ streaming buffer or process the MQTT stream directly.
