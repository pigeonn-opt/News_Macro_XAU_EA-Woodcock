# Deployment Checklist

## Backend

- [ ] Python 3.11+ installed.
- [ ] `.env` created from `.env.template`.
- [ ] `BACKEND_API_KEY` changed.
- [ ] `ENABLE_AUTO_EXECUTION=false` during first run.
- [ ] `LIVE_STAGE=shadow` during first run.
- [ ] `/health` returns ok.
- [ ] Manual event test works.
- [ ] Jin10 authorized URL and field mapping filled only from contract/API docs.

## MT5

- [ ] `GoldMacroAutoEA.mq5` copied to `MQL5/Experts`.
- [ ] MetaEditor compile passes.
- [ ] WebRequest URL added in MT5 options.
- [ ] `TradeSymbol` matches broker symbol.
- [ ] `PipSize` validated on broker.
- [ ] `EnableExecution=false` for dry run.
- [ ] EA successfully uploads market snapshot.
- [ ] EA successfully uploads MT5 calendar or logs unavailability.
- [ ] EA pulls NO_TRADE safely.

## Demo

- [ ] `ENABLE_AUTO_EXECUTION=true`.
- [ ] `LIVE_STAGE=demo`.
- [ ] `MAX_DEMO_LOTS=0.10` or smaller.
- [ ] `EnableExecution=true` on demo only.
- [ ] First order retcode checked.
- [ ] ACK stored.

## Micro live

- [ ] Demo has passed.
- [ ] Broker min lot / step / stop level checked.
- [ ] Daily max loss configured externally or in broker risk controls.
- [ ] `LIVE_STAGE=micro`.
- [ ] `MAX_MICRO_LIVE_LOTS<=1`.
- [ ] 24-48h shadow comparison reviewed.

