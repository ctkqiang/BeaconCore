# WebRTC Live Streaming Guide

## Overview

BeaconCore provides one-to-many live streaming using WebRTC for low-latency peer connections. A broadcaster sends media to the platform, which then delivers it to unlimited viewers in real-time.

---

## Architecture

```
┌─────────────┐
│ Broadcaster │
│  (Camera)   │
└──────┬──────┘
       │
       │ WebRTC SDP Offer
       ▼
┌──────────────────────┐
│ BeaconCore Server    │
│ (webrtc_handler.erl) │
└──────────────────────┘
       │
       ├─► Viewer 1 (SDP Answer + ICE)
       ├─► Viewer 2 (SDP Answer + ICE)
       ├─► Viewer 3 (SDP Answer + ICE)
       └─► Viewer N
```

---

## WebRTC Flow

### 1. Create Broadcast (Broadcaster)

The broadcaster initiates a stream.

**Request:**
```bash
curl -X POST http://127.0.0.1:8080/v1/streaming/broadcasts \
  -H "Authorization: Bearer secret-key-12345" \
  -H "Content-Type: application/json" \
  -d '{
    "stream_id": "stream-001",
    "broadcaster_id": "alice"
  }'
```

**Response:**
```json
{
  "ok": true,
  "stream_id": "stream-001",
  "status": "waiting_for_sdp"
}
```

**Backend:**
- Creates broadcast record in state
- Stream status = `waiting_for_sdp`
- Publishes `broadcast.created` event to RabbitMQ

---

### 2. Send SDP Offer (Broadcaster)

The broadcaster's WebRTC client generates an SDP offer and sends it to the server.

**Request:**
```bash
curl -X POST http://127.0.0.1:8080/v1/streaming/sdp \
  -H "Authorization: Bearer secret-key-12345" \
  -H "Content-Type: application/json" \
  -d '{
    "stream_id": "stream-001",
    "sdp_offer": "v=0\r\no=- ...(full SDP offer)..."
  }'
```

**Response:**
```json
{
  "ok": true,
  "status": "streaming"
}
```

**Backend:**
- Updates broadcast SDP offer
- Stream status = `streaming`
- Publishes `broadcast.started` event to RabbitMQ

---

### 3. Add Viewer to Stream

A viewer joins an active stream.

**Request:**
```bash
curl -X POST http://127.0.0.1:8080/v1/streaming/viewers \
  -H "Authorization: Bearer secret-key-12345" \
  -H "Content-Type: application/json" \
  -d '{
    "stream_id": "stream-001",
    "viewer_id": "bob"
  }'
```

**Response:**
```json
{
  "ok": true,
  "sdp_offer": "v=0\r\no=- ...(broadcaster's SDP offer)..."
}
```

**Backend:**
- Adds viewer to stream state
- Returns broadcaster's SDP offer so viewer can answer
- Increments viewer count
- Publishes `viewer.joined` event to RabbitMQ

---

### 4. Send SDP Answer (Viewer)

The viewer's WebRTC client receives the SDP offer and generates an answer.

**Request:**
```bash
curl -X POST http://127.0.0.1:8080/v1/streaming/sdp \
  -H "Authorization: Bearer secret-key-12345" \
  -H "Content-Type: application/json" \
  -d '{
    "viewer_key": "stream-001:bob",
    "sdp_answer": "v=0\r\no=- ...(full SDP answer)..."
  }'
```

**Response:**
```json
{
  "ok": true
}
```

**Backend:**
- Updates viewer SDP answer
- Sets viewer connection status = `connected`

---

### 5. ICE Candidates (Broadcaster & Viewers)

Both sides exchange ICE candidates for NAT traversal.

**Request (Broadcaster):**
```bash
curl -X POST http://127.0.0.1:8080/v1/streaming/ice \
  -H "Authorization: Bearer secret-key-12345" \
  -H "Content-Type: application/json" \
  -d '{
    "stream_id": "stream-001",
    "ice_candidate": {
      "candidate": "candidate:123...",
      "sdpMLineIndex": 0,
      "sdpMid": "video"
    }
  }'
```

**Request (Viewer):**
```bash
curl -X POST http://127.0.0.1:8080/v1/streaming/ice \
  -H "Authorization: Bearer secret-key-12345" \
  -H "Content-Type: application/json" \
  -d '{
    "viewer_key": "stream-001:bob",
    "ice_candidate": {
      "candidate": "candidate:456...",
      "sdpMLineIndex": 0,
      "sdpMid": "video"
    }
  }'
```

**Response:**
```json
{
  "ok": true
}
```

**Backend:**
- Appends ICE candidate to list
- Used for connection establishment

---

### 6. Media Flow

Once both sides have:
- SDP offer/answer exchanged
- ICE candidates gathered
- Connection established

Media flows directly between peers:
- Broadcaster → Viewers (1-to-many)
- Viewers → Chat (WebSocket, see MESSAGING.md)

---

## State Management

### Broadcast States

```
waiting_for_sdp → streaming → ended
```

- **waiting_for_sdp**: Broadcast created, awaiting broadcaster SDP
- **streaming**: Broadcaster sent SDP, media flowing
- **ended**: Broadcast terminated

### Viewer States

```
connecting → connected → disconnected
```

- **connecting**: Viewer added, awaiting SDP answer
- **connected**: SDP answered, connection established
- **disconnected**: Viewer removed or connection lost

---

## API Reference

### Create Broadcast

| Method | Path | Auth | Body |
|--------|------|------|------|
| POST | `/v1/streaming/broadcasts` | Bearer | `stream_id`, `broadcaster_id` |

### Send SDP (Broadcaster)

| Method | Path | Auth | Body |
|--------|------|------|------|
| POST | `/v1/streaming/sdp` | Bearer | `stream_id`, `sdp_offer` |

### Add Viewer

| Method | Path | Auth | Body |
|--------|------|------|------|
| POST | `/v1/streaming/viewers` | Bearer | `stream_id`, `viewer_id` |

### Send SDP (Viewer)

| Method | Path | Auth | Body |
|--------|------|------|------|
| POST | `/v1/streaming/sdp` | Bearer | `viewer_key`, `sdp_answer` |

### Send ICE Candidate

| Method | Path | Auth | Body |
|--------|------|------|------|
| POST | `/v1/streaming/ice` | Bearer | `stream_id`/`viewer_key`, `ice_candidate` |

### Get Broadcast State

| Method | Path | Auth |
|--------|------|------|
| GET | `/v1/streaming/broadcasts/<stream_id>` | Bearer |

### Get Active Viewers

| Method | Path | Auth |
|--------|------|------|
| GET | `/v1/streaming/viewers/<stream_id>` | Bearer |

### End Broadcast

| Method | Path | Auth | Body |
|--------|------|------|------|
| DELETE | `/v1/streaming/broadcasts/<stream_id>` | Bearer | (empty) |

---

## Example: Complete Flow

### Terminal 1 - Broadcaster Setup
```bash
# Create broadcast
curl -X POST http://127.0.0.1:8080/v1/streaming/broadcasts \
  -H "Authorization: Bearer secret-key-12345" \
  -H "Content-Type: application/json" \
  -d '{"stream_id":"demo-stream","broadcaster_id":"alice"}'

# In broadcaster app: generate SDP offer from camera
# Send SDP to server
curl -X POST http://127.0.0.1:8080/v1/streaming/sdp \
  -H "Authorization: Bearer secret-key-12345" \
  -H "Content-Type: application/json" \
  -d '{"stream_id":"demo-stream","sdp_offer":"<SDP_OFFER>"}'

# Exchange ICE candidates as they're discovered
for each ice_candidate; do
  curl -X POST http://127.0.0.1:8080/v1/streaming/ice \
    -H "Authorization: Bearer secret-key-12345" \
    -H "Content-Type: application/json" \
    -d '{"stream_id":"demo-stream","ice_candidate":"<ICE>"}'
done
```

### Terminal 2 - Viewer Setup
```bash
# Join the stream
curl -X POST http://127.0.0.1:8080/v1/streaming/viewers \
  -H "Authorization: Bearer secret-key-12345" \
  -H "Content-Type: application/json" \
  -d '{"stream_id":"demo-stream","viewer_id":"bob"}'

# Response contains broadcaster's SDP offer
# In viewer app: create answer from SDP offer
# Send SDP answer to server
curl -X POST http://127.0.0.1:8080/v1/streaming/sdp \
  -H "Authorization: Bearer secret-key-12345" \
  -H "Content-Type: application/json" \
  -d '{"viewer_key":"demo-stream:bob","sdp_answer":"<SDP_ANSWER>"}'

# Exchange ICE candidates
for each ice_candidate; do
  curl -X POST http://127.0.0.1:8080/v1/streaming/ice \
    -H "Authorization: Bearer secret-key-12345" \
    -H "Content-Type: application/json" \
    -d '{"viewer_key":"demo-stream:bob","ice_candidate":"<ICE>"}'
done
```

### Result
Once both sides complete the handshake, WebRTC media flows directly from broadcaster to viewers with <50ms latency.

---

## Error Handling

### Stream Not Found
```json
{
  "error": "broadcast_not_found"
}
```
Ensure `stream_id` exists and broadcaster sent SDP offer.

### Viewer Not Found
```json
{
  "error": "viewer_not_found"
}
```
Ensure viewer was added before sending SDP answer.

### Invalid SDP
Ensure SDP follows RFC 4566 format (v=0, o=, s=, etc.).

---

## Performance Tuning

### Media Bitrate
Configure in WebRTC client:
```javascript
const constraints = {
  video: { width: 1280, height: 720, frameRate: 30 },
  audio: { sampleRate: 48000 }
};
```

### Connection Timeout
Default: 30 seconds. Adjust in `webrtc_handler.erl`:
```erlang
{connection_timeout, 30000}
```

### ICE Gathering
Browsers gather candidates for ~5 seconds. Send when ready:
```javascript
pc.onicecandidate = (event) => {
  if (event.candidate) {
    sendICE(event.candidate);
  }
};
```

---

## Troubleshooting

### No Media After Connection
1. Verify SDP offer/answer exchanged
2. Check ICE candidates gathered
3. Ensure STUN/TURN servers configured
4. Verify firewall allows UDP 10000-20000

### High Latency
1. Check network RTT: `ping <server>`
2. Reduce media bitrate
3. Ensure broadcaster has stable connection
4. Check for packet loss: monitor TCP retransmits

### Connection Drops
1. Implement reconnection logic in client
2. Monitor via `/v1/streaming/broadcasts/<stream_id>`
3. Check server logs for errors

---

## References

- RFC 3264: Offer/Answer Model (SDP)
- RFC 5245: Interactive Connectivity Establishment (ICE)
- W3C WebRTC Specification
- IETF RTP Payload Formats
