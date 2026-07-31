//+------------------------------------------------------------------+
//|                                            SessionBreakoutEA.mq5 |
//+------------------------------------------------------------------+
#property copyright "Hamid Attari"
#property link      ""
#property version   "1.05" // Added Dynamic Range Multiplier for SL/TP

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\DealInfo.mqh>

// ============================================================================
//  ENUMS
// ============================================================================
enum ENUM_EXECUTION_MODE
{
    EXEC_PENDING_ORDERS, // Pending Orders Mode (Buy Stop / Sell Stop)
    EXEC_CANDLE_CLOSE    // Candle Close Mode (Market Buy / Market Sell)
};

// ============================================================================
//  INPUTS — TIMES 
// ============================================================================
input group    "--- Times (Broker Server Time) ---";
input int      DayOpenHour = 1;      // Tracking Start Hour
input int      DayOpenMin = 0;      // Tracking Start Minute
input int      TokyoHour = 3;      // Tokyo Open Hour
input int      TokyoMin = 0;      // Tokyo Open Minute

// ============================================================================
//  INPUTS — RISK MANAGEMENT
// ============================================================================
input group    "--- Risk Management ---";
input double   RiskPct = 1.0;     // Risk % of Equity per Trade
input double   RiskReward = 4.0;     // Main Risk:Reward Ratio (e.g., TP3 = 3.0)
input double   PartialClosePct = 50.0;    // Percentage of position to close at BE (0 to disable)

// ============================================================================
//  INPUTS — BREAK EVEN (RISK FREE)
// ============================================================================
input group    "--- Break Even Settings ---";
input bool     EnableBreakEven = true;   // Enable Break-Even logic?
input double   BE_Trigger_R = 2.0;    // Trigger Break-Even at this 'R' (e.g., TP2 = 2.0)
input int      BE_Offset = 10;     // Break-Even Offset from Entry (points, to cover spread/fees)

// ============================================================================
//  INPUTS — ORDER SETTINGS
// ============================================================================
input group               "--- Order Settings ---";
input ENUM_EXECUTION_MODE ExecutionMode = EXEC_CANDLE_CLOSE; // Entry Execution Mode
input bool                EnableLong = true;   // Enable Buy (Long)
input bool                EnableShort = true;   // Enable Sell (Short)
input ulong               MagicNumber = 123456; // Magic Number
input ulong               Slippage = 3;      // Slippage (points)
input int                 SL_Offset = 100;    // Stop Loss Offset (points, further away)
input int                 TP_Offset = 100;    // Take Profit Offset (points, closer to entry)

// ============================================================================
//  INPUTS — DYNAMIC RANGE MULTIPLIER
// ============================================================================
//  Session Range = HH - LL (expressed in the symbol's price units).
//  The selected multiplier is applied to the FINAL Stop Loss and Take Profit
//  distances, i.e. AFTER every other calculation, including the SL Buffer
//  (SL_Offset) and TP Buffer (TP_Offset).
//  The exact same multiplier is applied to both SL and TP, therefore the
//  original Risk:Reward ratio is preserved.
// ============================================================================
input group    "--- Dynamic Range Multiplier ---";
input bool     EnableRangeMultiplier = false; // Enable Dynamic Range Multiplier?
input double   Range_L1_Max = 10.0;   // Range Level 1 Maximum (Range < this)
input double   Range_L2_Max = 20.0;   // Range Level 2 Maximum
input double   Range_L3_Max = 40.0;   // Range Level 3 Maximum
input double   Range_L4_Min = 60.0;   // Range Level 4 Minimum
input double   Range_L4_Max = 80.0;   // Range Level 4 Maximum
input double   Mult_Range_L1 = 2.0;    // Multiplier for Range < L1 Max (e.g. < 10)
input double   Mult_Range_L2 = 1.0;    // Multiplier for L1 Max - L2 Max (e.g. 10-20)
input double   Mult_Range_L3 = 0.5;    // Multiplier for L2 Max - L3 Max (e.g. 20-40)
input double   Mult_Range_L4 = 0.25;   // Multiplier for L4 Min - L4 Max (e.g. 60-80)

// ============================================================================
//  INPUTS — TRADE MANAGEMENT
// ============================================================================
input group    "--- Trade Management ---";
input int      MaxTrades = 2;      // Max Trades per Day
input bool     CancelOpposite = false;  // Cancel Opposite Order/Monitoring on TP Hit

// ============================================================================
//  GLOBAL VARIABLES
// ============================================================================
CTrade         trade;
CPositionInfo  posInfo;
COrderInfo     orderInfo;

double         HH = 0.0;
double         LL = 0.0;
bool           isTracking = false;
bool           ordersPlaced = false;
int            currentDayOfYear = -1;
int            tradesTakenToday = 0;

// Variables for Pending Orders mode
ulong          buyStopTicket = 0;
ulong          sellStopTicket = 0;

// Variables for Candle Close mode
bool           monitorBuy = false;
bool           monitorSell = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_FOK);
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Calculate Lot Size based on Risk %                               |
//+------------------------------------------------------------------+
double CalculateLots(double entryPrice, double stopLoss)
{
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskAmount = equity * (RiskPct / 100.0);

    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    if (tickSize == 0 || tickValue == 0) return 0.0;

    double stopDistancePoints = MathAbs(entryPrice - stopLoss) / tickSize;
    if (stopDistancePoints == 0) return 0.0;

    double lotSize = riskAmount / (stopDistancePoints * tickValue);

    // Normalize lot size to broker specifications
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    lotSize = MathFloor(lotSize / stepLot) * stepLot;
    if (lotSize < minLot) lotSize = minLot;
    if (lotSize > maxLot) lotSize = maxLot;

    return lotSize;
}

//+------------------------------------------------------------------+
//| Get Dynamic Range Multiplier for the current session range        |
//+------------------------------------------------------------------+
double GetRangeMultiplier(double range)
{
    if (!EnableRangeMultiplier) return 1.0;
    if (range <= 0.0)           return 1.0;

    // Level 1 : Range < L1 Max                 (default: < 10   -> 2.00x)
    if (range < Range_L1_Max)
        return Mult_Range_L1;

    // Level 2 : L1 Max <= Range < L2 Max       (default: 10-20   -> 1.00x)
    if (range >= Range_L1_Max && range < Range_L2_Max)
        return Mult_Range_L2;

    // Level 3 : L2 Max <= Range < L3 Max       (default: 20-40   -> 0.50x)
    if (range >= Range_L2_Max && range < Range_L3_Max)
        return Mult_Range_L3;

    // Level 4 : L4 Min <= Range < L4 Max       (default: 60-80   -> 0.25x)
    if (range >= Range_L4_Min && range < Range_L4_Max)
        return Mult_Range_L4;

    // Any range not covered by the levels above (e.g. 40-60 or >= 80 with the
    // default settings) leaves Stop Loss and Take Profit untouched.
    return 1.0;
}

//+------------------------------------------------------------------+
//| Apply the Dynamic Range Multiplier to final SL / TP levels        |
//| Must be called LAST, after SL/TP buffers have been applied.       |
//| Scales both distances from entry by the same factor, so the       |
//| Risk:Reward ratio stays identical.                                |
//+------------------------------------------------------------------+
void ApplyRangeMultiplier(const double entryPrice, double& sl, double& tp, const double range)
{
    double mult = GetRangeMultiplier(range);
    if (mult == 1.0) return;

    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

    // Signed distances -> works for both Buy and Sell without extra branching
    double slDistance = sl - entryPrice;
    double tpDistance = tp - entryPrice;

    sl = NormalizeDouble(entryPrice + (slDistance * mult), digits);
    tp = NormalizeDouble(entryPrice + (tpDistance * mult), digits);

    PrintFormat("Dynamic Range Multiplier: Range=%.2f -> x%.2f | Entry=%s SL=%s TP=%s",
        range, mult,
        DoubleToString(entryPrice, digits),
        DoubleToString(sl, digits),
        DoubleToString(tp, digits));
}

//+------------------------------------------------------------------+
//| Cancel specific pending order                                    |
//+------------------------------------------------------------------+
void CancelOrder(ulong ticket)
{
    if (ticket > 0 && orderInfo.Select(ticket))
    {
        trade.OrderDelete(ticket);
    }
}

//+------------------------------------------------------------------+
//| Manage Break Even and Partial Close for Open Positions           |
//+------------------------------------------------------------------+
void ManageBreakEven()
{
    if (!EnableBreakEven) return;

    for (int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if (PositionSelectByTicket(ticket))
        {
            if (PositionGetInteger(POSITION_MAGIC) == MagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol)
            {
                double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
                double currentSL = PositionGetDouble(POSITION_SL);
                double currentTP = PositionGetDouble(POSITION_TP);
                double currentVol = PositionGetDouble(POSITION_VOLUME);
                long   posType = PositionGetInteger(POSITION_TYPE);

                double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
                int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

                // Volume constraints for partial close
                double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
                double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

                if (posType == POSITION_TYPE_BUY)
                {
                    double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);

                    // If SL has not been moved to Break-Even yet (SL is still below Entry)
                    if (currentSL > 0 && currentSL < entryPrice)
                    {
                        double initialRiskDist = entryPrice - currentSL;
                        double triggerPrice = entryPrice + (initialRiskDist * BE_Trigger_R);

                        if (currentPrice >= triggerPrice)
                        {
                            double newSL = NormalizeDouble(entryPrice + (BE_Offset * point), digits);

                            // 1. Move Stop Loss to Risk-Free
                            if (trade.PositionModify(ticket, newSL, currentTP))
                            {
                                // 2. Execute Partial Close if percentage is set > 0
                                double volToClose = MathFloor((currentVol * (PartialClosePct / 100.0)) / stepLot) * stepLot;
                                if (volToClose >= minLot)
                                {
                                    trade.PositionClosePartial(ticket, volToClose);
                                }
                            }
                        }
                    }
                }
                else if (posType == POSITION_TYPE_SELL)
                {
                    double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

                    // If SL has not been moved to Break-Even yet (SL is still above Entry)
                    if (currentSL > 0 && currentSL > entryPrice)
                    {
                        double initialRiskDist = currentSL - entryPrice;
                        double triggerPrice = entryPrice - (initialRiskDist * BE_Trigger_R);

                        if (currentPrice <= triggerPrice)
                        {
                            double newSL = NormalizeDouble(entryPrice - (BE_Offset * point), digits);

                            // 1. Move Stop Loss to Risk-Free
                            if (trade.PositionModify(ticket, newSL, currentTP))
                            {
                                // 2. Execute Partial Close if percentage is set > 0
                                double volToClose = MathFloor((currentVol * (PartialClosePct / 100.0)) / stepLot) * stepLot;
                                if (volToClose >= minLot)
                                {
                                    trade.PositionClosePartial(ticket, volToClose);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    datetime timeCurrent = TimeCurrent();
    MqlDateTime dtCurrent;
    TimeToStruct(timeCurrent, dtCurrent);

    // Construct today's target times
    MqlDateTime dtDayOpen = dtCurrent;
    dtDayOpen.hour = DayOpenHour;
    dtDayOpen.min = DayOpenMin;
    dtDayOpen.sec = 0;
    datetime dayOpenTime = StructToTime(dtDayOpen);

    MqlDateTime dtTokyoOpen = dtCurrent;
    dtTokyoOpen.hour = TokyoHour;
    dtTokyoOpen.min = TokyoMin;
    dtTokyoOpen.sec = 0;
    datetime tokyoOpenTime = StructToTime(dtTokyoOpen);

    // 1. DAILY RESET
    if (dtCurrent.day_of_year != currentDayOfYear)
    {
        // It's a new day, wait until DayOpenTime to reset completely
        if (timeCurrent >= dayOpenTime)
        {
            currentDayOfYear = dtCurrent.day_of_year;
            HH = 0.0;
            LL = 0.0;
            ordersPlaced = false;
            tradesTakenToday = 0;
            buyStopTicket = 0;
            sellStopTicket = 0;
            monitorBuy = false;
            monitorSell = false;
            isTracking = true;

            // Cancel leftover pending orders from previous days (End of Day expiry)
            for (int i = OrdersTotal() - 1; i >= 0; i--)
            {
                ulong ticket = OrderGetTicket(i);
                if (OrderSelect(ticket) && OrderGetInteger(ORDER_MAGIC) == MagicNumber)
                    trade.OrderDelete(ticket);
            }
        }
    }

    // 2. TRACKING WINDOW (Between Day Open and Tokyo Open)
    if (timeCurrent >= dayOpenTime && timeCurrent < tokyoOpenTime && isTracking)
    {
        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

        if (HH == 0.0 || bid > HH) HH = bid;
        if (LL == 0.0 || ask < LL) LL = ask;
    }

    // 3. TOKYO OPEN - PLACE PENDING ORDERS OR START MONITORING
    if (timeCurrent >= tokyoOpenTime && isTracking && !ordersPlaced)
    {
        isTracking = false; // Stop tracking for today

        if (HH > 0 && LL > 0 && HH > LL)
        {
            double risk = HH - LL;
            int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
            double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

            // MODE 1: PENDING ORDERS
            if (ExecutionMode == EXEC_PENDING_ORDERS)
            {
                // Standardize prices with Offsets applied
                double buyEntry = NormalizeDouble(HH, digits);
                double buySL = NormalizeDouble(LL - (SL_Offset * point), digits);
                double buyTP = NormalizeDouble(HH + (RiskReward * risk) - (TP_Offset * point), digits);

                double sellEntry = NormalizeDouble(LL, digits);
                double sellSL = NormalizeDouble(HH + (SL_Offset * point), digits);
                double sellTP = NormalizeDouble(LL - (RiskReward * risk) + (TP_Offset * point), digits);

                // --- FINAL STEP: Dynamic Range Multiplier (after all offsets) ---
                ApplyRangeMultiplier(buyEntry, buySL, buyTP, risk);
                ApplyRangeMultiplier(sellEntry, sellSL, sellTP, risk);

                // Place Buy Stop
                if (EnableLong && tradesTakenToday < MaxTrades)
                {
                    double lotL = CalculateLots(buyEntry, buySL);
                    if (trade.BuyStop(lotL, buyEntry, _Symbol, buySL, buyTP, ORDER_TIME_DAY, 0, "Tokyo Buy Stop"))
                    {
                        buyStopTicket = trade.ResultOrder();
                        tradesTakenToday++;
                    }
                }

                // Place Sell Stop
                if (EnableShort && tradesTakenToday < MaxTrades)
                {
                    double lotS = CalculateLots(sellEntry, sellSL);
                    if (trade.SellStop(lotS, sellEntry, _Symbol, sellSL, sellTP, ORDER_TIME_DAY, 0, "Tokyo Sell Stop"))
                    {
                        sellStopTicket = trade.ResultOrder();
                        tradesTakenToday++;
                    }
                }
            }
            // MODE 2: CANDLE CLOSE BREAKOUT
            else if (ExecutionMode == EXEC_CANDLE_CLOSE)
            {
                monitorBuy = EnableLong;
                monitorSell = EnableShort;
            }

            ordersPlaced = true;
        }
    }

    // 4. CANDLE CLOSE BREAKOUT EXECUTION (EXEC_CANDLE_CLOSE Mode Only)
    if (ExecutionMode == EXEC_CANDLE_CLOSE && ordersPlaced && (monitorBuy || monitorSell) && tradesTakenToday < MaxTrades)
    {
        MqlRates rates[];
        ArraySetAsSeries(rates, true);
        if (CopyRates(_Symbol, _Period, 1, 1, rates) > 0)
        {
            double lastClose = rates[0].close;

            double risk = HH - LL;
            int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
            double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

            // --- Check Buy Breakout ---
            if (monitorBuy && lastClose > HH)
            {
                double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

                double buySL = NormalizeDouble(LL - (SL_Offset * point), digits);
                double buyTP = NormalizeDouble(HH + (RiskReward * risk) - (TP_Offset * point), digits);

                // --- FINAL STEP: Dynamic Range Multiplier (after all offsets) ---
                ApplyRangeMultiplier(ask, buySL, buyTP, risk);

                double lotL = CalculateLots(ask, buySL);

                if (trade.Buy(lotL, _Symbol, ask, buySL, buyTP, "Tokyo Buy Breakout"))
                {
                    monitorBuy = false; // Disable buy monitoring for current session
                    tradesTakenToday++;
                }
            }

            // --- Check Sell Breakout ---
            if (monitorSell && lastClose < LL)
            {
                double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

                double sellSL = NormalizeDouble(HH + (SL_Offset * point), digits);
                double sellTP = NormalizeDouble(LL - (RiskReward * risk) + (TP_Offset * point), digits);

                // --- FINAL STEP: Dynamic Range Multiplier (after all offsets) ---
                ApplyRangeMultiplier(bid, sellSL, sellTP, risk);

                double lotS = CalculateLots(bid, sellSL);

                if (trade.Sell(lotS, _Symbol, bid, sellSL, sellTP, "Tokyo Sell Breakout"))
                {
                    monitorSell = false; // Disable sell monitoring for current session
                    tradesTakenToday++;
                }
            }
        }
    }

    // 5. TRADE MANAGEMENT - CANCEL OPPOSITE ON TP
    if (CancelOpposite && ordersPlaced)
    {
        HistorySelect(dayOpenTime, timeCurrent);
        int dealsTotal = HistoryDealsTotal();

        for (int i = dealsTotal - 1; i >= 0; i--)
        {
            ulong dealTicket = HistoryDealGetTicket(i);
            if (HistoryDealGetInteger(dealTicket, DEAL_MAGIC) == MagicNumber)
            {
                if (HistoryDealGetInteger(dealTicket, DEAL_ENTRY) == DEAL_ENTRY_OUT)
                {
                    double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
                    if (profit > 0)
                    {
                        long dealType = HistoryDealGetInteger(dealTicket, DEAL_TYPE);

                        // If Long exited with profit
                        if (dealType == DEAL_TYPE_SELL) // A long position closes via a Sell deal
                        {
                            if (ExecutionMode == EXEC_PENDING_ORDERS)
                            {
                                CancelOrder(sellStopTicket);
                                sellStopTicket = 0;
                            }
                            else if (ExecutionMode == EXEC_CANDLE_CLOSE)
                            {
                                monitorSell = false;
                            }
                        }
                        // If Short exited with profit
                        else if (dealType == DEAL_TYPE_BUY) // A short position closes via a Buy deal
                        {
                            if (ExecutionMode == EXEC_PENDING_ORDERS)
                            {
                                CancelOrder(buyStopTicket);
                                buyStopTicket = 0;
                            }
                            else if (ExecutionMode == EXEC_CANDLE_CLOSE)
                            {
                                monitorBuy = false;
                            }
                        }
                    }
                }
            }
        }
    }

    // 6. CONTINUOUS RISK-FREE MONITORING
    ManageBreakEven();
}
//+------------------------------------------------------------------+