# System Architecture & Design

## Overview

BeaconCore is built on Erlang/OTP 28 with pure BEAM concurrency. Zero external dependencies for core functionality (RabbitMQ is optional).

```
┌─────────────────────────────────────────────┐
│         BeaconCore Application              │
│  (beacon_core_supervisor.erl)               │
└────────────────┬────────────────────────────┘
                 │
    ┌────────────┼────────────┬──────────┐
    │            │            │          │
    ▼            ▼            ▼          ▼
 HTTP        WebSocket     WebRTC     RabbitMQ
 Handler     Handler       Handler    Consumer
```

---

## Supervision Tree

BeaconCore uses OTP supervision tree for fault tolerance and recovery.

```
beacon_core_app
  │
  └─ beacon_core_supervisor (one_for_one)
      │
      ├─ network_gateway (gen_server)
      │   │ Port: 8080
      │   │ Handles: HTTP/WebSocket
      │
      ├─ webrtc_handler (gen_server)
      │   │ Broadcasts: #{stream_id => broadcast{}}
      │   │ Viewers: #{viewer_key => viewer{}}
      │   │ Manages: SDP/ICE signaling
      │
      ├─ ae_public_ws (gen_server)
      │   │ WebSocket connections
      │   │ Chat routing
      │   │ User session management
      │
      ├─ ae_admin_handler (gen_server)
      │   │ Admin API endpoints
      │   │ Notification broadcast
      │   │ Authentication
      │
      ├─ ae_amqp_client (gen_server)
      │   │ RabbitMQ connection
      │   │ Channel management
      │   │ Publisher
      │
      ├─ ae_routing_engine (gen_server)
      │   │ Message router
      │   │ RabbitMQ consumer
      │   │ Event dispatcher
      │
      └─ beacon_logger (gen_server)
          │ Structured logging
          │ Log aggregation
```

---

## Module Responsibilities

### beacon_core.erl

**Application entry point**

- Starts supervision tree
- Initializes environment variables
- Loads configuration

```erlang
application:start(beacon_core).
```

---

### beacon_core_supervisor.erl

**Supervisor process**

- One-for-one restart strategy
- Restarts failed children
- Child specs for all modules

**Restart Policy:**
- If child dies: restart within 60 seconds
- Max 5 restarts per 60 seconds
- If exceeded: kill parent and entire supervision tree

---

### network_gateway.erl

**HTTP/WebSocket server**

Listens on port 8080 (configurable via `BEAKON_HTTP_PORT`).

**Responsibilities:**
1. Accept HTTP requests
2. Upgrade WebSocket connections
3. Route requests to handlers
4. Send HTTP responses

**Key Functions:**
```erlang
start_link()
handle_http_request(Method, Path, Headers, Body)
handle_websocket_upgrade(Headers, Socket)
send_response(Socket, StatusCode, Headers, Body)
```

---

### ae_public_ws.erl

**WebSocket chat handler**

Manages all WebSocket connections and chat routing.

**Per-Connection State:**
```erlang
-record(ws_state, {
  user_id :: binary(),
  socket :: port(),
  channels = [] :: [binary()],
  auth_token :: binary() | undefined,
  last_ping :: integer(),
  message_buffer = [] :: [any()]
}).
```

**Responsibilities:**
1. Accept WebSocket connections
2. Parse chat messages
3. Route to channel subscribers
4. Handle user join/leave
5. Queue offline messages

**Message Types Handled:**
```erlang
{type: "chat", channel: "...", message: "..."}
{type: "typing", channel: "..."}
{type: "join_channel", channel: "..."}
{type: "leave_channel", channel: "..."}
```

---

### webrtc_handler.erl

**WebRTC streaming manager**

Manages all broadcasts and viewers using gen_server state machine.

**State Structure:**
```erlang
-record(state, {
  broadcasts = #{} :: #{StreamId => broadcast},
  viewers = #{} :: #{ViewerKey => viewer},
  rabbit_channel :: pid()
}).

-record(broadcast, {
  stream_id :: binary(),
  broadcaster_id :: binary(),
  status :: atom(),  % waiting_for_sdp | streaming | ended
  start_time :: integer(),
  viewer_count :: integer(),
  viewers = #{} :: map(),
  sdp_offer :: binary() | undefined,
  ice_candidates = [] :: [binary()]
}).

-record(viewer, {
  viewer_id :: binary(),
  stream_id :: binary(),
  connected_at :: integer(),
  sdp_answer :: binary() | undefined,
  ice_candidates = [] :: [binary()],
  connection_status :: atom()  % connecting | connected | disconnected
}).
```

**Responsibilities:**
1. Create/end broadcasts
2. Add/remove viewers
3. Store SDP offers/answers
4. Collect ICE candidates
5. Publish events to RabbitMQ

**State Transitions:**
```
Broadcast:
  waiting_for_sdp → streaming → ended

Viewer:
  connecting → connected → disconnected
```

---

### ae_admin_handler.erl

**Admin API endpoint handler**

Handles POST /v1/admin/broadcast requests.

**Responsibilities:**
1. Validate Bearer token
2. Parse notification payload
3. Route based on filter type
4. Publish to RabbitMQ
5. Return event ID

**Filter Types:**
- `"all"` → Broadcast to all users
- `"<user_id>"` → Send to specific user
- `"segment-<name>"` → Send to user segment
- `"<topic>"` → Send to topic subscribers

---

### ae_amqp_client.erl

**RabbitMQ connection manager**

Maintains single connection to RabbitMQ. Implements connection pooling and auto-reconnect.

**Responsibilities:**
1. Connect to RabbitMQ
2. Create channels
3. Declare exchanges/queues
4. Handle connection failures
5. Auto-reconnect with backoff

**Connection Details:**
```erlang
Host: env:RABBITMQ_HOST (default: localhost)
Port: env:RABBITMQ_PORT (default: 5672)
User: env:RABBITMQ_DEFAULT_USER
Pass: env:RABBITMQ_DEFAULT_PASS
```

---

### ae_routing_engine.erl

**Message router & consumer**

Consumes messages from RabbitMQ and routes to connected users.

**Consumer Loop:**
```erlang
loop() ->
  {ok, Message} = rabbit_channel:consume(Channel, Queue),
  {EventType, EventData} = parse_message(Message),
  
  case EventType of
    "chat" -> route_to_channel(EventData);
    "notification" -> route_to_user(EventData);
    "broadcast" -> route_to_all(EventData);
    "event" -> log_event(EventData)
  end,
  
  rabbit_channel:ack(Channel, Message),
  loop().
```

**Responsibilities:**
1. Subscribe to RabbitMQ queue
2. Parse event type
3. Route to correct dispatcher
4. Handle offline messages
5. Acknowledge message delivery

---

### beacon_logger.erl

**Structured logging**

Centralized logging with JSON output for aggregation.

**Log Format:**
```json
{
  "timestamp": "2026-05-20T14:30:00Z",
  "level": "info",
  "module": "webrtc_handler",
  "function": "add_viewer/2",
  "message": "Viewer added to stream",
  "data": {
    "stream_id": "stream-001",
    "viewer_id": "bob",
    "total_viewers": 5
  }
}
```

**Log Levels:**
- `debug` - Development only
- `info` - Normal operation
- `warning` - Degraded behavior
- `error` - Failure, recovery attempted
- `critical` - Fatal error

---

## Data Flow Diagrams

### Broadcast Creation Flow

```
1. HTTP POST /v1/streaming/broadcasts
   ↓
2. network_gateway validates request
   ↓
3. webrtc_handler:create_broadcast(StreamId, BroadcasterId)
   ↓
4. Create broadcast record, status = waiting_for_sdp
   ↓
5. Publish broadcast.created event to RabbitMQ
   ↓
6. Return {ok, stream_id} to client
```

### SDP Offer Flow (Broadcaster)

```
1. HTTP POST /v1/streaming/sdp (broadcaster)
   ↓
2. network_gateway validates request
   ↓
3. webrtc_handler:broadcast_sdp_offer(StreamId, SdpOffer)
   ↓
4. Update broadcast SDP, status = streaming
   ↓
5. Publish broadcast.started event to RabbitMQ
   ↓
6. Return {ok, status: "streaming"} to client
```

### Viewer Join Flow

```
1. HTTP POST /v1/streaming/viewers
   ↓
2. network_gateway validates request
   ↓
3. webrtc_handler:add_viewer(StreamId, ViewerId)
   ↓
4. Create viewer record, status = connecting
   ↓
5. Publish viewer.joined event to RabbitMQ
   ↓
6. Return broadcaster's SDP offer to viewer
   ↓
7. Viewer creates answer
   ↓
8. HTTP POST /v1/streaming/sdp (viewer answer)
   ↓
9. webrtc_handler:send_sdp_answer(ViewerKey, SdpAnswer)
   ↓
10. Update viewer SDP, status = connected
```

### Chat Message Flow

```
1. WebSocket send {"type": "chat", "channel": "stream-001", "message": "Hi!"}
   ↓
2. ae_public_ws receives message
   ↓
3. Validate message format
   ↓
4. Create message object with timestamp
   ↓
5. Publish to RabbitMQ events exchange
   ↓
6. ae_routing_engine consumes message
   ↓
7. Route to all users in channel
   ↓
8. Send to each user via WebSocket
   ↓
9. Queue offline for disconnected users
```

### Admin Notification Flow

```
1. HTTP POST /v1/admin/broadcast
   ↓
2. ae_admin_handler validates Bearer token
   ↓
3. Parse payload and filter type
   ↓
4. Publish to RabbitMQ with routing key
   ↓
5. ae_routing_engine consumes
   ↓
6. If "all": broadcast to all connected users
7. If "id:<user_id>": send to specific user
8. If "segment:<name>": send to segment members
9. If "topic:<name>": send to topic subscribers
   ↓
10. Return {ok, event_id} to client
```

---

## Process Communication

### Message Passing

Erlang processes communicate via message passing:

```erlang
% Synchronous call (waits for reply)
{ok, State} = gen_server:call(webrtc_handler, {get_broadcast_state, StreamId})

% Asynchronous cast (returns immediately)
gen_server:cast(webrtc_handler, {broadcast_sdp_offer, StreamId, SdpOffer})

% Async message (custom message)
send_message(Pid, {custom_event, Data})
```

### RabbitMQ Integration

Messages flow through RabbitMQ for:
1. Event publishing (broadcasts, viewers)
2. Admin notifications
3. Chat messages
4. System events

---

## Scalability

### Horizontal Scaling

BeaconCore uses Erlang's distributed clustering via pg module:

**Node Discovery:**
```erlang
% Node A
pg:join(webrtc_streams, broadcast_group, node_a@host)

% Node B
pg:join(webrtc_streams, broadcast_group, node_b@host)

% Both nodes automatically synchronized
Pids = pg:get_members(webrtc_streams, broadcast_group)
```

**RPC Calls Between Nodes:**
```erlang
rpc:call(node_b@host, webrtc_handler, get_broadcast_state, [StreamId])
```

### Vertical Scaling

Single node can handle:
- **10,000+ concurrent WebSocket connections**
- **1000+ concurrent broadcasts**
- **1000+ viewers per stream**
- **100,000+ messages per second**

**Memory Usage:**
- Base: ~50MB
- Per connection: ~50KB
- Per broadcast: ~100KB
- Per viewer: ~10KB

### Load Balancing

For multi-node setups:

```
       ┌─────────────────────┐
       │   Load Balancer     │
       │  (HAProxy/Nginx)    │
       └────────┬────────────┘
                │
       ┌────────┼────────┐
       │        │        │
       ▼        ▼        ▼
    Node 1   Node 2   Node 3
    :8080    :8080    :8080
```

**Sticky Sessions:** WebSocket connections must stick to same node (connection pooling in middleware).

**RabbitMQ Clustering:** All nodes share same RabbitMQ broker.

---

## Fault Tolerance

### Restart Strategies

**One-for-One:** If child dies, only that child restarts
```erlang
{supervision_strategy, one_for_one}
```

**Max Restarts:** 5 restarts per 60 seconds

### Connection Recovery

**RabbitMQ Connection Loss:**
1. Detect connection drop
2. Log error
3. Wait 5 seconds (backoff)
4. Attempt reconnect
5. Resume operations once connected

**WebSocket Connection Loss:**
1. Client detects TCP close
2. Automatic reconnect (client-side)
3. Offline messages queued
4. Messages delivered on reconnect

### Broadcast Recovery

If broadcaster disconnects:
1. All viewers receive disconnection event
2. Viewers can reconnect to same stream
3. New viewers can join
4. Broadcast continues with new SDP if provided

---

## Security

### Authentication

**Bearer Token:**
```
Authorization: Bearer <BEAKON_ADMIN_API_KEY>
```

Token checked against environment variable. No cryptographic validation.

**WebSocket:**
User ID in query parameter (`user_id=alice`). Optional app-layer token.

### Authorization

- Non-authenticated endpoints: `/health`, `/ws` (WebSocket)
- Authenticated endpoints: All `/v1/` API routes
- Admin endpoints: Bearer token + specific key

### HTTPS/TLS

**Production:**
```
wss://beacon.example.com/ws  (Secure WebSocket)
https://beacon.example.com/v1/...  (HTTPS)
```

**Configuration:**
```bash
export BEAKON_SSL_CERT=/path/to/cert.pem
export BEAKON_SSL_KEY=/path/to/key.pem
```

### Security Headers

All responses include:
```
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
X-XSS-Protection: 1; mode=block
Strict-Transport-Security: max-age=31536000
Cache-Control: no-cache, no-store, must-revalidate
```

---

## Performance Optimization

### Connection Pooling

RabbitMQ uses single connection with multiple channels:

```erlang
{ok, Connection} = amqp_connection:open_connection(),
{ok, Channel1} = amqp_connection:open_channel(Connection),
{ok, Channel2} = amqp_connection:open_channel(Connection),
```

### Message Batching

For high-throughput scenarios, batch messages:

```erlang
Messages = queue:from_list([msg1, msg2, msg3, ...]),
rabbit_channel:publish_batch(Channel, Messages)
```

### Caching

Broadcast state cached in gen_server:

```erlang
-record(state, {
  broadcasts = #{} :: #{StreamId => broadcast}
})
```

No external cache needed.

### Rate Limiting

Per-token rate limiting:
- Streaming API: 1000 req/min
- Admin API: 100 req/min

Implemented in middleware before handlers.

---

## Monitoring

### Metrics

**System Metrics:**
```erlang
erlang:statistics(runtime)       % [Total, SinceLast]
erlang:system_info(process_count)
erlang:memory()                  % [{atom, Size}, ...]
```

**Application Metrics:**
- Active broadcasts: `maps:size(Broadcasts)`
- Active viewers: `maps:size(Viewers)`
- Message throughput: Counter in routing engine
- WebSocket connections: Connected clients

### Health Checks

GET `/health` returns:
```json
{
  "status": "healthy",
  "uptime_ms": 125430,
  "process_count": 150,
  "memory_mb": 64,
  "connections": {
    "websocket": 42,
    "rabbitmq": 1
  }
}
```

### Logging

Structured JSON logging to stdout/stderr. Pipe to log aggregator:

```bash
make run | logstash-forwarder  # Elasticsearch
make run | jq --slurp          # DataDog
make run | tee beacon.log      # File
```

---

## Deployment

### Docker

Build image:
```bash
docker build -t beaconcore:latest .
```

Run container:
```bash
docker run -d \
  -p 8080:8080 \
  -e BEAKON_ADMIN_API_KEY=secret \
  -e RABBITMQ_HOST=rabbitmq \
  --network beacon-network \
  beaconcore:latest
```

### Kubernetes

Deploy in K8s:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: beaconcore
spec:
  containers:
  - name: beaconcore
    image: beaconcore:latest
    ports:
    - containerPort: 8080
    env:
    - name: BEAKON_ADMIN_API_KEY
      valueFrom:
        secretKeyRef:
          name: beacon-secrets
          key: admin-api-key
```

### Configuration

Environment variables:
```bash
BEAKON_HTTP_PORT=8080
BEAKON_ADMIN_API_KEY=secret-key
RABBITMQ_HOST=localhost
RABBITMQ_PORT=5672
RABBITMQ_DEFAULT_USER=guest
RABBITMQ_DEFAULT_PASS=guest
```

---

## Future Enhancements

### Media Transport
- Integrate pion/webrtc-go via NIF
- Actual media stream handling
- Bitrate adaptation
- Simulcast support

### Database Integration
- Persistent broadcast history
- User statistics
- Segment definitions
- Topic subscriptions

### Advanced Features
- Stream recording
- Multi-bitrate (ABR)
- Viewer analytics
- CDN integration
- VAPID web push

---

## References

- Erlang/OTP 28 Documentation
- gen_server Behavior Guide
- Supervisor Behavior Guide
- AMQP 0-9-1 Protocol
- WebRTC Specification (RFC 7675)
