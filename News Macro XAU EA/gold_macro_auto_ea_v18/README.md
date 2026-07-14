# Gold Macro Auto EA v18

This package upgrades the previous Jin10/MT5 macro-news EA concept into an automatic, small-position execution bridge.

It is designed for controlled demo / micro-live deployment, not for unsupervised large-position production trading.

## What it does

- Pulls Jin10 authorized API data if configured.
- Receives MT5 Economic Calendar events from the EA.
- Receives MT5 market snapshots for XAUUSD, DXY, US02Y, US10Y, WTI, VIX or broker-equivalent symbols.
- Scores macro/fundamental events with an auditable rule engine that can later be replaced by an LLM.
- Treats war/geopolitical escalation as a small-position gold long candidate.
- Treats USD + short/long yield spikes as a small-position gold short candidate.
- Applies long-priority conflict handling: if any valid long candidate exists, all shorts are suppressed.
- Removes client approval and replaces it with an automatic execution gate.
- EA pulls only `AUTO_ALLOWED` signals, performs local risk checks, calls `OrderCheck`, then `OrderSend`, and sends ACK back.

## What it does not do

- It does not guarantee correct geopolitical judgment.
- It does not guarantee profit.
- It does not force five real trades per day.
- It does not hard-code unknown Jin10 endpoints.
- It does not bypass broker restrictions.

## Run backend

```bash
cd backend
cp .env.template .env
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8000
```

Windows:

```bat
cd backend
copy .env.template .env
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8000
```

Health check:

```bash
curl http://127.0.0.1:8000/health
```

## Safe stages

`.env` defaults to shadow mode:

```env
ENABLE_AUTO_EXECUTION=false
LIVE_STAGE=shadow
```

For demo testing:

```env
ENABLE_AUTO_EXECUTION=true
LIVE_STAGE=demo
MAX_DEMO_LOTS=0.10
```

For micro-live only after demo has passed:

```env
ENABLE_AUTO_EXECUTION=true
LIVE_STAGE=micro
MAX_MICRO_LIVE_LOTS=1
```

For controlled live:

```env
ENABLE_AUTO_EXECUTION=true
LIVE_STAGE=live
MAX_LIVE_LOTS=5
```

## Inject a manual geopolitical test event

```bash
curl -X POST http://127.0.0.1:8000/api/v1/events/manual \
  -H "Content-Type: application/json" \
  -H "X-API-Key: change-me" \
  -d '{
    "event_id":"manual_geo_001",
    "source":"MANUAL",
    "timestamp_utc":1760000000,
    "title":"Trump orders airstrike against Iran targets",
    "content":"US military action escalates Middle East risk. No ground troops involved.",
    "category":"geopolitical",
    "importance":"high",
    "currency":"USD"
  }'
```

Evaluate:

```bash
curl -X POST "http://127.0.0.1:8000/api/v1/macro/evaluate?lookback_hours=24" \
  -H "X-API-Key: change-me"
```

## Inject a rates spike test event

```bash
curl -X POST http://127.0.0.1:8000/api/v1/events/manual \
  -H "Content-Type: application/json" \
  -H "X-API-Key: change-me" \
  -d '{
    "event_id":"manual_rates_001",
    "source":"MANUAL",
    "timestamp_utc":1760000000,
    "title":"US 2-year and 10-year yields surge, DXY jumps on hawkish repricing",
    "content":"Higher-for-longer repricing pressures gold.",
    "category":"rates",
    "importance":"high",
    "currency":"USD"
  }'
```

## MT5 deployment

1. Copy `mt5/GoldMacroAutoEA.mq5` into `MQL5/Experts/`.
2. Compile with MetaEditor.
3. In MT5: Tools -> Options -> Expert Advisors -> Allow WebRequest for listed URL.
4. Add `http://127.0.0.1:8000`.
5. Attach EA to XAUUSD chart.
6. Keep `EnableExecution=false` until backend and demo tests pass.

## Important broker parameters

Before live trading verify:

- `TradeSymbol`: broker actual symbol, e.g. XAUUSD, GOLD, XAUUSDm.
- `PipSize`: broker-dependent. For XAUUSD this may be 0.10 or 0.01.
- `MaxSpreadPoints`.
- `MaxLots`.
- broker volume min/max/step.
- broker stop level and fill policy.

