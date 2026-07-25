//+------------------------------------------------------------------+
//|                                        PinBarTrendSignals.mq5     |
//|            Pin Bar Reversal Signal Indicator (Entry / SL / TP)    |
//|                                                                   |
//|  Draws, for the last N detected setups, the Entry, Stop Loss and  |
//|  Take Profit levels using the same logic as the PinBar EA:        |
//|                                                                   |
//|   Uptrend  : bearish Pin Bar + bullish confirm (High > Pin High)  |
//|              -> BUY.  Entry = confirm close, SL = Pin low,        |
//|                 TP = Entry + SLdist * RewardRatio.                |
//|   Downtrend: bullish Pin Bar + bearish confirm (Low < Pin Low)    |
//|              -> SELL. Entry = confirm close, SL = Pin high,       |
//|                 TP = Entry - SLdist * RewardRatio.                |
//|                                                                   |
//|  Each signal is rendered as three horizontal segments (Entry/SL/  |
//|  TP) plus a marker arrow and a text label on the chart.           |
//+------------------------------------------------------------------+
#property copyright "PinBarTrendSignals"
#property version   "1.00"
#property strict
#property indicator_chart_window
#property indicator_plots   0
#property indicator_buffers 0

//====================================================================
//  INPUT PARAMETERS
//====================================================================
input group    "=== Display ==="
input int      MaxSignals          = 100;          // How many recent signals to show
input int      SegmentBars         = 12;           // Length of each level line (bars to the right)
input bool     ShowLabels          = true;         // Show Entry/SL/TP text + R:R
input bool     ShowArrows          = true;         // Show entry direction arrows

input group    "=== Colours ==="
input color    BuyArrowColor       = clrDodgerBlue;// Buy marker colour
input color    SellArrowColor      = clrOrangeRed; // Sell marker colour
input color    EntryColor          = clrGold;      // Entry line colour
input color    SLColor             = clrRed;       // Stop Loss line colour
input color    TPColor             = clrLimeGreen; // Take Profit line colour
input int      LineWidth           = 2;            // Level line width

input group    "=== Risk / Reward ==="
input double   RewardRatio         = 1.0;          // Risk : Reward ratio (TP = SL * this)
input int      SL_BufferPoints     = 5;            // Extra buffer beyond Pin high/low for SL (points)

input group    "=== Pin Bar Definition ==="
input double   MinWickBodyRatio    = 2.0;          // Min wick-to-body ratio (wick >= ratio * body)
input double   MaxBodyToRangeRatio = 0.34;         // Max body size as fraction of full candle range
input double   MinOppositeWickPct  = 0.0;          // Max opposite wick as fraction of range (0 = disabled)

input group    "=== Trend Filter ==="
input bool     UseTrendFilter      = true;         // Enable swing-structure trend filter
input int      SwingLookback       = 3;            // Bars each side to confirm a swing (fractal)
input int      SwingCount          = 2;            // Recent swings compared for HH/HL, LH/LL

//====================================================================
//  GLOBAL STATE
//====================================================================
string   g_prefix = "PBSIG_";   // Unique object-name prefix for this indicator
double   g_point;               // Symbol point size
int      g_digits;              // Symbol digits

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   IndicatorSetString(INDICATOR_SHORTNAME, "PinBar Signals (E/SL/TP)");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Custom indicator deinitialization function                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   // Remove all objects created by this indicator.
   ObjectsDeleteAll(0, g_prefix);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Custom indicator iteration function                              |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   // Only rebuild when the number of bars changes (new bar / history load).
   // This keeps the indicator light and avoids per-tick redrawing.
   static int lastBars = 0;
   if(rates_total == lastBars)
      return(rates_total);
   lastBars = rates_total;

   // Clear previous drawings before re-scanning history.
   ObjectsDeleteAll(0, g_prefix);

   // Ensure the series arrays are indexed as time-series (0 = current).
   ArraySetAsSeries(time,  true);
   ArraySetAsSeries(open,  true);
   ArraySetAsSeries(high,  true);
   ArraySetAsSeries(low,   true);
   ArraySetAsSeries(close, true);

   ScanAndDrawSignals(rates_total, time, open, high, low, close);

   ChartRedraw();
   return(rates_total);
  }

//+------------------------------------------------------------------+
//| Scan history for setups and draw the most recent MaxSignals.     |
//|                                                                  |
//|  For a signal evaluated at a given bar:                          |
//|    pinShift  = bar + 1  (Pin Bar candle)                         |
//|    confShift = bar      (confirmation candle, closed after Pin)  |
//|  We iterate 'bar' from oldest to newest so labels stack in time. |
//+------------------------------------------------------------------+
void ScanAndDrawSignals(const int rates_total,
                        const datetime &time[],
                        const double &open[],
                        const double &high[],
                        const double &low[],
                        const double &close[])
  {
   // We need room for the trend filter behind the Pin Bar.
   int minBehind = UseTrendFilter ? (SwingLookback * 2 + SwingCount * 3 + 6) : 3;

   // Collect signals first (so we can keep only the last MaxSignals).
   // Arrays are parallel; index grows with each detected signal.
   int      sigDir[];      // +1 buy, -1 sell
   datetime sigTime[];     // confirmation candle time (anchor)
   double   sigEntry[];    // entry price
   double   sigSL[];       // stop loss price
   double   sigTP[];       // take profit price
   ArrayResize(sigDir, 0); ArrayResize(sigTime, 0);
   ArrayResize(sigEntry, 0); ArrayResize(sigSL, 0); ArrayResize(sigTP, 0);

   double buffer = SL_BufferPoints * g_point;

   // confShift = 'bar'; start from the oldest usable bar up to shift 1.
   int oldest = rates_total - 1 - minBehind;   // deepest confirmation bar
   for(int bar = oldest; bar >= 1; bar--)
     {
      int pinShift  = bar + 1;
      int confShift = bar;
      if(pinShift >= rates_total)
         continue;

      double pinO = open[pinShift],  pinH = high[pinShift];
      double pinL = low[pinShift],   pinC = close[pinShift];
      double cO   = open[confShift], cH   = high[confShift];
      double cL   = low[confShift],  cC   = close[confShift];

      // Trend evaluated relative to the Pin Bar (structure to its left).
      int trend = GetTrend(pinShift, rates_total, high, low);

      //--- Bullish setup: bearish Pin Bar + bullish confirmation ---
      if((!UseTrendFilter || trend > 0) &&
         IsBearishPinBar(pinO, pinH, pinL, pinC))
        {
         bool confBull = (cC > cO);
         if(confBull && cH > pinH)
           {
            double entry = cC;                    // confirmation close as entry
            double sl    = pinL - buffer;
            double dist  = entry - sl;
            if(dist > 0)
              {
               double tp = entry + dist * RewardRatio;
               AppendSignal(sigDir, sigTime, sigEntry, sigSL, sigTP,
                            +1, time[confShift], entry, sl, tp);
               continue; // one signal per bar
              }
           }
        }

      //--- Bearish setup: bullish Pin Bar + bearish confirmation ---
      if((!UseTrendFilter || trend < 0) &&
         IsBullishPinBar(pinO, pinH, pinL, pinC))
        {
         bool confBear = (cC < cO);
         if(confBear && cL < pinL)
           {
            double entry = cC;
            double sl    = pinH + buffer;
            double dist  = sl - entry;
            if(dist > 0)
              {
               double tp = entry - dist * RewardRatio;
               AppendSignal(sigDir, sigTime, sigEntry, sigSL, sigTP,
                            -1, time[confShift], entry, sl, tp);
              }
           }
        }
     }

   // Keep only the most recent MaxSignals entries.
   int total = ArraySize(sigDir);
   int start = (total > MaxSignals) ? total - MaxSignals : 0;

   for(int i = start; i < total; i++)
      DrawSignal(i, sigDir[i], sigTime[i], sigEntry[i], sigSL[i], sigTP[i],
                 time, rates_total);
  }

//+------------------------------------------------------------------+
//| Append one detected signal to the parallel arrays                |
//+------------------------------------------------------------------+
void AppendSignal(int &dir[], datetime &t[], double &e[], double &sl[], double &tp[],
                  int d, datetime tm, double entry, double slp, double tpp)
  {
   int n = ArraySize(dir);
   ArrayResize(dir, n + 1); ArrayResize(t, n + 1);
   ArrayResize(e, n + 1);   ArrayResize(sl, n + 1); ArrayResize(tp, n + 1);
   dir[n] = d; t[n] = tm; e[n] = entry; sl[n] = slp; tp[n] = tpp;
  }

//+------------------------------------------------------------------+
//| Draw one signal: Entry / SL / TP segments + arrow + label        |
//+------------------------------------------------------------------+
void DrawSignal(int id, int dir, datetime anchorTime,
                double entry, double sl, double tp,
                const datetime &time[], const int rates_total)
  {
   // Find the bar index of the anchor (confirmation) time.
   int shift = iBarShiftByTime(time, rates_total, anchorTime);
   if(shift < 0)
      return;

   // End time = SegmentBars to the RIGHT of the anchor (towards "now").
   int endShift = MathMax(shift - SegmentBars, 0);
   datetime tEnd = time[endShift];
   // If the segment would collapse, extend one bar into the future.
   if(tEnd <= anchorTime)
      tEnd = anchorTime + PeriodSeconds(_Period) * SegmentBars;

   string tag = g_prefix + (string)id + "_";

   // --- Three horizontal level segments (trend lines) ---
   DrawSegment(tag + "E",  anchorTime, entry, tEnd, entry, EntryColor);
   DrawSegment(tag + "SL", anchorTime, sl,    tEnd, sl,    SLColor);
   DrawSegment(tag + "TP", anchorTime, tp,    tEnd, tp,    TPColor);

   // --- Entry direction arrow at the anchor candle ---
   if(ShowArrows)
     {
      string an = tag + "arrow";
      // Wingdings arrows: 233 = up arrow, 234 = down arrow.
      int    code  = (dir > 0) ? 233 : 234;
      color  acol  = (dir > 0) ? BuyArrowColor : SellArrowColor;
      double aprice= entry;
      if(ObjectCreate(0, an, OBJ_ARROW, 0, anchorTime, aprice))
        {
         ObjectSetInteger(0, an, OBJPROP_ARROWCODE, code);
         ObjectSetInteger(0, an, OBJPROP_COLOR, acol);
         ObjectSetInteger(0, an, OBJPROP_WIDTH, 2);
         ObjectSetInteger(0, an, OBJPROP_ANCHOR,
                          (dir > 0) ? ANCHOR_TOP : ANCHOR_BOTTOM);
         ObjectSetInteger(0, an, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, an, OBJPROP_HIDDEN, true);
        }
     }

   // --- Text labels for each level ---
   if(ShowLabels)
     {
      string side = (dir > 0) ? "BUY" : "SELL";
      double rr   = RewardRatio;
      DrawText(tag + "tE",  tEnd, entry, StringFormat("%s Entry %s", side,
                                          DoubleToString(entry, g_digits)), EntryColor);
      DrawText(tag + "tSL", tEnd, sl,    "SL " + DoubleToString(sl, g_digits), SLColor);
      DrawText(tag + "tTP", tEnd, tp,    StringFormat("TP %s (1:%.1f)",
                                          DoubleToString(tp, g_digits), rr), TPColor);
     }
  }

//+------------------------------------------------------------------+
//| Draw a horizontal-ish trend-line segment between two points      |
//+------------------------------------------------------------------+
void DrawSegment(string name, datetime t1, double p1, datetime t2, double p2, color col)
  {
   if(ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2))
     {
      ObjectSetInteger(0, name, OBJPROP_COLOR, col);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, LineWidth);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
     }
  }

//+------------------------------------------------------------------+
//| Draw a small text label anchored to the left at (time, price)    |
//+------------------------------------------------------------------+
void DrawText(string name, datetime t, double price, string txt, color col)
  {
   if(ObjectCreate(0, name, OBJ_TEXT, 0, t, price))
     {
      ObjectSetString (0, name, OBJPROP_TEXT, txt);
      ObjectSetInteger(0, name, OBJPROP_COLOR, col);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
      ObjectSetString (0, name, OBJPROP_FONT, "Arial");
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
  }

//+------------------------------------------------------------------+
//| Find the bar shift for a given time in the series 'time[]'       |
//|   Returns -1 if not found.                                       |
//+------------------------------------------------------------------+
int iBarShiftByTime(const datetime &time[], const int rates_total, datetime t)
  {
   for(int i = 0; i < rates_total; i++)
      if(time[i] == t)
         return(i);
   return(-1);
  }

//+------------------------------------------------------------------+
//| Bearish Pin Bar test (long UPPER wick, small body) -> BUY setup  |
//+------------------------------------------------------------------+
bool IsBearishPinBar(double o, double h, double l, double c)
  {
   double range = h - l;
   if(range <= 0.0) return(false);

   double body      = MathAbs(c - o);
   double bodyHigh  = MathMax(o, c);
   double bodyLow   = MathMin(o, c);
   double upperWick = h - bodyHigh;
   double lowerWick = bodyLow - l;

   if(body > range * MaxBodyToRangeRatio)      return(false);
   if(upperWick < body * MinWickBodyRatio)     return(false);
   if(upperWick <= lowerWick)                  return(false);
   if(MinOppositeWickPct > 0.0 && lowerWick > range * MinOppositeWickPct)
      return(false);
   return(true);
  }

//+------------------------------------------------------------------+
//| Bullish Pin Bar test (long LOWER wick, small body) -> SELL setup |
//+------------------------------------------------------------------+
bool IsBullishPinBar(double o, double h, double l, double c)
  {
   double range = h - l;
   if(range <= 0.0) return(false);

   double body      = MathAbs(c - o);
   double bodyHigh  = MathMax(o, c);
   double bodyLow   = MathMin(o, c);
   double upperWick = h - bodyHigh;
   double lowerWick = bodyLow - l;

   if(body > range * MaxBodyToRangeRatio)      return(false);
   if(lowerWick < body * MinWickBodyRatio)     return(false);
   if(lowerWick <= upperWick)                  return(false);
   if(MinOppositeWickPct > 0.0 && upperWick > range * MinOppositeWickPct)
      return(false);
   return(true);
  }

//+------------------------------------------------------------------+
//| Trend detection via swing structure (fractal swings)             |
//|   fromShift : evaluate structure OLDER than this bar (to left).  |
//|   Returns +1 up (HH & HL), -1 down (LH & LL), 0 no clear trend.  |
//+------------------------------------------------------------------+
int GetTrend(int fromShift, const int rates_total,
             const double &high[], const double &low[])
  {
   if(!UseTrendFilter)
      return(0);

   int n    = SwingLookback;
   int need = SwingCount;

   double swingHighs[]; double swingLows[];
   ArrayResize(swingHighs, 0);
   ArrayResize(swingLows,  0);

   int maxScan = MathMin(rates_total - n - 1, fromShift + 300);

   // Scan bars strictly older than the Pin Bar.
   for(int shift = fromShift + 1; shift <= maxScan; shift++)
     {
      if(ArraySize(swingHighs) < need && IsSwingHigh(shift, n, rates_total, high))
         AppendDouble(swingHighs, high[shift]);
      if(ArraySize(swingLows) < need && IsSwingLow(shift, n, rates_total, low))
         AppendDouble(swingLows, low[shift]);
      if(ArraySize(swingHighs) >= need && ArraySize(swingLows) >= need)
         break;
     }

   if(ArraySize(swingHighs) < need || ArraySize(swingLows) < need)
      return(0);

   // Arrays ordered newest -> oldest.
   bool higherHighs = true, higherLows = true;
   bool lowerHighs  = true, lowerLows  = true;
   for(int i = 0; i < need - 1; i++)
     {
      if(swingHighs[i] <= swingHighs[i + 1]) higherHighs = false;
      if(swingHighs[i] >= swingHighs[i + 1]) lowerHighs  = false;
      if(swingLows[i]  <= swingLows[i + 1])  higherLows  = false;
      if(swingLows[i]  >= swingLows[i + 1])  lowerLows   = false;
     }

   if(higherHighs && higherLows) return(+1);
   if(lowerHighs  && lowerLows)  return(-1);
   return(0);
  }

//+------------------------------------------------------------------+
//| Fractal swing-high test at 'shift' (n bars each side)            |
//+------------------------------------------------------------------+
bool IsSwingHigh(int shift, int n, const int rates_total, const double &high[])
  {
   if(shift - n < 0 || shift + n >= rates_total) return(false);
   double center = high[shift];
   for(int k = 1; k <= n; k++)
     {
      if(high[shift + k] >= center) return(false);
      if(high[shift - k] >= center) return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Fractal swing-low test at 'shift' (n bars each side)             |
//+------------------------------------------------------------------+
bool IsSwingLow(int shift, int n, const int rates_total, const double &low[])
  {
   if(shift - n < 0 || shift + n >= rates_total) return(false);
   double center = low[shift];
   for(int k = 1; k <= n; k++)
     {
      if(low[shift + k] <= center) return(false);
      if(low[shift - k] <= center) return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Helper: append a double to a dynamic array                       |
//+------------------------------------------------------------------+
void AppendDouble(double &arr[], double value)
  {
   int sz = ArraySize(arr);
   ArrayResize(arr, sz + 1);
   arr[sz] = value;
  }
//+------------------------------------------------------------------+
