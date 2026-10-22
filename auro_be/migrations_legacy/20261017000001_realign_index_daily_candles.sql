-- Daily bars for index CFDs are now requested aligned to the 16:00 New York
-- cash close (see brokers::oanda::client::candle_query); the stored rows were
-- OANDA's default 17:00 bars and would interleave with the new ones. Drop
-- them: the live candle feed refills one buffer's worth on its next cycle and
-- POST /api/candles/backfill?instrument=..&granularity=D&days=3100 restores
-- the deep history the pipeline uses. Forex, metals and bonds keep 17:00.
DELETE FROM candles
WHERE granularity = 'D'
  AND instrument IN (
    'SPX500_USD', 'NAS100_USD', 'US30_USD', 'US2000_USD',
    'UK100_GBP', 'DE30_EUR', 'EU50_EUR', 'FR40_EUR', 'NL25_EUR', 'CH20_CHF',
    'JP225_USD', 'AU200_AUD', 'HK33_HKD', 'CN50_USD'
  );
