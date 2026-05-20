# Real-time Chat & Notifications Guide

## Overview

BeaconCore provides real-time messaging through WebSocket for chat and RabbitMQ for admin notifications. Users can join a WebSocket connection to send/receive messages, while admins publish notifications through HTTP.

---

## Architecture

```
┌────────────────┐
│ WebSocket      │
│ Connections    │
└────────┬───────┘
         │
         │ Message Routing
         ▼
┌──────────────────────────┐
│ ae_routing_engine.erl    │
│ (RabbitMQ Consumer)      │
└──────────┬───────────────┘
           │
           ├─► Chat Router (stream channels)
           ├─► User Router (specific user_id)
           ├─► Segment Router (user groups)
           └─► Broadcast Router (all users)

┌────────────────────┐
│ RabbitMQ           │
│ (Message Broker)   │
└────────┬───────────┘
         │
         │ Admin API
         ▼
┌──────────────────────┐
│ ae_admin_handler.erl │
│ (HTTP Endpoint)      │
└──────────────────────┘
```

---

## WebSocket Chat

### Connect

**URL:**
```
ws://127.0.0.1:8080/ws?user_id=alice&auth_token=secret123
```

**Query Parameters:**
- `user_id` (required): Unique user identifier
- `auth_token` (optional): Application-layer token

**Connection Handler:** `ae_public_ws.erl`

---

### Send Chat Message

Once connected, send JSON messages:

```json
{
  "type": "chat",
  "channel": "stream-001",
  "message": "Hello everyone!"
}
```

**Fields:**
- `type`: `"chat"` for regular messages
- `channel`: Stream ID or channel name
- `message`: Text content (max 2000 chars)
- `timestamp`: Auto-added by server (optional in request)

**Server Response:**
```json
{
  "type": "chat_ack",
  "message_id": "msg-123456",
  "status": "delivered"
}
```

---

### Receive Chat Message

All users in same channel receive:

```json
{
  "type": "chat",
  "channel": "stream-001",
  "user_id": "alice",
  "message": "Hello everyone!",
  "timestamp": 1716201600000
}
```

---

### Typing Indicator

Send while user is typing:

```json
{
  "type": "typing",
  "channel": "stream-001",
  "user_id": "alice"
}
```

**Server broadcasts to channel members:**
```json
{
  "type": "user_typing",
  "channel": "stream-001",
  "user_id": "alice"
}
```

Typing indicator times out after 3 seconds.

---

### User Status

**Join notification:**
```json
{
  "type": "user_joined",
  "channel": "stream-001",
  "user_id": "alice",
  "timestamp": 1716201600000
}
```

**Leave notification:**
```json
{
  "type": "user_left",
  "channel": "stream-001",
  "user_id": "alice",
  "timestamp": 1716201600000
}
```

---

## Admin Notifications

### Broadcast to All Users

Send HTTP request to admin endpoint:

```bash
curl -X POST http://127.0.0.1:8080/v1/admin/broadcast \
  -H "Authorization: Bearer secret-key-12345" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "broadcast",
    "payload": "{\"title\":\"System Alert\",\"message\":\"Maintenance in 30 minutes\"}",
    "filter": "all"
  }'
```

**Response:**
```json
{
  "ok": true,
  "event_id": "event-123",
  "message_id": "msg-456"
}
```

**All connected users receive:**
```json
{
  "type": "notification",
  "source": "admin",
  "payload": {
    "title": "System Alert",
    "message": "Maintenance in 30 minutes"
  },
  "timestamp": 1716201600000
}
```

---

### Send to Specific User

```bash
curl -X POST http://127.0.0.1:8080/v1/admin/broadcast \
  -H "Authorization: Bearer secret-key-12345" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "id",
    "payload": "{\"title\":\"Order Ready\",\"message\":\"Your order #12345 is ready for pickup\"}",
    "filter": "user-123"
  }'
```

**Only user-123 receives:**
```json
{
  "type": "notification",
  "source": "admin",
  "user_id": "user-123",
  "payload": {
    "title": "Order Ready",
    "message": "Your order #12345 is ready for pickup"
  },
  "timestamp": 1716201600000
}
```

---

### Send to User Segment

```bash
curl -X POST http://127.0.0.1:8080/v1/admin/broadcast \
  -H "Authorization: Bearer secret-key-12345" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "segment",
    "payload": "{\"title\":\"VIP Exclusive\",\"message\":\"50% off premium items\"}",
    "filter": "segment-vip"
  }'
```

Users with segment tag `segment-vip` receive the notification.

---

### Send to Topic Subscribers

```bash
curl -X POST http://127.0.0.1:8080/v1/admin/broadcast \
  -H "Authorization: Bearer secret-key-12345" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "topic",
    "payload": "{\"title\":\"Sports News\",\"message\":\"Goal! Team A scores\"}",
    "filter": "sports-news"
  }'
```

Users subscribed to topic `sports-news` receive the notification.

---

## RabbitMQ Message Flow

### Event Types

**Chat Message:**
```json
{
  "type": "chat",
  "channel": "stream-001",
  "user_id": "alice",
  "message": "Hello!",
  "timestamp": 1716201600000
}
```

**Broadcast Event:**
```json
{
  "type": "broadcast.created",
  "stream_id": "stream-001",
  "broadcaster_id": "alice",
  "timestamp": 1716201600000
}
```

**Viewer Event:**
```json
{
  "type": "viewer.joined",
  "stream_id": "stream-001",
  "viewer_id": "bob",
  "total_viewers": 5,
  "timestamp": 1716201600000
}
```

---

### Message Routing

**ae_routing_engine.erl** subscribes to RabbitMQ queue and routes:

1. **Channel Messages** → All users in channel via WebSocket
2. **User Messages** → Specific user or offline queue
3. **Broadcast Messages** → All connected users
4. **System Events** → Event log and analytics

---

## Offline Message Handling

### Offline Queue

When user disconnects, pending messages are queued:

```bash
# Check offline messages
curl -X GET http://127.0.0.1:8080/v1/messaging/offline \
  -H "Authorization: Bearer token" \
  -d '{"user_id": "alice"}'
```

**Response:**
```json
{
  "ok": true,
  "messages": [
    {
      "message_id": "msg-123",
      "type": "notification",
      "payload": "...",
      "timestamp": 1716201600000
    }
  ]
}
```

### Retrieve and Clear

```bash
# Get messages
GET /v1/messaging/offline?user_id=alice

# Clear after reading
DELETE /v1/messaging/offline?user_id=alice&message_id=msg-123
```

---

## Message Types

| Type | Direction | Source | Purpose |
|------|-----------|--------|---------|
| `chat` | Bidirectional | User/Server | Chat message in channel |
| `typing` | User → Server | User | Typing indicator |
| `user_typing` | Server → User | Server | Remote user typing |
| `user_joined` | Server → User | Server | User joined channel |
| `user_left` | Server → User | Server | User left channel |
| `notification` | Server → User | Admin/System | Admin notification |
| `broadcast.created` | Server → RabbitMQ | WebRTC | Stream created |
| `viewer.joined` | Server → RabbitMQ | WebRTC | Viewer joined |
| `viewer.left` | Server → RabbitMQ | WebRTC | Viewer left |

---

## Authentication

### WebSocket

User ID passed in query parameter:
```
ws://127.0.0.1:8080/ws?user_id=alice&auth_token=secret123
```

Application can validate `auth_token` server-side in handler.

### Admin API

All admin endpoints require Bearer token:
```
Authorization: Bearer <BEAKON_ADMIN_API_KEY>
```

---

## API Reference

### WebSocket Connect

| Method | Path | Auth |
|--------|------|------|
| GET | `/ws?user_id=<id>&auth_token=<token>` | User ID |

### Send Admin Notification

| Method | Path | Auth | Body |
|--------|------|------|------|
| POST | `/v1/admin/broadcast` | Bearer | `type`, `payload`, `filter` |

### Get Offline Messages

| Method | Path | Auth |
|--------|------|------|
| GET | `/v1/messaging/offline?user_id=<id>` | Bearer |

### Clear Offline Messages

| Method | Path | Auth |
|--------|------|------|
| DELETE | `/v1/messaging/offline?user_id=<id>&message_id=<id>` | Bearer |

---

## Example: Stream Chat

### User 1 - Broadcaster

```bash
# Connect to chat
wscat -c "ws://127.0.0.1:8080/ws?user_id=alice"

# In wscat, send message
> {"type":"chat","channel":"stream-001","message":"Welcome to my stream!"}

# Receive acknowledgement
< {"type":"chat_ack","message_id":"msg-001","status":"delivered"}
```

### User 2 - Viewer 1

```bash
# Connect to same channel
wscat -c "ws://127.0.0.1:8080/ws?user_id=bob"

# User joined notification
< {"type":"user_joined","channel":"stream-001","user_id":"bob"}

# Receive message from broadcaster
< {"type":"chat","channel":"stream-001","user_id":"alice","message":"Welcome to my stream!","timestamp":1716201600000}

# Send reply
> {"type":"chat","channel":"stream-001","message":"Thanks for streaming!"}
```

### User 3 - Admin

```bash
# Send system notification
curl -X POST http://127.0.0.1:8080/v1/admin/broadcast \
  -H "Authorization: Bearer secret-key-12345" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "broadcast",
    "payload": "{\"msg\":\"Stream will end in 5 minutes\"}",
    "filter": "all"
  }'

# All viewers receive:
< {"type":"notification","source":"admin","payload":{"msg":"Stream will end in 5 minutes"},"timestamp":1716201600000}
```

---

## Error Handling

### Invalid Message Format
```json
{
  "type": "error",
  "code": "INVALID_MESSAGE",
  "message": "Missing required fields"
}
```

### Channel Not Found
```json
{
  "type": "error",
  "code": "CHANNEL_NOT_FOUND",
  "message": "Channel does not exist"
}
```

### Rate Limited
```json
{
  "type": "error",
  "code": "RATE_LIMIT",
  "message": "Too many messages, please wait"
}
```

---

## Performance & Limits

- **Max concurrent WebSocket connections**: Unlimited (tested 10,000+)
- **Message throughput**: 100,000+ msg/sec
- **Message queue size**: Configurable (default 10,000)
- **Offline message retention**: 7 days
- **Chat message size**: Max 2000 characters
- **Notification payload size**: Max 10KB

---

## Troubleshooting

### WebSocket Connection Fails
1. Verify `/health` endpoint responds
2. Check firewall allows port 8080
3. Ensure user_id is provided
4. Check server logs

### Messages Not Received
1. Verify WebSocket connected (`onopen` called)
2. Check message format is valid JSON
3. Ensure channel name matches on sender/receiver
4. Verify receiver is in same channel

### RabbitMQ Queue Errors
1. Verify RabbitMQ running: `docker ps | grep rabbitmq`
2. Check connectivity: `telnet localhost 5672`
3. Review server logs for errors
4. Check queue bindings in RabbitMQ management UI

---

## References

- RFC 6455: WebSocket Protocol
- AMQP 0-9-1: RabbitMQ Message Format
- JSON Message Format Specification
- WebSocket Best Practices
