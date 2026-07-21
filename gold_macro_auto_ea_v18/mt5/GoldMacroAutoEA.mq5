//+------------------------------------------------------------------+
//| GoldMacroAutoEA.mq5 - offline CSV research mode                 |
//+------------------------------------------------------------------+
#property copyright "Gold Macro Auto EA"
#property version   "1.190"
#property strict
#property description "Reads local XAUUSD macro-news CSV data; no network API is used."

// The old backend/API inputs and network calls are intentionally disabled.
// input string BackendBaseUrl = "http://127.0.0.1:8000";
// input string ApiKey = "change-me";
// WebRequest(...);
// HttpGet(...); HttpPost(...); SyncMarketSnapshot(); SyncCalendarEvents();

input string CsvFileName        = "XAUUSD_Macro_News_Clean.csv";
input string PythonSignalFileName = "GoldMacroSignal.csv";
input bool   UseCommonFiles     = false;
input int    RefreshSeconds     = 60;
input bool   SelectRowByChartDate = true;
input bool   UsePythonSignalFile = true;
input bool   EnableExecutionInTester = true;
input bool   EnableExecutionLive = false;
input double FixedLots          = 0.01;
input int    MaxOrdersPerDay    = 5;
input int    DefaultSLPips      = 50;
input int    DefaultTPPips      = 200;
input double PipSize            = 0.10;
input ulong  MagicNumber        = 260318;
input int    DeviationPoints    = 50;
input double MinSignalScore     = 25.0;
input double GeoRiskLongLevel   = 50.0;
input double FedHawkishShortLevel = 50.0;

struct CsvMacroRow
{
   string date;
   double goldClose;
   double dxy;
   double us10y;
   double realYield10y;
   double vix;
   double geoRisk;
   double fedHawkish;
   double newsCount;
   int    longCandidate;
   int    shortCandidate;
   double goldReturn1d;
   double dxyChange;
   double us10yChange;
   double newsBias;
};

struct PythonSignalRow
{
   string date;
   string action;
   double score;
   string reason;
};

CsvMacroRow latestRow;
bool hasLatestRow = false;
string lastLoggedCsvDate = "";
string lastExecutedSignalId = "";
string lastAttemptedSignalId = "";
int executedToday = 0;
int executionDayKey = 0;

int OnInit()
{
   EventSetTimer(MathMax(1, RefreshSeconds));
   executionDayKey = DateKey(TimeCurrent());
   RefreshCsvSignal();
   Print("GoldMacroAutoEA v0.19 started. CSV is checked every ", RefreshSeconds,
         " seconds. Tester execution=", EnableExecutionInTester,
         " live/demo execution=", EnableExecutionLive);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

void OnTimer()
{
   RefreshCsvSignal();
}

void RefreshCsvSignal()
{
   CsvMacroRow row;
   if(!LoadCsvRow(CsvFileName, UseCommonFiles, SelectRowByChartDate, row))
   {
      Print("No CSV row is available for the chart date. Put XAUUSD_Macro_News_Clean.csv in MQL5\\Files (or Common\\Files if enabled).");
      return;
   }
   latestRow = row;
   hasLatestRow = true;

   double score = ScoreRow(row);
   string state = ResearchState(score);
   string signalSource = "EA local fallback";
   PythonSignalRow pythonSignal;
   if(UsePythonSignalFile && LoadPythonSignal(PythonSignalFileName, UseCommonFiles, row.date, pythonSignal))
   {
      score = pythonSignal.score;
      state = pythonSignal.action;
      signalSource = "Python local CSV";
   }
   TryExecuteResearchSignal(row.date, state, score);
   Comment("Offline CSV research mode\n",
           "date: ", row.date, " | gold close: ", DoubleToString(row.goldClose, 2), "\n",
           "GeoRisk: ", DoubleToString(row.geoRisk, 1),
           " | Fed hawkish: ", DoubleToString(row.fedHawkish, 1),
           " | news: ", DoubleToString(row.newsCount, 0), "\n",
           "long/short labels: ", IntegerToString(row.longCandidate), "/", IntegerToString(row.shortCandidate), "\n",
           "research state: ", state, " | score: ", DoubleToString(score, 2), "\n",
           "source: ", signalSource, " | No API calls.");
   if(row.date != lastLoggedCsvDate)
   {
      Print("CSV ", row.date, " research state=", state, " score=", DoubleToString(score, 2));
      lastLoggedCsvDate = row.date;
   }
}

bool ExecutionEnabled()
{
   if(MQLInfoInteger(MQL_TESTER))
      return EnableExecutionInTester;
   return EnableExecutionLive;
}

void TryExecuteResearchSignal(string signalDate, string state, double score)
{
   int todayKey = DateKey(TimeCurrent());
   if(todayKey != executionDayKey)
   {
      executionDayKey = todayKey;
      executedToday = 0;
   }
   if(!ExecutionEnabled() || executedToday >= MaxOrdersPerDay || MathAbs(score) < MinSignalScore)
      return;

   ENUM_ORDER_TYPE orderType;
   if(state == "LONG_RESEARCH")
      orderType = ORDER_TYPE_BUY;
   else if(state == "SHORT_RESEARCH")
      orderType = ORDER_TYPE_SELL;
   else
      return;

   string signalId = signalDate + "|" + state;
   if(signalId == lastAttemptedSignalId)
      return; // Avoid retrying an invalid daily order on every minute timer event.
   lastAttemptedSignalId = signalId;
   if(SendResearchOrder(orderType, signalId))
   {
      lastExecutedSignalId = signalId;
      executedToday++;
   }
}

bool SendResearchOrder(ENUM_ORDER_TYPE orderType, string signalId)
{
   string symbol = _Symbol;
   double volume = NormalizeVolume(FixedLots, symbol);
   if(volume <= 0.0)
   {
      Print("Order blocked: invalid volume ", FixedLots, " for ", symbol);
      return false;
   }
   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick))
   {
      Print("Order blocked: no tick for ", symbol);
      return false;
   }
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double price = orderType == ORDER_TYPE_BUY ? tick.ask : tick.bid;
   double slDistance = DefaultSLPips * PipSize;
   double tpDistance = DefaultTPPips * PipSize;

   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);
   request.action = TRADE_ACTION_DEAL;
   request.symbol = symbol;
   request.volume = volume;
   request.type = orderType;
   request.price = NormalizeDouble(price, digits);
   request.sl = NormalizeDouble(orderType == ORDER_TYPE_BUY ? price - slDistance : price + slDistance, digits);
   request.tp = NormalizeDouble(orderType == ORDER_TYPE_BUY ? price + tpDistance : price - tpDistance, digits);
   request.deviation = DeviationPoints;
   request.magic = MagicNumber;
   request.comment = "CSV|" + signalId;
   request.type_time = ORDER_TIME_GTC;
   request.type_filling = SupportedFillingMode(symbol);

   MqlTradeCheckResult check;
   ZeroMemory(check);
   if(!OrderCheck(request, check))
   {
      Print("OrderCheck failed. error=", GetLastError(), " comment=", check.comment);
      return false;
   }
   if(!OrderSend(request, result))
   {
      Print("OrderSend failed. error=", GetLastError());
      return false;
   }
   if(result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_PLACED)
   {
      Print("Order rejected. retcode=", result.retcode, " comment=", result.comment);
      return false;
   }
   Print("CSV order opened. signal=", signalId, " volume=", DoubleToString(volume, 2),
         " price=", DoubleToString(price, digits), " ticket=", result.order);
   return true;
}

ENUM_ORDER_TYPE_FILLING SupportedFillingMode(string symbol)
{
   // SYMBOL_FILLING_MODE is a flag set, whereas request.type_filling requires
   // exactly one mode. Select a mode the broker reports as supported.
   int supportedModes = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((supportedModes & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   if((supportedModes & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

double NormalizeVolume(double requestedLots, string symbol)
{
   double minVolume = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxVolume = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(minVolume <= 0.0 || maxVolume <= 0.0 || step <= 0.0)
      return 0.0;
   double normalized = MathFloor(requestedLots / step) * step;
   normalized = MathMax(minVolume, MathMin(maxVolume, normalized));
   return NormalizeDouble(normalized, 2);
}

// Reads the local bridge generated by backend/main.py --export-mt5-signals.
bool LoadPythonSignal(string fileName, bool commonFiles, string targetDate, PythonSignalRow &signal)
{
   int flags = FILE_READ | FILE_CSV | FILE_ANSI;
   if(commonFiles)
      flags |= FILE_COMMON;
   int handle = FileOpen(fileName, flags, ',');
   if(handle == INVALID_HANDLE)
      return false;

   // Header has eight columns. Only date, action, score and reason are needed.
   for(int col = 0; col < 8 && !FileIsEnding(handle); col++)
      FileReadString(handle);
   bool found = false;
   while(!FileIsEnding(handle))
   {
      string dateValue = FileReadString(handle);
      string actionValue = FileReadString(handle);
      string scoreValue = FileReadString(handle);
      FileReadString(handle); // gold_close
      FileReadString(handle); // geo_risk
      FileReadString(handle); // fed_hawkish
      FileReadString(handle); // news_count
      string reasonValue = FileReadString(handle);
      if(dateValue == targetDate)
      {
         signal.date = dateValue;
         signal.action = actionValue;
         signal.score = CsvNumber(scoreValue);
         signal.reason = reasonValue;
         found = true;
         break;
      }
   }
   FileClose(handle);
   return found;
}

// Column indices follow data/XAUUSD_Macro_News_Clean.csv exactly (0-based).
// In the Strategy Tester, TimeCurrent() is the simulated chart time.  For a
// weekend/holiday, the latest earlier daily record is selected.
bool LoadCsvRow(string fileName, bool commonFiles, bool selectByChartDate, CsvMacroRow &row)
{
   int flags = FILE_READ | FILE_CSV | FILE_ANSI;
   if(commonFiles)
      flags |= FILE_COMMON;
   string openedName = fileName;
   int handle = FileOpen(openedName, flags, ',');
   // MT5 retains EA input values between recompiles.  Support a previously
   // saved space-separated name while the real dataset uses underscores.
   if(handle == INVALID_HANDLE)
   {
      string alternateName = fileName;
      StringReplace(alternateName, " ", "_");
      if(alternateName != fileName)
      {
         ResetLastError();
         handle = FileOpen(alternateName, flags, ',');
         if(handle != INVALID_HANDLE)
         {
            openedName = alternateName;
            Print("Using CSV filename ", openedName, " instead of saved input ", fileName);
         }
      }
   }
   if(handle == INVALID_HANDLE)
   {
      Print("FileOpen failed: ", openedName, " error=", GetLastError(),
            ". Expected location: MQL5\\Files\\XAUUSD_Macro_News_Clean.csv");
      return false;
   }

   // Skip header: this version requires the documented 111-column layout.
   for(int col = 0; col < 111 && !FileIsEnding(handle); col++)
      FileReadString(handle);

   bool found = false;
   int bestDateKey = 0;
   int targetDateKey = DateKey(TimeCurrent());
   while(!FileIsEnding(handle))
   {
      string cells[];
      ArrayResize(cells, 111);
      for(int col = 0; col < 111; col++)
      {
         if(FileIsEnding(handle) && col > 0)
            break;
         cells[col] = FileReadString(handle);
      }
      if(StringLen(cells[0]) == 0)
         continue;
      int csvDateKey = DateKey(StringToTime(cells[0] + " 00:00"));
      if(selectByChartDate && (csvDateKey == 0 || csvDateKey > targetDateKey || csvDateKey < bestDateKey))
         continue;
      row.date           = cells[0];
      row.goldClose      = CsvNumber(cells[4]);
      row.dxy            = CsvNumber(cells[6]);
      row.us10y          = CsvNumber(cells[8]);
      row.realYield10y   = CsvNumber(cells[9]);
      row.vix            = CsvNumber(cells[11]);
      row.geoRisk        = CsvNumber(cells[93]);
      row.fedHawkish     = CsvNumber(cells[94]);
      row.newsCount      = CsvNumber(cells[95]);
      row.longCandidate  = (int)CsvNumber(cells[96]);
      row.shortCandidate = (int)CsvNumber(cells[97]);
      row.goldReturn1d   = CsvNumber(cells[98]);
      row.dxyChange      = CsvNumber(cells[103]);
      row.us10yChange    = CsvNumber(cells[104]);
      row.newsBias       = CsvNumber(cells[110]);
      bestDateKey        = csvDateKey;
      found              = true;
   }
   FileClose(handle);
   return found;
}

int DateKey(datetime timeValue)
{
   if(timeValue <= 0)
      return 0;
   MqlDateTime parts;
   TimeToStruct(timeValue, parts);
   return parts.year * 10000 + parts.mon * 100 + parts.day;
}

double CsvNumber(string value)
{
   if(StringLen(value) == 0)
      return 0.0;
   return StringToDouble(value);
}

double ScoreRow(const CsvMacroRow &row)
{
   double score = 0.0;
   if(row.longCandidate == 1)
      score += 35.0;
   if(row.shortCandidate == 1)
      score -= 35.0;
   if(row.geoRisk >= GeoRiskLongLevel)
      score += MathMin(30.0, row.geoRisk * 0.30);
   if(row.fedHawkish >= FedHawkishShortLevel)
      score -= MathMin(30.0, row.fedHawkish * 0.30);
   score -= MathMax(-15.0, MathMin(15.0, row.dxyChange * 1000.0));
   score -= MathMax(-15.0, MathMin(15.0, row.us10yChange * 100.0));
   return score;
}

string ResearchState(double score)
{
   if(score >= 25.0)
      return "LONG_RESEARCH";
   if(score <= -25.0)
      return "SHORT_RESEARCH";
   return "NEUTRAL";
}
