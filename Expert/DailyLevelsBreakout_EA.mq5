//+------------------------------------------------------------------+
//|                                      DailyLevelsBreakout_EA.mq5  |
//|  Dynamic Daily High/Low breakout EA                              |
//|  - 3 level-detection methods (per spec)                          |
//|  - Breakout quality / range / origin entry filters               |
//|  - Trade 1 @ RR 1:2, Trade 2 (only after SL) @ RR 1:4            |
//|  - Max 2 trades per day, halt after TP or after trade 2          |
//+------------------------------------------------------------------+
#property copyright  "Custom EA"
#property version    "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Detection method enum
enum ENUM_DETECTION_METHOD
  {
   METHOD_1 = 1,   // Method 1: Base High/Low of lookback window
   METHOD_2 = 2,   // Method 2: Base + confirmation-candle update
   METHOD_3 = 3    // Method 3: Reference candle High/Low
  };

//--- Update mode for Method 2 (single mode per spec, enum kept for extensibility)
enum ENUM_UPDATE_MODE
  {
   UPDATE_MAIN_HL = 0  // Update Main High and Low
  };

//=== Inputs =========================================================
input group "=== Daily Level Detection ==="
input int                    InpRefHour          = 10;         // Reference Time - Hour (chart/server time)
input int                    InpRefMinute        = 0;          // Reference Time - Minute
input int                    InpLookbackN        = 15;         // Lookback Candles 'N'
input int                    InpUpdateX          = 3;          // Update Candle Threshold 'X' (Method 2)
input ENUM_DETECTION_METHOD  InpMethod           = METHOD_1;   // Detection Method
input ENUM_UPDATE_MODE       InpUpdateMode       = UPDATE_MAIN_HL; // Update Mode (Method 2)

input group "=== Trade Execution ==="
input double                 InpSLBufferPoints   = 50.0;       // SL Buffer (points)
input double                 InpTPBufferPoints   = 50.0;       // TP Buffer (points)
input bool                   InpUseRiskPercent   = true;       // Use risk % sizing (else fixed lot)
input double                 InpRiskPercent      = 0.2;        // Risk % of balance per trade
input double                 InpFixedLot         = 0.10;       // Fixed lot size
input ulong                  InpMagic            = 20260729;   // Magic number
input int                    InpSlippagePoints   = 20;         // Max slippage (points)

input group "=== Display ==="
input bool                   InpDrawLevels          = true;           // Draw daily levels on chart
input color                  InpHighColor           = clrTomato;      // Defined High color
input color                  InpLowColor            = clrDeepSkyBlue; // Defined Low color
input color                  InpReferenceLineColor  = clrDodgerBlue;  // Defined Low color
input ENUM_LINE_STYLE        InpLineStyle           = STYLE_DOT;      // High and Low line style
input ENUM_LINE_STYLE        InpReferenceLineStyle  = STYLE_DOT;      // Reference Time Verical line style

//=== Globals ========================================================
CTrade    g_trade;

double    g_definedHigh   = 0.0;
double    g_definedLow    = 0.0;
bool      g_levelsSet     = false;
datetime  g_levelsDay     = 0;      // date (00:00) the current levels belong to
datetime  g_refBarTime    = 0;      // open time of the reference candle
datetime  g_lineStartTime = 0;      // where the H/L lines begin (before reference time)

int       g_tradesToday   = 0;      // trades opened today
bool      g_trade1HitSL   = false;  // true -> trade 2 permitted (RR 1:4)
bool      g_haltTrading   = false;  // hard stop until next day's reference time

datetime  g_lastBarTime   = 0;

const string OBJ_PREFIX = "DLB_";

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   Print("DailyLevelsBreakout_EA.OnInit()");

   if(InpRefHour < 0 || InpRefHour > 23 || InpRefMinute < 0 || InpRefMinute > 59)
     {
      Print("Invalid Reference Time.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpLookbackN < 1)
     {
      Print("Lookback Candles 'N' must be >= 1.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpUpdateX < 1)
     {
      Print("Update Threshold 'X' must be >= 1.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   UpdateDailyLevels();     // compute today's levels immediately on attach
   g_lastBarTime = 0;       // force the first incoming tick to run the full new-bar logic

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Deinitialization                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, OBJ_PREFIX);
  }

//+------------------------------------------------------------------+
//| Main tick handler - all logic runs on new-bar events             |
//+------------------------------------------------------------------+
void OnTick()
  {
//--- every tick: detect trade close (TP/SL) so lines are removed instantly
   if(g_levelsSet && !g_haltTrading && g_tradesToday > 0)
      UpdateTradeState();

   if(!IsNewBar())
      return;

   UpdateDailyLevels();

   if(g_levelsSet && !g_haltTrading)
      CheckEntrySignal();
  }

//+------------------------------------------------------------------+
//| New bar detection                                                |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t = iTime(_Symbol, _Period, 0);
   if(t == g_lastBarTime)
      return(false);
   g_lastBarTime = t;
   return(true);
  }

//+------------------------------------------------------------------+
//| Part 1: compute daily Defined High / Low                         |
//+------------------------------------------------------------------+
void UpdateDailyLevels()
  {
   datetime now = TimeCurrent();

//--- build today's reference timestamp
   MqlDateTime dt;
   TimeToStruct(now, dt);
   dt.hour = InpRefHour;
   dt.min  = InpRefMinute;
   dt.sec  = 0;
   datetime refTime  = StructToTime(dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   datetime dayStart = StructToTime(dt);

   if(now < refTime)          // reference time not yet reached today
      return;
   if(g_levelsDay == dayStart) // already computed for today
      return;

//--- Step 1: reference candle = candle whose open time == or immediately precedes refTime
   int refShift = iBarShift(_Symbol, _Period, refTime, false);
   if(refShift < 0)
      return;

//--- Method 3 uses the reference candle's own H/L -> wait until it has closed
   if(InpMethod == METHOD_3 && refShift == 0)
      return;

//--- ensure enough history for the lookback window
   if(Bars(_Symbol, _Period) < refShift + InpLookbackN + 2)
      return;

   double newHigh = 0.0, newLow = 0.0;

   if(InpMethod == METHOD_3)
     {
      //--- Method 3: reference candle High / Low, terminate
      newHigh = iHigh(_Symbol, _Period, refShift);
      newLow  = iLow(_Symbol, _Period, refShift);
     }
   else
     {
      //--- Lookback window: N completed candles BEFORE the reference candle
      //    shifts refShift+1 (newest in window) .. refShift+N (oldest in window)
      int winStart = refShift + 1;

      int highShift = iHighest(_Symbol, _Period, MODE_HIGH, InpLookbackN, winStart);
      int lowShift = iLowest(_Symbol, _Period, MODE_LOW,  InpLookbackN, winStart);
      if(highShift < 0 || lowShift < 0)
         return;

      double baseHigh = iHigh(_Symbol, _Period, highShift);
      double baseLow  = iLow(_Symbol, _Period, lowShift);
      newHigh = baseHigh;
      newLow  = baseLow;

      //      if(InpMethod == METHOD_2 && InpUpdateMode == UPDATE_MAIN_HL)
      //        {
      //         //--- Check 1: candles AFTER the Base High candle -> possible Updated Low
      //         //    (shifts winStart .. hiShift-1 are newer than the base-high candle)
      //         int countAfterHigh = highShift - winStart;
      //         if(countAfterHigh > 0)
      //           {
      //            int bearish = 0;
      //            for(int s = winStart; s < highShift; s++)
      //               if(iClose(_Symbol, _Period, s) < iOpen(_Symbol, _Period, s))
      //                  bearish++;
      //            if(bearish >= InpUpdateX)
      //              {
      //               int updatedLowShift = iLowest(_Symbol, _Period, MODE_LOW, countAfterHigh, winStart);
      //               if(updatedLowShift >= 0)
      //                  newLow = iLow(_Symbol, _Period, updatedLowShift);   // Updated Low
      //              }
      //           }
      //
      //         //--- Check 2: candles AFTER the Base Low candle -> possible Updated High
      //         int countAfterLow = lowShift - winStart;
      //         if(countAfterLow > 0)
      //           {
      //            int bullish = 0;
      //            for(int s = winStart; s < lowShift; s++)
      //               if(iClose(_Symbol, _Period, s) > iOpen(_Symbol, _Period, s))
      //                  bullish++;
      //            if(bullish >= InpUpdateX)
      //              {
      //               int updatedHighShift = iHighest(_Symbol, _Period, MODE_HIGH, countAfterLow, winStart);
      //               if(updatedHighShift >= 0)
      //                  newHigh = iHigh(_Symbol, _Period, updatedHighShift); // Updated High
      //              }
      //           }
      //        }

      if(InpMethod == METHOD_2 && InpUpdateMode == UPDATE_MAIN_HL)
        {
         if(highShift < lowShift)
           {
            //--- High occurred AFTER Low -> check for Updated Low
            //    include the High candle ITSELF in the bearish count
            //    (shifts winStart .. highShift, i.e. High candle and everything after it)
            int countFromHigh = highShift - winStart + 1;

            int bearish = 0;
            for(int s = winStart; s <= highShift; s++)          // <= includes the High candle
               if(iClose(_Symbol, _Period, s) < iOpen(_Symbol, _Period, s))
                  bearish++;

            if(bearish >= InpUpdateX)
              {
               int updatedLowShift = iLowest(_Symbol, _Period, MODE_LOW, countFromHigh, winStart);
               if(updatedLowShift >= 0)
                  newLow = iLow(_Symbol, _Period, updatedLowShift);   // Updated Low
              }
           }
         else
            if(lowShift < highShift)
              {
               //--- Low occurred AFTER High -> check for Updated High
               //    include the Low candle ITSELF in the bullish count
               int countFromLow = lowShift - winStart + 1;

               int bullish = 0;
               for(int s = winStart; s <= lowShift; s++)           // <= includes the Low candle
                  if(iClose(_Symbol, _Period, s) > iOpen(_Symbol, _Period, s))
                     bullish++;

               if(bullish >= InpUpdateX)
                 {
                  int updatedHighShift = iHighest(_Symbol, _Period, MODE_HIGH, countFromLow, winStart);
                  if(updatedHighShift >= 0)
                     newHigh = iHigh(_Symbol, _Period, updatedHighShift); // Updated High
                 }
              }
        }
     }

   if(newHigh <= newLow)
     {
      PrintFormat("Level calculation rejected: High (%.5f) <= Low (%.5f)", newHigh, newLow);
      return;
     }

//--- commit levels + reset daily trade state
   g_definedHigh = newHigh;
   g_definedLow  = newLow;
   g_levelsSet   = true;
   g_levelsDay   = dayStart;
   g_refBarTime  = iTime(_Symbol, _Period, refShift);

//--- lines start BEFORE the reference time: at the beginning of the
//    lookback window (Methods 1/2) or at the reference candle (Method 3)
   if(InpMethod == METHOD_3)
      g_lineStartTime = g_refBarTime;
   else
      g_lineStartTime = iTime(_Symbol, _Period, refShift + InpLookbackN);

   g_tradesToday = 0;
   g_trade1HitSL = false;
   g_haltTrading = false;

   PrintFormat("[%s] Daily levels set (Method %d): High=%.5f  Low=%.5f",
               TimeToString(dayStart, TIME_DATE), (int)InpMethod, g_definedHigh, g_definedLow);

   if(InpDrawLevels)
      DrawLevelLines(dayStart);
  }

//+------------------------------------------------------------------+
//| Part 2 + 3: entry signal check on the just-closed candle         |
//| Candle 1 = breakout candle (just closed)                         |
//| Candle 2 = candle preceding the breakout candle                  |
//| Candle 0 = current candle -> market entry at its open            |
//+------------------------------------------------------------------+
void CheckEntrySignal()
  {
//--- refresh trade state from position/history first
   UpdateTradeState();
   if(g_haltTrading)
      return;

//--- never stack positions; wait until the open trade closes
   if(HasOpenPosition())
      return;

//--- breakout candle must have formed AFTER the reference candle
   datetime c1time = iTime(_Symbol, _Period, 1);
   if(c1time <= g_refBarTime)
      return;

   double o1 = iOpen(_Symbol, _Period, 1);
   double h1 = iHigh(_Symbol, _Period, 1);
   double l1 = iLow(_Symbol, _Period, 1);
   double c1 = iClose(_Symbol, _Period, 1);

   double rangeCandle = h1 - l1;
   double rangeLevels = g_definedHigh - g_definedLow;

//--- shared conditions 2 & 3
   bool rangeOK  = (rangeCandle < rangeLevels);
   bool originOK = (o1 >= g_definedLow && o1 <= g_definedHigh);
   if(!rangeOK || !originOK)
      return;

//--- BUY condition 1: close above Defined High, body-above-line > upper wick
   bool buySignal  = (c1 > g_definedHigh) &&
                     ((c1 - g_definedHigh) > (h1 - c1));

//--- SELL condition 1: close below Defined Low, body-below-line > lower wick
   bool sellSignal = (c1 < g_definedLow) &&
                     ((g_definedLow - c1) > (c1 - l1));

   if(!buySignal && !sellSignal)
      return;

//--- which trade slot is this?
   if(g_tradesToday >= 2)
     {
      g_haltTrading = true;
      return;
     }
   if(g_tradesToday == 1 && !g_trade1HitSL)
     {
      // Trade 1 hit TP (or closed otherwise without SL) -> no more trades today
      g_haltTrading = true;
      return;
     }

   double rr = (g_tradesToday == 0) ? 2.0 : 4.0;   // Trade 1 -> 1:2, Trade 2 -> 1:4

   if(buySignal)
      ExecuteTrade(ORDER_TYPE_BUY, rr);
   else
      ExecuteTrade(ORDER_TYPE_SELL, rr);
  }

//+------------------------------------------------------------------+
//| Part 3: execute market order at open of the new candle           |
//+------------------------------------------------------------------+
void ExecuteTrade(const ENUM_ORDER_TYPE type, const double rr)
  {
   double point    = _Point;
   double slBuf    = InpSLBufferPoints * point;
   double tpBuf    = InpTPBufferPoints * point;

//--- Candle 2 = candle preceding the breakout candle
   double c2high = iHigh(_Symbol, _Period, 2);
   double c2low  = iLow(_Symbol, _Period, 2);

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   double entry, sl, tp;

   if(type == ORDER_TYPE_BUY)
     {
      entry = tick.ask;
      sl    = c2low - slBuf;
      if(entry - sl <= 0)
        {
         Print("BUY rejected: SL not below entry.");
         return;
        }
      tp = entry + ((entry - sl) * rr) - tpBuf;
      if(tp <= entry)
        {
         Print("BUY rejected: TP_Buffer collapses TP below entry.");
         return;
        }
     }
   else
     {
      entry = tick.bid;
      sl    = c2high + slBuf;
      if(sl - entry <= 0)
        {
         Print("SELL rejected: SL not above entry.");
         return;
        }
      tp = entry - ((sl - entry) * rr) + tpBuf;
      if(tp >= entry)
        {
         Print("SELL rejected: TP_Buffer collapses TP above entry.");
         return;
        }
     }

   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

//--- respect broker minimum stop distance
   double stopLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   if(MathAbs(entry - sl) < stopLevel || MathAbs(tp - entry) < stopLevel)
     {
      Print("Trade rejected: SL/TP inside broker minimum stop distance.");
      return;
     }

   double lots = CalcLots(MathAbs(entry - sl));
   if(lots <= 0)
     {
      Print("Trade rejected: lot size calculation failed.");
      return;
     }

   string comment = StringFormat(
                       "DLB (%02d:%02d) T%d RR1:%.0f",
                       InpRefHour,
                       InpRefMinute,
                       g_tradesToday + 1,
                       rr
                    );

   bool ok = (type == ORDER_TYPE_BUY)
             ? g_trade.Buy(lots, _Symbol, 0.0, sl, tp, comment)
             : g_trade.Sell(lots, _Symbol, 0.0, sl, tp, comment);

   if(ok)
     {
      g_tradesToday++;
      PrintFormat("Trade %d opened: %s  lots=%.2f  SL=%.5f  TP=%.5f (RR 1:%.0f)",
                  g_tradesToday, (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), lots, sl, tp, rr);
     }
   else
      PrintFormat("Order failed: %d - %s", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| Part 4: track closed trades -> SL/TP outcome & daily halt        |
//+------------------------------------------------------------------+
void UpdateTradeState()
  {
   if(g_tradesToday == 0 || HasOpenPosition())
      return;   // nothing opened yet, or trade still running

//--- last trade of the day has closed; determine outcome
   if(!HistorySelect(g_levelsDay, TimeCurrent() + 60))
      return;

   int    deals   = HistoryDealsTotal();
   long   lastReason = -1;
   for(int i = deals - 1; i >= 0; i--)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol)
         continue;
      if((ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagic)
         continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;
      lastReason = HistoryDealGetInteger(ticket, DEAL_REASON);
      break;
     }
   if(lastReason < 0)
      return;

   if(g_tradesToday == 1)
     {
      if(lastReason == DEAL_REASON_SL)
        {
         if(!g_trade1HitSL)
           {
            g_trade1HitSL = true;   // Trade 2 permitted, RR 1:4
            Print("Trade 1 hit SL -> one more trade allowed today (RR 1:4).");
           }
        }
      else
         if(lastReason == DEAL_REASON_TP)
           {
            g_haltTrading = true;      // TP -> done for the day
            RemoveLevelLines();
            Print("Trade 1 hit TP -> trading halted, lines removed.");
           }
         else
           {
            // manual close / other: treat conservatively as end of day
            g_haltTrading = true;
            RemoveLevelLines();
            Print("Trade 1 closed (non-SL/TP) -> trading halted, lines removed.");
           }
     }
   else
      if(g_tradesToday >= 2)
        {
         g_haltTrading = true;         // Trade 2 closed either way -> halt
         RemoveLevelLines();
         Print("Trade 2 closed -> trading halted, lines removed.");
        }
  }

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic)
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double CalcLots(const double slDistance)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   double lots = InpFixedLot;

   if(InpUseRiskPercent)
     {
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickValue <= 0 || tickSize <= 0 || slDistance <= 0)
         return(0.0);
      double riskMoney    = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
      double lossPerLot   = (slDistance / tickSize) * tickValue;
      if(lossPerLot <= 0)
         return(0.0);
      lots = riskMoney / lossPerLot;
     }

   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   return(NormalizeDouble(lots, 2));
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void RemoveLevelLines()
  {
   ObjectsDeleteAll(0, OBJ_PREFIX);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void DrawLevelLines(const datetime dayStart)
  {
   string dayTag = TimeToString(dayStart, TIME_DATE);
   string highName = OBJ_PREFIX + "high_" + dayTag;
   string lowName = OBJ_PREFIX + "low_"  + dayTag;
   datetime dayEnd = dayStart + 86400;

   ObjectsDeleteAll(0, OBJ_PREFIX);   // keep only the current day's lines

//--- vertical line at Reference Time
   string referenceTimeName = OBJ_PREFIX + "RefTime_" + dayTag;

   ObjectCreate(0, referenceTimeName, OBJ_VLINE, 0, g_refBarTime, 0);
   ObjectSetInteger(0, referenceTimeName, OBJPROP_COLOR, InpReferenceLineColor);
   ObjectSetInteger(0, referenceTimeName, OBJPROP_STYLE, InpReferenceLineStyle);
   ObjectSetInteger(0, referenceTimeName, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, referenceTimeName, OBJPROP_BACK, true);          // draw behind candles
   ObjectSetInteger(0, referenceTimeName, OBJPROP_SELECTABLE, false);

   ObjectCreate(0, highName, OBJ_TREND, 0, g_lineStartTime, g_definedHigh, dayEnd, g_definedHigh);
   ObjectSetInteger(0, highName, OBJPROP_COLOR, InpHighColor);
   ObjectSetInteger(0, highName, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, highName, OBJPROP_STYLE, InpLineStyle);
   ObjectSetInteger(0, highName, OBJPROP_RAY_RIGHT, false);

   ObjectCreate(0, lowName, OBJ_TREND, 0, g_lineStartTime, g_definedLow, dayEnd, g_definedLow);
   ObjectSetInteger(0, lowName, OBJPROP_COLOR, InpLowColor);
   ObjectSetInteger(0, lowName, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, lowName, OBJPROP_STYLE, InpLineStyle);
   ObjectSetInteger(0, lowName, OBJPROP_RAY_RIGHT, false);

   ChartRedraw(0);
  }
//+------------------------------------------------------------------+
