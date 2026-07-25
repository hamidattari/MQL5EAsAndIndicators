//+------------------------------------------------------------------+
//|                                                 BOS_Detector.mq5 |
//|            Break of Structure (BOS) Detector — Bullish & Bearish |
//|                                                                  |
//|  Detects valid Break of Structure events based on confirmed      |
//|  swing highs/lows (configurable pivot length) and visualizes     |
//|  them with horizontal structure lines and semi-transparent       |
//|  background zones drawn behind the candles.                      |
//|                                                                  |
//|  - Non-repainting: BOS is evaluated on CLOSED bars only.         |
//|  - Duplicate-safe: every BOS object is uniquely named by the     |
//|    bar time of the break; each swing can be broken only once.    |
//|  - Efficient: incremental OnCalculate processing — each closed   |
//|    bar is evaluated exactly once.                                |
//|  - Compatible with all symbols and timeframes.                   |
//+------------------------------------------------------------------+
#property copyright   "BOS Detector"
#property version     "1.00"
#property description "Detects bullish/bearish Break of Structure (BOS) events"
#property description "using confirmed pivot swings. Draws BOS lines and"
#property description "background zones behind the candles."
#property indicator_chart_window
#property indicator_plots 0

//+------------------------------------------------------------------+
//| User Inputs                                                      |
//+------------------------------------------------------------------+
input group "=== Structure Detection ==="
input int    InpPivotLength      = 5;          // Pivot/Swing Length (bars each side)

input group "=== BOS Lines ==="
input color  InpBullLineColor    = clrDodgerBlue;   // Bullish BOS Line Color
input color  InpBearLineColor    = clrOrangeRed;    // Bearish BOS Line Color
input int    InpLineWidth        = 2;               // BOS Line Width
input ENUM_LINE_STYLE InpLineStyle = STYLE_SOLID;   // BOS Line Style
input int    InpLineExtension    = 10;              // BOS Line Right Extension (bars, 0 = stop at break)

input group "=== Background Zones ==="
input color  InpBullZoneColor    = clrDodgerBlue;   // Bullish Background Color
input color  InpBearZoneColor    = clrOrangeRed;    // Bearish Background Color
input int    InpZoneOpacity      = 20;              // Rectangle Opacity % (0=invisible .. 100=solid)
input int    InpRectExtension    = 20;              // Rectangle Forward Extension (bars)

input group "=== Display Options ==="
input bool   InpShowHistory      = true;            // Enable Historical BOS Display
input bool   InpShowLabels       = true;            // Show "BOS" Text Labels

//+------------------------------------------------------------------+
//| Internal structures & globals                                    |
//+------------------------------------------------------------------+
// Holds the most recent CONFIRMED swing point of one type
struct SwingPoint
  {
   double            price;      // swing extreme price
   datetime          time;       // time of the swing bar
   int               bar;        // index of the swing bar (non-series)
   bool              valid;      // a confirmed swing exists
   bool              broken;     // this swing has already produced a BOS
  };

SwingPoint g_swingHigh;          // last confirmed swing high
SwingPoint g_swingLow;           // last confirmed swing low

string     g_prefix;             // unique object-name prefix for this instance
datetime   g_startTime;          // indicator attach time (for history filter)

// Last drawn BOS line — used to truncate it when a newer BOS occurs
string     g_lastLineName = "";
datetime   g_lastLineEnd  = 0;

//+------------------------------------------------------------------+
//| Reset swing state                                                |
//+------------------------------------------------------------------+
void ResetState()
  {
   g_swingHigh.valid  = false;  g_swingHigh.broken = false;
   g_swingHigh.price  = 0.0;    g_swingHigh.time   = 0;  g_swingHigh.bar = -1;
   g_swingLow.valid   = false;  g_swingLow.broken  = false;
   g_swingLow.price   = 0.0;    g_swingLow.time    = 0;  g_swingLow.bar  = -1;
   g_lastLineName     = "";
   g_lastLineEnd      = 0;
  }

//+------------------------------------------------------------------+
//| Blend a color toward the chart background to simulate            |
//| transparency (standard chart objects do not support true alpha,  |
//| so we pre-mix the color: opacity% of fg + (100-opacity)% of bg). |
//+------------------------------------------------------------------+
color BlendWithBackground(const color fg, const int opacityPercent)
  {
   int op = MathMax(0, MathMin(100, opacityPercent));
   color bg = (color)ChartGetInteger(0, CHART_COLOR_BACKGROUND);

   // color is stored as 0x00BBGGRR
   int fr = (fg)       & 0xFF, fgr = (fg >> 8)  & 0xFF, fb = (fg >> 16) & 0xFF;
   int br = (bg)       & 0xFF, bgr = (bg >> 8)  & 0xFF, bb = (bg >> 16) & 0xFF;

   int r = (fr * op + br * (100 - op)) / 100;
   int g = (fgr * op + bgr * (100 - op)) / 100;
   int b = (fb * op + bb * (100 - op)) / 100;

   return (color)((b << 16) | (g << 8) | r);
  }

//+------------------------------------------------------------------+
//| Confirmed swing high test at index p (strict left / >= right)    |
//+------------------------------------------------------------------+
bool IsSwingHigh(const double &high[], const int p, const int len, const int total)
  {
   if(p - len < 0 || p + len >= total)
      return(false);
   for(int j = 1; j <= len; j++)
     {
      if(high[p] <= high[p - j]) return(false);   // strictly higher than left side
      if(high[p] <  high[p + j]) return(false);   // >= right side (tie tolerant)
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Confirmed swing low test at index p                              |
//+------------------------------------------------------------------+
bool IsSwingLow(const double &low[], const int p, const int len, const int total)
  {
   if(p - len < 0 || p + len >= total)
      return(false);
   for(int j = 1; j <= len; j++)
     {
      if(low[p] >= low[p - j]) return(false);     // strictly lower than left side
      if(low[p] >  low[p + j]) return(false);     // <= right side (tie tolerant)
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Draw the horizontal BOS line (OBJ_TREND, no ray)                 |
//+------------------------------------------------------------------+
void DrawBOSLine(const string name, const datetime t1, const datetime t2,
                 const double price, const color clr)
  {
   if(ObjectFind(0, name) >= 0)          // duplicate guard
      return;

   if(!ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price))
      return;

   ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,      InpLineWidth);
   ObjectSetInteger(0, name, OBJPROP_STYLE,      InpLineStyle);
   ObjectSetInteger(0, name, OBJPROP_RAY_LEFT,   false);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT,  false);
   ObjectSetInteger(0, name, OBJPROP_BACK,       false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
   ObjectSetString (0, name, OBJPROP_TOOLTIP,    "BOS level @ " + DoubleToString(price, _Digits));
  }

//+------------------------------------------------------------------+
//| Draw the background BOS zone (OBJ_RECTANGLE, filled, behind)     |
//+------------------------------------------------------------------+
void DrawBOSZone(const string name, const datetime t1, const datetime t2,
                 const double p1, const double p2, const color baseColor)
  {
   if(ObjectFind(0, name) >= 0)          // duplicate guard
      return;

   if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, p1, t2, p2))
      return;

   color zoneColor = BlendWithBackground(baseColor, InpZoneOpacity);

   ObjectSetInteger(0, name, OBJPROP_COLOR,      zoneColor);
   ObjectSetInteger(0, name, OBJPROP_FILL,       true);
   ObjectSetInteger(0, name, OBJPROP_BACK,       true);   // behind the candles
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
  }

//+------------------------------------------------------------------+
//| Draw a small "BOS" text label above/below the break candle       |
//+------------------------------------------------------------------+
void DrawBOSLabel(const string name, const datetime t, const double price,
                  const color clr, const bool bullish)
  {
   if(!InpShowLabels || ObjectFind(0, name) >= 0)
      return;

   if(!ObjectCreate(0, name, OBJ_TEXT, 0, t, price))
      return;

   ObjectSetString (0, name, OBJPROP_TEXT,       "BOS");
   ObjectSetString (0, name, OBJPROP_FONT,       "Arial Bold");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   8);
   ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR,     bullish ? ANCHOR_LOWER : ANCHOR_UPPER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
  }

//+------------------------------------------------------------------+
//| Truncate the previously drawn BOS line at a new BOS time         |
//| ("extend to the right ... until another BOS occurs")             |
//+------------------------------------------------------------------+
void TruncatePreviousLine(const datetime newBosTime)
  {
   if(g_lastLineName != "" && g_lastLineEnd > newBosTime
      && ObjectFind(0, g_lastLineName) >= 0)
     {
      ObjectSetInteger(0, g_lastLineName, OBJPROP_TIME, 1, newBosTime);
     }
  }

//+------------------------------------------------------------------+
//| Register a BOS event: draws line + zone + label                  |
//+------------------------------------------------------------------+
void RegisterBOS(const bool bullish, const SwingPoint &swing,
                 const datetime bosTime, const double bosClose)
  {
   // Honor the "historical display" switch
   if(!InpShowHistory && bosTime < g_startTime)
      return;

   int    sec      = PeriodSeconds(_Period);
   string tag      = (bullish ? "BU_" : "BE_") + (string)(long)bosTime;
   string lineName = g_prefix + "LINE_" + tag;
   string zoneName = g_prefix + "ZONE_" + tag;
   string lblName  = g_prefix + "LBL_"  + tag;

   color lineClr = bullish ? InpBullLineColor : InpBearLineColor;
   color zoneClr = bullish ? InpBullZoneColor : InpBearZoneColor;

   // A new BOS ends the extension of the previous BOS line
   TruncatePreviousLine(bosTime);

   // --- BOS line: from the broken swing to (break bar + extension) ---
   datetime lineEnd = bosTime + (datetime)(MathMax(0, InpLineExtension) * sec);
   DrawBOSLine(lineName, swing.time, lineEnd, swing.price, lineClr);
   g_lastLineName = lineName;
   g_lastLineEnd  = lineEnd;

   // --- Background zone: swing level <-> BOS candle close,          ---
   // --- from the BOS candle forward by InpRectExtension bars        ---
   datetime zoneEnd = bosTime + (datetime)(MathMax(1, InpRectExtension) * sec);
   DrawBOSZone(zoneName, bosTime, zoneEnd, swing.price, bosClose, zoneClr);

   // --- Text label at the break point ---
   DrawBOSLabel(lblName, bosTime, bosClose, lineClr, bullish);
  }

//+------------------------------------------------------------------+
//| Custom indicator initialization                                  |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpPivotLength < 1)
     {
      Print("BOS Detector: Pivot length must be >= 1");
      return(INIT_PARAMETERS_INCORRECT);
     }

   // Unique prefix per symbol/timeframe so multiple instances coexist
   g_prefix    = "BOS_" + _Symbol + "_" + (string)(int)_Period + "_";
   g_startTime = TimeCurrent();

   ResetState();
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Custom indicator deinitialization — clean up all objects         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, g_prefix);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Main calculation — incremental, closed-bar only (non-repainting) |
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
   // Work with non-series (oldest -> newest) indexing
   ArraySetAsSeries(time,  false);
   ArraySetAsSeries(high,  false);
   ArraySetAsSeries(low,   false);
   ArraySetAsSeries(close, false);

   int len = InpPivotLength;
   if(rates_total < 2 * len + 2)
      return(rates_total);

   int start;
   if(prev_calculated == 0)
     {
      // Full recalculation (first run or history reload):
      // wipe our objects and rebuild structure from scratch
      ObjectsDeleteAll(0, g_prefix);
      ResetState();
      start = 2 * len;                       // first bar with a confirmable pivot
     }
   else
     {
      start = prev_calculated - 1;           // continue from the newly closed bar
     }

   // Process CLOSED bars only: the forming bar (rates_total-1) is skipped
   // and will be evaluated exactly once after it closes.
   for(int i = start; i < rates_total - 1; i++)
     {
      //--- 1) Confirm new swing points ------------------------------
      // A pivot at (i - len) becomes confirmed once 'len' bars have
      // closed to its right, i.e. exactly at bar i.
      int p = i - len;
      if(p >= len)
        {
         if(IsSwingHigh(high, p, len, rates_total))
           {
            g_swingHigh.price  = high[p];
            g_swingHigh.time   = time[p];
            g_swingHigh.bar    = p;
            g_swingHigh.valid  = true;
            g_swingHigh.broken = false;
           }
         if(IsSwingLow(low, p, len, rates_total))
           {
            g_swingLow.price  = low[p];
            g_swingLow.time   = time[p];
            g_swingLow.bar    = p;
            g_swingLow.valid  = true;
            g_swingLow.broken = false;
           }
        }

      //--- 2) Bullish BOS: close above last confirmed swing high ----
      if(g_swingHigh.valid && !g_swingHigh.broken && close[i] > g_swingHigh.price)
        {
         RegisterBOS(true, g_swingHigh, time[i], close[i]);
         g_swingHigh.broken = true;          // one BOS per swing — no duplicates
        }

      //--- 3) Bearish BOS: close below last confirmed swing low -----
      if(g_swingLow.valid && !g_swingLow.broken && close[i] < g_swingLow.price)
        {
         RegisterBOS(false, g_swingLow, time[i], close[i]);
         g_swingLow.broken = true;           // one BOS per swing — no duplicates
        }
     }

   ChartRedraw();
   return(rates_total);
  }
//+------------------------------------------------------------------+
