import { defineStore } from "pinia";
import { ref, computed } from "vue";

export interface PriceTick {
  bid: string;
  ask: string;
  time: string;
  tradeable: boolean;
  prevBid?: string;
  prevAsk?: string;
}

export const useMarketStore = defineStore("market", () => {
  const selectedInstrument = ref("EUR_USD");
  const prices = ref<Record<string, PriceTick>>({});
  const connected = ref(false);

  function selectInstrument(instrument: string) {
    selectedInstrument.value = instrument;
  }
  function updatePrice(
    instrument: string,
    tick: Omit<PriceTick, "prevBid" | "prevAsk">,
  ) {
    const existing = prices.value[instrument];
    prices.value[instrument] = {
      ...tick,
      prevBid: existing?.bid,
      prevAsk: existing?.ask,
    };
  }

  function setConnected(state: boolean) {
    connected.value = state;
  }

  const instrumentList = computed(() => {
    return Object.entries(prices.value)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([instrument, tick]) => {
        const bid = parseFloat(tick.bid);
        const ask = parseFloat(tick.ask);
        const spread = ask - bid;

        return {
          instrument,
          bid: tick.bid,
          ask: tick.ask,
          spread: spread.toFixed(instrument.includes("JPY") ? 3 : 5),
          tradeable: tick.tradeable,
          time: tick.time,
          bidDirection: tick.prevBid
            ? Math.abs(bid - parseFloat(tick.prevBid)) > 0.00001
              ? bid > parseFloat(tick.prevBid)
                ? "up"
                : "down"
              : "flat"
            : "flat",
          askDirection: tick.prevAsk
            ? Math.abs(ask - parseFloat(tick.prevAsk)) > 0.00001
              ? ask > parseFloat(tick.prevAsk)
                ? "up"
                : "down"
              : "flat"
            : "flat",
        };
      });
  });

  return {
    prices,
    connected,
    updatePrice,
    setConnected,
    instrumentList,
    selectedInstrument,
    selectInstrument,
  };
});
