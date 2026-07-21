# XAUUSD AI Dataset Schema

Daily multi-factor dataset for XAUUSD AI models.

Integrates:

- Market data
- Macro indicators
- Geopolitical news signals

Designed for:

- LSTM
- GRU
- Transformer
- Temporal CNN
- RL Trading Agents

## Dataset Structure

```text
XAUUSD_AI_Dataset

├── Market Layer
│   ├── XAUUSD
│   ├── DXY
│   ├── US2Y
│   ├── US10Y
│   ├── RealYield10Y
│   ├── WTI
│   └── VIX
│
├── Macro Layer
│   ├── CPI
│   ├── Core CPI
│   ├── NFP
│   ├── Unemployment
│   └── Wage
│
└── News Layer
    ├── GDELT Signals
    ├── Finnhub Signals
    ├── GeoRisk Score
    ├── Fed Hawkish Score
    ├── LONG_GOLD Candidate
    └── SHORT_GOLD Candidate
```

## Data Frequency

All data is converted into:

Daily Time Series
YYYY-MM-DD

All features are aligned by date.

## Data Sources

### Market Data

#### XAUUSD

Source:

MetaTrader Historical Data

Fields:

- Open
- High
- Low
- Close
- Tick Volume
- Volume
- Spread

#### DXY

Source:

Yahoo Finance
https://finance.yahoo.com/

Fields:

- Open
- High
- Low
- Close
- Adjusted Close
- Volume

#### Treasury Yield

Source:

FRED
https://fred.stlouisfed.org/

| Feature | FRED Series |
|---------|-------------|
| US2Y | DGS2 |
| US10Y | DGS10 |
| RealYield10Y | DFII10 |

#### WTI

Source:

FRED

Series:

DCOILWTICO

#### VIX

Source:

FRED

Series:

VIXCLS

### Macro Layer

Source:

FRED
https://fred.stlouisfed.org/

| Feature | Series |
|---------|--------|
| CPI | CPIAUCSL |
| Core CPI | CPILFESL |
| NFP | PAYEMS |
| Unemployment | UNRATE |
| Wage | CES0500000003 |

Rules:

- Only official released values are used.
- No fabricated data.
- No generated consensus.
- No forecast filling.

### News Layer

#### Sources

##### GDELT
https://www.gdeltproject.org/

Provides:

- Global news index
- Event extraction
- Keyword frequency
- Risk signals

##### Finnhub
https://finnhub.io/

Provides:

- Financial news
- Market headlines
- Event signals

#### News Signal Rules

##### LONG_GOLD Candidate

Triggered keywords:

- Iran
- Trump
- airstrike
- bombing
- missile
- war
- Hormuz
- sanctions

Meaning:

Higher geopolitical risk
→ Safe haven demand
→ Potential gold strength

Output:

LONG_GOLD_Candidate = 1

##### SHORT_GOLD Candidate

Triggered keywords:

- higher-for-longer
- hawkish
- hot inflation
- strong payrolls
- yields surge
- dollar jumps

Meaning:

Higher rates
+
Stronger USD
→ Gold pressure

Output:

SHORT_GOLD_Candidate = 1

## Data Cleaning Pipeline

### Date Normalization

Convert all timestamps:

YYYY-MM-DD

Supported:

- Yahoo Finance Date
- FRED observation_date
- MetaTrader Date

### Dataset Merge

Merge key:

date

Daily market data:

- XAUUSD
- DXY
- US2Y
- US10Y
- RealYield10Y
- WTI
- VIX

Macro data:

Monthly release data

Processing:

Forward fill after official release only

No future leakage.

Example:

January CPI cannot be used before CPI release date.

### News Processing

Daily aggregation:

- Keyword counts
- Risk scores
- Sentiment scores

### Missing Value Handling

#### Market Data

Missing caused by:

- Trading holidays
- Market closure
- FRED gaps

Method:

Forward Fill

#### Macro Data

Rules:

- No interpolation
- No prediction
- No fabricated values
- Only official releases

## Feature Engineering

### Gold Return

1 Day:

XAUUSD_return_1d =
Close(t) / Close(t-1) - 1

5 Day:

XAUUSD_return_5d

### Dollar Momentum

DXY_change

Measures:

USD strength change

### Yield Spread

Yield_Spread =
US10Y - US2Y

Captures:

- Fed expectation
- Recession risk
- Treasury pressure

### Gold Volatility

Gold_volatility_20

Calculated from:

Rolling 20-day gold returns

### News Momentum

GeoRisk_change

Measures:

Geopolitical risk acceleration

### Outlier Processing

Method:

Percentile Clipping

1% - 99%

Purpose:

- Reduce extreme noise
- Improve neural network stability

### Feature Scaling

Continuous features:

StandardScaler

Formula:

(value - mean) / std

Binary events:

0 / 1

Examples:

- LONG_GOLD_Candidate
- SHORT_GOLD_Candidate

## Final Dataset

Output:

gold_ai_dataset.csv

Columns:

- date
- gold_open
- gold_high
- gold_low
- gold_close
- gold_volume
- DXY
- US2Y
- US10Y
- RealYield10Y
- WTI
- VIX
- CPI
- CoreCPI
- NFP
- Unemployment
- Wage
- rate_hike_count
- explosion_count
- job_growth_count
- strait_of_hormuz_count
- airstrike_count
- embargo_count
- dollar_count
- air_strike_count
- price_index_count
- dollar_index_count
- usd_count
- jobs_report_count
- sanctions_count
- inflation_count
- missile_count
- consumer_price_count
- sanction_count
- yield_curve_count
- interest_rate_count
- powell_count
- launch_count
- hormuz_count
- donald_trump_count
- dxy_count
- inflation_data_count
- trump_count
- treasury_yields_count
- fighting_count
- fed_rate_count
- federal_reserve_count
- yields_count
- gulf_count
- rate_cut_count
- fed_count
- payrolls_count
- 10_year_count
- conflict_count
- ballistic_count
- iranian_count
- trade_ban_count
- unemployment_count
- war_count
- khamenei_count
- bomb_count
- car_bomb_count
- military_count
- iran_count
- hawkish_count
- cpi_count
- nonfarm_count
- nfp_count
- greenback_count
- bombing_count
- rate_decision_count
- strike_count
- rocket_count
- dovish_count
- bond_yields_count
- battle_count
- tehran_count
- gdelt_news_count
- finnhub_news_count
- iran_group_count
- trump_group_count
- airstrike_group_count
- bombing_group_count
- missile_group_count
- war_group_count
- hormuz_group_count
- sanctions_group_count
- rate_hike_group_count
- hawkish_group_count
- inflation_group_count
- jobs_group_count
- yields_group_count
- dollar_group_count
- GeoRisk_Score
- Fed_Hawkish_Score
- News_Count
- LONG_GOLD_Candidate
- SHORT_GOLD_Candidate
- gold_return_1d
- gold_return_5d
- gold_volatility_10
- gold_ma20
- gold_ma50
- DXY_change
- US10Y_change
- US2Y_change
- YieldCurve
- RealYield_change
- WTI_change
- VIX_change
- News_Bias

## AI Model Input

Sequence format:

(samples, time_steps, features)

Example:

(10000, 30, 35)

Meaning:

30 trading days
×
35 market factors
→
Predict future XAUUSD movement

## Supported Models

Compatible:

- LSTM
- GRU
- Transformer
- Temporal CNN
- Reinforcement Learning Agents
```