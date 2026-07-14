#property strict
#property version   "0.18"
#property description "Gold Macro Auto EA v18: macro/news auto-execution bridge for XAUUSD."

input string BackendBaseUrl      = "http://127.0.0.1:8000";
input string ApiKey              = "change-me";
input string TradeSymbol         = "XAUUSD";
input string MarketSymbolsCsv    = "XAUUSD,DXY,US02Y,US10Y,WTI,VIX";
input bool   EnableExecution     = false;

input int    PollSeconds         = 20;
input int    MarketSyncSeconds   = 30;
input int    CalendarSyncMinutes = 15;

input int    MaxSpreadPoints     = 120;
input int    DeviationPoints     = 50;
input double MaxLots             = 5.0;
input int    MaxOrdersPerDay     = 5;
input ulong  MagicNumber         = 260318;

// Broker-dependent. Must be verified before live. For many XAUUSD brokers 1 pip may be 0.10 or 0.01.
input double PipSize             = 0.10;
input int    DefaultSLPips       = 50;
input int    DefaultTPPips       = 200;

string lastExecutedSignalId = "";
datetime lastMarketSync = 0;
datetime lastCalendarSync = 0;
int executedToday = 0;
int todayKey = 0;

int OnInit()
{
   EventSetTimer(PollSeconds);
   todayKey = DayKey(TimeGMT());
   Print("GoldMacroAutoEA v18 initialized. Symbol=", TradeSymbol, " Backend=", BackendBaseUrl);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

void OnTimer()
{
   int key = DayKey(TimeGMT());
   if(key != todayKey)
   {
      todayKey = key;
      executedToday = 0;
   }

   if(TimeGMT() - lastMarketSync >= MarketSyncSeconds)
   {
      SyncMarketSnapshot();
      lastMarketSync = TimeGMT();
   }

   if(TimeGMT() - lastCalendarSync >= CalendarSyncMinutes * 60)
   {
      SyncCalendarEvents();
      lastCalendarSync = TimeGMT();
   }

   PollAndExecuteSignal();
}

int DayKey(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.year * 10000 + dt.mon * 100 + dt.day;
}

// -----------------------------------------------------------------------------
// Market snapshot upload
// -----------------------------------------------------------------------------

void SyncMarketSnapshot()
{
   string symbols[];
   int n = StringSplit(MarketSymbolsCsv, ',', symbols);
   string ticksJson = "";

   for(int i = 0; i < n; i++)
   {
      string s = Trim(symbols[i]);
      if(s == "") continue;
      if(!SymbolSelect(s, true))
      {
         Print("SymbolSelect failed for market snapshot: ", s);
         continue;
      }

      double bid = SymbolInfoDouble(s, SYMBOL_BID);
      double ask = SymbolInfoDouble(s, SYMBOL_ASK);
      double last = SymbolInfoDouble(s, SYMBOL_LAST);
      double point = SymbolInfoDouble(s, SYMBOL_POINT);
      int digits = (int)SymbolInfoInteger(s, SYMBOL_DIGITS);
      double spreadPoints = 0.0;
      if(point > 0 && bid > 0 && ask > 0)
         spreadPoints = (ask - bid) / point;

      string item =
         "{"
         "\"symbol\":\"" + EscapeJson(s) + "\"," +
         "\"bid\":" + DoubleOrNull(bid) + "," +
         "\"ask\":" + DoubleOrNull(ask) + "," +
         "\"last\":" + DoubleOrNull(last) + "," +
         "\"spread_points\":" + DoubleToString(spreadPoints, 2) + "," +
         "\"point\":" + DoubleOrNull(point) + "," +
         "\"digits\":" + IntegerToString(digits) + "," +
         "\"timestamp_utc\":" + IntegerToString((int)TimeGMT()) +
         "}";

      if(ticksJson != "") ticksJson += ",";
      ticksJson += item;
   }

   if(ticksJson == "")
      return;

   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   string server = AccountInfoString(ACCOUNT_SERVER);

   string body =
      "{"
      "\"source\":\"MT5\"," +
      "\"account_login\":" + IntegerToString((int)login) + "," +
      "\"account_server\":\"" + EscapeJson(server) + "\"," +
      "\"ticks\":[" + ticksJson + "]"
      "}";

   string response = "";
   int status = HttpPost(BackendBaseUrl + "/api/v1/mt5/market", body, response);
   if(status != 200)
      Print("Market sync status=", status, " response=", response);
}

string DoubleOrNull(double v)
{
   if(v <= 0.0) return "null";
   return DoubleToString(v, 8);
}

// -----------------------------------------------------------------------------
// MT5 economic calendar upload
// -----------------------------------------------------------------------------

void SyncCalendarEvents()
{
   MqlCalendarValue values[];
   datetime fromTime = TimeGMT() - 3600;
   datetime toTime = TimeGMT() + 24 * 3600;

   int total = CalendarValueHistory(values, fromTime, toTime, NULL, "USD");
   if(total <= 0)
   {
      Print("CalendarValueHistory returned ", total, ". Calendar may be unavailable for this broker/server.");
      return;
   }

   string eventsJson = "";
   int maxEvents = MathMin(total, 30);

   for(int i = 0; i < maxEvents; i++)
   {
      MqlCalendarEvent ev;
      string name = "MT5 economic calendar event";
      string importance = "UNKNOWN";
      string category = "calendar";

      if(CalendarEventById(values[i].event_id, ev))
      {
         name = ev.name;
         importance = IntegerToString((int)ev.importance);
         category = ev.event_code;
      }

      string eventId = "mt5_" + IntegerToString((int)values[i].event_id) + "_" + IntegerToString((int)values[i].time);

      string item =
         "{"
         "\"event_id\":\"" + EscapeJson(eventId) + "\"," +
         "\"source\":\"MT5_CALENDAR\"," +
         "\"timestamp_utc\":" + IntegerToString((int)values[i].time) + "," +
         "\"title\":\"" + EscapeJson(name) + "\"," +
         "\"content\":\"MT5 economic calendar event\"," +
         "\"category\":\"" + EscapeJson(category) + "\"," +
         "\"importance\":\"" + EscapeJson(importance) + "\"," +
         "\"currency\":\"USD\"," +
         "\"actual\":\"" + EscapeJson(CalendarLongToText(values[i].actual_value)) + "\"," +
         "\"forecast\":\"" + EscapeJson(CalendarLongToText(values[i].forecast_value)) + "\"," +
         "\"previous\":\"" + EscapeJson(CalendarLongToText(values[i].prev_value)) + "\"," +
         "\"raw\":{}"
         "}";

      if(eventsJson != "") eventsJson += ",";
      eventsJson += item;
   }

   string body =
      "{"
      "\"symbol\":\"" + EscapeJson(TradeSymbol) + "\"," +
      "\"events\":[" + eventsJson + "]"
      "}";

   string response = "";
   int status = HttpPost(BackendBaseUrl + "/api/v1/mt5/calendar", body, response);
   if(status != 200)
      Print("Calendar sync status=", status, " response=", response);
}

string CalendarLongToText(long v)
{
   if(v == LONG_MIN) return "";
   return LongToString(v);
}

// -----------------------------------------------------------------------------
// Signal polling and execution
// -----------------------------------------------------------------------------

void PollAndExecuteSignal()
{
   string response = "";
   string url = BackendBaseUrl + "/api/v1/mt5/next?symbol=" + TradeSymbol + "&evaluate_if_due=true";
   int status = HttpGet(url, response);

   if(status != 200)
   {
      Print("Signal poll error. status=", status, " response=", response);
      return;
   }

   string signalId = JsonString(response, "signal_id");
   string action = JsonString(response, "action");
   string permission = JsonString(response, "permission");
   string state = JsonString(response, "state");
   string reason = JsonString(response, "reason");

   double lots = JsonDouble(response, "lots");
   int slPips = (int)JsonDouble(response, "sl_pips");
   int tpPips = (int)JsonDouble(response, "tp_pips");
   int validUntil = (int)JsonDouble(response, "valid_until_utc");

   if(signalId == "" || action == "")
   {
      Print("Invalid signal JSON: ", response);
      return;
   }

   if(action == "NO_TRADE")
   {
      Print("No trade. reason=", reason);
      return;
   }

   if(permission != "AUTO_ALLOWED")
   {
      Print("Signal not auto allowed. signal_id=", signalId, " permission=", permission, " state=", state);
      return;
   }

   if(TimeGMT() > validUntil)
   {
      Print("Expired signal skipped. signal_id=", signalId);
      return;
   }

   if(signalId == lastExecutedSignalId)
   {
      Print("Duplicate signal skipped. signal_id=", signalId);
      return;
   }

   if(executedToday >= MaxOrdersPerDay)
   {
      Print("Daily EA order cap reached: ", executedToday);
      return;
   }

   if(!EnableExecution)
   {
      Print("Execution disabled. Would execute: ", action, " lots=", lots, " signal_id=", signalId, " reason=", reason);
      return;
   }

   bool ok = ExecuteSignal(signalId, action, lots, slPips, tpPips);
   if(ok)
   {
      lastExecutedSignalId = signalId;
      executedToday++;
   }
}

bool ExecuteSignal(string signalId, string action, double lots, int slPips, int tpPips)
{
   if(lots <= 0.0 || lots > MaxLots)
   {
      Print("Lots blocked. lots=", lots, " MaxLots=", MaxLots);
      return false;
   }

   if(!SymbolSelect(TradeSymbol, true))
   {
      Print("SymbolSelect failed: ", TradeSymbol);
      return false;
   }

   double ask = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS);

   if(ask <= 0.0 || bid <= 0.0 || point <= 0.0)
   {
      Print("Invalid price data.");
      return false;
   }

   double spreadPoints = (ask - bid) / point;
   if(spreadPoints > MaxSpreadPoints)
   {
      Print("Spread too wide. spread_points=", spreadPoints);
      return false;
   }

   double volume = NormalizeVolume(lots);
   if(volume <= 0.0)
   {
      Print("Volume blocked after normalization. requested=", lots);
      return false;
   }

   ENUM_ORDER_TYPE orderType;
   double price, sl, tp;
   double slDistance = slPips * PipSize;
   double tpDistance = tpPips * PipSize;

   if(action == "BUY")
   {
      orderType = ORDER_TYPE_BUY;
      price = ask;
      sl = price - slDistance;
      tp = price + tpDistance;
   }
   else if(action == "SELL")
   {
      orderType = ORDER_TYPE_SELL;
      price = bid;
      sl = price + slDistance;
      tp = price - tpDistance;
   }
   else
   {
      Print("Unsupported action: ", action);
      return false;
   }

   if(!StopsAreValid(price, sl, tp))
   {
      Print("Invalid stops. price=", price, " sl=", sl, " tp=", tp);
      return false;
   }

   MqlTradeRequest request;
   MqlTradeCheckResult check;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(check);
   ZeroMemory(result);

   request.action = TRADE_ACTION_DEAL;
   request.symbol = TradeSymbol;
   request.volume = volume;
   request.type = orderType;
   request.price = NormalizeDouble(price, digits);
   request.sl = NormalizeDouble(sl, digits);
   request.tp = NormalizeDouble(tp, digits);
   request.deviation = DeviationPoints;
   request.magic = MagicNumber;
   request.comment = "MacroAuto|" + signalId;
   request.type_time = ORDER_TIME_GTC;
   request.type_filling = ORDER_FILLING_FOK;

   if(!OrderCheck(request, check))
   {
      Print("OrderCheck call failed. retcode=", check.retcode, " comment=", check.comment);
      SendAck(signalId, action, volume, 0.0, "ORDERCHECK_CALL_FAILED", check.comment);
      return false;
   }

   if(check.retcode != TRADE_RETCODE_DONE && check.retcode != TRADE_RETCODE_PLACED)
   {
      Print("OrderCheck blocked. retcode=", check.retcode, " comment=", check.comment);
      SendAck(signalId, action, volume, 0.0, IntegerToString(check.retcode), check.comment);
      return false;
   }

   if(!OrderSend(request, result))
   {
      Print("OrderSend call failed. retcode=", result.retcode, " comment=", result.comment);
      SendAck(signalId, action, volume, 0.0, "ORDERSEND_CALL_FAILED", result.comment);
      return false;
   }

   bool filled = (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED || result.retcode == TRADE_RETCODE_DONE_PARTIAL);

   Print("OrderSend result signal_id=", signalId,
         " retcode=", result.retcode,
         " order=", result.order,
         " deal=", result.deal,
         " price=", result.price);

   SendAck(signalId, action, volume, result.price, IntegerToString(result.retcode), result.comment);
   return filled;
}

bool StopsAreValid(double price, double sl, double tp)
{
   double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   int stopsLevel = (int)SymbolInfoInteger(TradeSymbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(point <= 0.0) return false;
   double minDistance = stopsLevel * point;
   if(MathAbs(price - sl) < minDistance) return false;
   if(MathAbs(price - tp) < minDistance) return false;
   return true;
}

double NormalizeVolume(double lots)
{
   double minLot = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) return 0.0;

   double capped = MathMin(MathMax(lots, minLot), MathMin(maxLot, MaxLots));
   double steps = MathFloor(capped / step);
   double normalized = steps * step;
   if(normalized < minLot) return 0.0;
   return NormalizeDouble(normalized, 2);
}

// -----------------------------------------------------------------------------
// HTTP and JSON helpers
// -----------------------------------------------------------------------------

int HttpGet(string url, string &response)
{
   char data[];
   char result[];
   string headers = "X-API-Key: " + ApiKey + "\r\n" + "Content-Type: application/json\r\n";
   string resultHeaders = "";
   ResetLastError();
   int status = WebRequest("GET", url, headers, 10000, data, result, resultHeaders);
   if(status == -1)
   {
      int err = GetLastError();
      response = "WebRequest failed. err=" + IntegerToString(err);
      return -1;
   }
   response = CharArrayToString(result, 0, -1, CP_UTF8);
   return status;
}

int HttpPost(string url, string body, string &response)
{
   char data[];
   int len = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   if(len > 0) ArrayResize(data, len - 1);

   char result[];
   string headers = "X-API-Key: " + ApiKey + "\r\n" + "Content-Type: application/json\r\n";
   string resultHeaders = "";
   ResetLastError();
   int status = WebRequest("POST", url, headers, 10000, data, result, resultHeaders);
   if(status == -1)
   {
      int err = GetLastError();
      response = "WebRequest failed. err=" + IntegerToString(err);
      return -1;
   }
   response = CharArrayToString(result, 0, -1, CP_UTF8);
   return status;
}

void SendAck(string signalId, string action, double lots, double price, string retcode, string comment)
{
   string body =
      "{"
      "\"signal_id\":\"" + EscapeJson(signalId) + "\"," +
      "\"symbol\":\"" + EscapeJson(TradeSymbol) + "\"," +
      "\"action\":\"" + EscapeJson(action) + "\"," +
      "\"requested_lots\":" + DoubleToString(lots, 2) + "," +
      "\"filled_lots\":" + DoubleToString(lots, 2) + "," +
      "\"price\":" + DoubleToString(price, 5) + "," +
      "\"retcode\":\"" + EscapeJson(retcode) + "\"," +
      "\"comment\":\"" + EscapeJson(comment) + "\"," +
      "\"time_utc\":" + IntegerToString((int)TimeGMT()) +
      "}";

   string response = "";
   int status = HttpPost(BackendBaseUrl + "/api/v1/mt5/ack", body, response);
   Print("ACK status=", status, " response=", response);
}

string JsonString(string json, string key)
{
   string pattern = "\"" + key + "\":";
   int p = StringFind(json, pattern);
   if(p < 0) return "";
   p += StringLen(pattern);
   while(p < StringLen(json))
   {
      ushort c = StringGetCharacter(json, p);
      if(c != ' ' && c != '\t' && c != '\r' && c != '\n') break;
      p++;
   }
   if(p >= StringLen(json) || StringGetCharacter(json, p) != '"') return "";
   p++;
   int start = p;
   while(p < StringLen(json))
   {
      if(StringGetCharacter(json, p) == '"') return StringSubstr(json, start, p - start);
      p++;
   }
   return "";
}

double JsonDouble(string json, string key)
{
   string pattern = "\"" + key + "\":";
   int p = StringFind(json, pattern);
   if(p < 0) return 0.0;
   p += StringLen(pattern);
   while(p < StringLen(json))
   {
      ushort c = StringGetCharacter(json, p);
      if(c != ' ' && c != '\t' && c != '\r' && c != '\n') break;
      p++;
   }
   int start = p;
   while(p < StringLen(json))
   {
      ushort c = StringGetCharacter(json, p);
      bool ok = (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '+';
      if(!ok) break;
      p++;
   }
   string value = StringSubstr(json, start, p - start);
   return StringToDouble(value);
}

string EscapeJson(string s)
{
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   StringReplace(s, "\r", " ");
   StringReplace(s, "\n", " ");
   return s;
}

string Trim(string s)
{
   StringTrimLeft(s);
   StringTrimRight(s);
   return s;
}
