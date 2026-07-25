//+------------------------------------------------------------------+
//|                                              PinBarTrendEA.mq5    |
//|                        Pin Bar Reversal EA with Trend Filter      |
//|                                                                   |
//|  Strategy:                                                        |
//|   - Detect trend via swing structure (HH/HL = up, LH/LL = down).  |
//|   - Uptrend  : find bearish Pin Bar (long upper wick), then a     |
//|                bullish confirmation candle whose High > Pin High   |
//|                -> BUY. SL below Pin low, TP = 1:1 (SL distance).   |
//|   - Downtrend: find bullish Pin Bar (long lower wick), then a     |
//|                bearish confirmation candle whose Low < Pin Low     |
//|                -> SELL. SL above Pin high, TP = 1:1 (SL distance). |
//|   - Risk exactly RiskPercent of balance/equity per trade, with    |
//|     automatic lot sizing from the SL distance.                    |
//|   - One trade per signal; no duplicate positions per setup.       |
//+------------------------------------------------------------------+
#property copyright "PinBarTrendEA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>

//====================================================================
//  ENUMERATIONS
//====================================================================
// Which account figure to base the 1% risk on.
enum ENUM_RISK_BASE
  {
   RISK_ON_BALANCE = 0, // Account Balance
   RISK_ON_EQUITY  = 1  // Account Equity
  };

//====================================================================
//  INPUT PARAMETERS
//====================================================================
input group    "=== Risk Management ==="
input double         RiskPercent        = 1.0;             // Risk per trade (% of account)
input ENUM_RISK_BASE RiskBase           = RISK_ON_BALANCE; // Risk base (Balance/Equity)
input double         RewardRatio        = 1.0;             // Risk : Reward ratio (TP = SL * this)

input group    "=== Pin Bar Definition ==="
input double         MinWickBodyRatio   = 2.0;             // Min wick-to-body ratio (wick >= ratio * body)
input double         MaxBodyToRangeRatio= 0.34;            // Max body size as fraction of full candle range
input double         MinOppositeWickPct = 0.0;             // Max opposite wick as fraction of range (0 = disabled)

input group    "=== Trend Filter ==="
input bool           UseTrendFilter     = true;            // Enable swing-structure trend filter
input int            SwingLookback      = 3;               // Bars on each side to confirm a swing point (fractal)
input int            SwingCount         = 2;               // Number of recent swings compared for HH/HL, LH/LL

input group    "=== Trade Settings ==="
input long           MagicNumber        = 20260723;        // Magic number (unique EA id)
input int            SlippagePoints     = 20;              // Max slippage / deviation (points)
input int            SL_BufferPoints    = 5;               // Extra buffer beyond Pin high/low for SL (points)
input bool           TradeOnNewBarOnly  = true;            // Evaluate signals only on a new bar

//====================================================================
//  GLOBAL OBJECTS / STATE
//====================================================================
CTrade        trade;        // Trade execution helper
CSymbolInfo   symInfo;      // Symbol specification helper

datetime      g_lastBarTime      = 0;   // Time of the last processed bar
datetime      g_lastSignalPinTime= 0;   // Pin Bar time of the last signal we acted on (dedupe)

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   // Configure the trade helper object.
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetMarginMode();

   // Initialise the symbol info object.
   if(!symInfo.Name(_Symbol))
     {
      Print("ERROR: Unable to initialise symbol info for ", _Symbol);
      return(INIT_FAILED);
     }

   // Validate key inputs.
   if(RiskPercent <= 0.0)
     {
      Print("ERROR: RiskPercent must be greater than 0.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(MinWickBodyRatio <= 0.0)
     {
      Print("ERROR: MinWickBodyRatio must be greater than 0.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   Print("PinBarTrendEA initialised on ", _Symbol, " ", EnumToString((ENUM_TIMEFRAMES)_Period));
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Print("PinBarTrendEA stopped. Reason code: ", reason);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // We operate on completed candles, so all logic reads shifts >= 1.
   // Optionally restrict evaluation to the first tick of each new bar.
   if(TradeOnNewBarOnly)
     {
      datetime curBarTime = (datetime)iTime(_Symbol, _Period, 0);
      if(curBarTime == g_lastBarTime)
         return;               // Still the same bar -> nothing new to do.
      g_lastBarTime = curBarTime;
     }

   // Refresh symbol data before any calculation / order.
   if(!symInfo.RefreshRates())
      return;

   // Skip if we already hold a position opened by this EA on this symbol.
   if(HasOpenPosition())
      return;

   // Evaluate the strategy on the just-closed structure.
   CheckForSignals();
  }

//+------------------------------------------------------------------+
//| Returns true if this EA already has a position on this symbol    |
//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Core signal evaluation                                           |
//|                                                                  |
//| Candle indexing (all completed candles):                         |
//|   shift 1 = confirmation candle (most recently closed)           |
//|   shift 2 = Pin Bar candle                                       |
//+------------------------------------------------------------------+
void CheckForSignals()
  {
   int pinShift  = 2;   // Pin Bar candle
   int confShift = 1;   // Confirmation candle (closed after the Pin Bar)

   // Make sure enough history exists for the trend filter + candles.
   int required = MathMax(pinShift + 2, SwingLookback * 2 + SwingCount * 3 + 5);
   if(Bars(_Symbol, _Period) < required)
      return;

   // Load the Pin Bar and confirmation candle OHLC.
   double pinOpen  = iOpen (_Symbol, _Period, pinShift);
   double pinHigh  = iHigh (_Symbol, _Period, pinShift);
   double pinLow   = iLow  (_Symbol, _Period, pinShift);
   double pinClose = iClose(_Symbol, _Period, pinShift);

   double confOpen  = iOpen (_Symbol, _Period, confShift);
   double confHigh  = iHigh (_Symbol, _Period, confShift);
   double confLow   = iLow  (_Symbol, _Period, confShift);
   double confClose = iClose(_Symbol, _Period, confShift);

   datetime pinTime = (datetime)iTime(_Symbol, _Period, pinShift);

   // Prevent acting on the same Pin Bar setup twice.
   if(pinTime == g_lastSignalPinTime)
      return;

   // Determine current trend (evaluated up to the Pin Bar area).
   int trend = GetTrend();   // +1 up, -1 down, 0 none

   //================================================================
   //  BULLISH SETUP  (uptrend + bearish Pin Bar + bullish confirm)
   //================================================================
   if(!UseTrendFilter || trend > 0)
     {
      if(IsBearishPinBar(pinOpen, pinHigh, pinLow, pinClose))
        {
         // Confirmation: bullish candle whose High breaks Pin Bar High.
         bool confBullish = (confClose > confOpen);
         if(confBullish && confHigh > pinHigh)
           {
            // Entry at current ask; SL below Pin Bar low (+ buffer).
            double buffer   = SL_BufferPoints * symInfo.Point();
            double entry    = symInfo.Ask();
            double slPrice  = pinLow - buffer;
            double slDist   = entry - slPrice;

            if(slDist > 0)
              {
               double tpPrice = entry + slDist * RewardRatio;
               OpenTrade(ORDER_TYPE_BUY, entry, slPrice, tpPrice, slDist, pinTime);
              }
            else
               Print("BUY skipped: non-positive SL distance.");
           }
        }
     }

   //================================================================
   //  BEARISH SETUP  (downtrend + bullish Pin Bar + bearish confirm) |
   //================================================================
   if(!UseTrendFilter || trend < 0)
     {
      if(IsBullishPinBar(pinOpen, pinHigh, pinLow, pinClose))
        {
         // Confirmation: bearish candle whose Low breaks Pin Bar Low.
         bool confBearish = (confClose < confOpen);
         if(confBearish && confLow < pinLow)
           {
            // Entry at current bid; SL above Pin Bar high (+ buffer).
            double buffer   = SL_BufferPoints * symInfo.Point();
            double entry    = symInfo.Bid();
            double slPrice  = pinHigh + buffer;
            double slDist   = slPrice - entry;

            if(slDist > 0)
              {
               double tpPrice = entry - slDist * RewardRatio;
               OpenTrade(ORDER_TYPE_SELL, entry, slPrice, tpPrice, slDist, pinTime);
              }
            else
               Print("SELL skipped: non-positive SL distance.");
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Bearish Pin Bar test (long UPPER wick, small body)               |
//|   Used for bullish (BUY) reversal setups in an uptrend.          |
//+------------------------------------------------------------------+
bool IsBearishPinBar(double o, double h, double l, double c)
  {
   double range = h - l;
   if(range <= 0.0)
      return(false);

   double body      = MathAbs(c - o);
   double bodyHigh  = MathMax(o, c);
   double bodyLow   = MathMin(o, c);
   double upperWick = h - bodyHigh;   // long wick we require
   double lowerWick = bodyLow - l;    // opposite wick

   // Avoid division by zero for doji-like candles: use a tiny floor.
   double bodyForRatio = MathMax(body, range * 0.0001);

   // 1) Body must be small relative to the full range.
   if(body > range * MaxBodyToRangeRatio)
      return(false);

   // 2) Upper wick must dominate the body by the required ratio.
   if(upperWick < body * MinWickBodyRatio)
      return(false);

   // 3) Upper wick must also be the dominant wick of the candle.
   if(upperWick <= lowerWick)
      return(false);

   // 4) Optional: keep the opposite (lower) wick small.
   if(MinOppositeWickPct > 0.0 && lowerWick > range * MinOppositeWickPct)
      return(false);

   return(true);
  }

//+------------------------------------------------------------------+
//| Bullish Pin Bar test (long LOWER wick, small body)               |
//|   Used for bearish (SELL) reversal setups in a downtrend.        |
//+------------------------------------------------------------------+
bool IsBullishPinBar(double o, double h, double l, double c)
  {
   double range = h - l;
   if(range <= 0.0)
      return(false);

   double body      = MathAbs(c - o);
   double bodyHigh  = MathMax(o, c);
   double bodyLow   = MathMin(o, c);
   double upperWick = h - bodyHigh;   // opposite wick
   double lowerWick = bodyLow - l;    // long wick we require

   // 1) Body must be small relative to the full range.
   if(body > range * MaxBodyToRangeRatio)
      return(false);

   // 2) Lower wick must dominate the body by the required ratio.
   if(lowerWick < body * MinWickBodyRatio)
      return(false);

   // 3) Lower wick must also be the dominant wick of the candle.
   if(lowerWick <= upperWick)
      return(false);

   // 4) Optional: keep the opposite (upper) wick small.
   if(MinOppositeWickPct > 0.0 && upperWick > range * MinOppositeWickPct)
      return(false);

   return(true);
  }

//+------------------------------------------------------------------+
//| Trend detection via swing structure (fractal swings)             |
//|   Returns +1 (up: HH & HL), -1 (down: LH & LL), 0 (no clear).    |
//|                                                                  |
//| We scan completed bars starting just after the Pin Bar area,     |
//| collect the last SwingCount swing highs and swing lows, and      |
//| compare them for a consistent higher/lower sequence.             |
//+------------------------------------------------------------------+
int GetTrend()
  {
   if(!UseTrendFilter)
      return(0);

   int    n   = SwingLookback;                 // bars each side for a fractal
   int    need = SwingCount;                   // swings we want on each side
   double swingHighs[]; double swingLows[];
   ArrayResize(swingHighs, 0);
   ArrayResize(swingLows,  0);

   int totalBars = Bars(_Symbol, _Period);
   int maxScan   = MathMin(totalBars - n - 1, 300); // cap the scan window

   // Start scanning from shift 3 so we skip the confirmation/Pin candles.
   for(int shift = 3; shift <= maxScan; shift++)
     {
      // ----- Swing High: bar higher than n bars on each side -----
      if(ArraySize(swingHighs) < need && IsSwingHigh(shift, n))
         AppendDouble(swingHighs, iHigh(_Symbol, _Period, shift));

      // ----- Swing Low: bar lower than n bars on each side -----
      if(ArraySize(swingLows) < need && IsSwingLow(shift, n))
         AppendDouble(swingLows, iLow(_Symbol, _Period, shift));

      if(ArraySize(swingHighs) >= need && ArraySize(swingLows) >= need)
         break;
     }

   // Need at least SwingCount swings of each type to judge structure.
   if(ArraySize(swingHighs) < need || ArraySize(swingLows) < need)
      return(0);

   // Arrays are ordered newest -> oldest (we appended from recent shifts).
   // Higher highs  : each newer high > the next older high.
   // Higher lows   : each newer low  > the next older low.
   bool higherHighs = true, higherLows = true;
   bool lowerHighs  = true, lowerLows  = true;

   for(int i = 0; i < need - 1; i++)
     {
      if(swingHighs[i] <= swingHighs[i + 1]) higherHighs = false;
      if(swingHighs[i] >= swingHighs[i + 1]) lowerHighs  = false;
      if(swingLows[i]  <= swingLows[i + 1])  higherLows  = false;
      if(swingLows[i]  >= swingLows[i + 1])  lowerLows   = false;
     }

   if(higherHighs && higherLows) return(+1);  // bullish structure
   if(lowerHighs  && lowerLows)  return(-1);  // bearish structure
   return(0);                                  // no clear trend
  }

//+------------------------------------------------------------------+
//| True if bar at 'shift' is a fractal swing high (n bars each side)|
//+------------------------------------------------------------------+
bool IsSwingHigh(int shift, int n)
  {
   double center = iHigh(_Symbol, _Period, shift);
   for(int k = 1; k <= n; k++)
     {
      if(iHigh(_Symbol, _Period, shift + k) >= center) return(false);
      if(iHigh(_Symbol, _Period, shift - k) >= center) return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| True if bar at 'shift' is a fractal swing low (n bars each side) |
//+------------------------------------------------------------------+
bool IsSwingLow(int shift, int n)
  {
   double center = iLow(_Symbol, _Period, shift);
   for(int k = 1; k <= n; k++)
     {
      if(iLow(_Symbol, _Period, shift + k) <= center) return(false);
      if(iLow(_Symbol, _Period, shift - k) <= center) return(false);
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
//| Calculate lot size so that risking to the SL = RiskPercent       |
//|   slDistance : price distance between entry and stop loss        |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
  {
   // 1) Determine the monetary amount to risk.
   double base = (RiskBase == RISK_ON_EQUITY)
                 ? AccountInfoDouble(ACCOUNT_EQUITY)
                 : AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = base * RiskPercent / 100.0;

   // 2) Money lost per 1.00 lot if price moves by slDistance.
   double tickSize  = symInfo.TickSize();
   double tickValue = symInfo.TickValue();
   if(tickSize <= 0.0 || tickValue <= 0.0)
     {
      Print("ERROR: Invalid tick size/value. Cannot size the position.");
      return(0.0);
     }

   double ticksInSL   = slDistance / tickSize;
   double lossPerLot  = ticksInSL * tickValue;   // account currency per 1.0 lot
   if(lossPerLot <= 0.0)
      return(0.0);

   // 3) Raw lot = risk money / loss per lot.
   double lots = riskMoney / lossPerLot;

   // 4) Normalise to broker volume constraints.
   lots = NormalizeVolume(lots);
   return(lots);
  }

//+------------------------------------------------------------------+
//| Normalise a volume to the symbol's min/max/step constraints      |
//+------------------------------------------------------------------+
double NormalizeVolume(double lots)
  {
   double minLot  = symInfo.LotsMin();
   double maxLot  = symInfo.LotsMax();
   double lotStep = symInfo.LotsStep();

   if(lotStep <= 0.0)
      lotStep = 0.01;

   // Round DOWN to the nearest step so we never exceed the intended risk.
   lots = MathFloor(lots / lotStep) * lotStep;

   // Clamp to allowed range.
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;

   // Fix floating point residue to the step's decimal precision.
   int digits = (int)MathCeil(-MathLog10(lotStep));
   if(digits < 0) digits = 0;
   lots = NormalizeDouble(lots, digits);

   return(lots);
  }

//+------------------------------------------------------------------+
//| Open a market position with SL/TP and risk-based volume          |
//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE type, double entry, double sl, double tp,
               double slDistance, datetime pinTime)
  {
   // 1) Respect the broker's minimum stop distance (stops level).
   double point     = symInfo.Point();
   long   stopsLvl  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStop   = stopsLvl * point;
   if(minStop > 0.0 && slDistance < minStop)
     {
      Print("Trade skipped: SL distance (", DoubleToString(slDistance, _Digits),
            ") is below broker minimum stop (", DoubleToString(minStop, _Digits), ").");
      return;
     }

   // 2) Size the position from the 1% risk and SL distance.
   double lots = CalculateLotSize(slDistance);
   if(lots <= 0.0)
     {
      Print("Trade skipped: calculated lot size is zero (risk too small for constraints).");
      return;
     }

   // 3) Normalise prices to symbol digits.
   int digits = (int)symInfo.Digits();
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   // 4) Send the order.
   bool ok = false;
   string comment = "PinBar";
   
   
   if(type != ORDER_TYPE_BUY)
      ok = trade.Buy(lots, _Symbol, 0.0, tp, sl, comment);
   else
      ok = trade.Sell(lots, _Symbol, 0.0, tp, sl, comment);
      
   //if(type == ORDER_TYPE_BUY)
   //   ok = trade.Buy(lots, _Symbol, 0.0, sl, tp, comment);
   //else
   //   ok = trade.Sell(lots, _Symbol, 0.0, sl, tp, comment);

   if(ok && (trade.ResultRetcode() == TRADE_RETCODE_DONE ||
             trade.ResultRetcode() == TRADE_RETCODE_PLACED))
     {
      // Mark this Pin Bar as used so we never trade the same setup twice.
      g_lastSignalPinTime = pinTime;

      PrintFormat("%s opened: lots=%.2f entry~%.5f SL=%.5f TP=%.5f (SLdist=%.5f, risk=%.2f%%)",
                  (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
                  lots, entry, sl, tp, slDistance, RiskPercent);
     }
   else
     {
      PrintFormat("Order FAILED (%s): retcode=%d, %s",
                  (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }
  }
//+------------------------------------------------------------------+
