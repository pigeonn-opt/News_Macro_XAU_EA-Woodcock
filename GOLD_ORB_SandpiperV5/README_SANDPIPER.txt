GOLD_ORB Sandpiper
A. Overview
GOLD_ORB Sandpiper is an enhanced version of the original GOLD_ORB EA, adding time-based trading filters for more precise trade timing control.

B. Key Enhancements: Time Filters
Two new input parameters have been added to control when the EA can execute trades:
BlockedWeekDays = "3" - Blocks trading on specific days of the week (1=Monday, 7=Sunday). Multiple days can be specified with commas, e.g., "3,5" blocks Wednesday and Friday.
BlockedHours = "5,11" - Blocks trading during specific hours (server time, 0-23). Multiple hours can be specified with commas, e.g., "5,11" blocks trading at 5:00 AM and 11:00 AM.

C. Why These Filters?
These filters are particularly useful for:
Avoiding low-liquidity periods
Skipping high-impact news releases
Aligning with your preferred trading sessions
Reducing noise during non-optimal market hours

D. Installation
Download the EA files
Place in your MetaTrader 5 Experts folder
Compile the EA (F7)
Attach to a chart and configure parameters

E. Credits
Based on the original GOLD_ORB EA by yulz008.


GOLD_ORB diagnostic patch
Changes made:
1. GOLD_ORB.mq5: OnInit returns INIT_SUCCEEDED instead of a string.
2. GOLD_ORB.mq5: fixed RiskManagementModule bug where execute_trade was set to false every tick when MaxEquityDrawdownPercent != 0.
3. GOLD_ORB.mq5: uses ACCOUNT_EQUITY for equity drawdown high-water mark.
4. GOLD_ORB.mq5: added DebugPrint input and new-candle/signal logs.
5. Include/Trade.mqh: uses symbol-specific point/digits and broker filling mode instead of hardcoded ORDER_FILLING_IOC.

How to test:
- Put this folder under MQL5/Experts/GOLD_ORB_diagnostic.
- Compile GOLD_ORB.mq5 in MetaEditor.
- In Strategy Tester use H1, XAUUSD/GOLD, 6+ months of data.
- For smoke test: MaxEquityDrawdownPercent=0, MaxRiskPerTradePercent=0, FixedVolume=0.01, EnableTrail=false, PriceActionORB_CandleComposition=1.
- Then check Journal for [GOLD_ORB DEBUG].

Note: This patch was created by static source inspection. Compile and validate in your MT5 terminal before relying on it.
