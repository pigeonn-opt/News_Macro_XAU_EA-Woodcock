
#property copyright "Playground Inc 2021"
#property link      "https://www.mql5.com"
#property version   "1.00"

/* 
Author: Ulysses O. Andulte
Date Created: 10/26/2022
*/


//Include Files
#include "Include\Trade.mqh"
#include "Include\TrailingStops.mqh"
#include "Include\price_action.mqh"
#include "Include\Indicators.mqh"
#include "Include\TradeVirtual.mqh"
#include "Include\TrailingStopsVirtual.mqh"
#include "Include\MoneyManagement.mqh"
#include "Include\Math\Stat\Normal.mqh"
#include "Include\RiskManagement.mqh"
#include "Include\GoldTenAIInterface.mqh"


//Input Variables
input group  "SymBolInformation"
input int StartOfTradingHour_ServerTime = 1;

input group  "Trade Management"
input int TakeProfit =1200;
input int StopLoss =400;
input int MaxTradePerDay =2;
input bool LongPosition = true;
input bool ShortPosition = true;

input group "Trail Management"
input bool EnableTrail=true;
input int BreakEvenPoints = 0;
input int TrailStartPoints = 800;
input int TrailPoints = 600;
input int LockProfitPoints = 100;

input group "Risk Management"
input double MaxEquityDrawdownPercent = 10;
input double MaxRiskPerTradePercent = 1;
input double FixedVolume = 0.1;


input group "Advanced Equity Monitoring Module"
input bool SlopeDetection = false;
input int LossStreakThreshold = 0;

input group "Indicators"
input int PriceActionORB_CandleComposition = 3;

input group "Time Filters"                              // 新增分组
input string BlockedWeekDays = "3";                     // 禁止交易的星期
input string BlockedHours = "5,11";                     // 禁止交易的小时

input group "Debug"
input bool DebugPrint = true;

input group "AI / GoldTen Interface"
input bool EnableGoldTenAIInterface = false;
input string GoldTenAIEndpoint = "http://127.0.0.1:8000";
input string GoldTenAPIKey = "change-me";
input bool EnableMacroSignalOverride = false;
input int MacroPollSeconds = 20;


//Global Variables
bool execute_trade;
double capital;
int indicator_2;
bool indicator_3;
double TradeVolume = FixedVolume;
int macro_signal = 0;
bool macro_signal_available = false;

string g_blockedWeekDays;
string g_blockedHours;
//Class objects

//Trade management Module
//++++++++++++++++++++++++
CTrade trade; //a class for executing orders on the server
CTrailing trail; //a class for trail stop

//Indicators Module
//++++++++++++++++++++++++
Price_Action pa;// an indicator class for price action
CiMA MA100; //an indicator class for moving averages


//Virtual Trading Environment Module
//++++++++++++++++++++++++++++++++++++
CTradeVirtual tradevirtual;// a class for executing orders on virtual trade environment
CTrailingVirtual trailvirtual; //a class for trail stop virtual
VirtualTradeInfo VTrade; //a class for storing virtual information: details on  position, deals and closed trades

//AI / GoldTen interface stub
CGoldTenAIInterface gold_ten_ai;


//Working Code
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
// Event handler: Initialization
int OnInit()
{
   //Initialize Price action object for default or user input
   pa.Init();
   pa.candle_composition = PriceActionORB_CandleComposition;
   pa.trades_per_day = MaxTradePerDay;
   pa.StartOfTradinghour_servertime = StartOfTradingHour_ServerTime;
   // 新增：设置时间过滤
   pa.SetBlockedWeekDays(BlockedWeekDays);
   pa.SetBlockedHours(BlockedHours);

   //Initialize virtual trade environment
   tradevirtual.Init(VTrade);

   //Initialize AI interface stub (disabled by default)
   if(EnableGoldTenAIInterface)
   {
      string endpoint = GoldTenAIEndpoint;
      string api_key = GoldTenAPIKey;
      if(endpoint == "") endpoint = "http://127.0.0.1:8000";
      if(api_key == "") api_key = "change-me";

      gold_ten_ai.SetSymbol(_Symbol);
      gold_ten_ai.SetPollingInterval(MacroPollSeconds);
      bool init_ok = gold_ten_ai.Init(endpoint,api_key);
      PrintFormat("[GOLD_ORB DEBUG] Macro interface init. enabled=%s endpoint=%s api_key=%s", init_ok ? "true" : "false", endpoint, api_key);
      if(!init_ok)
         PrintFormat("[GOLD_ORB DEBUG] Macro interface init failed. error=%s", gold_ten_ai.LastError());
   }

   // *** 添加WebRequest测试代码（放在return之前）***
   string test_url = "http://192.168.0.104:8000/docs";
   char data[], result[];
   string headers = "";
   string result_headers = "";
   ResetLastError();
   int status = WebRequest("GET", test_url, headers, 5000, data, result, result_headers);
   PrintFormat("[GOLD_ORB TEST] WebRequest test: status=%d, error=%d", status, GetLastError());
   if(status == 200)
   {
      string response = CharArrayToString(result, 0, -1, CP_UTF8);
      PrintFormat("[GOLD_ORB TEST] Response: %s", response);
   }

   //******************************
   //Extra Variables (test cases)
   execute_trade = true;
   capital = AccountInfoDouble(ACCOUNT_EQUITY);
   return(INIT_SUCCEEDED);
}


//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
// Event handler: Execute each tick that will arrive from the server
void OnTick()
  {
   
   
   RiskManagementModule();
   if(EnableTrail) TrailModule();

   if(EnableGoldTenAIInterface)
      gold_ten_ai.OnTick();

   if(pa.new_candle_check2())
     {
      IndicatorModule();
      if(EnableGoldTenAIInterface && EnableMacroSignalOverride)
        {
         gold_ten_ai.OnNewBar();
         string macro_signal_json = "";
         string macro_error = "";
         macro_signal_available = false;
         macro_signal = 0;
         if(gold_ten_ai.RequestSignal(macro_signal_json, macro_error))
            macro_signal_available = ResolveMacroSignal(macro_signal_json, macro_signal, macro_error);
         else if(DebugPrint && macro_error != "")
            PrintFormat("[GOLD_ORB DEBUG] Macro signal poll failed: %s", macro_error);
        }
      if(DebugPrint)
        {
         MqlDateTime now;
         TimeToStruct(TimeCurrent(),now);
         PrintFormat("[GOLD_ORB DEBUG] time=%s hour=%d symbol=%s period=%s signal=%d execute_trade=%s volume=%.2f balance=%.2f equity=%.2f bid=%.5f ask=%.5f",
                     TimeToString(TimeCurrent(),TIME_DATE|TIME_MINUTES),
                     now.hour,
                     _Symbol,
                     EnumToString(_Period),
                     indicator_2,
                     execute_trade ? "true" : "false",
                     TradeVolume,
                     AccountInfoDouble(ACCOUNT_BALANCE),
                     AccountInfoDouble(ACCOUNT_EQUITY),
                     SymbolInfoDouble(_Symbol,SYMBOL_BID),
                     SymbolInfoDouble(_Symbol,SYMBOL_ASK));
        }
      ExecuteOrders();
     }
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
//End of Program




/////////////////////////////////////////////////////////////////////
//                     Functions
/////////////////////////////////////////////////////////////////////

int ResolveExecutionSignal(void)
  {
   if(EnableGoldTenAIInterface && EnableMacroSignalOverride && macro_signal_available)
      return macro_signal;
   return indicator_2;
  }

bool ResolveMacroSignal(const string signal_json, int &action_signal, string &error_text)
  {
   action_signal = 0;
   error_text = "";

   string action_text = JsonString(signal_json, "action");
   string permission = JsonString(signal_json, "permission");
   string state = JsonString(signal_json, "state");

   if(action_text == "BUY")
     {
      if(permission == "AUTO_ALLOWED" && state == "AUTO_ALLOWED")
        {
         action_signal = 11;
         return true;
        }
      error_text = "macro signal blocked; permission=" + permission + ", state=" + state;
      return false;
     }

   if(action_text == "SELL")
     {
      if(permission == "AUTO_ALLOWED" && state == "AUTO_ALLOWED")
        {
         action_signal = 10;
         return true;
        }
      error_text = "macro signal blocked; permission=" + permission + ", state=" + state;
      return false;
     }

   error_text = "macro signal malformed: " + signal_json;
   return false;
  }

string JsonString(const string json, const string key)
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

//+------------------------------------------------------------------+
//| //Risk Management Module     
//|      
//|  **MonitoringVirtualPosition - Monitors and Closes virtual position 
//|                                and update virtualtrade information
//|  
                              
//+------------------------------------------------------------------+
void RiskManagementModule(void)

  {
  
   //Virtual Equity Monitoring
   MonitorVirtualPostion(VTrade); 

   //Setting Up Equity Trail, will stop executing real orders once max equity drawdown is hit.
   //Original code turned execute_trade=false every tick whenever MaxEquityDrawdownPercent!=0.
   if(MaxEquityDrawdownPercent!=0)
     {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity > capital)
         capital = equity;

      double dd = 100.0*((equity - capital)/capital);
      if(dd < -1.0*MaxEquityDrawdownPercent)
        {
         PrintFormat("[GOLD_ORB DEBUG] Max equity drawdown hit: %.2f%%, real trading disabled",dd);
         execute_trade = false;
        }
     }


   //This module will detect if Lossing streak ended depending on the input integer and if equity is recovering, upward
   if(SlopeDetection || LossStreakThreshold!=0)
     {
      bool LossStreak_flag = LossStreakCounter(VTrade,3); //Lossing Streak Detection
      bool Slope_Equity_Flag = CheckSlope(VTrade,12); // Slope Equity Monitoring

      if(LossStreak_flag)
         execute_trade = false;
      if(Slope_Equity_Flag == true && LossStreak_flag == false)
         execute_trade = true;
     }
   
   //Dynamic Position Sizing Relative to port size, or FixedVolume for default if no input in MaxRiskPerTradePercent
   TradeVolume = MoneyManagement(_Symbol,FixedVolume,MaxRiskPerTradePercent,StopLoss);


  }



//+------------------------------------------------------------------+
//| //Trail Stop Module                                              |
//+------------------------------------------------------------------+
void TrailModule(void)

  {
   int i = 0;
   int total_positions = PositionsTotal();


   //RealPort Trail Module, will loop on all open positions to check if trail is hit
    if(total_positions!=0)
      {
      if(DebugPrint)
        PrintFormat("[TrailModule] RealPort total_positions=%d TrailPoints=%d TrailStartPoints=%d BreakEvenPoints=%d",
                total_positions, TrailPoints, TrailStartPoints, BreakEvenPoints);
      for(i=0 ; i <= total_positions -1; i++)
        {
        ulong ticket = PositionGetTicket(i);
        double posProfit = PositionGetDouble(POSITION_PROFIT);
        if(DebugPrint)
          PrintFormat("[TrailModule] RealPos idx=%d ticket=%I64u profit=%.2f symbol=%s",
                  i, ticket, posProfit, PositionGetString(POSITION_SYMBOL));

        if(BreakEvenPoints > 0)
          {
          bool be = trail.BreakEven(ticket, BreakEvenPoints, LockProfitPoints);
          if(DebugPrint) PrintFormat("[TrailModule] BreakEven(ticket=%I64u)=%s", ticket, be?"true":"false");
          }

        bool tr = trail.TrailingStop(ticket, TrailPoints, TrailStartPoints, 10); // trail distance, start trailing after profit threshold, step fixed at 10
        if(DebugPrint) PrintFormat("[TrailModule] TrailingStop(ticket=%I64u)=%s", ticket, tr?"true":"false");
        }
      }


   //Virtual Port Trail Module, will loop on all open positions to check if trail is hit
   int j=0;
   int total_positions_virtual = ArraySize(VTrade.position);
    if(total_positions_virtual!=0)
      {
      if(DebugPrint)
        PrintFormat("[TrailModule] VirtualPort total_positions_virtual=%d TrailPoints=%d TrailStartPoints=%d BreakEvenPoints=%d",
                total_positions_virtual, TrailPoints, TrailStartPoints, BreakEvenPoints);
      for(j=0 ; j <= total_positions_virtual -1; j++)
        {
        if(DebugPrint) PrintFormat("[TrailModule] VirtualPos idx=%d symbol=%s price=%.5f sl=%.5f tp=%.5f",
                          j, VTrade.position[j].symbol, VTrade.position[j].price, VTrade.position[j].sl, VTrade.position[j].tp);

        if(BreakEvenPoints > 0)
          {
          bool bev = trailvirtual.BreakEven(VTrade,j,BreakEvenPoints,LockProfitPoints);
          if(DebugPrint) PrintFormat("[TrailModule] Virtual BreakEven(idx=%d)=%s", j, bev?"true":"false");
          }

        bool trv = trailvirtual.TrailingStop(VTrade,j,TrailPoints,TrailStartPoints,10); // trail distance, start trailing after profit threshold, step fixed at 10
        if(DebugPrint) PrintFormat("[TrailModule] Virtual TrailingStop(idx=%d)=%s", j, trv?"true":"false");
        }
      }
  }




//+------------------------------------------------------------------+
//| //Indicators Module                                              |
//+------------------------------------------------------------------+
void IndicatorModule(void)
  {


   //Price action indicator
   //outputs "11" for Long position signal and "10" for Short position signal
   indicator_2 = pa.Open_Range_Breakout(); 


   // Moving Average indicator
   MA100.Init(_Symbol,PERIOD_CURRENT,100,0,MODE_SMA,PRICE_CLOSE); 
   double ma = MA100.Main(0); // get the value of the latest ma value wrt to latest candle
   iClose(_Symbol,_Period,1) > ma ? indicator_3 = true:indicator_3 = false; //compare the value with the candle

  }



//+------------------------------------------------------------------+
//| //Trade Execution Module                                          |
//+------------------------------------------------------------------+

void ExecuteOrders(void)

  {

//Buy/Sell Order: //Execute buy/sell orders given the indicators and user inputs if its enabled
   int final_signal = ResolveExecutionSignal();
   if(final_signal == 11 && LongPosition)
     {
      // 检查时间是否被禁止
      if(pa.IsTradingBlocked())
      {
         if(DebugPrint)
            Print("[GOLD_ORB DEBUG] 当前时间禁止交易");
         return;
      }


      if(DebugPrint)
         PrintFormat("[GOLD_ORB DEBUG] BUY signal. execute_trade=%s volume=%.2f SL_points=%d TP_points=%d macro_override=%s",execute_trade ? "true" : "false",TradeVolume,StopLoss,TakeProfit,macro_signal_available ? "true" : "false");
      tradevirtual.Buy(VTrade,_Symbol,TradeVolume,StopLoss,TakeProfit);
      if(execute_trade)//if this is false then the equity hits its maximum draw down as input by the user
         trade.Buy(_Symbol,TradeVolume,StopLoss,TakeProfit);
     }


   if(final_signal == 10 && ShortPosition)
     {
      if(DebugPrint)
         PrintFormat("[GOLD_ORB DEBUG] SELL signal. execute_trade=%s volume=%.2f SL_points=%d TP_points=%d macro_override=%s",execute_trade ? "true" : "false",TradeVolume,StopLoss,TakeProfit,macro_signal_available ? "true" : "false");
      tradevirtual.Sell(VTrade,_Symbol,TradeVolume,StopLoss,TakeProfit);
      if(execute_trade)//if this is false then the equity hits its maximum draw down as input by the user
         trade.Sell(_Symbol,TradeVolume,StopLoss,TakeProfit);

     }

  }


//+------------------------------------------------------------------+