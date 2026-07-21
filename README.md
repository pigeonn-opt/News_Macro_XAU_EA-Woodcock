# News_Macro_XAU_EA-Woodcock
 — Local CSV Version

> Educational/research software. Trading can lose money. Test with realistic spread, commission, slippage, contract size, and broker rules before any demo or live use.


### Overview

This project trades XAUUSD from local daily macro/news data. It does **not** use a web API at runtime. Python reads `XAUUSD_Macro_News_Clean.csv`, creates a local signal file, and the MT5 EA reads both files from `MQL5/Files`.

```text
XAUUSD_Macro_News_Clean.csv
          ↓
backend/main.py (local scoring)
          ↓
MQL5/Files/GoldMacroSignal.csv
          ↓
GoldMacroAutoEA.mq5 (date selection, risk checks, order execution)
```

### What changed from the original version

- The former Jin10/FastAPI/HTTP/WebRequest bridge is disabled and documented as comments in `backend/main.py` and `mt5/GoldMacroAutoEA.mq5`.
- `main.py` no longer starts a FastAPI server, pulls remote news, receives MT5 posts, or stores API data in SQLite.
- `main.py` now reads the local input CSV, scores each daily row, and exports `GoldMacroSignal.csv`.
- The EA uses `FileOpen()` instead of WebRequest. It selects the CSV row matching the Strategy Tester date; on a non-trading day it uses the latest earlier row.
- The EA checks every `RefreshSeconds` seconds. A valid daily signal is attempted once per date/direction, not repeatedly every minute.
- The EA has no neural-network implementation or model weights. The original backend was a rule-based macro scorer; the CSV schema is suitable for future ML, but no LSTM/GRU/Transformer was included.

### Input CSV

The required file is `data/XAUUSD_Macro_News_Clean.csv`. It contains 111 date-aligned daily columns. Important groups are:

| Group | Examples | Current use |
|---|---|---|
| Gold market | `gold_open`, `gold_high`, `gold_low`, `gold_close`, `gold_volume` | `gold_close` is exported for review. |
| Cross-market | `DXY`, `US2Y`, `US10Y`, `RealYield10Y`, `WTI`, `VIX` | DXY and US10Y changes adjust the score; the others are retained for future models. |
| Macro releases | `CPI`, `CoreCPI`, `NFP`, `Unemployment`, `Wage` | Retained as daily model features. |
| News/event counts | geopolitical, inflation, Fed, yield, USD, conflict keyword counts | Already aggregated in the source CSV and retained for future models. |
| Aggregated signals | `GeoRisk_Score`, `Fed_Hawkish_Score`, `News_Count`, `LONG_GOLD_Candidate`, `SHORT_GOLD_Candidate` | Used by the current score. |
| Engineered fields | returns, moving averages, volatility, DXY/yield/oil/VIX changes, `News_Bias` | `DXY_change` and `US10Y_change` adjust the current score; all remain available for ML. |

Blank numeric cells are treated as missing in Python, not silently fabricated. The EA reads the documented 111-column layout. Keep the header names, order, comma delimiter, and `YYYY-MM-DD` date format unchanged.

### Current scoring

This is a transparent baseline, not a neural network:

- `LONG_GOLD_Candidate`: +35
- `SHORT_GOLD_Candidate`: -35
- `GeoRisk_Score >= 50`: up to +30
- `Fed_Hawkish_Score >= 50`: up to -30
- `DXY_change` and `US10Y_change`: bounded negative adjustments when they rise

Score `>= 25` becomes `LONG_RESEARCH`; score `<= -25` becomes `SHORT_RESEARCH`; otherwise it is `NEUTRAL`.

### Create `GoldMacroSignal.csv`

From the project root:

```powershell
python .\backend\main.py --summary
python .\backend\main.py --export-mt5-signals
```

When this repository is installed below `MQL5\Experts\W2`, the second command writes to `MQL5\Files\GoldMacroSignal.csv`. For another layout, give the output path explicitly:

```powershell
python .\backend\main.py --export-mt5-signals "C:\Path\To\Terminal\MQL5\Files\GoldMacroSignal.csv"
```

The output has one row per date:

```text
date,action,score,gold_close,geo_risk,fed_hawkish,news_count,reason
2025-01-02,SHORT_RESEARCH,-60.00,...
```

Its purpose is to replace the old HTTP `/mt5/next` signal response with a local, auditable file. Regenerate it whenever the source data or scoring code changes.

### MT5 deployment

1. In MT5, choose **File → Open Data Folder**.
2. Copy `XAUUSD_Macro_News_Clean.csv` to `MQL5\Files\`.
3. Run the export command above so `GoldMacroSignal.csv` is in the same `MQL5\Files\` folder.
4. Copy/compile `mt5/GoldMacroAutoEA.mq5` under `MQL5\Experts\` with MetaEditor.
5. Attach it to the broker's XAUUSD chart and enable Algo Trading.
6. Use these initial inputs:

```text
CsvFileName             = XAUUSD_Macro_News_Clean.csv
PythonSignalFileName    = GoldMacroSignal.csv
UsePythonSignalFile     = true
SelectRowByChartDate    = true
RefreshSeconds          = 60
EnableExecutionInTester = true
EnableExecutionLive     = false
FixedLots               = 0.01
MaxOrdersPerDay         = 5
MinSignalScore          = 25
```

7. Run a Strategy Tester test first. The EA checks every minute by default, but a daily CSV signal is only attempted once per date and direction.

### Demo and live deployment

Keep `EnableExecutionLive=false` during testing. Before enabling it for a demo account, verify the broker symbol, minimum/maximum/step volume, `PipSize`, stops level, fill policy, spread, and the order journal. Only then set `EnableExecutionLive=true` for demo. Use the same checks again before live trading and start with the smallest possible lot.

If the journal shows `Unsupported filling mode`, use the current EA source: it detects the broker-supported FOK, IOC, or RETURN mode. If an order still fails, share the full `OrderCheck failed` or `Order rejected` line and verify broker stop-distance and volume rules.

### Future neural-network integration

The clean integration point is `evaluate_record()` in `backend/main.py`. A trained model can replace the baseline scoring there and keep the same exported columns (`date`, `action`, `score`, etc.). Preserve the feature list, scaling parameters, lookback window, train/validation date split, model architecture, and model weights together. Do not use future rows when calculating features or labels.


