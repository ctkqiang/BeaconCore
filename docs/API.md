# Complete API Reference

## Base URL

```
http://127.0.0.1:8080
```

In production, use HTTPS:
```
https://beacon.example.com
```

---

## Authentication

### Bearer Token

All endpoints except `/health` require Bearer token in `Authorization` header:

```bash
curl -H "Authorization: Bearer secret-key-12345" \
  http://127.0.0.1:8080/v1/streaming/broadcasts
```

Token is matched against `BEAKON_ADMIN_API_KEY` environment variable.

---

## Health Check

### GET /health

Service status check. No authentication required.

**Request:**
```bash
curl http://127.0.0.1:8080/health
```

**Response (200 OK):**
```json
{
  "status": "healthy",
  "uptime_ms": 125430,
  "version": "0.6.0",
  "timestamp": 1716201600000
}
```

**Response (503 Service Unavailable):**
```json
{
  "status": "unhealthy",
  "reason": "RabbitMQ connection failed",
  "timestamp": 1716201600000
}
```

---

## WebSocket Chat

### GET /ws

Establish WebSocket connection for real-time chat.

**URL:**
```
ws://127.0.0.1:8080/ws?user_id=alice&auth_token=optional
```

**Query Parameters:**
- `user_id` (required): Unique user identifier
- `auth_token` (optional): Application-layer authentication token

**Connection Example:**
```javascript
const ws = new WebSocket('ws://127.0.0.1:8080/ws?user_id=alice');
ws.onopen = () => console.log('Connected');
ws.onmessage = (e) => console.log('Message:', JSON.parse(e.data));
```

**Message Format:**
```json
{
  "type": "chat",
  "channel": "stream-001",
  "message": "Hello!",
  "timestamp": 1716201600000
}
```

See `MESSAGING.md` for complete chat protocol.

---

## Streaming API

### POST /v1/streaming/broadcasts

Create a new broadcast stream.

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

**Request Body:**
```json
{
  "stream_id": "stream-001",
  "broadcaster_id": "alice"
}
```

- `stream_id`: Unique identifier for stream (alphanumeric, max 64 chars)
- `broadcaster_id`: User ID of broadcaster (max 128 chars)

**Response (200 OK):**
```json
{
  "ok": true,
  "stream_id": "stream-001",
  "status": "waiting_for_sdp",
  "created_at": 1716201600000
}
```

**Error Response (400 Bad Request):**
```json
{
  "error": "invalid_stream_id",
  "message": "stream_id must be alphanumeric"
}
```

---

### POST /v1/streaming/sdp

Send SDP offer (broadcaster) or answer (viewer).

**Request (Broadcaster):**
```bash
curl -X POST http://127.0.0.1:8080/v1/streaming/sdp \
  -H "Authorization: Bearer secret-key-12345" \
  -H "Content-Type: application/json" \
  -d '{
    "stream_id": "stream-001",
    "sdp_offer": "v=0\r\no=- ...(full SDP)..."
  }'
```

**Request (Viewer):**
```bash
curl -X POST http://127.0.0.1:8080/v1/streaming/sdp \
  -H "Authorization: Bearer secret-key-12345" \
  -H "Content-Type: application/json" \
  -d '{
    "viewer_key": "stream-001:bob",
    "sdp_answer": "v=0\r\no=- ...(full SDP)..."
  }'
```

**Request Body (Broadcaster):**
```json
{
  "stream_id": "stream-001",
  "sdp_offer": "v=0\r\no=- ..."
}
```

**Request Body (Viewer):**
```json
{
  "viewer_key": "stream-001:bob",
  "sdp_answer": "v=0\r\no=- ..."
}
```

**Response (200 OK):**
```json
{
  "ok": true,
  "status": "connected"
}
```

---

### POST /v1/streaming/ice

Send ICE candidate for NAT traversal.

**Request (Broadcaster):**
```bash
curl -X POST http://127.0.0.1:8080/v1/streaming/ice \
  -H "Authorization: Bearer secret-key-12345" \
  -H "Content-Type: application/json" \
  -d '{
    "stream_id": "stream-001",
    "ice_candidate": {
      "candidate": "candidate:123 1 udp 2122260223 192.168.1.5 54321 typ host",
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
      "candidate": "candidate:456 1 udp 2122260223 192.168.1.10 54322 typ host",
      "sdpMLineIndex": 0,
      "sdpMid": "video"
    }
  }'
```

**Request Body:**
```json
{
  "stream_id": "stream-001",
  "ice_candidate": {
    "candidate": "candidate:...",
    "sdpMLineIndex": 0,
    "sdpMid": "video"
  }
}
```

**Response (200 OK):**
```json
{
  "ok": true,
  "ice_count": 5
}
```

---

### POST /v1/streaming/viewers

Add a viewer to a broadcast stream.

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

**Request Body:**
```json
{
  "stream_id": "stream-001",
  "viewer_id": "bob"
}
```

**Response (200 OK):**
```json
{
  "ok": true,
  "viewer_id": "bob",
  "sdp_offer": "v=0\r\no=- ...",
  "connected_at": 1716201600000
}
```

---

### GET /v1/streaming/broadcasts/:stream_id

Get broadcast stream state.

**Request:**
```bash
curl -X GET http://127.0.0.1:8080/v1/streaming/broadcasts/stream-001 \
  -H "Authorization: Bearer secret-key-12345"
```

**Response (200 OK):**
```json
{
  "ok": true,
  "stream_id": "stream-001",
  "broadcaster_id": "alice",
  "status": "streaming",
  "start_time": 1716201600000,
  "viewer_count": 5,
  "duration_ms": 45000
}
```

---

### GET /v1/streaming/viewers/:stream_id

Get active viewers for a stream.

**Request:**
```bash
curl -X GET http://127.0.0.1:8080/v1/streaming/viewers/stream-001 \
  -H "Authorization: Bearer secret-key-12345"
```

**Response (200 OK):**
```json
{
  "ok": true,
  "stream_id": "stream-001",
  "viewer_count": 3,
  "viewers": [
    {
      "viewer_id": "bob",
      "connected_at": 1716201600000,
      "status": "connected"
    },
    {
      "viewer_id": "charlie",
      "connected_at": 1716201610000,
      "status": "connected"
    }
  ]
}
```

---

### DELETE /v1/streaming/broadcasts/:stream_id

End a broadcast stream.

**Request:**
```bash
curl -X DELETE http://127.0.0.1:8080/v1/streaming/broadcasts/stream-001 \
  -H "Authorization: Bearer secret-key-12345"
```

**Response (200 OK):**
```json
{
  "ok": true,
  "stream_id": "stream-001",
  "viewer_count": 5,
  "duration_ms": 125000
}
```

---

### DELETE /v1/streaming/viewers/:stream_id/:viewer_id

Remove a viewer from a stream.

**Request:**
```bash
curl -X DELETE http://127.0.0.1:8080/v1/streaming/viewers/stream-001/bob \
  -H "Authorization: Bearer secret-key-12345"
```

**Response (200 OK):**
```json
{
  "ok": true,
  "viewer_id": "bob",
  "duration_ms": 45000
}
```

---

## Admin API

### POST /v1/admin/broadcast

Send notification via admin API.

**Request (Broadcast to All):**
```bash
curl -X POST http://127.0.0.1:8080/v1/admin/broadcast \
  -H "Authorization: Bearer secret-key-12345" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "broadcast",
    "payload": "{\"title\":\"Alert\",\"message\":\"System maintenance\"}",
    "filter": "all"
  }'
```

**Request (Send to User):**
```bash
curl -X POST http://127.0.0.1:8080/v1/admin/broadcast \
  -H "Authorization: Bearer secret-key-12345" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "id",
    "payload": "{\"title\":\"Notification\",\"message\":\"Your order is ready\"}",
    "filter": "user-123"
  }'
```

**Request Body:**
```json
{
  "type": "broadcast|id|segment|topic",
  "payload": "{...}",
  "filter": "all|user-123|segment-vip|sports-news"
}
```

- `type`: Message type (broadcast, id, segment, topic)
- `payload`: JSON string with message content
- `filter`: Target audience (all, user_id, segment_name, or topic_name)

**Response (200 OK):**
```json
{
  "ok": true,
  "event_id": "event-12345",
  "message_id": "msg-67890",
  "target_type": "broadcast",
  "recipients": -1
}
```

---

## Error Responses

### 400 Bad Request

Invalid request format or parameters.

```json
{
  "error": "bad_request",
  "message": "Invalid JSON body"
}
```

### 401 Unauthorized

Missing or invalid authentication token.

```json
{
  "error": "unauthorized",
  "message": "Invalid or missing authorization header"
}
```

### 403 Forbidden

Authenticated but not authorized.

```json
{
  "error": "forbidden",
  "message": "Your token does not have permission for this action"
}
```

### 404 Not Found

Resource not found.

```json
{
  "error": "not_found",
  "message": "Stream does not exist"
}
```

### 409 Conflict

Resource already exists or state conflict.

```json
{
  "error": "conflict",
  "message": "Stream already exists with this ID"
}
```

### 429 Too Many Requests

Rate limit exceeded.

```json
{
  "error": "rate_limit",
  "message": "Too many requests, please retry in 60 seconds"
}
```

### 500 Internal Server Error

Server-side error.

```json
{
  "error": "internal_error",
  "message": "An unexpected error occurred"
}
```

### 503 Service Unavailable

Service temporarily unavailable.

```json
{
  "error": "service_unavailable",
  "message": "RabbitMQ connection lost"
}
```

---

## HTTP Headers

### Request Headers

Required for all endpoints except `/health`:

```
Authorization: Bearer <token>
Content-Type: application/json
```

Optional:

```
X-Request-ID: <uuid>          # For request tracing
X-Correlation-ID: <uuid>      # For distributed tracing
User-Agent: <client-name>
```

### Response Headers

All responses include:

```
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
X-XSS-Protection: 1; mode=block
Strict-Transport-Security: max-age=31536000
Cache-Control: no-cache, no-store, must-revalidate
Content-Type: application/json
X-Request-ID: <uuid>
```

---

## Status Codes

| Code | Meaning |
|------|---------|
| 200 | Success |
| 201 | Created |
| 204 | No Content |
| 400 | Bad Request |
| 401 | Unauthorized |
| 403 | Forbidden |
| 404 | Not Found |
| 409 | Conflict |
| 429 | Too Many Requests |
| 500 | Internal Error |
| 503 | Service Unavailable |

---

## Rate Limits

Per authentication token:

- **Streaming API**: 1000 requests/minute
- **Admin API**: 100 requests/minute
- **WebSocket**: Unlimited concurrent connections
- **Messages per second**: 100,000+

Rate limit headers:

```
X-RateLimit-Limit: 1000
X-RateLimit-Remaining: 999
X-RateLimit-Reset: 1716201660
```

---

## Pagination

List endpoints support pagination:

```bash
curl -X GET "http://127.0.0.1:8080/v1/streams?page=2&limit=20" \
  -H "Authorization: Bearer token"
```

**Response:**
```json
{
  "ok": true,
  "data": [...],
  "pagination": {
    "page": 2,
    "limit": 20,
    "total": 150,
    "pages": 8
  }
}
```

---

## Webhook Events

Subscribe to events via webhook (optional):

```bash
curl -X POST http://127.0.0.1:8080/v1/webhooks \
  -H "Authorization: Bearer token" \
  -H "Content-Type: application/json" \
  -d '{
    "url": "https://example.com/webhook",
    "events": ["broadcast.created", "viewer.joined", "broadcast.ended"]
  }'
```

BeaconCore will POST events to your URL:

```json
{
  "type": "broadcast.created",
  "timestamp": 1716201600000,
  "data": {
    "stream_id": "stream-001",
    "broadcaster_id": "alice"
  },
  "id": "evt-12345"
}
```

---

## SDK & Client Libraries

Official SDKs:

- **JavaScript**: `@beaconcore/js`
- **Python**: `beaconcore-python`
- **Go**: `github.com/beaconcore/go-sdk`
- **Rust**: `beaconcore-rs`

Community SDKs welcome! See ARCHITECTURE.md for integration details.

---

## API Versioning

Current version: **v1**

API is versioned in URL path: `/v1/streaming/broadcasts`

Breaking changes will be in new version: `/v2/streaming/broadcasts`

---

## References

- RFC 7231: HTTP Semantics
- RFC 7230: HTTP Message Syntax
- RFC 6455: WebSocket Protocol
- AMQP 0-9-1 Specification
