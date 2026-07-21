# 18 Deep Iterations

This file maps the requested eighteen production iterations to code-level changes in this package.

## 1. Client approval removed

The previous `AWAITING_APPROVAL` gate is removed. Backend now uses an internal `AutoExecutionGate` and only emits `AUTO_ALLOWED` or `AUTO_BLOCKED`.

## 2. Auto execution stage gate

`.env` controls `ENABLE_AUTO_EXECUTION` and `LIVE_STAGE`. Shadow produces no executable lots. Demo caps lots at `MAX_DEMO_LOTS`. Micro caps lots at `MAX_MICRO_LIVE_LOTS`. Live caps lots at `MAX_LIVE_LOTS`.

## 3. Jin10 authorized API adapter

`Jin10Client` reads URL, headers and field mappings from `.env`. No fake endpoint is hard-coded.

## 4. MT5 calendar adapter

`GoldMacroAutoEA.mq5` uploads USD economic calendar values via `CalendarValueHistory` to `/api/v1/mt5/calendar`.

## 5. News source reliability

The current MVP stores source and importance. It gives official/important news a bonus inside `MacroEngine`. Full T1/T2/T3 source scoring can be added in the same class.

## 6. Deduplication and cooldown

`event_hash`, event ids, SQLite uniqueness, and `recent_signal_exists()` prevent repeated trades on the same event cluster.

## 7. Event classification

`MacroEngine` separates `GEO_WAR_LONG_MODE`, `RATES_SPIKE_SHORT_MODE`, and `DOVISH_MACRO_LONG_MODE`.

## 8. Geopolitical severity

War/airstrike/Iran/Hormuz patterns create severity score. Denial/ceasefire/no-ground-troops reduce severity or add fade risk.

## 9. Rates spike short engine

USD, DXY, UST 2Y/10Y, real-yield, higher-for-longer, hot CPI/NFP patterns create gold short candidates.

## 10. Numeric macro surprise

If events contain actual/forecast values, CPI/PCE and NFP surprise logic can create long/short candidates.

## 11. Market confirmation

`MarketConfirmer` uses MT5-uploaded XAUUSD, DXY, oil, US02Y, US10Y snapshots to confirm or penalize signals.

## 12. Long-priority conflict rule

If any valid long candidate exists, all shorts are suppressed before signal generation. This is implemented in `generate_signal()`.

## 13. Small-position sizing

`SizingEngine` returns 1/3/5/8 lots for geopolitical long states and 1/3/5 lots for rates-short states, capped by live stage.

## 14. Daily five opportunity control

`DAILY_WINDOWS_UTC`, `MAX_AUTO_SIGNALS_PER_DAY`, and severe-event override control how opportunities are created.

## 15. Backend auto execution gate

`AutoExecutionGate` checks auto-execution enabled, stage, lots, confidence, macro score, daily cap, daily window, duplicate cooldown, and short confirmation.

## 16. EA local risk guard

EA checks execution switch, signal expiry, duplicate signal, daily count, spread, lots, symbol select, price availability, stop distance, and volume normalization.

## 17. OrderCheck then OrderSend

EA calls `OrderCheck` first, then `OrderSend`, then checks retcode and sends ACK.

## 18. Audit trail

SQLite stores events, market ticks, signals, and MT5 ACKs. Every order can be traced back to event ids and market confirmation.

## Extra: kill switch foundation

`ENABLE_AUTO_EXECUTION=false` acts as global kill switch. For production, add separate admin route to flip live stage and disable new entries.
