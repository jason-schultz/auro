import { ref, onUnmounted } from "vue";
import { useMarketStore } from "@/stores/market";

export function useWebSocket(url: string) {
  const connected = ref(false);
  const marketStore = useMarketStore();
  let ws: WebSocket | null = null;
  let reconnectTimeout: ReturnType<typeof setTimeout> | null = null;

  function connect() {
    if (ws?.readyState === WebSocket.OPEN) return;

    ws = new WebSocket(url);

    ws.onopen = () => {
      connected.value = true;
      marketStore.setConnected(true);
      console.log("[WS] Connected to price stream");
    };

    ws.onmessage = (event) => {
      try {
        const data = JSON.parse(event.data);

        if (data.type === "price") {
          marketStore.updatePrice(data.instrument, {
            bid: data.bid,
            ask: data.ask,
            time: data.time,
            tradeable: data.tradeable,
          });
        }
      } catch (e) {
        console.warn("[WS] Failed to parse message:", e);
      }
    };

    ws.onclose = () => {
      connected.value = false;
      marketStore.setConnected(false);
      console.log("[WS] Disconnected. Reconnecting in 3s...");
      scheduleReconnect();
    };

    ws.onerror = (err) => {
      console.error("[WS] Error:", err);
      ws?.close();
    };
  }

  function scheduleReconnect() {
    if (reconnectTimeout) clearTimeout(reconnectTimeout);
    reconnectTimeout = setTimeout(() => {
      connect();
    }, 3000);
  }

  function disconnect() {
    if (reconnectTimeout) clearTimeout(reconnectTimeout);
    reconnectTimeout = null;
    ws?.close();
    ws = null;
  }

  onUnmounted(() => {
    disconnect();
  });

  return { connected, connect, disconnect };
}
