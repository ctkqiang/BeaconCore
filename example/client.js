// BeaconCore Live Streaming Client
// Proof of concept for WebRTC streaming + WebSocket chat

class BeaconCoreClient {
    constructor() {
        this.mode = 'broadcaster';
        this.serverUrl = 'http://127.0.0.1:8080';
        this.apiToken = 'secret-key-12345';
        this.ws = null;
        this.streamId = null;
        this.userId = null;
        this.broadcastStartTime = null;
        this.viewers = new Map();
        this.messageBuffer = [];
    }

    log(level, message, data = {}) {
        const timestamp = new Date().toISOString();
        const logEntry = document.createElement('div');
        logEntry.className = 'log-entry';

        let levelClass = `log-${level}`;
        let logContent = `<span class="log-timestamp">[${timestamp}]</span>
                         <span class="log-level ${levelClass}">[${level.toUpperCase()}]</span>
                         <span>${message}`;

        if (Object.keys(data).length > 0) {
            logContent += ` | ${JSON.stringify(data)}`;
        }
        logContent += '</span>';

        logEntry.innerHTML = logContent;
        const logsDiv = document.getElementById('logs');
        logsDiv.appendChild(logEntry);
        logsDiv.scrollTop = logsDiv.scrollHeight;
    }

    // HTTP Utility
    async makeRequest(method, path, body = null) {
        const headers = {
            'Authorization': `Bearer ${this.apiToken}`,
            'Content-Type': 'application/json'
        };

        try {
            const options = {
                method,
                headers
            };

            if (body) {
                options.body = JSON.stringify(body);
            }

            this.log('debug', `${method} ${this.serverUrl}${path}`, {
                headers: Object.keys(headers),
                body_size: body ? JSON.stringify(body).length : 0
            });

            const response = await fetch(`${this.serverUrl}${path}`, options);
            const data = await response.json().catch(() => ({}));

            this.log(response.ok ? 'info' : 'error', `${method} ${path} - ${response.status}`, {
                status: response.status,
                response_size: JSON.stringify(data).length
            });

            return { ok: response.ok, status: response.status, data };
        } catch (error) {
            this.log('error', `Request failed: ${method} ${path}`, { error: error.message });
            return { ok: false, error: error.message };
        }
    }

    // WebSocket Chat
    connectWebSocket(userId) {
        return new Promise((resolve, reject) => {
            const wsUrl = `ws://${this.serverUrl.split('://')[1]}/ws?user_id=${userId}`;
            this.log('info', 'Connecting to WebSocket', { url: wsUrl, user_id: userId });

            try {
                this.ws = new WebSocket(wsUrl);

                this.ws.onopen = () => {
                    this.log('info', 'WebSocket connected', { user_id: userId });
                    resolve(true);
                };

                this.ws.onmessage = (event) => {
                    try {
                        const message = JSON.parse(event.data);
                        this.handleWebSocketMessage(message);
                    } catch (e) {
                        this.log('warn', 'Failed to parse WebSocket message', { error: e.message });
                    }
                };

                this.ws.onerror = (error) => {
                    this.log('error', 'WebSocket error', { error: error.message || 'Unknown error' });
                    reject(error);
                };

                this.ws.onclose = () => {
                    this.log('warn', 'WebSocket disconnected', { user_id: userId });
                };
            } catch (error) {
                this.log('error', 'WebSocket connection failed', { error: error.message });
                reject(error);
            }
        });
    }

    handleWebSocketMessage(message) {
        this.log('debug', 'WebSocket message received', { type: message.type });

        const container = this.mode === 'broadcaster' ? 'broadcaster-messages' : 'viewer-messages';
        const messagesDiv = document.getElementById(container);

        if (message.type === 'chat') {
            const isOwn = message.user_id === this.userId;
            const msgDiv = document.createElement('div');
            msgDiv.className = `message ${isOwn ? 'own' : 'other'}`;
            msgDiv.innerHTML = `
                <strong>${message.user_id || 'Unknown'}:</strong> ${message.message}
                <div class="message-meta">${new Date(message.timestamp).toLocaleTimeString()}</div>
            `;
            messagesDiv.appendChild(msgDiv);
            messagesDiv.scrollTop = messagesDiv.scrollHeight;
        } else if (message.type === 'user_joined') {
            const msgDiv = document.createElement('div');
            msgDiv.className = 'message system';
            msgDiv.innerHTML = `<div>👤 ${message.user_id} joined the chat</div>`;
            messagesDiv.appendChild(msgDiv);

            if (this.mode === 'broadcaster') {
                this.viewers.set(message.user_id, { joined_at: new Date() });
                this.updateViewersList();
            }
        } else if (message.type === 'user_left') {
            const msgDiv = document.createElement('div');
            msgDiv.className = 'message system';
            msgDiv.innerHTML = `<div>👤 ${message.user_id} left the chat</div>`;
            messagesDiv.appendChild(msgDiv);

            if (this.mode === 'broadcaster') {
                this.viewers.delete(message.user_id);
                this.updateViewersList();
            }
        }
    }

    sendChatMessage(message) {
        if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
            this.log('warn', 'WebSocket not connected, cannot send message', {});
            return;
        }

        const payload = {
            type: 'chat',
            channel: this.streamId,
            message: message,
            timestamp: Date.now()
        };

        try {
            this.ws.send(JSON.stringify(payload));
            this.log('debug', 'Chat message sent', { channel: this.streamId, size: message.length });
        } catch (error) {
            this.log('error', 'Failed to send chat message', { error: error.message });
        }
    }

    // Broadcaster Methods
    async startBroadcast() {
        const streamId = document.getElementById('stream-id').value;
        const broadcasterId = document.getElementById('broadcaster-id').value;
        const apiToken = document.getElementById('api-token').value;

        this.streamId = streamId;
        this.userId = broadcasterId;
        this.apiToken = apiToken;

        this.log('info', 'Starting broadcast', { stream_id: streamId, broadcaster_id: broadcasterId });

        const response = await this.makeRequest('POST', '/v1/streaming/broadcasts', {
            stream_id: streamId,
            broadcaster_id: broadcasterId
        });

        if (response.ok) {
            this.broadcastStartTime = Date.now();
            document.getElementById('broadcast-status').textContent = 'Connected';
            document.getElementById('broadcast-status').className = 'status-badge status-connected';
            document.getElementById('broadcast-stream-id').textContent = streamId;
            document.getElementById('end-broadcast-btn').disabled = false;

            // Connect to chat
            try {
                await this.connectWebSocket(broadcasterId);
                this.startDurationTimer();
                this.log('info', 'Broadcaster connected and ready', { stream_id: streamId });
            } catch (error) {
                this.log('error', 'Failed to connect to chat', { error: error.message });
            }
        } else {
            this.log('error', 'Failed to start broadcast', { status: response.status, error: response.data });
        }
    }

    async endBroadcast() {
        if (!this.streamId) return;

        this.log('info', 'Ending broadcast', { stream_id: this.streamId });

        const response = await this.makeRequest('DELETE', `/v1/streaming/broadcasts/${this.streamId}`);

        if (response.ok) {
            document.getElementById('broadcast-status').textContent = 'Disconnected';
            document.getElementById('broadcast-status').className = 'status-badge status-disconnected';
            document.getElementById('broadcast-stream-id').textContent = '-';
            document.getElementById('broadcast-viewers').textContent = '0';
            document.getElementById('broadcast-duration').textContent = '00:00:00';
            document.getElementById('end-broadcast-btn').disabled = true;

            if (this.ws) {
                this.ws.close();
                this.ws = null;
            }

            this.viewers.clear();
            this.updateViewersList();
            this.broadcastStartTime = null;

            this.log('info', 'Broadcast ended', { stream_id: this.streamId });
        } else {
            this.log('error', 'Failed to end broadcast', { status: response.status });
        }
    }

    startDurationTimer() {
        setInterval(() => {
            if (this.broadcastStartTime && this.mode === 'broadcaster') {
                const elapsed = Date.now() - this.broadcastStartTime;
                const seconds = Math.floor(elapsed / 1000);
                const hours = Math.floor(seconds / 3600);
                const minutes = Math.floor((seconds % 3600) / 60);
                const secs = seconds % 60;

                document.getElementById('broadcast-duration').textContent =
                    `${String(hours).padStart(2, '0')}:${String(minutes).padStart(2, '0')}:${String(secs).padStart(2, '0')}`;

                document.getElementById('broadcast-viewers').textContent = this.viewers.size;
            }
        }, 1000);
    }

    updateViewersList() {
        const list = document.getElementById('viewers-list');

        if (this.viewers.size === 0) {
            list.innerHTML = `
                <div class="empty-state">
                    <div class="empty-state-icon">👥</div>
                    <div>No viewers yet</div>
                </div>
            `;
            return;
        }

        list.innerHTML = '';
        this.viewers.forEach((viewer, viewerId) => {
            const item = document.createElement('div');
            item.className = 'viewer-item';
            item.innerHTML = `
                <span class="viewer-name">${viewerId}</span>
                <span class="viewer-status">Connected</span>
            `;
            list.appendChild(item);
        });
    }

    // Viewer Methods
    async joinStream() {
        const streamId = document.getElementById('viewer-stream-id').value;
        const viewerId = document.getElementById('viewer-name').value;
        const apiToken = document.getElementById('viewer-api-token').value;
        const serverUrl = document.getElementById('viewer-server-url').value;

        this.streamId = streamId;
        this.userId = viewerId;
        this.apiToken = apiToken;
        this.serverUrl = serverUrl;

        this.log('info', 'Joining stream', { stream_id: streamId, viewer_id: viewerId });

        const response = await this.makeRequest('POST', '/v1/streaming/viewers', {
            stream_id: streamId,
            viewer_id: viewerId
        });

        if (response.ok) {
            document.getElementById('viewer-status').textContent = 'Connected';
            document.getElementById('viewer-status').className = 'status-badge status-connected';
            document.getElementById('viewer-stream-id-display').textContent = streamId;
            document.getElementById('leave-stream-btn').disabled = false;

            // Connect to chat
            try {
                await this.connectWebSocket(viewerId);
                this.log('info', 'Viewer connected to stream', { stream_id: streamId });
            } catch (error) {
                this.log('error', 'Failed to connect to chat', { error: error.message });
            }
        } else {
            this.log('error', 'Failed to join stream', { status: response.status, error: response.data });
        }
    }

    async leaveStream() {
        if (!this.streamId) return;

        this.log('info', 'Leaving stream', { stream_id: this.streamId });

        const response = await this.makeRequest('DELETE', `/v1/streaming/viewers/${this.streamId}/${this.userId}`);

        if (response.ok) {
            document.getElementById('viewer-status').textContent = 'Disconnected';
            document.getElementById('viewer-status').className = 'status-badge status-disconnected';
            document.getElementById('viewer-stream-id-display').textContent = '-';
            document.getElementById('leave-stream-btn').disabled = true;

            if (this.ws) {
                this.ws.close();
                this.ws = null;
            }

            this.log('info', 'Left stream', { stream_id: this.streamId });
        } else {
            this.log('error', 'Failed to leave stream', { status: response.status });
        }
    }

    async getStreamInfo() {
        if (!this.streamId) {
            this.log('warn', 'No stream selected', {});
            return;
        }

        const response = await this.makeRequest('GET', `/v1/streaming/broadcasts/${this.streamId}`);

        if (response.ok) {
            const info = response.data.data || response.data;
            this.log('info', 'Stream info retrieved', info);
        } else {
            this.log('error', 'Failed to get stream info', { status: response.status });
        }
    }

    // Testing
    async testHealth() {
        this.log('info', 'Testing server health', { server: this.serverUrl });

        try {
            const response = await fetch(`${this.serverUrl}/health`);
            const data = await response.json();

            this.log('info', 'Health check passed', {
                status: data.status,
                uptime_seconds: data.uptime_seconds,
                services: data.services
            });
        } catch (error) {
            this.log('error', 'Health check failed', { error: error.message });
        }
    }
}

// Global client instance
let client = new BeaconCoreClient();

// UI Functions
function switchMode(mode) {
    client.mode = mode;
    document.getElementById('broadcaster-mode').classList.toggle('hidden', mode !== 'broadcaster');
    document.getElementById('viewer-mode').classList.toggle('hidden', mode !== 'viewer');

    document.querySelector('.mode-btn.broadcaster').classList.toggle('active', mode === 'broadcaster');
    document.querySelector('.mode-btn.viewer').classList.toggle('active', mode === 'viewer');

    client.log('info', 'Mode switched', { mode: mode });
}

function startBroadcast() {
    client.startBroadcast();
}

function endBroadcast() {
    client.endBroadcast();
}

function joinStream() {
    client.joinStream();
}

function leaveStream() {
    client.leaveStream();
}

function getStreamInfo() {
    client.getStreamInfo();
}

function sendBroadcasterMessage() {
    const input = document.getElementById('broadcaster-message-input');
    const message = input.value.trim();

    if (message) {
        client.sendChatMessage(message);
        input.value = '';
    }
}

function sendViewerMessage() {
    const input = document.getElementById('viewer-message-input');
    const message = input.value.trim();

    if (message) {
        client.sendChatMessage(message);
        input.value = '';
    }
}

function handleBroadcasterMessageKeypress(event) {
    if (event.key === 'Enter') {
        sendBroadcasterMessage();
    }
}

function handleViewerMessageKeypress(event) {
    if (event.key === 'Enter') {
        sendViewerMessage();
    }
}

function testHealth() {
    client.testHealth();
}

// Initialize
document.addEventListener('DOMContentLoaded', () => {
    client.log('info', 'BeaconCore Client initialized', {
        version: '1.0.0',
        server: 'http://127.0.0.1:8080'
    });
});
