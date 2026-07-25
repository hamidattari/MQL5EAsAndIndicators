//+------------------------------------------------------------------+
//|                                                 QuasimodoRTM.mq5 |
//|        RTM-Style Quasimodo (QM) Pattern Indicator  —  MT5        |
//|                                                                  |
//|  Detects and labels the last N completed Quasimodo patterns:     |
//|   • Full QM structure  (LS = Left Shoulder, HEAD, RS = Right     |
//|     Shoulder) drawn as a zig-zag with swing high/low labels      |
//|   • QM supply/demand zone (RTM style, shaded rectangle)          |
//|   • Entry  : green arrow + "ENTRY" label at the right shoulder   |
//|   • SL     : red line   + "SL"  label (beyond the head)          |
//|   • TP1/TP2: green lines + "TP1"/"TP2" labels                    |
//|   • Risk-Reward label (e.g.  R:R 1:2 | 1:3)                      |
//|                                                                  |
//|  Multi-chart grid: enable "Open Grid Charts" to auto-open a set  |
//|  of symbols (XAUUSD, EURUSD, ...) with a dark RTM theme and this |
//|  indicator attached to each — then press Alt+R (or use Window >  |
//|  Tile Windows) in MT5 to arrange them as a grid/collage.         |
//+------------------------------------------------------------------+
#property copyright   "QuasimodoRTM"
#property link        ""
#property version     "1.00"
#property description "RTM-style Quasimodo (QM) pattern detector with full structure labels, Entry / SL / TP1 / TP2 and Risk-Reward."
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

//--- keep these two inputs FIRST (they are overridden when the
//--- indicator attaches itself to the grid charts via iCustom)
input bool     InpOpenGridCharts   = false;                                  // Open Grid Charts (multi-symbol collage)
input string   InpGridSymbols      = "XAUUSD,EURUSD,GBPUSD,USDJPY,BTCUSD,US30"; // Grid Symbols (comma separated)

input group    "=== Detection ==="
input int      InpSwingStrength    = 3;      // Swing Strength (bars each side of a pivot)
input int      InpLookbackBars     = 3000;   // Lookback Bars to scan
input int      InpMaxPatterns      = 10;     // Max QM Patterns to display
input int      InpRetestMaxBars    = 300;    // Max bars allowed for Right-Shoulder retest

input group    "=== Trade Levels ==="
input int      InpSLBufferPoints   = 150;    // SL buffer beyond the Head (points)
input double   InpRR1              = 2.0;    // TP1 Risk-Reward (1 : x)
input double   InpRR2              = 3.0;    // TP2 Risk-Reward (1 : x)
input int      InpLevelLengthBars  = 60;     // Length of Entry/SL/TP lines (bars)

input group    "=== Style ==="
input color    InpBullColor        = C'38,166,154';   // Bullish structure color
input color    InpBearColor        = C'239,83,80';    // Bearish structure color
input color    InpEntryColor       = clrLime;         // Entry arrow/label color
input color    InpSLColor          = clrRed;          // Stop Loss color
input color    InpTPColor          = C'0,200,83';     // Take Profit color
input color    InpZoneBullColor    = C'21,58,48';     // Bullish QM zone fill
input color    InpZoneBearColor    = C'66,30,38';     // Bearish QM zone fill
input color    InpTextColor        = clrWhiteSmoke;   // Structure text color
input int      InpStructWidth      = 2;      // Structure line width
input int      InpFontSize         = 9;      // Label font size
input string   InpFont             = "Arial";// Label font
input bool     InpApplyRTMTheme    = true;   // Apply dark RTM theme to this chart

//--- object name prefix
#define PREFIX "QMRTM_"

//+------------------------------------------------------------------+
//| Data structures                                                  |
//+------------------------------------------------------------------+
struct SwingPoint
  {
   int               bar;
   datetime          time;
   double            price;
   bool              isHigh;
  };

struct QMPattern
  {
   bool              isBull;
   datetime          tLS,tL1,tHead,tL2,tRS;
   double            pLS,pL1,pHead,pL2;
   double            entry,sl,tp1,tp2;
   int               barRS;
  };

datetime g_lastBarTime = 0;

//+------------------------------------------------------------------+
//| Custom indicator initialization                                  |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpApplyRTMTheme)
      ApplyRTMTheme(0);

   if(InpOpenGridCharts)
      OpenGridCharts();

   g_lastBarTime = 0; // force full redraw
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Custom indicator deinitialization                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0,PREFIX,-1,-1);
   ChartRedraw();
  }
//+------------------------------------------------------------------+
//| Custom indicator iteration                                       |
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
   if(rates_total < InpSwingStrength*2+10)
      return(rates_total);

   //--- chronological indexing (0 = oldest)
   ArraySetAsSeries(time,false);
   ArraySetAsSeries(high,false);
   ArraySetAsSeries(low,false);
   ArraySetAsSeries(close,false);

   //--- recalculate only on a new bar (or first run)
   datetime curBar = time[rates_total-1];
   if(curBar == g_lastBarTime)
      return(rates_total);
   g_lastBarTime = curBar;

   //--- 1) find swings
   SwingPoint swings[];
   FindSwings(time,high,low,rates_total,swings);

   //--- 2) find QM patterns
   QMPattern patterns[];
   FindPatterns(swings,time,high,low,rates_total,patterns);

   //--- 3) keep only the last N and draw
   ObjectsDeleteAll(0,PREFIX,-1,-1);
   int total = ArraySize(patterns);
   int first = MathMax(0,total-InpMaxPatterns);
   int shown = 0;
   for(int i=first; i<total; i++)
      DrawPattern(patterns[i],++shown);

   ChartRedraw();
   return(rates_total);
  }
//+------------------------------------------------------------------+
//| Detect alternating swing highs / lows                            |
//+------------------------------------------------------------------+
void FindSwings(const datetime &time[],const double &high[],
                const double &low[],const int total,
                SwingPoint &swings[])
  {
   int s     = InpSwingStrength;
   int start = MathMax(s, total - InpLookbackBars);

   for(int i=start; i<total-s; i++)
     {
      bool isHigh = true;
      bool isLow  = true;
      for(int k=1; k<=s && (isHigh || isLow); k++)
        {
         if(high[i] <= high[i-k] || high[i] < high[i+k]) isHigh = false;
         if(low[i]  >= low[i-k]  || low[i]  > low[i+k])  isLow  = false;
        }
      if(!isHigh && !isLow)
         continue;

      SwingPoint sp;
      sp.bar    = i;
      sp.time   = time[i];
      sp.isHigh = isHigh;              // if both, treat as high first
      sp.price  = isHigh ? high[i] : low[i];

      int n = ArraySize(swings);
      if(n>0 && swings[n-1].isHigh == sp.isHigh)
        {
         // same type in a row -> keep the more extreme pivot
         bool replace = sp.isHigh ? (sp.price >= swings[n-1].price)
                                  : (sp.price <= swings[n-1].price);
         if(replace)
            swings[n-1] = sp;
         continue;
        }
      ArrayResize(swings,n+1);
      swings[n] = sp;
     }
  }
//+------------------------------------------------------------------+
//| Scan the swing sequence for completed Quasimodo patterns         |
//+------------------------------------------------------------------+
void FindPatterns(const SwingPoint &swings[],const datetime &time[],
                  const double &high[],const double &low[],
                  const int total,QMPattern &patterns[])
  {
   int n = ArraySize(swings);
   double slBuf = InpSLBufferPoints * _Point;

   for(int i=0; i+3<n; i++)
     {
      //================= BEARISH QM (SELL) =================
      // LS(high) -> L1(low) -> HEAD(higher high) -> L2(lower low = BOS)
      if(swings[i].isHigh && !swings[i+1].isHigh &&
         swings[i+2].isHigh && !swings[i+3].isHigh &&
         swings[i+2].price > swings[i].price &&        // head takes out LS
         swings[i+3].price < swings[i+1].price)        // break of structure
        {
         double entry = swings[i].price;               // QM level = LS
         double sl    = swings[i+2].price + slBuf;
         double risk  = sl - entry;
         if(risk > 0.0)
           {
            // right shoulder = first retest of the QM level after BOS
            int rs = -1;
            int from = swings[i+3].bar + 1;
            int to   = MathMin(total-1, swings[i+3].bar + InpRetestMaxBars);
            for(int b=from; b<=to; b++)
              {
               if(high[b] >= entry) { rs = b; break; }
               if(low[b]  <  swings[i+3].price - risk) break; // ran away
              }
            if(rs > 0)
              {
               QMPattern p;
               p.isBull = false;
               p.tLS   = swings[i].time;    p.pLS   = swings[i].price;
               p.tL1   = swings[i+1].time;  p.pL1   = swings[i+1].price;
               p.tHead = swings[i+2].time;  p.pHead = swings[i+2].price;
               p.tL2   = swings[i+3].time;  p.pL2   = swings[i+3].price;
               p.tRS   = time[rs];          p.barRS = rs;
               p.entry = entry;
               p.sl    = sl;
               p.tp1   = entry - risk*InpRR1;
               p.tp2   = entry - risk*InpRR2;
               int c = ArraySize(patterns);
               ArrayResize(patterns,c+1);
               patterns[c] = p;
              }
           }
        }
      //================= BULLISH QM (BUY) ==================
      // LS(low) -> H1(high) -> HEAD(lower low) -> H2(higher high = BOS)
      if(!swings[i].isHigh && swings[i+1].isHigh &&
         !swings[i+2].isHigh && swings[i+3].isHigh &&
         swings[i+2].price < swings[i].price &&        // head takes out LS
         swings[i+3].price > swings[i+1].price)        // break of structure
        {
         double entry = swings[i].price;               // QM level = LS
         double sl    = swings[i+2].price - slBuf;
         double risk  = entry - sl;
         if(risk > 0.0)
           {
            int rs = -1;
            int from = swings[i+3].bar + 1;
            int to   = MathMin(total-1, swings[i+3].bar + InpRetestMaxBars);
            for(int b=from; b<=to; b++)
              {
               if(low[b] <= entry) { rs = b; break; }
               if(high[b] > swings[i+3].price + risk) break; // ran away
              }
            if(rs > 0)
              {
               QMPattern p;
               p.isBull = true;
               p.tLS   = swings[i].time;    p.pLS   = swings[i].price;
               p.tL1   = swings[i+1].time;  p.pL1   = swings[i+1].price;
               p.tHead = swings[i+2].time;  p.pHead = swings[i+2].price;
               p.tL2   = swings[i+3].time;  p.pL2   = swings[i+3].price;
               p.tRS   = time[rs];          p.barRS = rs;
               p.entry = entry;
               p.sl    = sl;
               p.tp1   = entry + risk*InpRR1;
               p.tp2   = entry + risk*InpRR2;
               int c = ArraySize(patterns);
               ArrayResize(patterns,c+1);
               patterns[c] = p;
              }
           }
        }
     }
  }
//+------------------------------------------------------------------+
//| Draw one complete QM pattern                                     |
//+------------------------------------------------------------------+
void DrawPattern(const QMPattern &p,const int idx)
  {
   string  id     = PREFIX + IntegerToString(idx) + "_";
   color   sc     = p.isBull ? InpBullColor : InpBearColor;
   color   zc     = p.isBull ? InpZoneBullColor : InpZoneBearColor;
   datetime tEnd  = p.tRS + PeriodSeconds()*InpLevelLengthBars;
   double  off    = (p.sl - p.entry) * 0.15 * (p.isBull ? -1.0 : 1.0);
   if(p.isBull) off = (p.entry - p.sl) * 0.15;

   //--- RTM QM zone (entry -> SL area, shaded)
   Rect(id+"zone", p.tHead, p.entry, tEnd, p.sl, zc);

   //--- zig-zag structure  LS -> L1 -> HEAD -> L2 -> RS
   Trend(id+"z1", p.tLS,  p.pLS,  p.tL1,  p.pL1,  sc, InpStructWidth, STYLE_SOLID);
   Trend(id+"z2", p.tL1,  p.pL1,  p.tHead,p.pHead,sc, InpStructWidth, STYLE_SOLID);
   Trend(id+"z3", p.tHead,p.pHead,p.tL2,  p.pL2,  sc, InpStructWidth, STYLE_SOLID);
   Trend(id+"z4", p.tL2,  p.pL2,  p.tRS,  p.entry,sc, InpStructWidth, STYLE_SOLID);

   //--- structure labels
   bool bull = p.isBull;
   Text(id+"ls",   p.tLS,   p.pLS,   "LS",   InpTextColor, bull?ANCHOR_UPPER:ANCHOR_LOWER, InpFontSize);
   Text(id+"head", p.tHead, p.pHead, "HEAD", sc,           bull?ANCHOR_UPPER:ANCHOR_LOWER, InpFontSize+2);
   Text(id+"rs",   p.tRS,   p.entry, "RS",   InpTextColor, bull?ANCHOR_UPPER:ANCHOR_LOWER, InpFontSize);
   Text(id+"l1",   p.tL1,   p.pL1,   bull?"HIGH":"LOW",     InpTextColor, bull?ANCHOR_LOWER:ANCHOR_UPPER, InpFontSize-1);
   Text(id+"l2",   p.tL2,   p.pL2,   bull?"HH \x2022 BOS":"LL \x2022 BOS", sc, bull?ANCHOR_LOWER:ANCHOR_UPPER, InpFontSize-1);
   Text(id+"ttl",  p.tHead, p.pHead + (bull?-1:1)*MathAbs(off)*2.0,
        StringFormat("QM #%d (%s)", idx, bull?"BUY":"SELL"), sc,
        bull?ANCHOR_UPPER:ANCHOR_LOWER, InpFontSize+1);

   //--- entry arrow + label
   double aPrice = bull ? p.entry - MathAbs(off) : p.entry + MathAbs(off);
   Arrow(id+"arr", p.tRS, aPrice, bull ? 233 : 234, InpEntryColor);
   Text(id+"ent", p.tRS, aPrice, "ENTRY", InpEntryColor,
        bull?ANCHOR_UPPER:ANCHOR_LOWER, InpFontSize);

   //--- Entry / SL / TP1 / TP2 levels
   Trend(id+"lEntry", p.tRS, p.entry, tEnd, p.entry, clrSilver,   1, STYLE_DOT);
   Trend(id+"lSL",    p.tRS, p.sl,    tEnd, p.sl,    InpSLColor,  2, STYLE_SOLID);
   Trend(id+"lTP1",   p.tRS, p.tp1,   tEnd, p.tp1,   InpTPColor,  2, STYLE_SOLID);
   Trend(id+"lTP2",   p.tRS, p.tp2,   tEnd, p.tp2,   InpTPColor,  2, STYLE_DASH);

   int d = _Digits;
   Text(id+"txtEntry", tEnd, p.entry, "ENTRY "+DoubleToString(p.entry,d), clrSilver,  ANCHOR_LEFT, InpFontSize-1);
   Text(id+"txtSL",    tEnd, p.sl,    "SL "   +DoubleToString(p.sl,d),    InpSLColor, ANCHOR_LEFT, InpFontSize);
   Text(id+"txtTP1",   tEnd, p.tp1,   "TP1 "  +DoubleToString(p.tp1,d),   InpTPColor, ANCHOR_LEFT, InpFontSize);
   Text(id+"txtTP2",   tEnd, p.tp2,   "TP2 "  +DoubleToString(p.tp2,d),   InpTPColor, ANCHOR_LEFT, InpFontSize);

   //--- risk-reward label
   Text(id+"rr", p.tRS + PeriodSeconds()*(InpLevelLengthBars/2),
        bull ? p.sl - MathAbs(off) : p.sl + MathAbs(off),
        StringFormat("R:R  1:%s | 1:%s",
                     DoubleToString(InpRR1, InpRR1==MathRound(InpRR1)?0:1),
                     DoubleToString(InpRR2, InpRR2==MathRound(InpRR2)?0:1)),
        clrGold, bull?ANCHOR_UPPER:ANCHOR_LOWER, InpFontSize);
  }
//+------------------------------------------------------------------+
//| Object helpers                                                   |
//+------------------------------------------------------------------+
void Trend(const string name,datetime t1,double p1,datetime t2,double p2,
           color clr,int width,ENUM_LINE_STYLE style)
  {
   ObjectCreate(0,name,OBJ_TREND,0,t1,p1,t2,p2);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,width);
   ObjectSetInteger(0,name,OBJPROP_STYLE,style);
   ObjectSetInteger(0,name,OBJPROP_RAY_LEFT,false);
   ObjectSetInteger(0,name,OBJPROP_RAY_RIGHT,false);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
  }

void Text(const string name,datetime t,double p,const string txt,
          color clr,ENUM_ANCHOR_POINT anchor,int fontSize)
  {
   ObjectCreate(0,name,OBJ_TEXT,0,t,p);
   ObjectSetString(0,name,OBJPROP_TEXT,txt);
   ObjectSetString(0,name,OBJPROP_FONT,InpFont);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,fontSize);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_ANCHOR,anchor);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
  }

void Arrow(const string name,datetime t,double p,int code,color clr)
  {
   ObjectCreate(0,name,OBJ_ARROW,0,t,p);
   ObjectSetInteger(0,name,OBJPROP_ARROWCODE,code);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,3);
   ObjectSetInteger(0,name,OBJPROP_ANCHOR,code==233?ANCHOR_TOP:ANCHOR_BOTTOM);
   ObjectSetInteger(0,name,OBJPROP_BACK,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
  }

void Rect(const string name,datetime t1,double p1,datetime t2,double p2,color clr)
  {
   ObjectCreate(0,name,OBJ_RECTANGLE,0,t1,p1,t2,p2);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_FILL,true);
   ObjectSetInteger(0,name,OBJPROP_BACK,true);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
  }
//+------------------------------------------------------------------+
//| Dark RTM-style chart theme                                       |
//+------------------------------------------------------------------+
void ApplyRTMTheme(const long cid)
  {
   ChartSetInteger(cid,CHART_MODE,CHART_CANDLES);
   ChartSetInteger(cid,CHART_COLOR_BACKGROUND,C'14,17,23');
   ChartSetInteger(cid,CHART_COLOR_FOREGROUND,C'170,178,190');
   ChartSetInteger(cid,CHART_COLOR_GRID,C'28,33,42');
   ChartSetInteger(cid,CHART_COLOR_CHART_UP,C'38,166,154');
   ChartSetInteger(cid,CHART_COLOR_CHART_DOWN,C'239,83,80');
   ChartSetInteger(cid,CHART_COLOR_CANDLE_BULL,C'38,166,154');
   ChartSetInteger(cid,CHART_COLOR_CANDLE_BEAR,C'239,83,80');
   ChartSetInteger(cid,CHART_COLOR_CHART_LINE,C'170,178,190');
   ChartSetInteger(cid,CHART_SHOW_GRID,true);
   ChartSetInteger(cid,CHART_SHIFT,true);
   ChartSetInteger(cid,CHART_AUTOSCROLL,true);
   ChartSetInteger(cid,CHART_SHOW_PERIOD_SEP,false);
  }
//+------------------------------------------------------------------+
//| Open the multi-symbol grid and attach this indicator to each     |
//| chart. Use MT5 menu: Window -> Tile Windows (Alt+R) to arrange   |
//| the opened charts as a grid / collage.                           |
//+------------------------------------------------------------------+
void OpenGridCharts()
  {
   string syms[];
   int n = StringSplit(InpGridSymbols,',',syms);
   string me = MQLInfoString(MQL_PROGRAM_NAME);

   for(int i=0; i<n; i++)
     {
      string s = syms[i];
      StringTrimLeft(s);
      StringTrimRight(s);
      if(StringLen(s)==0 || s==_Symbol)
         continue;
      if(!SymbolSelect(s,true))
        {
         PrintFormat("QuasimodoRTM: symbol %s not found, skipped.",s);
         continue;
        }
      long cid = ChartOpen(s,PERIOD_CURRENT);
      if(cid<=0)
         continue;
      ApplyRTMTheme(cid);
      // attach this indicator with grid opening disabled (no recursion)
      int h = iCustom(s,PERIOD_CURRENT,me,false,"");
      if(h!=INVALID_HANDLE)
         ChartIndicatorAdd(cid,0,h);
     }
   Print("QuasimodoRTM: grid charts opened. Press Alt+R (Window > Tile Windows) to arrange as a grid.");
  }
//+------------------------------------------------------------------+
