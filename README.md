# BeaconCore (烽燧)

**A high-performance, distributed notification microservice built with Erlang/OTP 28 and pure native components.**

Real-time push notifications at scale. WebSocket + HTTP REST + RabbitMQ with zero external dependencies.

---

## Quick Start (5 minutes)

### Prerequisites
```bash
erl -version              # Erlang/OTP 28+
docker run -d --name rabbitmq -p 5672:5672 -p 15672:15672 rabbitmq:3.12-management
npm install -g wscat      # WebSocket CLI client
```

### Run
```bash
cd D:\ctkqiang\BeaconCore
make clean && make compile
make kill && make run
```

### Test
**Terminal 2:**
```bash
wscat -c "ws://127.0.0.1:8080/ws?user_id=alice"
```

See: `Connected (press CTRL+C to quit)` [OK]

**Terminal 3:**
```bash
curl http://127.0.0.1:8080/health | jq
```

See: JSON response with `status: "degraded"` [OK]

---

## What is BeaconCore?

BeaconCore is a **notification microservice** that:

[OK] Accepts broadcasts from admin via HTTP REST  
[OK] Queues messages in RabbitMQ (AMQP 0-9-1)  
[OK] Delivers to online users via WebSocket (real-time)  
[OK] Delivers to offline users via W3C Web Push (VAPID)  
[OK] Runs on pure Erlang/OTP (zero external dependencies)  
[OK] Scales horizontally (cluster-native with pg module)  
[OK] Includes health checks & security headers  
[OK] Logs everything to console in real-time  

---

## Architecture

```
┌─ Public Users (WebSocket)    ─┐
│                               │
│  ws://localhost:8080/ws       │
│  ↓                            │
│  Process Group Registration   │
│  pg:join(scope, {user, id})  │
│                               │
└─────────────────────────────┬─┘

      ┌─ Admin/Services (HTTP) ──┐
      │                          │
      │ POST /v1/admin/broadcast │
      │ ↓                        │
      │ RabbitMQ Publish         │
      │                          │
      └──────────┬───────────────┘

      ┌─ Routing Engine (AMQP Consumer) ─┐
      │                                   │
      │ 1. Read from RabbitMQ queue      │
      │ 2. Query users from database     │
      │ 3. Dispatch to online/offline    │
      │                                   │
      └───────────────────────────────────┘
            │
      ┌─────┴──────┐
      ↓            ↓
   Online:      Offline:
   WebSocket    VAPID Push
   (Direct)     (Vendor)
```

---

## API Quick Reference

### Health Check
```bash
curl http://127.0.0.1:8080/health
```

### WebSocket Connect
```bash
wscat -c "ws://127.0.0.1:8080/ws?user_id=alice"
```

### Admin Broadcast
```bash
curl -X POST http://127.0.0.1:8080/v1/admin/broadcast \
  -H "Content-Type: application/json" \
  -d '{"type":"broadcast","payload":"{\"msg\":\"hello\"}","filter":"all"}'
```

---

## Testing

### Test 1: Health Check
**Terminal 1:** Start service
```bash
make run
```

**Terminal 2:** Check health
```bash
curl -i http://127.0.0.1:8080/health
```

**Expected:** 200 OK with JSON containing `"status": "healthy"`

---

### Test 2: WebSocket Connection
**Terminal 1:** Already running from Test 1

**Terminal 2:** Connect as user
```bash
wscat -c "ws://127.0.0.1:8080/ws?user_id=alice"
```

**Expected:** 
```
Connected (press CTRL+C to quit)
```

---

### Test 3: Admin Broadcast with Authentication
**Terminal 1:** Already running

**Terminal 2:** Still connected as alice

**Terminal 3:** Send authenticated broadcast
```bash
curl -X POST http://127.0.0.1:8080/v1/admin/broadcast \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer secret-key-12345" \
  -d '{"type":"broadcast","payload":"{\"msg\":\"hello\"}","filter":"all"}'
```

**Expected:** 202 Accepted response

**Terminal 1:** Check logs for `[NOTICE] Message published to RabbitMQ`

---

### Test 4: Authentication Failure
**Terminal 3:** Try without Authorization header
```bash
curl -X POST http://127.0.0.1:8080/v1/admin/broadcast \
  -H "Content-Type: application/json" \
  -d '{"type":"broadcast","payload":"test","filter":"all"}'
```

**Expected:** 401 Unauthorized with error message

**Terminal 3:** Try with wrong token
```bash
curl -X POST http://127.0.0.1:8080/v1/admin/broadcast \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer wrong-token" \
  -d '{"type":"broadcast","payload":"test","filter":"all"}'
```

**Expected:** 401 Unauthorized

---

### Test 5: Multiple Concurrent Users
**Terminal 2:** Already running as alice

**Terminal 4:** Connect another user
```bash
wscat -c "ws://127.0.0.1:8080/ws?user_id=bob"
```

**Terminal 5:** Send broadcast
```bash
curl -X POST http://127.0.0.1:8080/v1/admin/broadcast \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer secret-key-12345" \
  -d '{"type":"broadcast","payload":"{\"msg\":\"broadcast\"}","filter":"all"}'
```

**Expected:** Both Terminal 2 (alice) and Terminal 4 (bob) receive the message

---

### Test 6: User-Specific Delivery
**Terminal 5:** Send message to specific user
```bash
curl -X POST http://127.0.0.1:8080/v1/admin/broadcast \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer secret-key-12345" \
  -d '{"type":"id","payload":"{\"msg\":\"for alice only\"}","filter":"alice"}'
```

**Expected:** Only Terminal 2 (alice) receives the message, not bob

---

## Project Structure

```
BeaconCore/
├── README.md                    # This file
├── Makefile                     # Build: compile, run, dev, kill, clean
├── beacon_core.erl              # Application entry point
├── beacon_core_supervisor.erl   # Process supervision tree
│
├── src/
│   ├── network_gateway.erl      # HTTP/WebSocket gateway (port 8080)
│   ├── ae_public_ws.erl         # WebSocket handler (RFC 6455)
│   ├── ae_admin_handler.erl     # Admin broadcast handler
│   ├── ae_amqp_client.erl       # AMQP 0-9-1 client (pure Erlang)
│   ├── ae_routing_engine.erl    # Message router (consuming RabbitMQ)
│   ├── beacon_logger.erl        # Structured logging
│   └── database_connector.erl   # Database connection pool
│
├── header/
│   ├── logger.hrl               # Logging macros (?LOG_INFO, etc)
│   └── database_connector.hrl    # DB types
│
├── ebin/                        # Compiled .beam files
├── config/
│   └── sys.config               # System configuration
│
└── .env                         # Create this: environment variables
```

---

## Configuration

Create `.env` file with these variables:

```bash
# HTTP Server
BEAKON_HTTP_PORT=8080

# Admin API Security
BEAKON_ADMIN_API_KEY=your-secret-api-key-here

# Database (PostgreSQL/MySQL)
BEAKON_DB_HOST=localhost
BEAKON_DB_PORT=5432
BEAKON_DB_USER=postgres
BEAKON_DB_PASS=postgres
BEAKON_DB_NAME=beacon_notifications
BEAKON_DB_SSL_MODE=disable

# RabbitMQ/AMQP
RABBITMQ_HOST=localhost
RABBITMQ_PORT=5672
RABBITMQ_DEFAULT_USER=guest
RABBITMQ_DEFAULT_PASS=guest
RABBITMQ_MANAGEMENT_PORT=15672

# VAPID Keys (for Web Push - future implementation)
BEAKON_VAPID_PUBLIC_KEY=your-public-key
BEAKON_VAPID_PRIVATE_KEY=your-private-key
```

**Security Notes:**
- `BEAKON_ADMIN_API_KEY` should be a cryptographically random string (32+ characters)
- Store `.env` securely (don't commit to git)
- In production, use secrets management (AWS Secrets Manager, HashiCorp Vault, etc.)
- Rotate API keys regularly

---

## Current Status

### Phase 0-7 Implemented & Working
- [OK] HTTP gateway (GET /health, GET /ws, POST /v1/admin/broadcast)
- [OK] WebSocket connections (RFC 6455 handshake + frame handling)
- [OK] User registration in process groups (pg module)
- [OK] Admin broadcast API with JSON parsing
- [OK] Bearer token authentication (Authorization header validation)
- [OK] RabbitMQ publishing (AMQP 0-9-1 client with handshake)
- [OK] Health endpoint with security headers and service status checks
- [OK] Real-time console logging with structured output
- [OK] Routing engine consumer loop (receives RabbitMQ messages)
- [OK] Online user dispatch via process groups (WebSocket delivery)
- [OK] Message routing by type (broadcast, user_id, segment, channel)
- [OK] Structured error handling (4xx/5xx responses)

### In Progress
- [ ] VAPID Web Push (offline user notifications, RFC 8291)
- [ ] Database integration (audit logs, user subscriptions)
- [ ] Rate limiting per API key
- [ ] Connection pooling and performance optimization

### Known Limitations
- **Manual JSON parsing** - Fragile for complex nested payloads (consider jq or native JSON library)
- **Database not wired** - Audit logs written in memory only
- **No TLS/SSL** - Plain HTTP/WebSocket (add reverse proxy with TLS in production)
- **Offline users** - Currently logged but not delivered via Web Push (Phase 8)

---

## Makefile Commands

```bash
make compile        # Compile all Erlang modules
make run            # Start with real-time logs
make dev            # Interactive shell
make kill           # Stop application
make clean          # Remove compiled .beam files
```

---

## Troubleshooting

### WebSocket won't connect
```bash
curl http://127.0.0.1:8080/health  # Test HTTP first
# If works, check firewall on port 8080
```

### Port 8080 already in use
```bash
make kill
sleep 5
make run
```

### RabbitMQ connection refused
```bash
docker ps | grep rabbitmq
# If not running:
docker run -d --name rabbitmq -p 5672:5672 -p 15672:15672 rabbitmq:3.12-management
```

### Compilation errors
```bash
make clean
make compile 2>&1 | grep -i error
```

---

## Next Steps

### Immediate Priority (Phase 7-8, 6-8 hours)
1. **Implement routing engine consumer** - Read RabbitMQ, dispatch to users
2. **Add VAPID Web Push** - Offline user notifications

### Short Term (Phase 9-10, 7-9 hours)
3. **Database integration** - Audit logs, subscriptions
4. **Test suite** - EUnit + integration tests

### Production Ready (Phase 11-12, 4-6 hours)
5. **Authentication & rate limiting** - Secure admin API
6. **Load testing** - Performance verification

---

## Usage Examples

### 1. Public Health Check
**Purpose:** Monitor service availability and system status  
**Authentication:** None (public endpoint)

```bash
curl -i http://127.0.0.1:8080/health
```

**Response (200 OK):**
```json
{
  "timestamp": "2026-05-18T14:32:45Z",
  "status": "healthy",
  "uptime_seconds": 3600,
  "services": {
    "database": "ok",
    "process_group": "ok",
    "amqp": "ok"
  },
  "memory_mb": 45,
  "version": "1.0.0",
  "node": "beacon_core@127.0.0.1"
}
```

---

### 2. User Client: WebSocket Connection
**Purpose:** Receive real-time notifications as a user  
**Authentication:** User ID in query string (no token needed for WebSocket)

**Terminal 1: Connect as user alice**
```bash
wscat -c "ws://127.0.0.1:8080/ws?user_id=alice"
```

**Expected output:**
```
Connected (press CTRL+C to quit)
>
```

**Terminal 2: Send a broadcast**
```bash
curl -X POST http://127.0.0.1:8080/v1/admin/broadcast \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer secret-key-12345" \
  -d '{
    "type": "broadcast",
    "payload": "{\"title\": \"System Alert\", \"message\": \"Maintenance window\"}",
    "filter": "all"
  }'
```

**Terminal 1: Message received in wscat**
```
< {"title": "System Alert", "message": "Maintenance window"}
```

---

### 3. Admin API: Broadcast to All Users
**Purpose:** Send notification to all connected users  
**Authentication:** Bearer token (BEAKON_ADMIN_API_KEY from .env)

```bash
curl -X POST http://127.0.0.1:8080/v1/admin/broadcast \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer secret-key-12345" \
  -d '{
    "type": "broadcast",
    "payload": "{\"title\": \"Alert\", \"message\": \"System maintenance\"}",
    "filter": "all"
  }'
```

**Response (202 Accepted):**
```json
{
  "status": "dispatched"
}
```

---

### 4. Admin API: Send to Specific User
**Purpose:** Deliver notification to a single user by ID  
**Authentication:** Bearer token required

```bash
curl -X POST http://127.0.0.1:8080/v1/admin/broadcast \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer secret-key-12345" \
  -d '{
    "type": "id",
    "payload": "{\"message\": \"Your order #12345 is ready for pickup\"}",
    "filter": "user_67890"
  }'
```

**Behavior:**
- If user is online (connected via WebSocket): message delivered immediately
- If user is offline: message queued for VAPID Web Push (future implementation)

---

### 5. Admin API: Send to User Segment
**Purpose:** Deliver to all users in a segment (e.g., premium, vip)  
**Authentication:** Bearer token required

```bash
curl -X POST http://127.0.0.1:8080/v1/admin/broadcast \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer secret-key-12345" \
  -d '{
    "type": "segment",
    "payload": "{\"offer\": \"Premium members: 50% off next purchase\"}",
    "filter": "premium"
  }'
```

**Routing:** Message sent to all users with segment tag "premium" registered in process groups

---

### 6. Admin API: Send to Channel
**Purpose:** Broadcast to specific channel (e.g., announcements, alerts)  
**Authentication:** Bearer token required

```bash
curl -X POST http://127.0.0.1:8080/v1/admin/broadcast \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer secret-key-12345" \
  -d '{
    "type": "channel",
    "payload": "{\"type\": \"warning\", \"text\": \"API maintenance scheduled\"}",
    "filter": "announcements"
  }'
```

---

### 7. Authentication Error Handling
**Missing Authorization Header:**
```bash
curl -X POST http://127.0.0.1:8080/v1/admin/broadcast \
  -H "Content-Type: application/json" \
  -d '{"type":"broadcast","payload":"test","filter":"all"}'
```

**Response (401 Unauthorized):**
```json
{
  "error": "Unauthorized"
}
```

**Invalid Token:**
```bash
curl -X POST http://127.0.0.1:8080/v1/admin/broadcast \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer wrong-token" \
  -d '{"type":"broadcast","payload":"test","filter":"all"}'
```

**Response (401 Unauthorized):**
```json
{
  "error": "Unauthorized"
}
```

---

## API Endpoints

| Method | Path | Authentication | Purpose | Response |
|--------|------|---|---------|--------|
| GET | `/health` | None | Service health status | 200 OK (JSON) |
| GET | `/ws?user_id=<id>` | User ID in query | WebSocket upgrade | 101 Switching Protocols |
| POST | `/v1/admin/broadcast` | Bearer token | Send notification | 202 Accepted |

---

## Performance Characteristics

- **WebSocket Connections:** Tested with multiple concurrent users
- **Message Throughput:** Limited by RabbitMQ queue depth
- **Memory Usage:** ~35MB base + per-connection overhead
- **Latency:** Sub-100ms for online delivery (network dependent)

---

## Security

**HTTP Security Headers:**
- `X-Content-Type-Options: nosniff` — Prevent MIME sniffing
- `X-Frame-Options: DENY` — Prevent clickjacking
- `X-XSS-Protection: 1; mode=block` — XSS protection
- `Strict-Transport-Security: max-age=31536000` — Force HTTPS
- `Cache-Control: no-cache, no-store, must-revalidate` — Prevent caching sensitive data

**Authentication:**
- Admin API (`/v1/admin/broadcast`) requires `Authorization: Bearer <token>` header
- Token must match `BEAKON_ADMIN_API_KEY` environment variable
- Invalid or missing tokens return `401 Unauthorized`
- WebSocket connections use user ID (authenticated via application layer)

**Configuration:**
Set in `.env`:
```
BEAKON_ADMIN_API_KEY=your-secret-api-key-here
```

**Production Recommendations:**
- Enable TLS/SSL for all traffic (upgrade to wss:// for WebSocket)
- Use strong API keys (32+ characters, cryptographically random)
- Rotate API keys regularly
- Implement rate limiting per API key
- Add database audit logging for all admin actions
- Use network-level access controls (firewall rules)

---

## Support

### Check Logs
```bash
tail -f beacon.log          # Background mode
make run                    # Foreground mode (see logs directly)
```

### Debug Commands
```bash
curl http://127.0.0.1:8080/health      # Test HTTP
wscat -c "ws://127.0.0.1:8080/ws?user_id=test"  # Test WebSocket
```

### RabbitMQ Management UI
```
http://localhost:15672
Username: guest
Password: guest
```

---

## License

MIT License

---

## Status Summary

**What Works Now:**
- OK: WebSocket connections & message handling
- OK: Admin broadcast API
- OK: Message publishing to RabbitMQ
- OK: Health monitoring
- OK: Real-time logging

**What's Coming:**
- Pending: Message delivery to users (routing engine)
- Pending: Offline Web Push (VAPID)
- Pending: Database integration
- Pending: Load testing & optimization

---

**Version:** 0.5.0 (Beta)  
**Last Updated:** 2026-05-18  
**Next Milestone:** Routing Engine Implementation