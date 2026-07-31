//+------------------------------------------------------------------+
//|                                      DailyLevelsBreakout_EA.mq5  |
//|  Dynamic Daily High/Low breakout EA                              |
//|  - 3 level-detection methods                                     |
//|  - Breakout quality / range / origin entry filters               |
//|  - 4 Fully Independent Trading Sessions                          |
//|  - Trade 1 @ RR 1:2, Trade 2 (only after SL) @ RR 1:4 (per sesh) |
//|  - Max 2 trades per session, halt after TP or after trade 2      |
//+------------------------------------------------------------------+
#property copyright "DailyLevelsBreakout"
#property version   "2.20"
#property strict

#include <Trade\Trade.mqh>

//--- Detection method enum
enum ENUM_DETECTION_METHOD
{
    METHOD_1 = 1,   // Method 1: Base High/Low of lookback window
    METHOD_2 = 2,   // Method 2: Base + confirmation-candle update
    METHOD_3 = 3    // Method 3: Reference candle High/Low
};

//--- Update mode for Method 2
enum ENUM_UPDATE_MODE
{
    UPDATE_MAIN_HL = 0  // Update Main High and Low
};

//--- Entry mode enum
enum ENUM_ENTRY_MODE
{
    ENTRY_MODE_1 = 1,   // EntryMode = 1 (DMT)
    ENTRY_MODE_2 = 2,   // EntryMode = 2 (Breakout Entry)
    ENTRY_MODE_3 = 3    // EntryMode = 3 (Breakout Entry & Candle Close Confirmation)
};

//=== Inputs =========================================================
input group "=== Daily Level Detection ==="
input int                    InpLookbackN = 12;         // Lookback Candles 'N'
input int                    InpUpdateX = 3;          // Update Candle Threshold 'X' (Method 2)
input ENUM_DETECTION_METHOD  InpMethod = METHOD_1;   // Detection Method
input ENUM_UPDATE_MODE       InpUpdateMode = UPDATE_MAIN_HL; // Update Mode (Method 2)

input group "=== Session 1 ==="
input bool                   InpS1_Enable = true;       // Enable Session 1
input int                    InpS1_RefH = 3;          // Reference Hour
input int                    InpS1_RefM = 0;          // Reference Minute
input int                    InpS1_EndH = 10;         // Trading End Hour
input int                    InpS1_EndM = 0;          // Trading End Minute
input color                  InpS1_Color = clrTomato;  // Line Color

input group "=== Session 2 ==="
input bool                   InpS2_Enable = true;       // Enable Session 2
input int                    InpS2_RefH = 10;         // Reference Hour
input int                    InpS2_RefM = 0;          // Reference Minute
input int                    InpS2_EndH = 17;         // Trading End Hour
input int                    InpS2_EndM = 0;          // Trading End Minute
input color                  InpS2_Color = clrDeepSkyBlue; // Line Color

input group "=== Session 3 ==="
input bool                   InpS3_Enable = true;      // Enable Session 3
input int                    InpS3_RefH = 15;         // Reference Hour
input int                    InpS3_RefM = 0;          // Reference Minute
input int                    InpS3_EndH = 22;         // Trading End Hour
input int                    InpS3_EndM = 0;          // Trading End Minute
input color                  InpS3_Color = clrGold;    // Line Color

input group "=== Session 4 ==="
input bool                   InpS4_Enable = true;      // Enable Session 4
input int                    InpS4_RefH = 19;         // Reference Hour
input int                    InpS4_RefM = 0;          // Reference Minute
input int                    InpS4_EndH = 23;         // Trading End Hour
input int                    InpS4_EndM = 59;         // Trading End Minute
input color                  InpS4_Color = clrOrchid;  // Line Color

input group "=== Trade Execution ==="
input ENUM_ENTRY_MODE        InpEntryMode = ENTRY_MODE_1; // Trade Entry Mode
input bool                   InpSkipSecondTradeIfFirstTP = true; // Skip second trade if first reaches TP
input double                 InpSLBufferPoints = 50.0;       // SL Buffer (points)
input double                 InpTPBufferPoints = 50.0;       // TP Buffer (points)
input bool                   InpUseRiskPercent = true;       // Use risk % sizing (else fixed lot)
input double                 InpRiskPercent = 0.2;        // Risk % of balance per trade
input double                 InpFixedLot = 0.10;       // Fixed lot size
input ulong                  InpMagic = 20260729;   // Base Magic Number (Sessions use Base + 0,1,2,3)
input int                    InpSlippagePoints = 20;         // Max slippage (points)

input group "=== Close Before Market Close ==="
input bool                   EnableCloseBeforeMarketClose = true;  // Enable market-close protection
input int                    MinutesBeforeMarketClose = 15;    // Close positions X minutes before market close
input int                    InpMC_SessionMergeGapMin = 5;     // Advanced: merge sessions separated by <= N min
input bool                   InpMC_CloseOnlyEaTrades = true;  // Only touch this EA's orders/positions (by Magic)

input group "=== Display ==="
input bool                   InpDrawLevels = true;           // Draw daily levels on chart
input ENUM_LINE_STYLE        InpLineStyle = STYLE_DOT;      // High/Low Line Style
input ENUM_LINE_STYLE        InpReferenceLineStyle = STYLE_DOT;      // Reference Time Line Style
input int                    InpPriceLabelFontSize = 9;              // Price Label Font Size (8-10)

input group "=== Reset Button UI Settings ==="
input ENUM_BASE_CORNER   InpBtnCorner = CORNER_LEFT_UPPER; // Anchor Corner
input int                InpBtnX = 20;                // X Distance (pixels)
input int                InpBtnY = 130;               // Y Distance (pixels)
input int                InpBtnWidth = 120;               // Button Width (pixels)
input int                InpBtnHeight = 30;                // Button Height (pixels)

//=== Structs & Globals =============================================
CTrade    g_trade;
datetime  g_lastBarTime = 0;
datetime  g_lastChartDay = 0;
const string OBJ_PREFIX = "DLB_";

//--- Market-Close Protection state ---------------------------------
bool     g_mcBlockTrading = false;  // new entries blocked until next trading session
datetime g_mcResumeTime = 0;      // server time at which trading may resume
datetime g_mcHandledClose = 0;      // market-close stamp already acted upon
datetime g_mcLoggedClose = 0;      // market-close stamp already logged
int      g_mcLastLoggedMin = -1;     // countdown log throttle
int      g_mcMinutes = 15;     // validated copy of MinutesBeforeMarketClose
bool     g_mcNoSchedWarned = false;  // "no session data" warning printed once

struct SessionData
{
    bool              enable;
    int               refH, refM;
    int               endH, endM;
    color             lineColor;

    // Level Calculation Results
    bool              levelsSet;
    datetime          levelsDay;       // 00:00 timestamp of the day levels were calculated
    double            definedHigh;
    double            definedLow;
    double            originalHigh;    // Store the original calculated high for reset
    double            originalLow;     // Store the original calculated low for reset
    datetime          refBarTime;
    datetime          lineStartTime;   // Left anchor timestamp
    datetime          lineEndTime;     // Right anchor timestamp (NEW: prevents horizontal dragging)

    // Session State Tracking
    int               tradesToday;
    bool              trade1HitSL;
    bool              haltTrading;

    // Breakout Direction Tracking Locks
    bool              buyTriggered;
    bool              sellTriggered;
};

SessionData g_sessions[4];

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    Print("DailyLevelsBreakout_EA.OnInit()");

    g_trade.SetDeviationInPoints(InpSlippagePoints);
    g_trade.SetTypeFillingBySymbol(_Symbol);

    // --- Market-Close Protection: validate inputs and arm watchdog timer ---
    g_mcBlockTrading = false;
    g_mcResumeTime = 0;
    g_mcHandledClose = 0;
    g_mcLoggedClose = 0;
    g_mcLastLoggedMin = -1;
    g_mcMinutes = MinutesBeforeMarketClose;

    if (EnableCloseBeforeMarketClose)
    {
        if (g_mcMinutes < 1)
        {
            Print("[MarketClose] MinutesBeforeMarketClose < 1 -> clamped to 1.");
            g_mcMinutes = 1;
        }
        if (g_mcMinutes > 1440)
        {
            Print("[MarketClose] MinutesBeforeMarketClose > 1440 -> clamped to 1440.");
            g_mcMinutes = 1440;
        }

        datetime mcClose = 0;
        if (MC_GetMarketCloseTime(MC_ServerNow(), mcClose))
            PrintFormat("[MarketClose] Enabled. Threshold=%d min. Current session closes at %s (server time).",
                g_mcMinutes, TimeToString(mcClose, TIME_DATE | TIME_MINUTES));
        else
            PrintFormat("[MarketClose] Enabled. Threshold=%d min. %s is outside a trading session right now.",
                g_mcMinutes, _Symbol);

        EventSetTimer(5);   // watchdog: keeps working when ticks stop arriving before the close
    }

    // --- FIX: Reset global variables memory on Initialization ---
    // This ensures levels force-recalculate when input parameters (like InpLookbackN) change
    ZeroMemory(g_sessions);

    // Create Reset Button on Chart
    CreateResetButton();

    // Initialize Session Array
    g_sessions[0].enable = InpS1_Enable;
    g_sessions[0].refH = InpS1_RefH;
    g_sessions[0].refM = InpS1_RefM;
    g_sessions[0].endH = InpS1_EndH;
    g_sessions[0].endM = InpS1_EndM;
    g_sessions[0].lineColor = InpS1_Color;
    g_sessions[1].enable = InpS2_Enable;
    g_sessions[1].refH = InpS2_RefH;
    g_sessions[1].refM = InpS2_RefM;
    g_sessions[1].endH = InpS2_EndH;
    g_sessions[1].endM = InpS2_EndM;
    g_sessions[1].lineColor = InpS2_Color;
    g_sessions[2].enable = InpS3_Enable;
    g_sessions[2].refH = InpS3_RefH;
    g_sessions[2].refM = InpS3_RefM;
    g_sessions[2].endH = InpS3_EndH;
    g_sessions[2].endM = InpS3_EndM;
    g_sessions[2].lineColor = InpS3_Color;
    g_sessions[3].enable = InpS4_Enable;
    g_sessions[3].refH = InpS4_RefH;
    g_sessions[3].refM = InpS4_RefM;
    g_sessions[3].endH = InpS4_EndH;
    g_sessions[3].endM = InpS4_EndM;
    g_sessions[3].lineColor = InpS4_Color;

    for (int i = 0; i < 4; i++)
    {
        if (g_sessions[i].enable)
        {
            if (g_sessions[i].refH < 0 || g_sessions[i].refH > 23 || g_sessions[i].refM < 0 || g_sessions[i].refM > 59)
            {
                PrintFormat("Invalid Reference Time for Session %d", i + 1);
                return(INIT_PARAMETERS_INCORRECT);
            }
        }
    }

    g_trade.SetDeviationInPoints(InpSlippagePoints);
    g_trade.SetTypeFillingBySymbol(_Symbol);

    // Compute levels on attach if time has already passed
    for (int i = 0; i < 4; i++)
        UpdateSessionLevels(i);

    g_lastBarTime = 0;
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Deinitialization                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    // --- FIX: Removed 'if(reason == REASON_REMOVE)' ---
    // Always delete chart objects on Deinit (including REASON_PARAMETERS)
    // to prevent stuck drawings when modifying inputs
    ObjectsDeleteAll(0, OBJ_PREFIX);

    EventKillTimer();   // Market-Close Protection watchdog
}

//+------------------------------------------------------------------+
//| Tick Handler                                                     |
//+------------------------------------------------------------------+
void OnTick()
{
    // Market-close protection runs before anything else so it can veto new entries
    if (EnableCloseBeforeMarketClose)
        ManageMarketCloseProtection();

    // Continuous trade state monitor (instantly catch SL/TP closes)
    UpdateTradeState();

    // For EntryMode 2 (Breakout Entry), evaluate on every tick after Reference Time
    if (InpEntryMode == ENTRY_MODE_2)
    {
        for (int i = 0; i < 4; i++)
        {
            if (IsSessionActiveForTrading(i))
                CheckEntrySignal(i);
        }
    }

    if (!IsNewBar())
        return;

    // 1. Calculate session levels
    for (int i = 0; i < 4; i++)
        UpdateSessionLevels(i);

    // 2. Evaluate entry signals for active sessions (EntryMode 1 and EntryMode 3)
    if (InpEntryMode != ENTRY_MODE_2)
    {
        for (int i = 0; i < 4; i++)
        {
            if (IsSessionActiveForTrading(i))
                CheckEntrySignal(i);
        }
    }
}

//+------------------------------------------------------------------+
//| New bar detection                                                |
//+------------------------------------------------------------------+
bool IsNewBar()
{
    datetime t = iTime(_Symbol, _Period, 0);
    if (t == g_lastBarTime)
        return(false);
    g_lastBarTime = t;
    return(true);
}

//+------------------------------------------------------------------+
//| Session level detection                                          |
//+------------------------------------------------------------------+
void UpdateSessionLevels(int sIdx)
{
    if (!g_sessions[sIdx].enable)
        return;

    datetime now = TimeCurrent();
    MqlDateTime dt;
    TimeToStruct(now, dt);

    // Build today's Reference Time for session sIdx
    dt.hour = g_sessions[sIdx].refH;
    dt.min = g_sessions[sIdx].refM;
    dt.sec = 0;
    datetime refTime = StructToTime(dt);

    dt.hour = 0;
    dt.min = 0;
    dt.sec = 0;
    datetime dayStart = StructToTime(dt);

    if (now < refTime)
        return; // Reference time not yet reached today
    if (g_sessions[sIdx].levelsDay == dayStart)
        return; // Already calculated for today

    // Shift of reference candle
    int refShift = iBarShift(_Symbol, _Period, refTime, false);
    if (refShift < 0)
        return;

    // Method 3 needs reference candle to be fully closed
    if (InpMethod == METHOD_3 && refShift == 0)
        return;

    if (Bars(_Symbol, _Period) < refShift + InpLookbackN + 2)
        return;

    double newHigh = 0.0, newLow = 0.0;

    if (InpMethod == METHOD_3)
    {
        newHigh = iHigh(_Symbol, _Period, refShift);
        newLow = iLow(_Symbol, _Period, refShift);
    }
    else
    {
        int winStart = refShift + 1;
        int highShift = iHighest(_Symbol, _Period, MODE_HIGH, InpLookbackN, winStart);
        int lowShift = iLowest(_Symbol, _Period, MODE_LOW, InpLookbackN, winStart);

        if (highShift < 0 || lowShift < 0)
            return;

        newHigh = iHigh(_Symbol, _Period, highShift);
        newLow = iLow(_Symbol, _Period, lowShift);

        if (InpMethod == METHOD_2 && InpUpdateMode == UPDATE_MAIN_HL)
        {
            if (highShift < lowShift)
            {
                int countFromHigh = highShift - winStart + 1;
                int bearish = 0;
                for (int s = winStart; s <= highShift; s++)
                    if (iClose(_Symbol, _Period, s) < iOpen(_Symbol, _Period, s))
                        bearish++;

                if (bearish >= InpUpdateX)
                {
                    int updatedLowShift = iLowest(_Symbol, _Period, MODE_LOW, countFromHigh, winStart);
                    if (updatedLowShift >= 0)
                        newLow = iLow(_Symbol, _Period, updatedLowShift);
                }
            }
            else
                if (lowShift < highShift)
                {
                    int countFromLow = lowShift - winStart + 1;
                    int bullish = 0;
                    for (int s = winStart; s <= lowShift; s++)
                        if (iClose(_Symbol, _Period, s) > iOpen(_Symbol, _Period, s))
                            bullish++;

                    if (bullish >= InpUpdateX)
                    {
                        int updatedHighShift = iHighest(_Symbol, _Period, MODE_HIGH, countFromLow, winStart);
                        if (updatedHighShift >= 0)
                            newHigh = iHigh(_Symbol, _Period, updatedHighShift);
                    }
                }
        }
    }

    if (newHigh <= newLow)
    {
        PrintFormat("Session %d Level calculation rejected: High (%.5f) <= Low (%.5f)", sIdx + 1, newHigh, newLow);
        return;
    }

    // Perform clean line reset when a new day starts
    DeleteSessionObjects(sIdx);

    // Commit Levels & Reset Session State
    g_sessions[sIdx].definedHigh = newHigh;
    g_sessions[sIdx].definedLow = newLow;
    g_sessions[sIdx].originalHigh = newHigh; // Save original for reset button
    g_sessions[sIdx].originalLow = newLow;  // Save original for reset button

    g_sessions[sIdx].levelsSet = true;
    g_sessions[sIdx].levelsDay = dayStart;
    g_sessions[sIdx].refBarTime = iTime(_Symbol, _Period, refShift);
    g_sessions[sIdx].tradesToday = 0;
    g_sessions[sIdx].trade1HitSL = false;
    g_sessions[sIdx].haltTrading = false;

    g_sessions[sIdx].buyTriggered = false;
    g_sessions[sIdx].sellTriggered = false;

    if (InpMethod == METHOD_3)
        g_sessions[sIdx].lineStartTime = g_sessions[sIdx].refBarTime;
    else
        g_sessions[sIdx].lineStartTime = iTime(_Symbol, _Period, refShift + InpLookbackN);

    PrintFormat("[%s] Session %d Levels set (Method %d): High=%.5f  Low=%.5f",
        TimeToString(dayStart, TIME_DATE), sIdx + 1, (int)InpMethod, newHigh, newLow);

    if (InpDrawLevels)
        DrawSessionLevelLines(sIdx, dayStart);
}

//+------------------------------------------------------------------+
//| Check Entry Signals for specific session                         |
//+------------------------------------------------------------------+
void CheckEntrySignal(int sIdx)
{
    if (!g_sessions[sIdx].levelsSet || g_sessions[sIdx].haltTrading)
        return;

    // Prevent stacking multiple open trades in the same session
    if (HasOpenPositionForSession(sIdx))
        return;

    bool buySignal = false;
    bool sellSignal = false;
    double h1 = 0.0, l1 = 0.0;

    if (InpEntryMode == ENTRY_MODE_2)
    {
        // EntryMode = 2 (Breakout Entry)
        datetime now = TimeCurrent();
        if (now < g_sessions[sIdx].refBarTime)
            return;

        MqlTick tick;
        if (!SymbolInfoTick(_Symbol, tick))
            return;

        if (tick.bid > g_sessions[sIdx].definedHigh && !g_sessions[sIdx].buyTriggered)
            buySignal = true;

        if (tick.bid < g_sessions[sIdx].definedLow && !g_sessions[sIdx].sellTriggered)
            sellSignal = true;
    }
    else
    {
        // Breakout candle must have formed ON OR AFTER the session reference candle
        datetime c1time = iTime(_Symbol, _Period, 1);
        if (c1time < g_sessions[sIdx].refBarTime)
            return;

        double o1 = iOpen(_Symbol, _Period, 1);
        h1 = iHigh(_Symbol, _Period, 1);
        l1 = iLow(_Symbol, _Period, 1);
        double c1 = iClose(_Symbol, _Period, 1);

        if (InpEntryMode == ENTRY_MODE_1)
        {
            // EntryMode = 1 (Current Behavior)
            double rangeCandle = h1 - l1;
            double rangeLevels = g_sessions[sIdx].definedHigh - g_sessions[sIdx].definedLow;

            // Quality Filters
            bool rangeOK = (rangeCandle < rangeLevels);
            bool originOK = (o1 >= g_sessions[sIdx].definedLow && o1 <= g_sessions[sIdx].definedHigh);
            if (!rangeOK || !originOK)
                return;

            // Breakout Signals
            if ((c1 > g_sessions[sIdx].definedHigh) && ((c1 - g_sessions[sIdx].definedHigh) > (h1 - c1)) && !g_sessions[sIdx].buyTriggered)
                buySignal = true;

            if ((c1 < g_sessions[sIdx].definedLow) && ((g_sessions[sIdx].definedLow - c1) > (c1 - l1)) && !g_sessions[sIdx].sellTriggered)
                sellSignal = true;
        }
        else
            if (InpEntryMode == ENTRY_MODE_3)
            {
                // EntryMode = 3 (Candle Close Confirmation)
                if ((c1 > g_sessions[sIdx].definedHigh) && !g_sessions[sIdx].buyTriggered)
                    buySignal = true;

                if ((c1 < g_sessions[sIdx].definedLow) && !g_sessions[sIdx].sellTriggered)
                    sellSignal = true;
            }
    }

    if (!buySignal && !sellSignal)
        return;

    // Session Trade Management Rules
    if (g_sessions[sIdx].tradesToday >= 2)
    {
        g_sessions[sIdx].haltTrading = true;
        return;
    }

    if (g_sessions[sIdx].tradesToday == 1)
    {
        if (InpSkipSecondTradeIfFirstTP && !g_sessions[sIdx].trade1HitSL)
        {
            // Trade 1 closed via TP or manual close -> Halt trading for session
            g_sessions[sIdx].haltTrading = true;
            return;
        }
    }

    double rr = (g_sessions[sIdx].tradesToday == 0) ? 2.0 : 4.0;

    if (buySignal)
        ExecuteTrade(ORDER_TYPE_BUY, rr, sIdx, h1, l1);
    else
        if (sellSignal)
            ExecuteTrade(ORDER_TYPE_SELL, rr, sIdx, h1, l1);
}
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Execute Market Order                                             |
//+------------------------------------------------------------------+
void ExecuteTrade(const ENUM_ORDER_TYPE type, const double rr, int sIdx, double h1 = 0.0, double l1 = 0.0)
{
    // Market-close protection: hard block (covers any call path)
    if (EnableCloseBeforeMarketClose && g_mcBlockTrading)
    {
        PrintFormat("[MarketClose] Entry suppressed - trading blocked until %s (server time).",
            TimeToString(g_mcResumeTime, TIME_DATE | TIME_MINUTES));
        return;
    }

    double point = _Point;
    double slBuf = InpSLBufferPoints * point;
    double tpBuf = InpTPBufferPoints * point;

    MqlTick tick;
    if (!SymbolInfoTick(_Symbol, tick))
        return;

    double entry, sl, tp;

    if (type == ORDER_TYPE_BUY)
    {
        entry = tick.ask;

        if (InpEntryMode == ENTRY_MODE_1)
        {
            double c2low = iLow(_Symbol, _Period, 2);
            sl = c2low - slBuf;
        }
        else
            if (InpEntryMode == ENTRY_MODE_2)
            {
                sl = g_sessions[sIdx].definedLow - slBuf;
            }
            else // ENTRY_MODE_3
            {
                double candleRange = h1 - l1;
                sl = entry - candleRange - slBuf;
            }

        if (entry - sl <= 0)
            return;

        tp = entry + ((entry - sl) * rr) - tpBuf;
        if (tp <= entry)
            return;
    }
    else
    {
        entry = tick.bid;

        if (InpEntryMode == ENTRY_MODE_1)
        {
            double c2high = iHigh(_Symbol, _Period, 2);
            sl = c2high + slBuf;
        }
        else
            if (InpEntryMode == ENTRY_MODE_2)
            {
                sl = g_sessions[sIdx].definedHigh + slBuf;
            }
            else // ENTRY_MODE_3
            {
                double candleRange = h1 - l1;
                sl = entry + candleRange + slBuf;
            }

        if (sl - entry <= 0)
            return;

        tp = entry - ((sl - entry) * rr) + tpBuf;
        if (tp >= entry)
            return;
    }

    sl = NormalizeDouble(sl, _Digits);
    tp = NormalizeDouble(tp, _Digits);

    double stopLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
    if (MathAbs(entry - sl) < stopLevel || MathAbs(tp - entry) < stopLevel)
    {
        Print("Trade rejected: SL/TP inside broker minimum stop distance.");
        return;
    }

    double lots = CalcLots(MathAbs(entry - sl));
    if (lots <= 0)
        return;

    // Bind session index to Magic Number
    g_trade.SetExpertMagicNumber(InpMagic + sIdx);

    string comment = StringFormat("DLB S%d [%02d:%02d-%02d:%02d] T%d RR1:%.0f",
        sIdx + 1,
        g_sessions[sIdx].refH,
        g_sessions[sIdx].refM,
        g_sessions[sIdx].endH,
        g_sessions[sIdx].endM,
        g_sessions[sIdx].tradesToday + 1,
        rr);

    bool ok = (type == ORDER_TYPE_BUY)
        ? g_trade.Buy(lots, _Symbol, 0.0, sl, tp, comment)
        : g_trade.Sell(lots, _Symbol, 0.0, sl, tp, comment);

    if (ok)
    {
        g_sessions[sIdx].tradesToday++;
        if (type == ORDER_TYPE_BUY)
            g_sessions[sIdx].buyTriggered = true;
        if (type == ORDER_TYPE_SELL)
            g_sessions[sIdx].sellTriggered = true;

        PrintFormat("Session %d Trade %d opened: %s lots=%.2f SL=%.5f TP=%.5f (RR 1:%.0f)",
            sIdx + 1, g_sessions[sIdx].tradesToday, (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), lots, sl, tp, rr);
    }
    else
        PrintFormat("Order failed: %d - %s", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Track closed deals and update session state                      |
//+------------------------------------------------------------------+
void UpdateTradeState()
{
    datetime now = TimeCurrent();

    for (int s = 0; s < 4; s++)
    {
        if (g_sessions[s].tradesToday == 0 || g_sessions[s].haltTrading)
            continue;

        // Wait until open trade for this session closes
        if (HasOpenPositionForSession(s))
            continue;

        if (!HistorySelect(g_sessions[s].levelsDay, now + 60))
            continue;

        int deals = HistoryDealsTotal();
        long lastReason = -1;

        for (int i = deals - 1; i >= 0; i--)
        {
            ulong ticket = HistoryDealGetTicket(i);
            if (ticket == 0)
                continue;
            if (HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol)
                continue;
            if ((ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != (InpMagic + s))
                continue;
            if (HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
                continue;

            lastReason = HistoryDealGetInteger(ticket, DEAL_REASON);
            break;
        }

        if (lastReason < 0)
            continue;

        if (g_sessions[s].tradesToday == 1)
        {
            if (lastReason == DEAL_REASON_SL)
            {
                if (!g_sessions[s].trade1HitSL)
                {
                    g_sessions[s].trade1HitSL = true;
                    PrintFormat("Session %d Trade 1 hit SL -> Trade 2 now permitted (RR 1:4).", s + 1);
                }
            }
            else
            {
                if (InpSkipSecondTradeIfFirstTP)
                {
                    g_sessions[s].haltTrading = true;
                    PrintFormat("Session %d Trade 1 closed (non-SL) -> Session halted.", s + 1);
                }
                else
                {
                    PrintFormat("Session %d Trade 1 closed (TP/non-SL) -> Trade 2 permitted.", s + 1);
                }
            }
        }
        else
            if (g_sessions[s].tradesToday >= 2)
            {
                g_sessions[s].haltTrading = true;
                PrintFormat("Session %d Trade 2 closed -> Session halted.", s + 1);
            }
    }
}

//+------------------------------------------------------------------+
//| Session Activity Helpers                                         |
//+------------------------------------------------------------------+
bool IsSessionActiveForTrading(int sIdx)
{
    if (!g_sessions[sIdx].enable || !g_sessions[sIdx].levelsSet)
        return false;

    // Market-close protection: no new entries until the next valid trading session
    if (EnableCloseBeforeMarketClose && g_mcBlockTrading)
        return false;

    datetime now = TimeCurrent();
    MqlDateTime dt;
    TimeToStruct(now, dt);

    dt.hour = 0;
    dt.min = 0;
    dt.sec = 0;
    datetime dayStart = StructToTime(dt);

    if (g_sessions[sIdx].levelsDay != dayStart)
        return false;

    datetime startTrade = dayStart + g_sessions[sIdx].refH * 3600 + g_sessions[sIdx].refM * 60;
    datetime endTrade = dayStart + g_sessions[sIdx].endH * 3600 + g_sessions[sIdx].endM * 60;

    // If End Time is invalid or earlier than start, active until next session reference or EOD
    if (endTrade <= startTrade)
        endTrade = GetNextSessionRefTime(sIdx, dayStart);

    return (now >= startTrade && now < endTrade);
}

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
datetime GetNextSessionRefTime(int sIdx, datetime dayStart)
{
    int currentRefSec = g_sessions[sIdx].refH * 3600 + g_sessions[sIdx].refM * 60;
    int minNextSec = 86400; // End of day (24:00)

    for (int i = 0; i < 4; i++)
    {
        if (i == sIdx || !g_sessions[i].enable)
            continue;

        int otherRefSec = g_sessions[i].refH * 3600 + g_sessions[i].refM * 60;
        if (otherRefSec > currentRefSec && otherRefSec < minNextSec)
            minNextSec = otherRefSec;
    }

    return (dayStart + minNextSec);
}

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool HasOpenPositionForSession(int sIdx)
{
    for (int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0)
            continue;
        if (PositionGetString(POSITION_SYMBOL) == _Symbol &&
            (ulong)PositionGetInteger(POSITION_MAGIC) == (InpMagic + sIdx))
            return(true);
    }
    return(false);
}

//+------------------------------------------------------------------+
//| Calculate Lot Size                                               |
//+------------------------------------------------------------------+
double CalcLots(const double slDistance)
{
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    double lots = InpFixedLot;

    if (InpUseRiskPercent)
    {
        double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        if (tickValue <= 0 || tickSize <= 0 || slDistance <= 0)
            return(0.0);

        double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
        double lossPerLot = (slDistance / tickSize) * tickValue;
        if (lossPerLot <= 0)
            return(0.0);

        lots = riskMoney / lossPerLot;
    }

    lots = MathFloor(lots / lotStep) * lotStep;
    lots = MathMax(minLot, MathMin(maxLot, lots));
    return(NormalizeDouble(lots, 2));
}

//+------------------------------------------------------------------+
//| Chart Level Drawing (Locked horizontal time anchors & slope)     |
//+------------------------------------------------------------------+
void DrawSessionLevelLines(int sIdx, const datetime dayStart)
{
    // Delete previous objects for this session before drawing new ones
    DeleteSessionObjects(sIdx);

    string dayTag = TimeToString(dayStart, TIME_DATE);
    string prefix = OBJ_PREFIX + "S" + IntegerToString(sIdx + 1) + "_";

    string highName = prefix + "High_" + dayTag;
    string lowName = prefix + "Low_" + dayTag;
    string refName = prefix + "RefTime_" + dayTag;
    string highLbl = prefix + "HighLabel_" + dayTag;
    string lowLbl = prefix + "LowLabel_" + dayTag;

    // Calculate and cache the line's end time in the session structure
    g_sessions[sIdx].lineEndTime = GetNextSessionRefTime(sIdx, dayStart);

    // 1. Reference Vertical Line
    ObjectCreate(0, refName, OBJ_VLINE, 0, g_sessions[sIdx].refBarTime, 0);
    ObjectSetInteger(0, refName, OBJPROP_COLOR, g_sessions[sIdx].lineColor);
    ObjectSetInteger(0, refName, OBJPROP_STYLE, InpReferenceLineStyle);
    ObjectSetInteger(0, refName, OBJPROP_WIDTH, 1);
    ObjectSetInteger(0, refName, OBJPROP_BACK, true);
    ObjectSetInteger(0, refName, OBJPROP_SELECTABLE, false);

    // 2. High Line (Selectable for vertical dragging only)
    ObjectCreate(0, highName, OBJ_TREND, 0, g_sessions[sIdx].lineStartTime, g_sessions[sIdx].definedHigh, g_sessions[sIdx].lineEndTime, g_sessions[sIdx].definedHigh);
    ObjectSetInteger(0, highName, OBJPROP_COLOR, g_sessions[sIdx].lineColor);
    ObjectSetInteger(0, highName, OBJPROP_WIDTH, 1);
    ObjectSetInteger(0, highName, OBJPROP_STYLE, InpLineStyle);
    ObjectSetInteger(0, highName, OBJPROP_RAY_RIGHT, false);
    ObjectSetInteger(0, highName, OBJPROP_RAY_LEFT, false);
    ObjectSetInteger(0, highName, OBJPROP_SELECTABLE, true);
    ObjectSetInteger(0, highName, OBJPROP_SELECTED, false);

    // 3. Low Line (Selectable for vertical dragging only)
    ObjectCreate(0, lowName, OBJ_TREND, 0, g_sessions[sIdx].lineStartTime, g_sessions[sIdx].definedLow, g_sessions[sIdx].lineEndTime, g_sessions[sIdx].definedLow);
    ObjectSetInteger(0, lowName, OBJPROP_COLOR, g_sessions[sIdx].lineColor);
    ObjectSetInteger(0, lowName, OBJPROP_WIDTH, 1);
    ObjectSetInteger(0, lowName, OBJPROP_STYLE, InpLineStyle);
    ObjectSetInteger(0, lowName, OBJPROP_RAY_RIGHT, false);
    ObjectSetInteger(0, lowName, OBJPROP_RAY_LEFT, false);
    ObjectSetInteger(0, lowName, OBJPROP_SELECTABLE, true);
    ObjectSetInteger(0, lowName, OBJPROP_SELECTED, false);

    // 4. High Price Label (Above High line, anchored left of Reference Bar)
    ObjectCreate(0, highLbl, OBJ_TEXT, 0, g_sessions[sIdx].refBarTime, g_sessions[sIdx].definedHigh);
    ObjectSetString(0, highLbl, OBJPROP_TEXT, DoubleToString(g_sessions[sIdx].definedHigh, _Digits) + " ");
    ObjectSetInteger(0, highLbl, OBJPROP_COLOR, g_sessions[sIdx].lineColor);
    ObjectSetInteger(0, highLbl, OBJPROP_FONTSIZE, InpPriceLabelFontSize);
    ObjectSetInteger(0, highLbl, OBJPROP_ANCHOR, ANCHOR_RIGHT_LOWER);
    ObjectSetInteger(0, highLbl, OBJPROP_SELECTABLE, false);

    // 5. Low Price Label (Below Low line, anchored left of Reference Bar)
    ObjectCreate(0, lowLbl, OBJ_TEXT, 0, g_sessions[sIdx].refBarTime, g_sessions[sIdx].definedLow);
    ObjectSetString(0, lowLbl, OBJPROP_TEXT, DoubleToString(g_sessions[sIdx].definedLow, _Digits) + " ");
    ObjectSetInteger(0, lowLbl, OBJPROP_COLOR, g_sessions[sIdx].lineColor);
    ObjectSetInteger(0, lowLbl, OBJPROP_FONTSIZE, InpPriceLabelFontSize);
    ObjectSetInteger(0, lowLbl, OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
    ObjectSetInteger(0, lowLbl, OBJPROP_SELECTABLE, false);

    ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Delete objects for a specific session only                       |
//+------------------------------------------------------------------+
void DeleteSessionObjects(int sIdx)
{
    string prefix = OBJ_PREFIX + "S" + IntegerToString(sIdx + 1) + "_";
    ObjectsDeleteAll(0, prefix);
    ChartRedraw(0);
}
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Chart Event Handler                                              |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,
    const long& lparam,
    const double& dparam,
    const string& sparam)
{
    // 1. Handle Object Dragging (Manual High/Low Adjustments)
    if (id == CHARTEVENT_OBJECT_DRAG || id == CHARTEVENT_OBJECT_CHANGE)
    {
        if (StringFind(sparam, OBJ_PREFIX) == 0 && sparam != BTN_RESET_NAME)
        {
            UpdateLevelsFromChartLines(sparam);
        }
    }

    // 2. Handle Reset Button Click
    if (id == CHARTEVENT_OBJECT_CLICK)
    {
        if (sparam == BTN_RESET_NAME)
        {
            ResetLevelsToOriginal();

            // Release the button state (pop it back up)
            ObjectSetInteger(0, BTN_RESET_NAME, OBJPROP_STATE, false);
        }
    }
}
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Helper: Dynamically updates Price Label position and text        |
//+------------------------------------------------------------------+
void UpdateSessionPriceLabel(const string labelName, const double newPrice)
{
    if (ObjectFind(0, labelName) >= 0)
    {
        ObjectSetDouble(0, labelName, OBJPROP_PRICE, newPrice);
        ObjectSetString(0, labelName, OBJPROP_TEXT, DoubleToString(newPrice, _Digits) + " ");
    }
}

//+------------------------------------------------------------------+
//| Update Session Levels & enforce strict horizontal/time locks     |
//+------------------------------------------------------------------+
void UpdateLevelsFromChartLines(const string objectName)
{
    for (int sIdx = 0; sIdx < 4; sIdx++)
    {
        string sessionTag = OBJ_PREFIX + "S" + IntegerToString(sIdx + 1) + "_";

        // Match the dragged line with its corresponding session
        if (StringFind(objectName, sessionTag) == 0)
        {
            // 1. Read price of whichever anchor point was moved (or anchor 0 by default)
            double newPrice = ObjectGetDouble(0, objectName, OBJPROP_PRICE, 0);
            double altPrice = ObjectGetDouble(0, objectName, OBJPROP_PRICE, 1);

            // If anchor 1 was dragged to a different price than anchor 0, use anchor 1's price
            if (MathAbs(newPrice - altPrice) > _Point)
            {
                if (StringFind(objectName, "_High_") > 0 && MathAbs(altPrice - g_sessions[sIdx].definedHigh) > _Point)
                    newPrice = altPrice;
                else
                    if (StringFind(objectName, "_Low_") > 0 && MathAbs(altPrice - g_sessions[sIdx].definedLow) > _Point)
                        newPrice = altPrice;
            }

            if (newPrice <= 0)
                return;

            // 2. ENFORCE HORIZONTAL LOCK: Keep both anchors at the exact same Y-axis price
            ObjectSetDouble(0, objectName, OBJPROP_PRICE, 0, newPrice);
            ObjectSetDouble(0, objectName, OBJPROP_PRICE, 1, newPrice);

            // 3. ENFORCE TIME ANCHOR LOCK: Prevent dragging start/end points horizontally
            ObjectSetInteger(0, objectName, OBJPROP_TIME, 0, g_sessions[sIdx].lineStartTime);
            ObjectSetInteger(0, objectName, OBJPROP_TIME, 1, g_sessions[sIdx].lineEndTime);

            // 4. Update internal session levels and their corresponding text label
            string dayTag = TimeToString(g_sessions[sIdx].levelsDay, TIME_DATE);
            if (StringFind(objectName, "_High_") > 0)
            {
                g_sessions[sIdx].definedHigh = newPrice;
                UpdateSessionPriceLabel(sessionTag + "HighLabel_" + dayTag, newPrice);
                PrintFormat("[User Action] Session %d High manually adjusted to %.5f", sIdx + 1, newPrice);
            }
            else
                if (StringFind(objectName, "_Low_") > 0)
                {
                    g_sessions[sIdx].definedLow = newPrice;
                    UpdateSessionPriceLabel(sessionTag + "LowLabel_" + dayTag, newPrice);
                    PrintFormat("[User Action] Session %d Low manually adjusted to %.5f", sIdx + 1, newPrice);
                }

            ChartRedraw(0);
            break;
        }
    }
}
//+------------------------------------------------------------------+

const string BTN_RESET_NAME = OBJ_PREFIX + "ResetBtn";

//+------------------------------------------------------------------+
//| Create/Update UI Button with custom position inputs              |
//+------------------------------------------------------------------+
void CreateResetButton()
{
    if (ObjectFind(0, BTN_RESET_NAME) < 0)
    {
        ObjectCreate(0, BTN_RESET_NAME, OBJ_BUTTON, 0, 0, 0);
    }

    // Set user-defined coordinates & size
    ObjectSetInteger(0, BTN_RESET_NAME, OBJPROP_CORNER, InpBtnCorner);
    ObjectSetInteger(0, BTN_RESET_NAME, OBJPROP_XDISTANCE, InpBtnX);
    ObjectSetInteger(0, BTN_RESET_NAME, OBJPROP_YDISTANCE, InpBtnY);
    ObjectSetInteger(0, BTN_RESET_NAME, OBJPROP_XSIZE, InpBtnWidth);
    ObjectSetInteger(0, BTN_RESET_NAME, OBJPROP_YSIZE, InpBtnHeight);

    // Styling & Behavior
    ObjectSetString(0, BTN_RESET_NAME, OBJPROP_TEXT, "Reset Levels");
    ObjectSetInteger(0, BTN_RESET_NAME, OBJPROP_COLOR, clrWhite);
    ObjectSetInteger(0, BTN_RESET_NAME, OBJPROP_BGCOLOR, clrSlateGray);
    ObjectSetInteger(0, BTN_RESET_NAME, OBJPROP_BORDER_COLOR, clrBlack);
    ObjectSetInteger(0, BTN_RESET_NAME, OBJPROP_STATE, false);
    ObjectSetInteger(0, BTN_RESET_NAME, OBJPROP_HIDDEN, true);
    ObjectSetInteger(0, BTN_RESET_NAME, OBJPROP_SELECTABLE, false);

    ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Reset levels back to their calculated origin                     |
//+------------------------------------------------------------------+
void ResetLevelsToOriginal()
{
    for (int i = 0; i < 4; i++)
    {
        // Check if session is active and original levels exist
        if (g_sessions[i].levelsSet && g_sessions[i].originalHigh > 0 && g_sessions[i].originalLow > 0)
        {
            g_sessions[i].definedHigh = g_sessions[i].originalHigh;
            g_sessions[i].definedLow = g_sessions[i].originalLow;

            // Redraw lines (and labels) at their original coordinates
            DrawSessionLevelLines(i, g_sessions[i].levelsDay);

            PrintFormat("[Reset] Session %d levels reverted to original: High=%.5f, Low=%.5f", i + 1, g_sessions[i].originalHigh, g_sessions[i].originalLow);
        }
    }
    ChartRedraw(0);
}
//+------------------------------------------------------------------+
//| Timer Handler (watchdog for market-close protection)             |
//+------------------------------------------------------------------+
void OnTimer()
{
    if (EnableCloseBeforeMarketClose)
        ManageMarketCloseProtection();
}
//+------------------------------------------------------------------+
//+==================================================================+
//|  MARKET-CLOSE PROTECTION MODULE                                  |
//|  Uses the broker's symbol trading-session schedule (server time). |
//|  DST- and Friday-safe: nothing is hardcoded, the schedule and the |
//|  server clock are re-read on every evaluation.                    |
//+==================================================================+

//--- Most reliable server-side "now" -------------------------------
datetime MarketCloseServerNow()
{
    datetime ts = TimeTradeServer();
    datetime tc = TimeCurrent();
    return(ts > tc ? ts : tc);
}

//--- Server-time midnight of the given timestamp -------------------
datetime MarketCloseDayStart(const datetime t)
{
    MqlDateTime dt;
    TimeToStruct(t, dt);
    dt.hour = 0;
    dt.min = 0;
    dt.sec = 0;
    return(StructToTime(dt));
}

//--- Server-time day of week of the given timestamp ----------------
ENUM_DAY_OF_WEEK MarketCloseDayOfWeek(const datetime t)
{
    MqlDateTime dt;
    TimeToStruct(t, dt);
    return((ENUM_DAY_OF_WEEK)dt.day_of_week);
}

//+------------------------------------------------------------------+
//| Read all trading sessions of the calendar day containing         |
//| 'dayAnchor'. Returns count; fromSec/toSec are seconds from 00:00 |
//| (a session ending at midnight is normalised to 86400).           |
//+------------------------------------------------------------------+
int MarketCloseGetDaySessions(const datetime dayAnchor, int& fromSec[], int& toSec[])
{
    ArrayResize(fromSec, 0);
    ArrayResize(toSec, 0);

    ENUM_DAY_OF_WEEK dow = MarketCloseDayOfWeek(dayAnchor);
    datetime sFrom, sTo;
    int count = 0;

    for (uint idx = 0; idx < 24; idx++)
    {
        if (!SymbolInfoSessionTrade(_Symbol, dow, idx, sFrom, sTo))
            break;

        int f = (int)((long)sFrom % 86400);
        int t = (int)((long)sTo % 86400);
        if (t <= f)
            t = 86400;                       // session runs up to midnight

        ArrayResize(fromSec, count + 1);
        ArrayResize(toSec, count + 1);
        fromSec[count] = f;
        toSec[count] = t;
        count++;
    }

    // Defensive ordering (brokers normally return sessions sorted)
    for (int i = 1; i < count; i++)
        for (int j = i; j > 0 && fromSec[j] < fromSec[j - 1]; j--)
        {
            int tmpF = fromSec[j];
            fromSec[j] = fromSec[j - 1];
            fromSec[j - 1] = tmpF;
            int tmpT = toSec[j];
            toSec[j] = toSec[j - 1];
            toSec[j - 1] = tmpT;
        }

    return(count);
}

//+------------------------------------------------------------------+
//| Resolve the REAL market closing time for the session that is     |
//| currently running. Contiguous sessions - including a block that  |
//| runs through midnight into the next day - are merged, so the     |
//| result is the moment the market actually stops trading.          |
//| Returns false when the symbol is not inside a session now.       |
//+------------------------------------------------------------------+
bool MarketCloseGetMarketCloseTime(const datetime now, datetime& closeTime)
{
    closeTime = 0;

    int gap = (InpMC_SessionMergeGapMin > 0 ? InpMC_SessionMergeGapMin : 0) * 60;

    datetime day = MarketCloseDayStart(now);
    int      sod = (int)(now - day);

    int f[], t[];
    int n = MarketCloseGetDaySessions(day, f, t);

    if (n <= 0)
    {
        if (!g_mcNoSchedWarned && MarketCloseDayOfWeek(now) != SATURDAY && MarketCloseDayOfWeek(now) != SUNDAY)
        {
            PrintFormat("[MarketClose] No trading session schedule published by the broker for %s on this weekday.", _Symbol);
            g_mcNoSchedWarned = true;
        }
        return(false);                      // market closed today (weekend / holiday schedule)
    }

    // Locate the session we are inside (a short pre-session gap counts as inside)
    int k = -1;
    for (int i = 0; i < n; i++)
        if (sod >= f[i] - gap && sod < t[i])
        {
            k = i;
            break;
        }
    if (k < 0)
        return(false);                      // between sessions / outside trading hours

    int endSec = t[k];
    int guard = 0;

    while (guard++ < 10)
    {
        // (a) merge the next same-day session when the gap is negligible (split sessions)
        bool merged = false;
        for (int i = k + 1; i < n; i++)
        {
            if (f[i] >= endSec && (f[i] - endSec) <= gap)
            {
                endSec = t[i];
                k = i;
                merged = true;
                break;
            }
        }
        if (merged)
            continue;

        // (b) session ends at midnight -> does the next day continue seamlessly?
        if (endSec >= 86400 - gap)
        {
            datetime nextDay = day + 86400;
            int nf[], nt[];
            int nn = MarketCloseGetDaySessions(nextDay, nf, nt);

            if (nn > 0 && nf[0] <= gap)        // yes: Mon-Thu style rollover, market never closes
            {
                ArrayResize(f, nn);
                ArrayResize(t, nn);
                for (int i = 0; i < nn; i++)
                {
                    f[i] = nf[i];
                    t[i] = nt[i];
                }
                day = nextDay;
                n = nn;
                k = 0;
                endSec = t[0];
                continue;
            }
        }
        break;                              // this is the real close (e.g. Friday early close)
    }

    closeTime = day + endSec;
    return(true);
}

//+------------------------------------------------------------------+
//| First session start strictly after 'fromTime' (up to 8 days)     |
//+------------------------------------------------------------------+
bool MarketCloseGetNextSessionStart(const datetime fromTime, datetime& openTime)
{
    openTime = 0;
    datetime base = MarketCloseDayStart(fromTime);

    for (int d = 0; d <= 8; d++)
    {
        datetime day = base + d * 86400;
        int f[], t[];
        int n = MarketCloseGetDaySessions(day, f, t);

        for (int i = 0; i < n; i++)
        {
            datetime st = day + f[i];
            if (st > fromTime)
            {
                openTime = st;
                return(true);
            }
        }
    }
    return(false);
}

//--- Does this EA still have exposure on the symbol? ---------------
bool MarketCloseHasExposure()
{
    for (int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0)
            continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
        ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
        if (InpMC_CloseOnlyEaTrades && (magic < InpMagic || magic > InpMagic + 3))
            continue;
        return(true);
    }

    for (int i = OrdersTotal() - 1; i >= 0; i--)
    {
        ulong ticket = OrderGetTicket(i);
        if (ticket == 0)
            continue;
        if (OrderGetString(ORDER_SYMBOL) != _Symbol)
            continue;
        ulong magic = (ulong)OrderGetInteger(ORDER_MAGIC);
        if (InpMC_CloseOnlyEaTrades && (magic < InpMagic || magic > InpMagic + 3))
            continue;
        return(true);
    }
    return(false);
}

//--- Step 1: cancel pending orders for the symbol ------------------
int MarketCloseCancelPendingOrders()
{
    int cancelled = 0;

    for (int i = OrdersTotal() - 1; i >= 0; i--)
    {
        ulong ticket = OrderGetTicket(i);
        if (ticket == 0)
            continue;
        if (OrderGetString(ORDER_SYMBOL) != _Symbol)
            continue;

        ulong magic = (ulong)OrderGetInteger(ORDER_MAGIC);
        if (InpMC_CloseOnlyEaTrades && (magic < InpMagic || magic > InpMagic + 3))
            continue;

        if (g_trade.OrderDelete(ticket))
        {
            cancelled++;
            PrintFormat("[MarketClose] Pending order #%I64u (%s) cancelled before market close.",
                ticket, EnumToString((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE)));
        }
        else
            PrintFormat("[MarketClose] FAILED to cancel pending order #%I64u: %d - %s",
                ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
    }

    if (cancelled > 0)
        PrintFormat("[MarketClose] %d pending order(s) cancelled for %s.", cancelled, _Symbol);

    return(cancelled);
}

//--- Step 2: close every open position for the symbol --------------
int MarketCloseCloseAllPositions()
{
    int closed = 0;

    for (int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0)
            continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;

        ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
        if (InpMC_CloseOnlyEaTrades && (magic < InpMagic || magic > InpMagic + 3))
            continue;

        double vol = PositionGetDouble(POSITION_VOLUME);
        double profit = PositionGetDouble(POSITION_PROFIT);
        string dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL");

        if (g_trade.PositionClose(ticket, InpSlippagePoints))
        {
            closed++;
            PrintFormat("[MarketClose] Position #%I64u %s %.2f lots (magic %I64u, P/L %.2f) CLOSED by market-close protection.",
                ticket, dir, vol, magic, profit);
        }
        else
            PrintFormat("[MarketClose] FAILED to close position #%I64u: %d - %s (will retry)",
                ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
    }

    if (closed > 0)
        PrintFormat("[MarketClose] %d position(s) closed for %s.", closed, _Symbol);

    return(closed);
}

//+------------------------------------------------------------------+
//| Main controller - called from OnTick() and OnTimer()             |
//+------------------------------------------------------------------+
void ManageMarketCloseProtection()
{
    if (!EnableCloseBeforeMarketClose)
        return;

    datetime now = MarketCloseServerNow();
    if (now <= 0)
        return;

    // --- Release the block once the next valid trading session has begun ---
    if (g_mcBlockTrading && g_mcResumeTime > 0 && now >= g_mcResumeTime)
    {
        g_mcBlockTrading = false;
        g_mcLastLoggedMin = -1;
        PrintFormat("[MarketClose] New trading session started (%s server time) -> trading re-enabled.",
            TimeToString(now, TIME_DATE | TIME_MINUTES));
    }

    // --- Resolve the actual market closing time from the symbol schedule ---
    datetime closeTime = 0;
    if (!MC_GetMarketCloseTime(now, closeTime))
    {
        // Outside a trading session: keep any active block, nothing else to do
        if (g_mcBlockTrading && g_mcResumeTime > 0)
            return;
        return;
    }

    long remainingSec = (long)(closeTime - now);
    int  remainingMin = (int)MathCeil(remainingSec / 60.0);

    // --- Log the detected closing time once per resolved close ---
    if (closeTime != g_mcLoggedClose)
    {
        g_mcLoggedClose = closeTime;
        MqlDateTime cdt;
        TimeToStruct(closeTime, cdt);
        PrintFormat("[MarketClose] Detected market close for %s: %s (server time, %s) | remaining: %d min | trigger threshold: %d min",
            _Symbol,
            TimeToString(closeTime, TIME_DATE | TIME_MINUTES),
            EnumToString((ENUM_DAY_OF_WEEK)cdt.day_of_week),
            remainingMin, g_mcMinutes);
    }

    // --- Countdown logging inside the final hour / threshold window ---
    int logWindow = (g_mcMinutes > 60 ? g_mcMinutes + 15 : 60);
    if (remainingMin <= logWindow && remainingMin != g_mcLastLoggedMin)
    {
        g_mcLastLoggedMin = remainingMin;
        PrintFormat("[MarketClose] %s closes at %s - %d minute(s) remaining (threshold %d).",
            _Symbol, TimeToString(closeTime, TIME_DATE | TIME_MINUTES), remainingMin, g_mcMinutes);
    }

    // --- Trigger window reached ---
    if (remainingSec <= (long)g_mcMinutes * 60)
    {
        bool firstTime = (g_mcHandledClose != closeTime);

        if (firstTime)
        {
            g_mcHandledClose = closeTime;
            PrintFormat("[MarketClose] *** PROTECTION TRIGGERED *** %d min (<= %d) to market close at %s. Flattening %s.",
                remainingMin, g_mcMinutes,
                TimeToString(closeTime, TIME_DATE | TIME_MINUTES), _Symbol);

            datetime nextOpen = 0;
            if (MC_GetNextSessionStart(closeTime, nextOpen))
                g_mcResumeTime = nextOpen;
            else
                g_mcResumeTime = closeTime + 3600;   // fallback if the broker publishes no next session

            g_mcBlockTrading = true;
            PrintFormat("[MarketClose] New entries blocked until the next trading session opens at %s (server time).",
                TimeToString(g_mcResumeTime, TIME_DATE | TIME_MINUTES));
        }
        else
            g_mcBlockTrading = true;   // stay blocked for the whole window

        // Cancel pendings first, then close positions. Retry (max every 3 s) on failures.
        static datetime lastAttempt = 0;
        if (MC_HasExposure() && (firstTime || now - lastAttempt >= 3))
        {
            lastAttempt = now;
            MarketCloseCancelPendingOrders();
            MarketCloseCloseAllPositions();
        }
    }
}
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
