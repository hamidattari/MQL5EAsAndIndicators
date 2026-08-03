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
input int                    InpOpenTolerancePoints = 1; // Open price tolerance in points for EntryMode = 1 (DMT)
input int                    InpBreakoutTolerancePoints = 1; // Breakout shadow tolerance in points for EntryMode = 1 (DMT)

input group "=== Close Before Market Close ==="
input bool                   EnableCloseBeforeMarketClose = true;  // Enable market-close protection
input int                    MinutesBeforeMarketClose = 15;    // Close positions X minutes before market close
input int                    InpMC_SessionMergeGapMin = 5;     // Advanced: merge sessions separated by <= N min
input bool                   InpMC_CloseOnlyEaTrades = true;  // Only touch this EA's orders/positions (by Magic)

input group "=== Display ==="
input bool                   InpDrawLevels = true;           // Draw daily levels on chart
input bool                   InpExtendLinesToSessionEnd = false; // true = extend to session end time, false = stop at next session ref time
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

//--- Session ON/OFF toggle buttons ---------------------------------
const string BTN_SESSION_PREFIX = OBJ_PREFIX + "SessBtn";
bool g_sessionButtonState[4] = { true, true, true, true };  // effective session enable flags (button-driven)

//--- High/Low source timeframe selector button --------------------
//  Cycles the timeframe used ONLY as the data source for High/Low
//  detection. All other logic (BOS, breakout, entries, SL/TP,
//  sessions) stays untouched and simply consumes the resulting
//  High/Low values.
const string BTN_HLTF_NAME = OBJ_PREFIX + "HLTFBtn";
const string GV_HLTF_PREFIX = "DLB_HLTF_";      // terminal global variable (persists selection)
#define HLTF_OPTION_COUNT 5
ENUM_TIMEFRAMES g_highAndLowTimeframeOptions[HLTF_OPTION_COUNT] = { PERIOD_CURRENT, PERIOD_M1, PERIOD_M5, PERIOD_M15, PERIOD_H1 };
string                g_highAndLowTimeframeLabels[HLTF_OPTION_COUNT] = { "Current", "M1", "M5", "M15", "H1" };
int g_highAndLowTimeframeIndex = 0;                      // 0 = current chart timeframe

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

        datetime marketCloseTime = 0;
        if (MarketCloseGetMarketCloseTime(MarketCloseServerNow(), marketCloseTime))
            PrintFormat("[MarketClose] Enabled. Threshold=%d min. Current session closes at %s (server time).",
                g_mcMinutes, TimeToString(marketCloseTime, TIME_DATE | TIME_MINUTES));
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

    // Restore the last selected High/Low timeframe (if it was ever saved)
    LoadHighAndLowTimeframeSelection();

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

    // Session ON/OFF buttons: seed their state from the input parameters,
    // then let the buttons drive g_sessions[].enable from here on.
    g_sessionButtonState[0] = InpS1_Enable;
    g_sessionButtonState[1] = InpS2_Enable;
    g_sessionButtonState[2] = InpS3_Enable;
    g_sessionButtonState[3] = InpS4_Enable;
    for (int sessionIndex = 0; sessionIndex < 4; sessionIndex++)
        g_sessions[sessionIndex].enable = g_sessionButtonState[sessionIndex];
    CreateSessionButtons();

    // High/Low timeframe selector button (placed below all other buttons)
    CreateHighAndLowTimeframeButton();

    for (int sessionIndex = 0; sessionIndex < 4; sessionIndex++)
    {
        if (g_sessions[sessionIndex].enable)
        {
            if (g_sessions[sessionIndex].refH < 0 || g_sessions[sessionIndex].refH > 23 || g_sessions[sessionIndex].refM < 0 || g_sessions[sessionIndex].refM > 59)
            {
                PrintFormat("Invalid Reference Time for Session %d", sessionIndex + 1);
                return(INIT_PARAMETERS_INCORRECT);
            }
        }
    }

    g_trade.SetDeviationInPoints(InpSlippagePoints);
    g_trade.SetTypeFillingBySymbol(_Symbol);

    // Compute levels on attach if time has already passed
    for (int sessionIndex = 0; sessionIndex < 4; sessionIndex++)
        UpdateSessionLevels(sessionIndex);

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
        for (int sessionIndex = 0; sessionIndex < 4; sessionIndex++)
        {
            if (IsSessionActiveForTrading(sessionIndex))
                CheckEntrySignal(sessionIndex);
        }
    }

    if (!IsNewBar())
        return;

    // 1. Calculate session levels
    for (int sessionIndex = 0; sessionIndex < 4; sessionIndex++)
        UpdateSessionLevels(sessionIndex);

    // 2. Evaluate entry signals for active sessions (EntryMode 1 and EntryMode 3)
    if (InpEntryMode != ENTRY_MODE_2)
    {
        for (int sessionIndex = 0; sessionIndex < 4; sessionIndex++)
        {
            if (IsSessionActiveForTrading(sessionIndex))
                CheckEntrySignal(sessionIndex);
        }
    }
}

//+------------------------------------------------------------------+
//| New bar detection                                                |
//+------------------------------------------------------------------+
bool IsNewBar()
{
    datetime currentBarTime = iTime(_Symbol, _Period, 0);
    if (currentBarTime == g_lastBarTime)
        return(false);
    g_lastBarTime = currentBarTime;
    return(true);
}

//+------------------------------------------------------------------+
//| Session level detection                                          |
//+------------------------------------------------------------------+
void UpdateSessionLevels(int sessionIndex)
{
    if (!g_sessions[sessionIndex].enable)
        return;

    datetime currentServerTime = TimeCurrent();
    MqlDateTime dateTimeStruct;
    TimeToStruct(currentServerTime, dateTimeStruct);

    // Build today's Reference Time for session sessionIndex
    dateTimeStruct.hour = g_sessions[sessionIndex].refH;
    dateTimeStruct.min = g_sessions[sessionIndex].refM;
    dateTimeStruct.sec = 0;
    datetime referenceTime = StructToTime(dateTimeStruct);

    dateTimeStruct.hour = 0;
    dateTimeStruct.min = 0;
    dateTimeStruct.sec = 0;
    datetime startOfDayTime = StructToTime(dateTimeStruct);

    if (currentServerTime < referenceTime)
        return; // Reference time not yet reached today
    if (g_sessions[sessionIndex].levelsDay == startOfDayTime)
        return; // Already calculated for today

    // High/Low data source timeframe (chart timeframe unless the user picked another one)
    ENUM_TIMEFRAMES highAndLowTimeframe = HighLowTimeframe();

    // Shift of reference candle
    int referenceCandleShift = iBarShift(_Symbol, highAndLowTimeframe, referenceTime, false);
    if (referenceCandleShift < 0)
        return;

    // Method 3 needs reference candle to be fully closed
    if (InpMethod == METHOD_3 && referenceCandleShift == 0)
        return;

    if (Bars(_Symbol, highAndLowTimeframe) < referenceCandleShift + InpLookbackN + 2)
        return;

    double calculatedHigh = 0.0, calculatedLow = 0.0;

    if (InpMethod == METHOD_3)
    {
        calculatedHigh = iHigh(_Symbol, highAndLowTimeframe, referenceCandleShift);
        calculatedLow = iLow(_Symbol, highAndLowTimeframe, referenceCandleShift);
    }
    else
    {
        int windowStartShift = referenceCandleShift + 1;
        int highestCandleShift = iHighest(_Symbol, highAndLowTimeframe, MODE_HIGH, InpLookbackN, windowStartShift);
        int lowestCandleShift = iLowest(_Symbol, highAndLowTimeframe, MODE_LOW, InpLookbackN, windowStartShift);

        if (highestCandleShift < 0 || lowestCandleShift < 0)
            return;

        calculatedHigh = iHigh(_Symbol, highAndLowTimeframe, highestCandleShift);
        calculatedLow = iLow(_Symbol, highAndLowTimeframe, lowestCandleShift);

        if (InpMethod == METHOD_2 && InpUpdateMode == UPDATE_MAIN_HL)
        {
            if (highestCandleShift < lowestCandleShift)
            {
                int candlesFromHighest = highestCandleShift - windowStartShift + 1;
                int bearishCandleCount = 0;
                for (int candleShift = windowStartShift; candleShift <= highestCandleShift; candleShift++)
                    if (iClose(_Symbol, highAndLowTimeframe, candleShift) < iOpen(_Symbol, highAndLowTimeframe, candleShift))
                        bearishCandleCount++;

                if (bearishCandleCount >= InpUpdateX)
                {
                    int newLowestCandleShift = iLowest(_Symbol, highAndLowTimeframe, MODE_LOW, candlesFromHighest, windowStartShift);
                    if (newLowestCandleShift >= 0)
                        calculatedLow = iLow(_Symbol, highAndLowTimeframe, newLowestCandleShift);
                }
            }
            else
                if (lowestCandleShift < highestCandleShift)
                {
                    int candlesFromLowest = lowestCandleShift - windowStartShift + 1;
                    int bullishCandleCount = 0;
                    for (int candleShift = windowStartShift; candleShift <= lowestCandleShift; candleShift++)
                        if (iClose(_Symbol, highAndLowTimeframe, candleShift) > iOpen(_Symbol, highAndLowTimeframe, candleShift))
                            bullishCandleCount++;

                    if (bullishCandleCount >= InpUpdateX)
                    {
                        int newHighestCandleShift = iHighest(_Symbol, highAndLowTimeframe, MODE_HIGH, candlesFromLowest, windowStartShift);
                        if (newHighestCandleShift >= 0)
                            calculatedHigh = iHigh(_Symbol, highAndLowTimeframe, newHighestCandleShift);
                    }
                }
        }
    }

    if (calculatedHigh <= calculatedLow)
    {
        PrintFormat("Session %d Level calculation rejected: High (%.5f) <= Low (%.5f)", sessionIndex + 1, calculatedHigh, calculatedLow);
        return;
    }

    // Perform clean line reset when a new day starts
    DeleteSessionObjects(sessionIndex);

    // Commit Levels & Reset Session State
    g_sessions[sessionIndex].definedHigh = calculatedHigh;
    g_sessions[sessionIndex].definedLow = calculatedLow;
    g_sessions[sessionIndex].originalHigh = calculatedHigh; // Save original for reset button
    g_sessions[sessionIndex].originalLow = calculatedLow;  // Save original for reset button

    g_sessions[sessionIndex].levelsSet = true;
    g_sessions[sessionIndex].levelsDay = startOfDayTime;
    g_sessions[sessionIndex].refBarTime = iTime(_Symbol, highAndLowTimeframe, referenceCandleShift);
    g_sessions[sessionIndex].tradesToday = 0;
    g_sessions[sessionIndex].trade1HitSL = false;
    g_sessions[sessionIndex].haltTrading = false;

    g_sessions[sessionIndex].buyTriggered = false;
    g_sessions[sessionIndex].sellTriggered = false;

    if (InpMethod == METHOD_3)
        g_sessions[sessionIndex].lineStartTime = g_sessions[sessionIndex].refBarTime;
    else
        g_sessions[sessionIndex].lineStartTime = iTime(_Symbol, highAndLowTimeframe, referenceCandleShift + InpLookbackN);

    PrintFormat("[%s] Session %d Levels set (Method %d, HL TF: %s): High=%.5f  Low=%.5f",
        TimeToString(startOfDayTime, TIME_DATE), sessionIndex + 1, (int)InpMethod,
        HighLowTimeframeLabel(), calculatedHigh, calculatedLow);

    if (InpDrawLevels)
        DrawSessionLevelLines(sessionIndex, startOfDayTime);
}

//+------------------------------------------------------------------+
//| Check Entry Signals for specific session                         |
//+------------------------------------------------------------------+
void CheckEntrySignal(int sessionIndex)
{
    if (!g_sessions[sessionIndex].levelsSet || g_sessions[sessionIndex].haltTrading)
        return;

    // Prevent stacking multiple open trades in the same session
    if (HasOpenPositionForSession(sessionIndex))
        return;

    bool buySignal = false;
    bool sellSignal = false;
    double previousCandleHigh = 0.0, previousCandleLow = 0.0;

    if (InpEntryMode == ENTRY_MODE_2)
    {
        // EntryMode = 2 (Breakout Entry)
        datetime currentServerTime = TimeCurrent();
        if (currentServerTime < g_sessions[sessionIndex].refBarTime)
            return;

        MqlTick latestTick;
        if (!SymbolInfoTick(_Symbol, latestTick))
            return;

        if (latestTick.bid > g_sessions[sessionIndex].definedHigh && !g_sessions[sessionIndex].buyTriggered)
            buySignal = true;

        if (latestTick.bid < g_sessions[sessionIndex].definedLow && !g_sessions[sessionIndex].sellTriggered)
            sellSignal = true;
    }
    else
    {
        // Breakout candle must have formed ON OR AFTER the session reference candle
        datetime previousCandleTime = iTime(_Symbol, _Period, 1);
        if (previousCandleTime < g_sessions[sessionIndex].refBarTime)
            return;

        double previousCandleOpen = iOpen(_Symbol, _Period, 1);
        previousCandleHigh = iHigh(_Symbol, _Period, 1);
        previousCandleLow = iLow(_Symbol, _Period, 1);
        double previousCandleClose = iClose(_Symbol, _Period, 1);

        if (InpEntryMode == ENTRY_MODE_1)
        {
            // EntryMode = 1 (Current Behavior with Tolerance Buffers)
            double previousCandleRange = previousCandleHigh - previousCandleLow;
            double rangeLevels = g_sessions[sessionIndex].definedHigh - g_sessions[sessionIndex].definedLow;

            // Convert tolerance buffers from points to price values
            double openTolerance = InpOpenTolerancePoints * _Point;
            double breakoutTolerance = InpBreakoutTolerancePoints * _Point;

            // Quality Filters
            bool rangeOK = (previousCandleRange < rangeLevels);

            // Allow the open price to be slightly outside the levels by openTolerance
            double allowedLow = g_sessions[sessionIndex].definedLow - openTolerance;
            double allowedHigh = g_sessions[sessionIndex].definedHigh + openTolerance;

            bool originOK = (previousCandleOpen >= allowedLow && previousCandleOpen <= allowedHigh);

            if (!rangeOK || !originOK)
                return;

            // --- Breakout Signals with Shadow Tolerance Buffer ---

            // Buy Signal Calculation
            double buyBreakoutDistance = previousCandleClose - g_sessions[sessionIndex].definedHigh;
            double upperShadow = previousCandleHigh - previousCandleClose;

            // Breakout distance plus tolerance buffer must be strictly greater than upper shadow length
            if ((previousCandleClose > g_sessions[sessionIndex].definedHigh) &&
                ((buyBreakoutDistance + breakoutTolerance) > upperShadow) &&
                !g_sessions[sessionIndex].buyTriggered)
            {
                buySignal = true;
            }

            // Sell Signal Calculation
            double sellBreakoutDistance = g_sessions[sessionIndex].definedLow - previousCandleClose;
            double lowerShadow = previousCandleClose - previousCandleLow;

            // Breakout distance plus tolerance buffer must be strictly greater than lower shadow length
            if ((previousCandleClose < g_sessions[sessionIndex].definedLow) &&
                ((sellBreakoutDistance + breakoutTolerance) > lowerShadow) &&
                !g_sessions[sessionIndex].sellTriggered)
            {
                sellSignal = true;
            }
        }
        else
            if (InpEntryMode == ENTRY_MODE_3)
            {
                // EntryMode = 3 (Candle Close Confirmation)
                if ((previousCandleClose > g_sessions[sessionIndex].definedHigh) && !g_sessions[sessionIndex].buyTriggered)
                    buySignal = true;

                if ((previousCandleClose < g_sessions[sessionIndex].definedLow) && !g_sessions[sessionIndex].sellTriggered)
                    sellSignal = true;
            }
    }

    if (!buySignal && !sellSignal)
        return;

    // Session Trade Management Rules
    if (g_sessions[sessionIndex].tradesToday >= 2)
    {
        g_sessions[sessionIndex].haltTrading = true;
        return;
    }

    if (g_sessions[sessionIndex].tradesToday == 1)
    {
        if (InpSkipSecondTradeIfFirstTP && !g_sessions[sessionIndex].trade1HitSL)
        {
            // Trade 1 closed via TP or manual close -> Halt trading for session
            g_sessions[sessionIndex].haltTrading = true;
            return;
        }
    }

    double rewardToRiskRatio = (g_sessions[sessionIndex].tradesToday == 0) ? 2.0 : 4.0;

    if (buySignal)
        ExecuteTrade(ORDER_TYPE_BUY, rewardToRiskRatio, sessionIndex, previousCandleHigh, previousCandleLow);
    else
        if (sellSignal)
            ExecuteTrade(ORDER_TYPE_SELL, rewardToRiskRatio, sessionIndex, previousCandleHigh, previousCandleLow);
}
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Execute Market Order                                             |
//+------------------------------------------------------------------+
void ExecuteTrade(const ENUM_ORDER_TYPE orderType, const double rewardToRiskRatio, int sessionIndex, double previousCandleHigh = 0.0, double previousCandleLow = 0.0)
{
    // Market-close protection: hard block (covers any call path)
    if (EnableCloseBeforeMarketClose && g_mcBlockTrading)
    {
        PrintFormat("[MarketClose] Entry suppressed - trading blocked until %s (server time).",
            TimeToString(g_mcResumeTime, TIME_DATE | TIME_MINUTES));
        return;
    }

    double pointValue = _Point;
    double stopLossBuffer = InpSLBufferPoints * pointValue;
    double takeProfitBuffer = InpTPBufferPoints * pointValue;

    MqlTick latestTick;
    if (!SymbolInfoTick(_Symbol, latestTick))
        return;

    double entryPrice, stopLossPrice, takeProfitPrice;

    if (orderType == ORDER_TYPE_BUY)
    {
        entryPrice = latestTick.ask;

        if (InpEntryMode == ENTRY_MODE_1)
        {
            double twoCandlesAgoLow = iLow(_Symbol, _Period, 2);
            stopLossPrice = twoCandlesAgoLow - stopLossBuffer;
        }
        else
            if (InpEntryMode == ENTRY_MODE_2)
            {
                stopLossPrice = g_sessions[sessionIndex].definedLow - stopLossBuffer;
            }
            else // ENTRY_MODE_3
            {
                double previousCandleRange = previousCandleHigh - previousCandleLow;
                stopLossPrice = entryPrice - previousCandleRange - stopLossBuffer;
            }

        if (entryPrice - stopLossPrice <= 0)
            return;

        takeProfitPrice = entryPrice + ((entryPrice - stopLossPrice) * rewardToRiskRatio) - takeProfitBuffer;
        if (takeProfitPrice <= entryPrice)
            return;
    }
    else
    {
        entryPrice = latestTick.bid;

        if (InpEntryMode == ENTRY_MODE_1)
        {
            double twoCandlesBeforeHigh = iHigh(_Symbol, _Period, 2);
            stopLossPrice = twoCandlesBeforeHigh + stopLossBuffer;
        }
        else
            if (InpEntryMode == ENTRY_MODE_2)
            {
                stopLossPrice = g_sessions[sessionIndex].definedHigh + stopLossBuffer;
            }
            else // ENTRY_MODE_3
            {
                double previousCandleRange = previousCandleHigh - previousCandleLow;
                stopLossPrice = entryPrice + previousCandleRange + stopLossBuffer;
            }

        if (stopLossPrice - entryPrice <= 0)
            return;

        takeProfitPrice = entryPrice - ((stopLossPrice - entryPrice) * rewardToRiskRatio) + takeProfitBuffer;
        if (takeProfitPrice >= entryPrice)
            return;
    }

    stopLossPrice = NormalizeDouble(stopLossPrice, _Digits);
    takeProfitPrice = NormalizeDouble(takeProfitPrice, _Digits);

    double brokerStopLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * pointValue;
    if (MathAbs(entryPrice - stopLossPrice) < brokerStopLevel || MathAbs(takeProfitPrice - entryPrice) < brokerStopLevel)
    {
        Print("Trade rejected: SL/TP inside broker minimum stop distance.");
        return;
    }

    double tradeLotSize = CalcLots(MathAbs(entryPrice - stopLossPrice));
    if (tradeLotSize <= 0)
        return;

    // Bind session index to Magic Number
    g_trade.SetExpertMagicNumber(InpMagic + sessionIndex);

    string tradeComment = StringFormat("DLB S%d [%02d:%02d-%02d:%02d] T%d RR1:%.0f",
        sessionIndex + 1,
        g_sessions[sessionIndex].refH,
        g_sessions[sessionIndex].refM,
        g_sessions[sessionIndex].endH,
        g_sessions[sessionIndex].endM,
        g_sessions[sessionIndex].tradesToday + 1,
        rewardToRiskRatio);

    bool isTradeSuccessful = (orderType == ORDER_TYPE_BUY)
        ? g_trade.Buy(tradeLotSize, _Symbol, 0.0, stopLossPrice, takeProfitPrice, tradeComment)
        : g_trade.Sell(tradeLotSize, _Symbol, 0.0, stopLossPrice, takeProfitPrice, tradeComment);

    if (isTradeSuccessful)
    {
        g_sessions[sessionIndex].tradesToday++;
        if (orderType == ORDER_TYPE_BUY)
            g_sessions[sessionIndex].buyTriggered = true;
        if (orderType == ORDER_TYPE_SELL)
            g_sessions[sessionIndex].sellTriggered = true;

        PrintFormat("Session %d Trade %d opened: %s lots=%.2f SL=%.5f TP=%.5f (RR 1:%.0f)",
            sessionIndex + 1, g_sessions[sessionIndex].tradesToday, (orderType == ORDER_TYPE_BUY ? "BUY" : "SELL"), tradeLotSize, stopLossPrice, takeProfitPrice, rewardToRiskRatio);
    }
    else
        PrintFormat("Order failed: %d - %s", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Track closed deals and update session state                      |
//+------------------------------------------------------------------+
void UpdateTradeState()
{
    datetime currentServerTime = TimeCurrent();

    for (int sessionIndex = 0; sessionIndex < 4; sessionIndex++)
    {
        if (g_sessions[sessionIndex].tradesToday == 0 || g_sessions[sessionIndex].haltTrading)
            continue;

        // Wait until open trade for this session closes
        if (HasOpenPositionForSession(sessionIndex))
            continue;

        if (!HistorySelect(g_sessions[sessionIndex].levelsDay, currentServerTime + 60))
            continue;

        int totalDeals = HistoryDealsTotal();
        long lastDealReason = -1;

        for (int dealIndex = totalDeals - 1; dealIndex >= 0; dealIndex--)
        {
            ulong dealTicket = HistoryDealGetTicket(dealIndex);
            if (dealTicket == 0)
                continue;
            if (HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
                continue;
            if ((ulong)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != (InpMagic + sessionIndex))
                continue;
            if (HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
                continue;

            lastDealReason = HistoryDealGetInteger(dealTicket, DEAL_REASON);
            break;
        }

        if (lastDealReason < 0)
            continue;

        if (g_sessions[sessionIndex].tradesToday == 1)
        {
            if (lastDealReason == DEAL_REASON_SL)
            {
                if (!g_sessions[sessionIndex].trade1HitSL)
                {
                    g_sessions[sessionIndex].trade1HitSL = true;
                    PrintFormat("Session %d Trade 1 hit SL -> Trade 2 now permitted (RR 1:4).", sessionIndex + 1);
                }
            }
            else
            {
                if (InpSkipSecondTradeIfFirstTP)
                {
                    g_sessions[sessionIndex].haltTrading = true;
                    PrintFormat("Session %d Trade 1 closed (non-SL) -> Session halted.", sessionIndex + 1);
                }
                else
                {
                    PrintFormat("Session %d Trade 1 closed (TP/non-SL) -> Trade 2 permitted.", sessionIndex + 1);
                }
            }
        }
        else
            if (g_sessions[sessionIndex].tradesToday >= 2)
            {
                g_sessions[sessionIndex].haltTrading = true;
                PrintFormat("Session %d Trade 2 closed -> Session halted.", sessionIndex + 1);
            }
    }
}

//+------------------------------------------------------------------+
//| Session Activity Helpers                                         |
//+------------------------------------------------------------------+
bool IsSessionActiveForTrading(int sessionIndex)
{
    if (!g_sessions[sessionIndex].enable || !g_sessions[sessionIndex].levelsSet)
        return false;

    // Market-close protection: no new entries until the next valid trading session
    if (EnableCloseBeforeMarketClose && g_mcBlockTrading)
        return false;

    datetime currentServerTime = TimeCurrent();
    MqlDateTime dateTimeStruct;
    TimeToStruct(currentServerTime, dateTimeStruct);

    dateTimeStruct.hour = 0;
    dateTimeStruct.min = 0;
    dateTimeStruct.sec = 0;
    datetime startOfDayTime = StructToTime(dateTimeStruct);

    if (g_sessions[sessionIndex].levelsDay != startOfDayTime)
        return false;

    datetime tradeStartTime = startOfDayTime + g_sessions[sessionIndex].refH * 3600 + g_sessions[sessionIndex].refM * 60;
    datetime tradeEndTime = startOfDayTime + g_sessions[sessionIndex].endH * 3600 + g_sessions[sessionIndex].endM * 60;

    // If End Time is invalid or earlier than start, active until next session reference or EOD
    if (tradeEndTime <= tradeStartTime)
        tradeEndTime = GetNextSessionRefTime(sessionIndex, startOfDayTime);

    return (currentServerTime >= tradeStartTime && currentServerTime < tradeEndTime);
}

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
datetime GetNextSessionRefTime(int sessionIndex, datetime startOfDayTime)
{
    int currentSessionRefSeconds = g_sessions[sessionIndex].refH * 3600 + g_sessions[sessionIndex].refM * 60;
    int nextSessionRefSeconds = 86400; // End of day (24:00)

    for (int i = 0; i < 4; i++)
    {
        if (i == sessionIndex || !g_sessions[i].enable)
            continue;

        int otherSessionRefSeconds = g_sessions[i].refH * 3600 + g_sessions[i].refM * 60;
        if (otherSessionRefSeconds > currentSessionRefSeconds && otherSessionRefSeconds < nextSessionRefSeconds)
            nextSessionRefSeconds = otherSessionRefSeconds;
    }

    return (startOfDayTime + nextSessionRefSeconds);
}

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool HasOpenPositionForSession(int sessionIndex)
{
    for (int positionIndex = PositionsTotal() - 1; positionIndex >= 0; positionIndex--)
    {
        ulong positionTicket = PositionGetTicket(positionIndex);
        if (positionTicket == 0)
            continue;
        if (PositionGetString(POSITION_SYMBOL) == _Symbol &&
            (ulong)PositionGetInteger(POSITION_MAGIC) == (InpMagic + sessionIndex))
            return(true);
    }
    return(false);
}

//+------------------------------------------------------------------+
//| Calculate Lot Size                                               |
//+------------------------------------------------------------------+
double CalcLots(const double stopLossDistance)
{
    double minimumLotSize = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maximumLotSize = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lotSizeStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    double calculatedLotSize = InpFixedLot;

    if (InpUseRiskPercent)
    {
        double symbolTickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double symbolTickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        if (symbolTickValue <= 0 || symbolTickSize <= 0 || stopLossDistance <= 0)
            return(0.0);

        double amountToRisk = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
        double potentialLossPerLot = (stopLossDistance / symbolTickSize) * symbolTickValue;
        if (potentialLossPerLot <= 0)
            return(0.0);

        calculatedLotSize = amountToRisk / potentialLossPerLot;
    }

    calculatedLotSize = MathFloor(calculatedLotSize / lotSizeStep) * lotSizeStep;
    calculatedLotSize = MathMax(minimumLotSize, MathMin(maximumLotSize, calculatedLotSize));
    return(NormalizeDouble(calculatedLotSize, 2));
}

//+------------------------------------------------------------------+
//| Chart Level Drawing (Locked horizontal time anchors & slope)     |
//+------------------------------------------------------------------+
void DrawSessionLevelLines(int sessionIndex, const datetime startOfDayTime)
{
    // Delete previous objects for this session before drawing new ones
    DeleteSessionObjects(sessionIndex);

    string dateString = TimeToString(startOfDayTime, TIME_DATE);
    string objectPrefix = OBJ_PREFIX + "S" + IntegerToString(sessionIndex + 1) + "_";

    string highLineName = objectPrefix + "High_" + dateString;
    string lowLineName = objectPrefix + "Low_" + dateString;
    string referenceLineName = objectPrefix + "RefTime_" + dateString;
    string highLabelName = objectPrefix + "HighLabel_" + dateString;
    string lowLabelName = objectPrefix + "LowLabel_" + dateString;


    if (InpExtendLinesToSessionEnd)
    {
        // Calculate exact end time based on user inputs (endH and endM)
        g_sessions[sessionIndex].lineEndTime = startOfDayTime + (g_sessions[sessionIndex].endH * 3600) + (g_sessions[sessionIndex].endM * 60);

        // If by mistake the end time is set before start time (e.g., overnight session), fallback to next session ref time or EOD
        if (g_sessions[sessionIndex].lineEndTime <= g_sessions[sessionIndex].refBarTime)
        {
            g_sessions[sessionIndex].lineEndTime = GetNextSessionRefTime(sessionIndex, startOfDayTime);
        }
    }
    else
    {
        // Calculate and cache the line's end time in the session structure
        g_sessions[sessionIndex].lineEndTime = GetNextSessionRefTime(sessionIndex, startOfDayTime);
    }

    // 1. Reference Vertical Line
    ObjectCreate(0, referenceLineName, OBJ_VLINE, 0, g_sessions[sessionIndex].refBarTime, 0);
    ObjectSetInteger(0, referenceLineName, OBJPROP_COLOR, g_sessions[sessionIndex].lineColor);
    ObjectSetInteger(0, referenceLineName, OBJPROP_STYLE, InpReferenceLineStyle);
    ObjectSetInteger(0, referenceLineName, OBJPROP_WIDTH, 1);
    ObjectSetInteger(0, referenceLineName, OBJPROP_BACK, true);
    ObjectSetInteger(0, referenceLineName, OBJPROP_SELECTABLE, false);

    // 2. High Line (Selectable for vertical dragging only)
    ObjectCreate(0, highLineName, OBJ_TREND, 0, g_sessions[sessionIndex].lineStartTime, g_sessions[sessionIndex].definedHigh, g_sessions[sessionIndex].lineEndTime, g_sessions[sessionIndex].definedHigh);
    ObjectSetInteger(0, highLineName, OBJPROP_COLOR, g_sessions[sessionIndex].lineColor);
    ObjectSetInteger(0, highLineName, OBJPROP_WIDTH, 1);
    ObjectSetInteger(0, highLineName, OBJPROP_STYLE, InpLineStyle);
    ObjectSetInteger(0, highLineName, OBJPROP_RAY_RIGHT, false);
    ObjectSetInteger(0, highLineName, OBJPROP_RAY_LEFT, false);
    ObjectSetInteger(0, highLineName, OBJPROP_SELECTABLE, true);
    ObjectSetInteger(0, highLineName, OBJPROP_SELECTED, false);

    // 3. Low Line (Selectable for vertical dragging only)
    ObjectCreate(0, lowLineName, OBJ_TREND, 0, g_sessions[sessionIndex].lineStartTime, g_sessions[sessionIndex].definedLow, g_sessions[sessionIndex].lineEndTime, g_sessions[sessionIndex].definedLow);
    ObjectSetInteger(0, lowLineName, OBJPROP_COLOR, g_sessions[sessionIndex].lineColor);
    ObjectSetInteger(0, lowLineName, OBJPROP_WIDTH, 1);
    ObjectSetInteger(0, lowLineName, OBJPROP_STYLE, InpLineStyle);
    ObjectSetInteger(0, lowLineName, OBJPROP_RAY_RIGHT, false);
    ObjectSetInteger(0, lowLineName, OBJPROP_RAY_LEFT, false);
    ObjectSetInteger(0, lowLineName, OBJPROP_SELECTABLE, true);
    ObjectSetInteger(0, lowLineName, OBJPROP_SELECTED, false);

    // 4. High Price Label (Above High line, anchored left of Reference Bar)
    ObjectCreate(0, highLabelName, OBJ_TEXT, 0, g_sessions[sessionIndex].refBarTime, g_sessions[sessionIndex].definedHigh);
    ObjectSetString(0, highLabelName, OBJPROP_TEXT, DoubleToString(g_sessions[sessionIndex].definedHigh, _Digits) + " ");
    ObjectSetInteger(0, highLabelName, OBJPROP_COLOR, g_sessions[sessionIndex].lineColor);
    ObjectSetInteger(0, highLabelName, OBJPROP_FONTSIZE, InpPriceLabelFontSize);
    ObjectSetInteger(0, highLabelName, OBJPROP_ANCHOR, ANCHOR_RIGHT_LOWER);
    ObjectSetInteger(0, highLabelName, OBJPROP_SELECTABLE, false);

    // 5. Low Price Label (Below Low line, anchored left of Reference Bar)
    ObjectCreate(0, lowLabelName, OBJ_TEXT, 0, g_sessions[sessionIndex].refBarTime, g_sessions[sessionIndex].definedLow);
    ObjectSetString(0, lowLabelName, OBJPROP_TEXT, DoubleToString(g_sessions[sessionIndex].definedLow, _Digits) + " ");
    ObjectSetInteger(0, lowLabelName, OBJPROP_COLOR, g_sessions[sessionIndex].lineColor);
    ObjectSetInteger(0, lowLabelName, OBJPROP_FONTSIZE, InpPriceLabelFontSize);
    ObjectSetInteger(0, lowLabelName, OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
    ObjectSetInteger(0, lowLabelName, OBJPROP_SELECTABLE, false);

    ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Delete objects for a specific session only                       |
//+------------------------------------------------------------------+
void DeleteSessionObjects(int sessionIndex)
{
    string objectPrefix = OBJ_PREFIX + "S" + IntegerToString(sessionIndex + 1) + "_";
    ObjectsDeleteAll(0, objectPrefix);
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
        if (StringFind(sparam, OBJ_PREFIX) == 0 && sparam != BTN_RESET_NAME && sparam != BTN_HLTF_NAME && !IsSessionToggleButton(sparam))
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

        // High/Low timeframe selector button
        if (sparam == BTN_HLTF_NAME)
        {
            CycleHighLowTimeframe();
        }

        // Session ON/OFF toggle buttons
        int clickedSession = SessionIndexFromButton(sparam);
        if (clickedSession >= 0)
        {
            ToggleSessionEnabled(clickedSession);
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
    for (int sessionIndex = 0; sessionIndex < 4; sessionIndex++)
    {
        string sessionPrefix = OBJ_PREFIX + "S" + IntegerToString(sessionIndex + 1) + "_";

        // Match the dragged line with its corresponding session
        if (StringFind(objectName, sessionPrefix) == 0)
        {
            // 1. Read price of whichever anchor point was moved (or anchor 0 by default)
            double primaryAnchorPrice = ObjectGetDouble(0, objectName, OBJPROP_PRICE, 0);
            double secondaryAnchorPrice = ObjectGetDouble(0, objectName, OBJPROP_PRICE, 1);

            // If anchor 1 was dragged to a different price than anchor 0, use anchor 1's price
            if (MathAbs(primaryAnchorPrice - secondaryAnchorPrice) > _Point)
            {
                if (StringFind(objectName, "_High_") > 0 && MathAbs(secondaryAnchorPrice - g_sessions[sessionIndex].definedHigh) > _Point)
                    primaryAnchorPrice = secondaryAnchorPrice;
                else
                    if (StringFind(objectName, "_Low_") > 0 && MathAbs(secondaryAnchorPrice - g_sessions[sessionIndex].definedLow) > _Point)
                        primaryAnchorPrice = secondaryAnchorPrice;
            }

            if (primaryAnchorPrice <= 0)
                return;

            // 2. ENFORCE HORIZONTAL LOCK: Keep both anchors at the exact same Y-axis price
            ObjectSetDouble(0, objectName, OBJPROP_PRICE, 0, primaryAnchorPrice);
            ObjectSetDouble(0, objectName, OBJPROP_PRICE, 1, primaryAnchorPrice);

            // 3. ENFORCE TIME ANCHOR LOCK: Prevent dragging start/end points horizontally
            ObjectSetInteger(0, objectName, OBJPROP_TIME, 0, g_sessions[sessionIndex].lineStartTime);
            ObjectSetInteger(0, objectName, OBJPROP_TIME, 1, g_sessions[sessionIndex].lineEndTime);

            // 4. Update internal session levels and their corresponding text label
            string dateString = TimeToString(g_sessions[sessionIndex].levelsDay, TIME_DATE);
            if (StringFind(objectName, "_High_") > 0)
            {
                g_sessions[sessionIndex].definedHigh = primaryAnchorPrice;
                UpdateSessionPriceLabel(sessionPrefix + "HighLabel_" + dateString, primaryAnchorPrice);
                PrintFormat("[User Action] Session %d High manually adjusted to %.5f", sessionIndex + 1, primaryAnchorPrice);
            }
            else
                if (StringFind(objectName, "_Low_") > 0)
                {
                    g_sessions[sessionIndex].definedLow = primaryAnchorPrice;
                    UpdateSessionPriceLabel(sessionPrefix + "LowLabel_" + dateString, primaryAnchorPrice);
                    PrintFormat("[User Action] Session %d Low manually adjusted to %.5f", sessionIndex + 1, primaryAnchorPrice);
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
//| Session toggle buttons: helpers                                  |
//+------------------------------------------------------------------+
string SessionButtonName(int sessionIndex)
{
    return BTN_SESSION_PREFIX + IntegerToString(sessionIndex + 1);
}

bool IsSessionToggleButton(const string objectName)
{
    return (SessionIndexFromButton(objectName) >= 0);
}

int SessionIndexFromButton(const string objectName)
{
    for (int sessionIndex = 0; sessionIndex < 4; sessionIndex++)
        if (objectName == SessionButtonName(sessionIndex))
            return sessionIndex;
    return -1;
}

//+------------------------------------------------------------------+
//| Create the four Session ON/OFF buttons under "Reset Levels"      |
//+------------------------------------------------------------------+
void CreateSessionButtons()
{
    int verticalGap = 4;                       // spacing between buttons (pixels)
    bool anchoredToBottom = (InpBtnCorner == CORNER_LEFT_LOWER || InpBtnCorner == CORNER_RIGHT_LOWER);

    for (int sessionIndex = 0; sessionIndex < 4; sessionIndex++)
    {
        string buttonName = SessionButtonName(sessionIndex);
        if (ObjectFind(0, buttonName) < 0)
            ObjectCreate(0, buttonName, OBJ_BUTTON, 0, 0, 0);

        // Stack the buttons directly below the Reset Levels button.
        // For bottom-anchored corners, "below" means a smaller Y distance.
        int offset = (sessionIndex + 1) * (InpBtnHeight + verticalGap);
        int yDistance = anchoredToBottom ? (InpBtnY - offset) : (InpBtnY + offset);

        ObjectSetInteger(0, buttonName, OBJPROP_CORNER, InpBtnCorner);
        ObjectSetInteger(0, buttonName, OBJPROP_XDISTANCE, InpBtnX);
        ObjectSetInteger(0, buttonName, OBJPROP_YDISTANCE, yDistance);
        ObjectSetInteger(0, buttonName, OBJPROP_XSIZE, InpBtnWidth);
        ObjectSetInteger(0, buttonName, OBJPROP_YSIZE, InpBtnHeight);
        ObjectSetInteger(0, buttonName, OBJPROP_BORDER_COLOR, clrBlack);
        ObjectSetInteger(0, buttonName, OBJPROP_COLOR, clrWhite);
        ObjectSetInteger(0, buttonName, OBJPROP_HIDDEN, true);
        ObjectSetInteger(0, buttonName, OBJPROP_SELECTABLE, false);

        RefreshSessionButton(sessionIndex);
    }

    ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Sync a session button's look with the effective enable state     |
//+------------------------------------------------------------------+
void RefreshSessionButton(int sessionIndex)
{
    string buttonName = SessionButtonName(sessionIndex);
    if (ObjectFind(0, buttonName) < 0)
        return;

    bool isEnabled = g_sessionButtonState[sessionIndex];

    ObjectSetString(0, buttonName, OBJPROP_TEXT,
        "Session " + IntegerToString(sessionIndex + 1) + (isEnabled ? ": ON" : ": OFF"));
    ObjectSetInteger(0, buttonName, OBJPROP_BGCOLOR, isEnabled ? clrSeaGreen : clrFireBrick);
    ObjectSetInteger(0, buttonName, OBJPROP_COLOR, clrWhite);
    ObjectSetInteger(0, buttonName, OBJPROP_STATE, false);   // never stay visually pressed
}

//+------------------------------------------------------------------+
//| Toggle a session ON/OFF from its chart button                    |
//+------------------------------------------------------------------+
void ToggleSessionEnabled(int sessionIndex)
{
    SetSessionEnabled(sessionIndex, !g_sessionButtonState[sessionIndex]);
}

//+------------------------------------------------------------------+
//| Apply a session enable state (button == effective EA state)      |
//+------------------------------------------------------------------+
void SetSessionEnabled(int sessionIndex, bool isEnabled)
{
    if (sessionIndex < 0 || sessionIndex > 3)
        return;

    g_sessionButtonState[sessionIndex] = isEnabled;

    // The EA reads g_sessions[].enable everywhere, so the button drives it directly.
    g_sessions[sessionIndex].enable = isEnabled;

    if (!isEnabled)
    {
        // Behave exactly as if the input parameter were false: no levels, no trades.
        g_sessions[sessionIndex].levelsSet = false;
        g_sessions[sessionIndex].levelsDay = 0;   // allow a fresh calculation if re-enabled later today
        DeleteSessionObjects(sessionIndex);
    }
    else
    {
        // Re-enabled: recalculate and redraw immediately, without waiting for a new bar.
        g_sessions[sessionIndex].levelsDay = 0;
        UpdateSessionLevels(sessionIndex);
    }

    RefreshSessionButton(sessionIndex);
    PrintFormat("[User Action] Session %d %s via chart button.", sessionIndex + 1, isEnabled ? "ENABLED" : "DISABLED");
    ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Reset levels back to their calculated origin                     |
//+------------------------------------------------------------------+
void ResetLevelsToOriginal()
{
    for (int sessionIndex = 0; sessionIndex < 4; sessionIndex++)
    {
        // Check if session is active and original levels exist
        if (g_sessions[sessionIndex].levelsSet && g_sessions[sessionIndex].originalHigh > 0 && g_sessions[sessionIndex].originalLow > 0)
        {
            g_sessions[sessionIndex].definedHigh = g_sessions[sessionIndex].originalHigh;
            g_sessions[sessionIndex].definedLow = g_sessions[sessionIndex].originalLow;

            // Redraw lines (and labels) at their original coordinates
            DrawSessionLevelLines(sessionIndex, g_sessions[sessionIndex].levelsDay);

            PrintFormat("[Reset] Session %d levels reverted to original: High=%.5f, Low=%.5f", sessionIndex + 1, g_sessions[sessionIndex].originalHigh, g_sessions[sessionIndex].originalLow);
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
    datetime serverTime = TimeTradeServer();
    datetime localTime = TimeCurrent();
    return(serverTime > localTime ? serverTime : localTime);
}

//--- Server-time midnight of the given timestamp -------------------
datetime MarketCloseDayStart(const datetime targetTime)
{
    MqlDateTime dateTimeStruct;
    TimeToStruct(targetTime, dateTimeStruct);
    dateTimeStruct.hour = 0;
    dateTimeStruct.min = 0;
    dateTimeStruct.sec = 0;
    return(StructToTime(dateTimeStruct));
}

//--- Server-time day of week of the given timestamp ----------------
ENUM_DAY_OF_WEEK MarketCloseDayOfWeek(const datetime targetTime)
{
    MqlDateTime dateTimeStruct;
    TimeToStruct(targetTime, dateTimeStruct);
    return((ENUM_DAY_OF_WEEK)dateTimeStruct.day_of_week);
}

//+------------------------------------------------------------------+
//| Read all trading sessions of the calendar day containing         |
//| 'targetDayAnchor'. Returns count; sessionStartSeconds/sessionEndSeconds are seconds from 00:00 |
//| (a session ending at midnight is normalised to 86400).           |
//+------------------------------------------------------------------+
int MarketCloseGetDaySessions(const datetime targetDayAnchor, int& sessionStartSeconds[], int& sessionEndSeconds[])
{
    ArrayResize(sessionStartSeconds, 0);
    ArrayResize(sessionEndSeconds, 0);

    ENUM_DAY_OF_WEEK dayOfWeek = MarketCloseDayOfWeek(targetDayAnchor);
    datetime tempSessionStart, tempSessionEnd;
    int sessionCount = 0;

    for (uint sessionIndex = 0; sessionIndex < 24; sessionIndex++)
    {
        if (!SymbolInfoSessionTrade(_Symbol, dayOfWeek, sessionIndex, tempSessionStart, tempSessionEnd))
            break;

        int startSeconds = (int)((long)tempSessionStart % 86400);
        int endSeconds = (int)((long)tempSessionEnd % 86400);
        if (endSeconds <= startSeconds)
            endSeconds = 86400;                       // session runs up to midnight

        ArrayResize(sessionStartSeconds, sessionCount + 1);
        ArrayResize(sessionEndSeconds, sessionCount + 1);
        sessionStartSeconds[sessionCount] = startSeconds;
        sessionEndSeconds[sessionCount] = endSeconds;
        sessionCount++;
    }

    // Defensive ordering (brokers normally return sessions sorted)
    for (int sessionIndex = 1; sessionIndex < sessionCount; sessionIndex++)
        for (int j = sessionIndex; j > 0 && sessionStartSeconds[j] < sessionStartSeconds[j - 1]; j--)
        {
            int tempStartSwap = sessionStartSeconds[j];
            sessionStartSeconds[j] = sessionStartSeconds[j - 1];
            sessionStartSeconds[j - 1] = tempStartSwap;
            int tempEndSwap = sessionEndSeconds[j];
            sessionEndSeconds[j] = sessionEndSeconds[j - 1];
            sessionEndSeconds[j - 1] = tempEndSwap;
        }

    return(sessionCount);
}

//+------------------------------------------------------------------+
//| Resolve the REAL market closing time for the session that is     |
//| currently running. Contiguous sessions - including a block that  |
//| runs through midnight into the next day - are merged, so the     |
//| result is the moment the market actually stops trading.          |
//| Returns false when the symbol is not inside a session now.       |
//+------------------------------------------------------------------+
bool MarketCloseGetMarketCloseTime(const datetime currentTime, datetime& marketCloseTime)
{
    marketCloseTime = 0;

    int mergeGapSeconds = (InpMC_SessionMergeGapMin > 0 ? InpMC_SessionMergeGapMin : 0) * 60;

    datetime startOfDay = MarketCloseDayStart(currentTime);
    int      secondsSinceStartOfDay = (int)(currentTime - startOfDay);

    int startSecondsArray[], endSecondsArray[];
    int totalSessions = MarketCloseGetDaySessions(startOfDay, startSecondsArray, endSecondsArray);

    if (totalSessions <= 0)
    {
        if (!g_mcNoSchedWarned && MarketCloseDayOfWeek(currentTime) != SATURDAY && MarketCloseDayOfWeek(currentTime) != SUNDAY)
        {
            PrintFormat("[MarketClose] No trading session schedule published by the broker for %s on this weekday.", _Symbol);
            g_mcNoSchedWarned = true;
        }
        return(false);                      // market closed today (weekend / holiday schedule)
    }

    // Locate the session we are inside (a short pre-session gap counts as inside)
    int currentSessionIndex = -1;
    for (int i = 0; i < totalSessions; i++)
        if (secondsSinceStartOfDay >= startSecondsArray[i] - mergeGapSeconds && secondsSinceStartOfDay < endSecondsArray[i])
        {
            currentSessionIndex = i;
            break;
        }
    if (currentSessionIndex < 0)
        return(false);                      // between sessions / outside trading hours

    int sessionEndSeconds = endSecondsArray[currentSessionIndex];
    int loopGuardCount = 0;

    while (loopGuardCount++ < 10)
    {
        // (a) merge the next same-day session when the gap is negligible (split sessions)
        bool isSessionMerged = false;
        for (int i = currentSessionIndex + 1; i < totalSessions; i++)
        {
            if (startSecondsArray[i] >= sessionEndSeconds && (startSecondsArray[i] - sessionEndSeconds) <= mergeGapSeconds)
            {
                sessionEndSeconds = endSecondsArray[i];
                currentSessionIndex = i;
                isSessionMerged = true;
                break;
            }
        }
        if (isSessionMerged)
            continue;

        // (b) session ends at midnight -> does the next day continue seamlessly?
        if (sessionEndSeconds >= 86400 - mergeGapSeconds)
        {
            datetime nextDayStart = startOfDay + 86400;
            int nextDayStartSeconds[], nextDayEndSeconds[];
            int nextDayTotalSessions = MarketCloseGetDaySessions(nextDayStart, nextDayStartSeconds, nextDayEndSeconds);

            if (nextDayTotalSessions > 0 && nextDayStartSeconds[0] <= mergeGapSeconds)         // yes: Mon-Thu style rollover, market never closes
            {
                ArrayResize(startSecondsArray, nextDayTotalSessions);
                ArrayResize(endSecondsArray, nextDayTotalSessions);
                for (int i = 0; i < nextDayTotalSessions; i++)
                {
                    startSecondsArray[i] = nextDayStartSeconds[i];
                    endSecondsArray[i] = nextDayEndSeconds[i];
                }
                startOfDay = nextDayStart;
                totalSessions = nextDayTotalSessions;
                currentSessionIndex = 0;
                sessionEndSeconds = endSecondsArray[0];
                continue;
            }
        }
        break;                              // this is the real close (e.g. Friday early close)
    }

    marketCloseTime = startOfDay + sessionEndSeconds;
    return(true);
}

//+------------------------------------------------------------------+
//| First session start strictly after 'referenceTime' (up to 8 days)     |
//+------------------------------------------------------------------+
bool MarketCloseGetNextSessionStart(const datetime referenceTime, datetime& nextSessionOpenTime)
{
    nextSessionOpenTime = 0;
    datetime baseDayStart = MarketCloseDayStart(referenceTime);

    for (int dayOffset = 0; dayOffset <= 8; dayOffset++)
    {
        datetime currentOffsetDay = baseDayStart + dayOffset * 86400;
        int startSecondsArray[], endSecondsArray[];
        int totalSessions = MarketCloseGetDaySessions(currentOffsetDay, startSecondsArray, endSecondsArray);

        for (int i = 0; i < totalSessions; i++)
        {
            datetime calculatedSessionStart = currentOffsetDay + startSecondsArray[i];
            if (calculatedSessionStart > referenceTime)
            {
                nextSessionOpenTime = calculatedSessionStart;
                return(true);
            }
        }
    }
    return(false);
}

//--- Does this EA still have exposure on the symbol? ---------------
bool MarketCloseHasExposure()
{
    for (int positionIndex = PositionsTotal() - 1; positionIndex >= 0; positionIndex--)
    {
        ulong positionTicket = PositionGetTicket(positionIndex);
        if (positionTicket == 0)
            continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
        ulong expertMagicNumber = (ulong)PositionGetInteger(POSITION_MAGIC);
        if (InpMC_CloseOnlyEaTrades && (expertMagicNumber < InpMagic || expertMagicNumber > InpMagic + 3))
            continue;
        return(true);
    }

    for (int orderIndex = OrdersTotal() - 1; orderIndex >= 0; orderIndex--)
    {
        ulong orderTicket = OrderGetTicket(orderIndex);
        if (orderTicket == 0)
            continue;
        if (OrderGetString(ORDER_SYMBOL) != _Symbol)
            continue;
        ulong expertMagicNumber = (ulong)OrderGetInteger(ORDER_MAGIC);
        if (InpMC_CloseOnlyEaTrades && (expertMagicNumber < InpMagic || expertMagicNumber > InpMagic + 3))
            continue;
        return(true);
    }
    return(false);
}

//--- Step 1: cancel pending orders for the symbol ------------------
int MarketCloseCancelPendingOrders()
{
    int cancelledOrdersCount = 0;

    for (int i = OrdersTotal() - 1; i >= 0; i--)
    {
        ulong orderTicket = OrderGetTicket(i);
        if (orderTicket == 0)
            continue;
        if (OrderGetString(ORDER_SYMBOL) != _Symbol)
            continue;

        ulong expertMagicNumber = (ulong)OrderGetInteger(ORDER_MAGIC);
        if (InpMC_CloseOnlyEaTrades && (expertMagicNumber < InpMagic || expertMagicNumber > InpMagic + 3))
            continue;

        if (g_trade.OrderDelete(orderTicket))
        {
            cancelledOrdersCount++;
            PrintFormat("[MarketClose] Pending order #%I64u (%s) cancelled before market close.",
                orderTicket, EnumToString((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE)));
        }
        else
            PrintFormat("[MarketClose] FAILED to cancel pending order #%I64u: %d - %s",
                orderTicket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
    }

    if (cancelledOrdersCount > 0)
        PrintFormat("[MarketClose] %d pending order(s) cancelled for %s.", cancelledOrdersCount, _Symbol);

    return(cancelledOrdersCount);
}

//--- Step 2: close every open position for the symbol --------------
int MarketCloseCloseAllPositions()
{
    int closedPositionsCount = 0;

    for (int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong positionTicket = PositionGetTicket(i);
        if (positionTicket == 0)
            continue;
        if (PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;

        ulong expertMagicNumber = (ulong)PositionGetInteger(POSITION_MAGIC);
        if (InpMC_CloseOnlyEaTrades && (expertMagicNumber < InpMagic || expertMagicNumber > InpMagic + 3))
            continue;

        double positionVolume = PositionGetDouble(POSITION_VOLUME);
        double positionProfit = PositionGetDouble(POSITION_PROFIT);
        string positionDirection = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL");

        if (g_trade.PositionClose(positionTicket, InpSlippagePoints))
        {
            closedPositionsCount++;
            PrintFormat("[MarketClose] Position #%I64u %s %.2f lots (magic %I64u, P/L %.2f) CLOSED by market-close protection.",
                positionTicket, positionDirection, positionVolume, expertMagicNumber, positionProfit);
        }
        else
            PrintFormat("[MarketClose] FAILED to close position #%I64u: %d - %s (will retry)",
                positionTicket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
    }

    if (closedPositionsCount > 0)
        PrintFormat("[MarketClose] %d position(s) closed for %s.", closedPositionsCount, _Symbol);

    return(closedPositionsCount);
}

//+------------------------------------------------------------------+
//| Main controller - called from OnTick() and OnTimer()             |
//+------------------------------------------------------------------+
void ManageMarketCloseProtection()
{
    if (!EnableCloseBeforeMarketClose)
        return;

    datetime currentServerTime = MarketCloseServerNow();
    if (currentServerTime <= 0)
        return;

    // --- Release the block once the next valid trading session has begun ---
    if (g_mcBlockTrading && g_mcResumeTime > 0 && currentServerTime >= g_mcResumeTime)
    {
        g_mcBlockTrading = false;
        g_mcLastLoggedMin = -1;
        PrintFormat("[MarketClose] New trading session started (%s server time) -> trading re-enabled.",
            TimeToString(currentServerTime, TIME_DATE | TIME_MINUTES));
    }

    // --- Resolve the actual market closing time from the symbol schedule ---
    datetime calculatedCloseTime = 0;
    if (!MarketCloseGetMarketCloseTime(currentServerTime, calculatedCloseTime))
    {
        // Outside a trading session: keep any active block, nothing else to do
        if (g_mcBlockTrading && g_mcResumeTime > 0)
            return;
        return;
    }

    long remainingSecondsToClose = (long)(calculatedCloseTime - currentServerTime);
    int  remainingMinutesToClose = (int)MathCeil(remainingSecondsToClose / 60.0);

    // --- Log the detected closing time once per resolved close ---
    if (calculatedCloseTime != g_mcLoggedClose)
    {
        g_mcLoggedClose = calculatedCloseTime;
        MqlDateTime closeTimeStruct;
        TimeToStruct(calculatedCloseTime, closeTimeStruct);
        PrintFormat("[MarketClose] Detected market close for %s: %s (server time, %s) | remaining: %d min | trigger threshold: %d min",
            _Symbol,
            TimeToString(calculatedCloseTime, TIME_DATE | TIME_MINUTES),
            EnumToString((ENUM_DAY_OF_WEEK)closeTimeStruct.day_of_week),
            remainingMinutesToClose, g_mcMinutes);
    }

    // --- Countdown logging inside the final hour / threshold window ---
    int loggingWindowMinutes = (g_mcMinutes > 60 ? g_mcMinutes + 15 : 60);
    if (remainingMinutesToClose <= loggingWindowMinutes && remainingMinutesToClose != g_mcLastLoggedMin)
    {
        g_mcLastLoggedMin = remainingMinutesToClose;
        PrintFormat("[MarketClose] %s closes at %s - %d minute(s) remaining (threshold %d).",
            _Symbol, TimeToString(calculatedCloseTime, TIME_DATE | TIME_MINUTES), remainingMinutesToClose, g_mcMinutes);
    }

    // --- Trigger window reached ---
    if (remainingSecondsToClose <= (long)g_mcMinutes * 60)
    {
        bool isFirstTimeHandlingClose = (g_mcHandledClose != calculatedCloseTime);

        if (isFirstTimeHandlingClose)
        {
            g_mcHandledClose = calculatedCloseTime;
            PrintFormat("[MarketClose] *** PROTECTION TRIGGERED *** %d min (<= %d) to market close at %s. Flattening %s.",
                remainingMinutesToClose, g_mcMinutes,
                TimeToString(calculatedCloseTime, TIME_DATE | TIME_MINUTES), _Symbol);

            datetime nextSessionOpenTime = 0;
            if (MarketCloseGetNextSessionStart(calculatedCloseTime, nextSessionOpenTime))
                g_mcResumeTime = nextSessionOpenTime;
            else
                g_mcResumeTime = calculatedCloseTime + 3600;   // fallback if the broker publishes no next session

            g_mcBlockTrading = true;
            PrintFormat("[MarketClose] New entries blocked until the next trading session opens at %s (server time).",
                TimeToString(g_mcResumeTime, TIME_DATE | TIME_MINUTES));
        }
        else
            g_mcBlockTrading = true;   // stay blocked for the whole window

        // Cancel pendings first, then close positions. Retry (max every 3 s) on failures.
        static datetime lastRetryTime = 0;
        if (MarketCloseHasExposure() && (isFirstTimeHandlingClose || currentServerTime - lastRetryTime >= 3))
        {
            lastRetryTime = currentServerTime;
            MarketCloseCancelPendingOrders();
            MarketCloseCloseAllPositions();
        }
    }
}
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| High/Low timeframe selector: helpers                             |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES HighLowTimeframe()
{
    if (g_highAndLowTimeframeIndex <= 0 || g_highAndLowTimeframeIndex >= HLTF_OPTION_COUNT)
        return((ENUM_TIMEFRAMES)_Period);          // "Current" -> chart timeframe
    return(g_highAndLowTimeframeOptions[g_highAndLowTimeframeIndex]);
}

string HighLowTimeframeLabel()
{
    if (g_highAndLowTimeframeIndex < 0 || g_highAndLowTimeframeIndex >= HLTF_OPTION_COUNT)
        return(g_highAndLowTimeframeLabels[0]);
    return(g_highAndLowTimeframeLabels[g_highAndLowTimeframeIndex]);
}

string HighAndLowTimeframeGlobalName()
{
    // Per symbol + chart timeframe, so each chart remembers its own choice.
    return(GV_HLTF_PREFIX + _Symbol + "_" + IntegerToString((int)_Period));
}

void LoadHighAndLowTimeframeSelection()
{
    string globalName = HighAndLowTimeframeGlobalName();
    if (!GlobalVariableCheck(globalName))
        return;

    int savedIndex = (int)GlobalVariableGet(globalName);
    if (savedIndex >= 0 && savedIndex < HLTF_OPTION_COUNT)
    {
        g_highAndLowTimeframeIndex = savedIndex;
        PrintFormat("[HL TF] Restored High/Low timeframe: %s", HighLowTimeframeLabel());
    }
}

void SaveHighAndLowTimeframeSelection()
{
    GlobalVariableSet(HighAndLowTimeframeGlobalName(), (double)g_highAndLowTimeframeIndex);
}

//+------------------------------------------------------------------+
//| Create the HL timeframe button below all existing buttons        |
//+------------------------------------------------------------------+
void CreateHighAndLowTimeframeButton()
{
    int verticalGap = 4;                        // same spacing as the session buttons
    bool anchoredToBottom = (InpBtnCorner == CORNER_LEFT_LOWER || InpBtnCorner == CORNER_RIGHT_LOWER);

    if (ObjectFind(0, BTN_HLTF_NAME) < 0)
        ObjectCreate(0, BTN_HLTF_NAME, OBJ_BUTTON, 0, 0, 0);

    // Reset button + 4 session buttons already occupy slots 0..4 -> this one is slot 5.
    int offset = 5 * (InpBtnHeight + verticalGap);
    int yDistance = anchoredToBottom ? (InpBtnY - offset) : (InpBtnY + offset);

    ObjectSetInteger(0, BTN_HLTF_NAME, OBJPROP_CORNER, InpBtnCorner);
    ObjectSetInteger(0, BTN_HLTF_NAME, OBJPROP_XDISTANCE, InpBtnX);
    ObjectSetInteger(0, BTN_HLTF_NAME, OBJPROP_YDISTANCE, yDistance);
    ObjectSetInteger(0, BTN_HLTF_NAME, OBJPROP_XSIZE, InpBtnWidth);
    ObjectSetInteger(0, BTN_HLTF_NAME, OBJPROP_YSIZE, InpBtnHeight);
    ObjectSetInteger(0, BTN_HLTF_NAME, OBJPROP_BORDER_COLOR, clrBlack);
    ObjectSetInteger(0, BTN_HLTF_NAME, OBJPROP_HIDDEN, true);
    ObjectSetInteger(0, BTN_HLTF_NAME, OBJPROP_SELECTABLE, false);

    RefreshHighAndLowTimeframeButton();
    ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Keep the button caption in sync with the selected timeframe      |
//+------------------------------------------------------------------+
void RefreshHighAndLowTimeframeButton()
{
    if (ObjectFind(0, BTN_HLTF_NAME) < 0)
        return;

    ObjectSetString(0, BTN_HLTF_NAME, OBJPROP_TEXT, "HL TF: " + HighLowTimeframeLabel());
    ObjectSetInteger(0, BTN_HLTF_NAME, OBJPROP_COLOR, clrWhite);
    ObjectSetInteger(0, BTN_HLTF_NAME, OBJPROP_BGCOLOR, clrDarkSlateBlue);
    ObjectSetInteger(0, BTN_HLTF_NAME, OBJPROP_STATE, false);   // never stay visually pressed
}

//+------------------------------------------------------------------+
//| Cycle Current -> M1 -> M5 -> M15 -> H1 -> Current                |
//+------------------------------------------------------------------+
void CycleHighLowTimeframe()
{
    g_highAndLowTimeframeIndex = (g_highAndLowTimeframeIndex + 1) % HLTF_OPTION_COUNT;
    SaveHighAndLowTimeframeSelection();
    RefreshHighAndLowTimeframeButton();

    // Touch the new series so the terminal starts loading its history.
    ENUM_TIMEFRAMES selectedTimeframe = HighLowTimeframe();
    Bars(_Symbol, selectedTimeframe);

    PrintFormat("[User Action] High/Low timeframe switched to %s via chart button.", HighLowTimeframeLabel());

    RecalculateLevelsForHighAndLowTimeframeChange();
    ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Recompute High/Low with the new source timeframe.                |
//| Session trading state (trade counters, locks, halts) is fully    |
//| preserved: only the High/Low values are refreshed.               |
//+------------------------------------------------------------------+
void RecalculateLevelsForHighAndLowTimeframeChange()
{
    for (int sessionIndex = 0; sessionIndex < 4; sessionIndex++)
    {
        if (!g_sessions[sessionIndex].enable)
            continue;

        // Snapshot the live trading state so the switch cannot alter it
        int  savedTradesToday = g_sessions[sessionIndex].tradesToday;
        bool savedTrade1HitSL = g_sessions[sessionIndex].trade1HitSL;
        bool savedHaltTrading = g_sessions[sessionIndex].haltTrading;
        bool savedBuyTriggered = g_sessions[sessionIndex].buyTriggered;
        bool savedSellTriggered = g_sessions[sessionIndex].sellTriggered;

        g_sessions[sessionIndex].levelsDay = 0;   // force a fresh calculation for today
        UpdateSessionLevels(sessionIndex);

        g_sessions[sessionIndex].tradesToday = savedTradesToday;
        g_sessions[sessionIndex].trade1HitSL = savedTrade1HitSL;
        g_sessions[sessionIndex].haltTrading = savedHaltTrading;
        g_sessions[sessionIndex].buyTriggered = savedBuyTriggered;
        g_sessions[sessionIndex].sellTriggered = savedSellTriggered;
    }
}
//+------------------------------------------------------------------+
