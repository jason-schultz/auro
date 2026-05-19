import { onBeforeUnmount, onMounted, ref } from "vue";

export interface SignalFeedEvent {
    strategy_id: string;
    strategy_type: string;
    instrument: string;
    granularity: string;
    action: string;
    price: number;
    reason: string;
    oanda_trade_id: string | null;
    timestamp: string;
    received_at: string;
}

type ConnectionState = "connecting" | "connected" | "disconnected";

const TOPIC = "signals:feed";
const MAX_EVENTS = 40;
const MAX_SEEN_EVENT_KEYS = 200;

function signalEventKey(item: Omit<SignalFeedEvent, "received_at">): string {
    if (item.oanda_trade_id) {
        return [item.oanda_trade_id, item.action, item.instrument, item.granularity].join("|");
    }
    return [
        item.strategy_id,
        item.action,
        item.instrument,
        item.granularity,
        item.timestamp,
        item.reason,
    ].join("|");
}

function socketUrl(): string {
    const protocol = window.location.protocol === "https:" ? "wss" : "ws";
    return `${protocol}://${window.location.host}/opus/socket/websocket?vsn=2.0.0`;
}

export function useSignalFeed() {
    const events = ref<SignalFeedEvent[]>([]);
    const state = ref<ConnectionState>("disconnected");
    const error = ref<string | null>(null);
    const seenEventKeys = new Set<string>();
    const seenEventOrder: string[] = [];

    let ws: WebSocket | null = null;
    let heartbeat: ReturnType<typeof setInterval> | null = null;
    let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
    let refCounter = 1;

    function nextRef(): string {
        const value = refCounter;
        refCounter += 1;
        return String(value);
    }

    function sendFrame(topic: string, event: string, payload: object, joinRef: string | null = null) {
        if (!ws || ws.readyState !== WebSocket.OPEN) return;
        ws.send(JSON.stringify([joinRef, nextRef(), topic, event, payload]));
    }

    function rememberEventKey(key: string) {
        seenEventKeys.add(key);
        seenEventOrder.push(key);
        if(seenEventOrder.length > MAX_SEEN_EVENT_KEYS) {
            const oldest = seenEventOrder.shift();
            if (oldest) {
                seenEventKeys.delete(oldest);
            }
        }
    }

    function connect() {
        if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) {
            return;
        }

        state.value = "connecting";
        error.value = null;

        ws = new WebSocket(socketUrl());

        ws.onopen = () => {
            state.value = "connected";
            const joinRef = nextRef();
            sendFrame(TOPIC, "phx_join", {}, joinRef);

            heartbeat = setInterval(() => {
                sendFrame("phoenix", "heartbeat", {});
            }, 30_000);
        };

        ws.onmessage = (messageEvent) => {
            try {
                const message = JSON.parse(messageEvent.data) as [string | null, string | null, string, string, unknown];
                const topic = message[2];
                const event = message[3];
                const payload = message[4];

                if (topic === TOPIC && event === "signal_event" && payload && typeof payload === "object") {
                    const item = payload as Omit<SignalFeedEvent, "received_at">;
                    const key = signalEventKey(item);
                    if (!seenEventKeys.has(key)) {
                        rememberEventKey(key);
                        events.value = [
                            {
                                ...item,
                                received_at: new Date().toISOString(),
                            },
                            ...events.value,
                        ].slice(0, MAX_EVENTS);
                    }
                }
            } catch {
                // Ignore malformed socket frames.
            }
        };

        ws.onclose = () => {
            state.value = "disconnected";
            if (heartbeat) {
                clearInterval(heartbeat);
                heartbeat = null;
            }

            reconnectTimer = setTimeout(() => {
                connect();
            }, 3_000);
        };

        ws.onerror = () => {
            error.value = "Signal feed socket error";
        };
    }

    function disconnect() {
        if (reconnectTimer) {
            clearTimeout(reconnectTimer);
            reconnectTimer = null;
        }
        if (heartbeat) {
            clearInterval(heartbeat);
            heartbeat = null;
        }
        if (ws) {
            ws.close();
            ws = null;
        }
        state.value = "disconnected";
    }

    function clear() {
        events.value = [];
    }

    onMounted(connect);
    onBeforeUnmount(disconnect);

    return {
        events,
        state,
        error,
        clear,
    };
}
