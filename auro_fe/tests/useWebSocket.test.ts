import { beforeEach, describe, expect, it } from "bun:test";
import { createPinia, setActivePinia } from "pinia";
import { useWebSocket } from "../src/composables/useWebSocket";
import { useMarketStore } from "../src/stores/market";

type Handler = ((...args: any[]) => void) | null;

class FakeWebSocket {
    static OPEN = 1;
    static instances: FakeWebSocket[] = [];

    readyState = 0;
    onopen: Handler = null;
    onmessage: Handler = null;
    onclose: Handler = null;
    onerror: Handler = null;

    constructor(public url: string) {
        FakeWebSocket.instances.push(this);
    }

    close() {
        this.readyState = 3;
        this.onclose?.();
    }
}

describe("useWebSocket", () => {
    beforeEach(() => {
        FakeWebSocket.instances = [];
        setActivePinia(createPinia());
        (globalThis as any).WebSocket = FakeWebSocket;
    });

    it("connects and updates market store on price events", () => {
        const marketStore = useMarketStore();
        const ws = useWebSocket("ws://prices");

        ws.connect();
        const socket = FakeWebSocket.instances[0];
        expect(socket).toBeDefined();

        socket!.readyState = FakeWebSocket.OPEN;
        socket!.onopen?.();

        expect(ws.connected.value).toBe(true);
        expect(marketStore.connected).toBe(true);

        socket!.onmessage?.({
            data: JSON.stringify({
                type: "price",
                instrument: "EUR_USD",
                bid: "1.10000",
                ask: "1.10020",
                time: "2026-05-11T10:00:00Z",
                tradeable: true,
            }),
        });

        expect(marketStore.prices.EUR_USD?.bid).toBe("1.10000");
        expect(marketStore.prices.EUR_USD?.ask).toBe("1.10020");
    });

    it("ignores malformed payloads without throwing", () => {
        const ws = useWebSocket("ws://prices");
        ws.connect();

        const socket = FakeWebSocket.instances[0];
        expect(() => socket!.onmessage?.({ data: "not-json" })).not.toThrow();
    });
});
