//+------------------------------------------------------------------+
//|                                              QuasimodoRTM_EA.mq5 |
//|        RTM-Style Quasimodo (QM) Expert Advisor  —  MT5           |
//|                                                                  |
//|  Trades the same QM logic as the QuasimodoRTM indicator:         |
//|   • LS -> L1 -> HEAD -> BOS  =>  limit order at the QM level     |
//|     (Left Shoulder price = Right Shoulder retest entry)          |
//|   • SL beyond the HEAD (+ buffer)                                |
//|   • Position is fully closed at TP1 (TP = Entry +/- Risk * RR1)  |
//|   • Order expires if the retest does not happen in time          |
//|   • One trade per pattern (keyed by the HEAD bar time)           |
//+------------------------------------------------------------------+
#property copyright   "QuasimodoRTM"
#property link        ""
#property version     "1.00"
#property description "Expert Advisor based on the QuasimodoRTM indicator. Enters on the Right-Shoulder retest of the QM level, SL beyond the Head, closes the position on TP1."

#include <Trade\Trade.mqh>

input group    "=== Detection (same as indicator) ==="
input int      InpSwingStrength    = 3;      // Swing Strength (bars each side of a pivot)
input int      InpLookbackBars     = 1000;   // Lookback Bars to scan
input int      InpRetestMaxBars    = 300;    // Max bars to wait for Right-Shoulder retest (order expiry)

input group    "=== Trade Levels ==="
input int      InpSLBufferPoints   = 150;    // SL buffer beyond the Head (points)
input double   InpRR1              = 2.0;    // TP1 Risk-Reward (1 : x)  -> full close here

input group    "=== Money Management ==="
input double   InpRiskPercent      = 1.0;    // Risk % of equity per trade (0 = use fixed lots)
input double   InpFixedLots        = 0.10;   // Fixed lot size (used when Risk % = 0)
input int      InpMaxOpenTrades    = 3;      // Max simultaneous positions + pending orders

input group    "=== Filters ==="
input bool     InpTradeBullish     = true;   // Trade bullish QM (BUY)
input bool     InpTradeBearish     = true;   // Trade bearish QM (SELL)
input int      InpMaxSpreadPoints  = 0;      // Max spread in points (0 = no filter)

input group    "=== Misc ==="
input long     InpMagic            = 20260719; // Magic number
input string   InpComment          = "QM-RTM"; // Order comment prefix

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

struct QMSetup
  {
   bool              isBull;
   datetime          tHead;     // pattern signature
   datetime          tBOS;
   int               barBOS;
   double            entry;     // QM level (Left Shoulder)
   double            sl;
   double            tp1;
  };

CTrade   g_trade;
datetime g_lastBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(20);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_lastBarTime = 0;
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
  }
//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- work once per bar (pending limit orders handle the fills)
   datetime curBar = iTime(_Symbol,PERIOD_CURRENT,0);
   if(curBar == g_lastBarTime)
      return;
   g_lastBarTime = curBar;

   //--- load history (chronological: index 0 = oldest)
   int need = MathMin(InpLookbackBars + InpSwingStrength*2 + 10,
                      Bars(_Symbol,PERIOD_CURRENT));
   MqlRates rates[];
   ArraySetAsSeries(rates,false);
   int total = CopyRates(_Symbol,PERIOD_CURRENT,0,need,rates);
   if(total < InpSwingStrength*2+10)
      return;

   //--- detect swings and active (untested) QM setups
   SwingPoint swings[];
   FindSwings(rates,total,swings);

   QMSetup setups[];
   FindActiveSetups(swings,rates,total,setups);

   //--- place orders for new setups
   for(int i=0; i<ArraySize(setups); i++)
      TryPlaceOrder(setups[i]);
  }
//+------------------------------------------------------------------+
//| Detect alternating swing highs / lows                            |
//+------------------------------------------------------------------+
void FindSwings(const MqlRates &rates[],const int total,SwingPoint &swings[])
  {
   int s = InpSwingStrength;

   for(int i=s; i<total-s; i++)
     {
      bool isHigh = true;
      bool isLow  = true;
      for(int k=1; k<=s && (isHigh || isLow); k++)
        {
         if(rates[i].high <= rates[i-k].high || rates[i].high < rates[i+k].high) isHigh = false;
         if(rates[i].low  >= rates[i-k].low  || rates[i].low  > rates[i+k].low)  isLow  = false;
        }
      if(!isHigh && !isLow)
         continue;

      SwingPoint sp;
      sp.bar    = i;
      sp.time   = rates[i].time;
      sp.isHigh = isHigh;              // if both, treat as high first
      sp.price  = isHigh ? rates[i].high : rates[i].low;

      int n = ArraySize(swings);
      if(n>0 && swings[n-1].isHigh == sp.isHigh)
        {
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
//| Find QM setups whose BOS is done but QM level not yet retested   |
//+------------------------------------------------------------------+
void FindActiveSetups(const SwingPoint &swings[],const MqlRates &rates[],
                      const int total,QMSetup &setups[])
  {
   int    n     = ArraySize(swings);
   double slBuf = InpSLBufferPoints * _Point;

   for(int i=0; i+3<n; i++)
     {
      //================= BEARISH QM (SELL) =================
      if(InpTradeBearish &&
         swings[i].isHigh && !swings[i+1].isHigh &&
         swings[i+2].isHigh && !swings[i+3].isHigh &&
         swings[i+2].price > swings[i].price &&        // head takes out LS
         swings[i+3].price < swings[i+1].price)        // break of structure
        {
         double entry = swings[i].price;
         double sl    = swings[i+2].price + slBuf;
         double risk  = sl - entry;
         if(risk > 0.0 && IsStillActive(rates,total,swings[i+3].bar,entry,false,risk,swings[i+3].price))
            AddSetup(setups,false,swings[i+2].time,swings[i+3].time,
                     swings[i+3].bar,entry,sl,entry - risk*InpRR1);
        }
      //================= BULLISH QM (BUY) ==================
      if(InpTradeBullish &&
         !swings[i].isHigh && swings[i+1].isHigh &&
         !swings[i+2].isHigh && swings[i+3].isHigh &&
         swings[i+2].price < swings[i].price &&        // head takes out LS
         swings[i+3].price > swings[i+1].price)        // break of structure
        {
         double entry = swings[i].price;
         double sl    = swings[i+2].price - slBuf;
         double risk  = entry - sl;
         if(risk > 0.0 && IsStillActive(rates,total,swings[i+3].bar,entry,true,risk,swings[i+3].price))
            AddSetup(setups,true,swings[i+2].time,swings[i+3].time,
                     swings[i+3].bar,entry,sl,entry + risk*InpRR1);
        }
     }
  }
//+------------------------------------------------------------------+
//| Setup is active if the QM level was NOT touched since the BOS,   |
//| price did not run away, and the retest window has not expired    |
//+------------------------------------------------------------------+
bool IsStillActive(const MqlRates &rates[],const int total,const int barBOS,
                   const double entry,const bool isBull,const double risk,
                   const double bosPrice)
  {
   if(total-1 - barBOS > InpRetestMaxBars)
      return(false);                                  // window expired

   for(int b=barBOS+1; b<total; b++)
     {
      if(isBull)
        {
         if(rates[b].low  <= entry)            return(false); // already retested
         if(rates[b].high >  bosPrice + risk)  return(false); // ran away
        }
      else
        {
         if(rates[b].high >= entry)            return(false); // already retested
         if(rates[b].low  <  bosPrice - risk)  return(false); // ran away
        }
     }
   return(true);
  }
//+------------------------------------------------------------------+
void AddSetup(QMSetup &setups[],const bool isBull,const datetime tHead,
              const datetime tBOS,const int barBOS,const double entry,
              const double sl,const double tp1)
  {
   int c = ArraySize(setups);
   ArrayResize(setups,c+1);
   setups[c].isBull = isBull;
   setups[c].tHead  = tHead;
   setups[c].tBOS   = tBOS;
   setups[c].barBOS = barBOS;
   setups[c].entry  = NormalizePrice(entry);
   setups[c].sl     = NormalizePrice(sl);
   setups[c].tp1    = NormalizePrice(tp1);
  }
//+------------------------------------------------------------------+
//| Place a limit order at the QM level (Right-Shoulder retest)      |
//+------------------------------------------------------------------+
void TryPlaceOrder(const QMSetup &s)
  {
   //--- one trade per pattern (signature = head time)
   string sig = SignatureKey(s);
   if(GlobalVariableCheck(sig))
      return;

   //--- exposure limit
   if(CountMine() >= InpMaxOpenTrades)
      return;

   //--- spread filter
   if(InpMaxSpreadPoints > 0)
     {
      long spread = SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
      if(spread > InpMaxSpreadPoints)
         return;
     }

   //--- validate the limit price vs current market
   double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   int    stopsLvl = (int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minDist  = stopsLvl * _Point;

   if(s.isBull  && !(s.entry < bid - minDist)) return;   // buy limit must be below
   if(!s.isBull && !(s.entry > ask + minDist)) return;   // sell limit must be above

   //--- lot size
   double lots = CalcLots(MathAbs(s.entry - s.sl));
   if(lots <= 0.0)
      return;

   //--- expiration = end of the retest window
   datetime expiry = s.tBOS + (datetime)PeriodSeconds()*InpRetestMaxBars;
   if(expiry <= TimeCurrent() + PeriodSeconds())
      return;

   string comment = InpComment + (s.isBull ? " BUY " : " SELL ") +
                    TimeToString(s.tHead,TIME_DATE|TIME_MINUTES);

   bool ok;
   if(s.isBull)
      ok = g_trade.BuyLimit (lots,s.entry,_Symbol,s.sl,s.tp1,
                             ORDER_TIME_SPECIFIED,expiry,comment);
   else
      ok = g_trade.SellLimit(lots,s.entry,_Symbol,s.sl,s.tp1,
                             ORDER_TIME_SPECIFIED,expiry,comment);

   if(ok && (g_trade.ResultRetcode()==TRADE_RETCODE_DONE ||
             g_trade.ResultRetcode()==TRADE_RETCODE_PLACED))
     {
      GlobalVariableSet(sig,1.0);   // never trade this pattern again
      PrintFormat("QM-EA: %s limit placed @ %s | SL %s | TP1 %s | lots %.2f",
                  s.isBull?"BUY":"SELL",
                  DoubleToString(s.entry,_Digits),
                  DoubleToString(s.sl,_Digits),
                  DoubleToString(s.tp1,_Digits),lots);
     }
   else
      PrintFormat("QM-EA: order failed, retcode=%d (%s)",
                  g_trade.ResultRetcode(),g_trade.ResultRetcodeDescription());
  }
//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
string SignatureKey(const QMSetup &s)
  {
   return StringFormat("QMEA_%s_%s_%d_%d",_Symbol,
                       s.isBull?"B":"S",(int)Period(),(long)s.tHead);
  }

int CountMine()
  {
   int cnt = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk>0 && PositionGetInteger(POSITION_MAGIC)==InpMagic &&
         PositionGetString(POSITION_SYMBOL)==_Symbol)
         cnt++;
     }
   for(int i=OrdersTotal()-1; i>=0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk>0 && OrderGetInteger(ORDER_MAGIC)==InpMagic &&
         OrderGetString(ORDER_SYMBOL)==_Symbol)
         cnt++;
     }
   return(cnt);
  }

double CalcLots(const double slDistance)
  {
   double lots = InpFixedLots;

   if(InpRiskPercent > 0.0 && slDistance > 0.0)
     {
      double tickValue = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
      if(tickValue > 0.0 && tickSize > 0.0)
        {
         double riskMoney    = AccountInfoDouble(ACCOUNT_EQUITY)*InpRiskPercent/100.0;
         double lossPerLot   = slDistance/tickSize*tickValue;
         if(lossPerLot > 0.0)
            lots = riskMoney/lossPerLot;
        }
     }

   double minLot  = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(lotStep > 0.0)
      lots = MathFloor(lots/lotStep)*lotStep;
   lots = MathMax(minLot,MathMin(maxLot,lots));
   return(NormalizeDouble(lots,2));
  }

double NormalizePrice(const double price)
  {
   return(NormalizeDouble(price,_Digits));
  }
//+------------------------------------------------------------------+
