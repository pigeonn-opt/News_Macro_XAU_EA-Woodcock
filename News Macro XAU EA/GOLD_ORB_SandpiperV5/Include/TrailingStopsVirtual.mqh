//+------------------------------------------------------------------+
//|                                            TradeStopsVirtual.mqh |
//|                                              Playground Inc 2021 |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Playground Inc 2021"
#property link      "https://www.mql5.com"
#property version   "1.00"



#include "errordescription.mqh"
#include "TradeVirtual.mqh"


//+------------------------------------------------------------------+
//| Trailing Stop Class                                              |
//+------------------------------------------------------------------+


//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
class CTrailingVirtual
  {
protected:
   MqlTradeRequest   request;

public:
   MqlTradeResult    result;



   bool              TrailingStop(VirtualTradeInfo &vTrade, int index,  int pTrailPoints, int pMinProfit = 0, int pStep = 10);
   bool              TrailingStop(VirtualTradeInfo &vTrade, int index,  double pTrailPrice, int pMinProfit = 0, int pStep = 10);
   bool              BreakEven(VirtualTradeInfo &vTrade, int index, int pBreakEven = 0, int pLockProfit = 0);


  };




// Trailing stop (points, hedging orders)
bool CTrailingVirtual::TrailingStop(VirtualTradeInfo &vTrade,int index, int pTrailPoints,int pMinProfit=0,int pStep=10)
  {
   if(pTrailPoints > 0)
     {
      if(DebugPrint) PrintFormat("[CTrailingVirtual] TrailingStop(idx=%d,pTrailPoints=%d,pMinProfit=%d,pStep=%d)", index, pTrailPoints, pMinProfit, pStep);


      string posType = vTrade.position[index].type;
      double currentStop = vTrade.position[index].sl;
      double openPrice = vTrade.position[index].price;
      string symbol = vTrade.position[index].symbol;

      double point = SymbolInfoDouble(symbol,SYMBOL_POINT);
      int digits = (int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);

      if(pStep < 10)
         pStep = 10;
      double step = pStep * point;

      double minProfit = pMinProfit * point;
      double trailStop = pTrailPoints * point;
      currentStop = NormalizeDouble(currentStop,digits);

      double trailStopPrice;
      double currentProfit;





      if(posType == "long")
        {
         trailStopPrice = SymbolInfoDouble(symbol,SYMBOL_BID) - trailStop;
         trailStopPrice = NormalizeDouble(trailStopPrice,digits);
         currentProfit = SymbolInfoDouble(symbol,SYMBOL_BID) - openPrice;

         if(trailStopPrice > currentStop + step && currentProfit >= minProfit)
           {
            vTrade.position[index].sl = trailStopPrice;
            vTrade.position[index].tp = 0;
            if(DebugPrint) PrintFormat("[CTrailingVirtual] BUY set SL idx=%d sl=%.5f tp=%.5f currentProfit=%.5f minProfit=%.5f", index, vTrade.position[index].sl, vTrade.position[index].tp, currentProfit, minProfit);
            return(true);
           }
         else
           if(DebugPrint) PrintFormat("[CTrailingVirtual] BUY no change idx=%d trailStopPrice=%.5f currentStop=%.5f currentProfit=%.5f minProfit=%.5f", index, trailStopPrice, currentStop, currentProfit, minProfit);
            return(false);


        }


      else
         if(posType == "short")
           {
            trailStopPrice = SymbolInfoDouble(symbol,SYMBOL_ASK) + trailStop;
            trailStopPrice = NormalizeDouble(trailStopPrice,digits);
            currentProfit = openPrice - SymbolInfoDouble(symbol,SYMBOL_ASK);

            if((trailStopPrice < currentStop - step || currentStop == 0) && currentProfit >= minProfit)
              {
               vTrade.position[index].sl = trailStopPrice;
               vTrade.position[index].tp = 0;
               if(DebugPrint) PrintFormat("[CTrailingVirtual] SELL set SL idx=%d sl=%.5f tp=%.5f currentProfit=%.5f minProfit=%.5f", index, vTrade.position[index].sl, vTrade.position[index].tp, currentProfit, minProfit);
               return(true);
              }
            else
               if(DebugPrint) PrintFormat("[CTrailingVirtual] SELL no change idx=%d trailStopPrice=%.5f currentStop=%.5f currentProfit=%.5f minProfit=%.5f", index, trailStopPrice, currentStop, currentProfit, minProfit);
               return(false);

           }
         else
            return(false);
     }

   else
      return(false);


  }


// Trailing stop (price, hedging orders)
bool CTrailingVirtual::TrailingStop(VirtualTradeInfo &vTrade,int index, double pTrailPrice,int pMinProfit=0,int pStep=10)
  {
   if(pTrailPrice > 0)
     {
      if(DebugPrint) PrintFormat("[CTrailingVirtual] TrailingStopPrice(idx=%d,pTrailPrice=%.5f,pMinProfit=%d,pStep=%d)", index, pTrailPrice, pMinProfit, pStep);


      long posType = PositionGetInteger(POSITION_TYPE);
      double currentStop = PositionGetDouble(POSITION_SL);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      string symbol = PositionGetString(POSITION_SYMBOL);

      double point = SymbolInfoDouble(symbol,SYMBOL_POINT);
      int digits = (int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);

      if(pStep < 10)
         pStep = 10;
      double step = pStep * point;
      double minProfit = pMinProfit * point;

      currentStop = NormalizeDouble(currentStop,digits);
      pTrailPrice = NormalizeDouble(pTrailPrice,digits);

      double currentProfit;
      double trailStopPrice =0.0;



      double bid = 0, ask = 0;



      if(posType == POSITION_TYPE_BUY)
        {
         bid = SymbolInfoDouble(symbol,SYMBOL_BID);
         currentProfit = bid - openPrice;
            if(pTrailPrice > currentStop + step && currentProfit >= minProfit)
              {
               vTrade.position[index].sl = trailStopPrice;
               if(DebugPrint) PrintFormat("[CTrailingVirtual] Price BUY set SL idx=%d sl=%.5f currentProfit=%.5f minProfit=%.5f", index, vTrade.position[index].sl, currentProfit, minProfit);
               return(true);
              }
            else
              {
               if(DebugPrint) PrintFormat("[CTrailingVirtual] Price BUY no change idx=%d pTrailPrice=%.5f currentStop=%.5f currentProfit=%.5f minProfit=%.5f", index, pTrailPrice, currentStop, currentProfit, minProfit);
               return(false);
              }
        }
      else
         if(posType == POSITION_TYPE_SELL)
           {
            ask = SymbolInfoDouble(symbol,SYMBOL_ASK);
            currentProfit = openPrice - ask;
            if((pTrailPrice < currentStop - step || currentStop == 0) && currentProfit >= minProfit)
              {
               vTrade.position[index].sl = trailStopPrice;
                 if(DebugPrint) PrintFormat("[CTrailingVirtual] Price SELL set SL idx=%d sl=%.5f currentProfit=%.5f minProfit=%.5f", index, vTrade.position[index].sl, currentProfit, minProfit);
               return(true);
              }
            else
                 if(DebugPrint) PrintFormat("[CTrailingVirtual] Price SELL no change idx=%d pTrailPrice=%.5f currentStop=%.5f currentProfit=%.5f minProfit=%.5f", index, pTrailPrice, currentStop, currentProfit, minProfit);
                 return(false);
           }



         else
            return(false);

     }
   else
      return(false);
  }


// Break even stop for virtual positions
bool CTrailingVirtual::BreakEven(VirtualTradeInfo &vTrade, int index, int pBreakEven, int pLockProfit)
  {
   if(pBreakEven > 0 && index >= 0 && index < ArraySize(vTrade.position))
     {
      string posType = vTrade.position[index].type;
      double currentSL = vTrade.position[index].sl;
      double openPrice = vTrade.position[index].price;
      string symbol = vTrade.position[index].symbol;

      double point = SymbolInfoDouble(symbol,SYMBOL_POINT);
      int digits = (int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);

      double breakEvenStop;
      double currentProfit;

      if(posType == "long")
        {
         breakEvenStop = openPrice + (pLockProfit * point);
         currentProfit = SymbolInfoDouble(symbol,SYMBOL_BID) - openPrice;
         breakEvenStop = NormalizeDouble(breakEvenStop, digits);
         currentProfit = NormalizeDouble(currentProfit, digits);

         if((currentSL < breakEvenStop || currentSL == 0) && currentProfit >= pBreakEven * point)
           {
            vTrade.position[index].sl = breakEvenStop;
            return(true);
           }
         else
            return(false);
        }
      else if(posType == "short")
        {
         breakEvenStop = openPrice - (pLockProfit * point);
         currentProfit = openPrice - SymbolInfoDouble(symbol,SYMBOL_ASK);
         breakEvenStop = NormalizeDouble(breakEvenStop, digits);
         currentProfit = NormalizeDouble(currentProfit, digits);

         if((currentSL > breakEvenStop || currentSL == 0) && currentProfit >= pBreakEven * point)
           {
            vTrade.position[index].sl = breakEvenStop;
            return(true);
           }
         else
            return(false);
        }
      else
         return(false);
     }
   return(false);
  }




//+------------------------------------------------------------------+

//+------------------------------------------------------------------+



//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
