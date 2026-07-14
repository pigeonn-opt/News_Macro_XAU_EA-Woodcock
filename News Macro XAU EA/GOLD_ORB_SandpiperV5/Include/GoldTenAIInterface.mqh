//+------------------------------------------------------------------+
//| GoldTen AI Interface Bridge                                     |
//| Purpose: optional connection to Gold Macro Auto EA v18 backend  |
//+------------------------------------------------------------------+

class CGoldTenAIInterface
  {
private:
   bool              m_initialized;
   string            m_endpoint;
   string            m_api_key;
  // Visible build tag to help confirm the loaded binary matches source
  string            m_build_tag;
   string            m_last_error;
   string            m_symbol;
   string            m_last_signal_json;
   string            m_last_signal_id;
   int               m_poll_interval_seconds;
   int               m_last_poll_time;

   string ExtractJsonString(const string json, const string key)
     {
      string pattern = "\"" + key + "\":";
      int p = StringFind(json, pattern);
      if(p < 0)
         return "";
      p += StringLen(pattern);
      while(p < StringLen(json))
        {
         ushort c = StringGetCharacter(json, p);
         if(c != ' ' && c != '\t' && c != '\r' && c != '\n')
            break;
         p++;
        }
      if(p >= StringLen(json) || StringGetCharacter(json, p) != '"')
         return "";
      p++;
      int start = p;
      while(p < StringLen(json))
        {
         if(StringGetCharacter(json, p) == '"')
            return StringSubstr(json, start, p - start);
         p++;
        }
      return "";
     }

public:
   CGoldTenAIInterface(void) : m_initialized(false), m_endpoint(""), m_api_key(""), m_last_error(""), m_symbol("XAUUSD"), m_last_signal_json(""), m_last_signal_id(""), m_poll_interval_seconds(20), m_last_poll_time(0)
     {
      m_build_tag = "BUILD:2026-07-13T17:40:00";
     }

   bool Init(const string endpoint="", const string api_key="")
     {
      m_endpoint = (endpoint != "") ? endpoint : "http://127.0.0.1:8000";
      m_api_key  = (api_key != "") ? api_key : "change-me";
      m_last_error = "";
      m_last_signal_json = "";
      m_last_signal_id = "";
      m_initialized = true;
      // Print build tag so we can verify which compiled binary is running
      PrintFormat("[GOLD_ORB DEBUG] GoldTen BuildTag=%s", m_build_tag);
      // Masked API key for debug reporting
      string masked = StringSubstr(m_api_key, 0, MathMin(StringLen(m_api_key),4)) + (StringLen(m_api_key) > 4 ? "..." : "");
      PrintFormat("[GOLD_ORB DEBUG] GoldTen Init api_key_mask=%s endpoint=%s", masked, m_endpoint);
      return(true);
     }

   void Deinit(void)
     {
      m_initialized = false;
      m_endpoint = "";
      m_api_key = "";
      m_last_error = "";
      m_last_signal_json = "";
      m_last_signal_id = "";
      m_last_poll_time = 0;
     }

   void SetSymbol(const string symbol)
     {
      m_symbol = symbol;
     }

   void SetPollingInterval(const int seconds)
     {
      if(seconds > 0)
         m_poll_interval_seconds = seconds;
     }

   bool IsReady(void) const
     {
      return(m_initialized);
     }

   bool OnTick(void)
     {
      int now = (int)TimeCurrent();
      if(m_last_poll_time == 0 || now - m_last_poll_time >= m_poll_interval_seconds)
        {
         m_last_poll_time = now;
         string signal_json = "";
         string error_text = "";
         return RequestSignal(signal_json, error_text);
        }
      return(true);
     }

   bool OnNewBar(void)
     {
      return OnTick();
     }

   bool RequestSignal(string &signal_json, string &error_text)
     {
      signal_json = "";
      error_text = "";
      if(!m_initialized)
        {
         error_text = "GoldTen interface is not initialized yet";
         m_last_error = error_text;
         return(false);
        }

      string params = "symbol=" + m_symbol + "&evaluate_if_due=true";
      string url = m_endpoint + "/api/v1/mt5/next?" + params;
      PrintFormat("[GOLD_ORB DEBUG] Macro poll url=%s", url);
      char data[];
      char result[];
      string headers = "X-API-Key: " + m_api_key + "\r\n" + "Content-Type: application/json\r\n";
      string result_headers = "";
      ResetLastError();
      int status = WebRequest("GET", url, headers, 10000, data, result, result_headers);
      if(status == -1)
        {
         int err = GetLastError();
         error_text = "WebRequest failed. err=" + IntegerToString(err);
         m_last_error = error_text;
         PrintFormat("[GOLD_ORB DEBUG] Macro request failed: %s", error_text);
         return(false);
        }

      signal_json = CharArrayToString(result, 0, -1, CP_UTF8);
      PrintFormat("[GOLD_ORB DEBUG] Macro response status=%d body=%s", status, signal_json);
      if(status != 200)
        {
         error_text = "HTTP " + IntegerToString(status) + ": " + signal_json;
         m_last_error = error_text;
         return(false);
        }

      m_last_signal_json = signal_json;
      m_last_signal_id = ExtractJsonString(signal_json, "signal_id");
      m_last_error = "";
      return(true);
     }

   bool SendSignal(const string symbol,const double price,const int action,const double volume,string &error_text)
     {
      error_text = "";
      if(!m_initialized || m_endpoint == "")
        {
         error_text = "GoldTen interface is not initialized yet";
         return(false);
        }

      string action_name = (action == 1 || action == 11) ? "BUY" : "SELL";
      string body =
         "{"
         "\"signal_id\":" + (m_last_signal_id == "" ? "\"\"" : "\"" + EscapeJson(m_last_signal_id) + "\"") + ","
         "\"symbol\":" + (symbol == "" ? "\"\"" : "\"" + EscapeJson(symbol) + "\"") + ","
         "\"action\":" + (action_name == "" ? "\"\"" : "\"" + EscapeJson(action_name) + "\"") + ","
         "\"requested_lots\":" + DoubleToString(volume, 2) + ","
         "\"filled_lots\":" + DoubleToString(volume, 2) + ","
         "\"price\":" + DoubleToString(price, 5) + ","
         "\"retcode\":\"ACK_SENT\","
         "\"comment\":\"macro_bridge\","
         "\"time_utc\":" + IntegerToString((int)TimeCurrent()) +
         "}";

      char data[];
      int len = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
      if(len > 0)
         ArrayResize(data, len - 1);
      char result[];
      string headers = "X-API-Key: " + m_api_key + "\r\n" + "Content-Type: application/json\r\n";
      string result_headers = "";
      ResetLastError();
      int status = WebRequest("POST", m_endpoint + "/api/v1/mt5/ack", headers, 10000, data, result, result_headers);
      if(status == -1)
        {
         int err = GetLastError();
         error_text = "WebRequest failed. err=" + IntegerToString(err);
         m_last_error = error_text;
         return(false);
        }

      string response = CharArrayToString(result, 0, -1, CP_UTF8);
      if(status != 200)
        {
         error_text = "HTTP " + IntegerToString(status) + ": " + response;
         m_last_error = error_text;
         return(false);
        }
      m_last_error = "";
      return(true);
     }

   string LastError(void) const
     {
      return(m_last_error);
     }

   string EscapeJson(const string s)
     {
      string out = s;
      StringReplace(out, "\\", "\\\\");
      StringReplace(out, "\"", "\\\"");
      StringReplace(out, "\r", " ");
      StringReplace(out, "\n", " ");
      return out;
     }
  };
