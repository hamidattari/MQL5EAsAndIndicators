//+------------------------------------------------------------------+
//|                                      ButtonTraderPro_Panel.mq5   |
//|                Professional Button-Based Trading EA (Panel UI)   |
//|                                                                  |
//|  Collapsible / expandable panel containing 4 trade buttons:      |
//|     Buy1 (1:2), Buy2 (1:4), Sell1 (1:2), Sell2 (1:4)             |
//|  - Automatic position sizing based on % risk of balance          |
//|  - Stop Loss from Low/High of candle 2 bars ago +/- buffer       |
//|  - Panel has configurable X/Y offset and collapse/expand toggle  |
//|  - Selectable execution mode: Instant or Next Candle open        |
//+------------------------------------------------------------------+
#property copyright "ButtonTraderPro"
#property version   "2.50"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>

//--- Trade helpers
CTrade         tradeManager;
CSymbolInfo    symbolInformation;

//--- Execution mode
enum ENUM_EXECUTION_MODE
{
    EXEC_INSTANT = 0,  // Instant Execution
    EXEC_NEXT_CANDLE = 1   // Next Candle Execution
};

//============================ USER INPUTS ============================//
input group "=== Risk Management ==="
input double   InpRiskPercent = 1.0;     // Risk per trade (% of account balance)

input group "=== Stop Loss / Take Profit ==="
input int      InpStopLossBufferPoints = 50;      // Extra points beyond the 2-bar candle
input int      InpTakeProfitBufferPoints = 50;      // Points subtracted from calculated TP

input group "=== Execution Mode ==="
input ENUM_EXECUTION_MODE InpExecutionMode = EXEC_INSTANT; // Default execution mode

input group "=== Panel Position & Offset ==="
input ENUM_BASE_CORNER InpPanelAnchorCorner = CORNER_LEFT_UPPER; // Anchor corner
input int      InpPanelXOffset = 12;      // Panel X offset from corner (pixels)
input int      InpPanelYOffset = 112;     // Panel Y offset from corner (pixels)
input bool     InpStartPanelCollapsed = false;   // Start with panel collapsed?

input group "=== Panel Appearance ==="
input int      InpPanelWidthPixels = 320;     // Panel width  (pixels)
input int      InpButtonHeightPixels = 34;      // Trade button height (pixels)
input int      InpButtonGapPixels = 6;       // Gap between buttons (pixels)
input int      InpPanelInnerPadding = 8;       // Inner padding (pixels)
input int      InpTitleBarHeightPixels = 26;      // Title bar height (pixels)
input int      InpButtonFontSize = 10;      // Font size on buttons
input string   InpButtonFontName = "Arial Bold"; // Font name
input color    InpPanelBackgroundColor = C'40,40,45';   // Panel background color
input color    InpTitleBackgroundColor = C'25,25,30';   // Title bar background color
input color    InpTitleTextColor = clrWhite;      // Title text color

input group "=== Trade Settings ==="
input ulong    InpExpertMagicNumber = 20240617; // Magic number
input ulong    InpMaxSlippagePoints = 30;       // Max slippage (points)

//========================= OBJECT NAME CONSTANTS ====================//
#define PNL_BG      "BTP_Panel_BG"
#define PNL_TITLE   "BTP_Panel_Title"
#define PNL_LABEL   "BTP_Panel_Label"
#define PNL_TOGGLE  "BTP_Panel_Toggle"
#define BTN_MODE    "BTP_ExecMode"
#define BTN_BUY1    "BTP_Buy1"
#define BTN_BUY2    "BTP_Buy2"
#define BTN_SELL1   "BTP_Sell1"
#define BTN_SELL2   "BTP_Sell2"

//--- Pending trade request (for Next Candle Execution)
struct PendingTradeRequest
{
    bool             isActive;
    string           buttonObjectName;
    ENUM_ORDER_TYPE  direction;
    double           rewardToRiskMultiple;
};

//--- Runtime state
bool                 g_isPanelCollapsed = false;
ENUM_EXECUTION_MODE  g_executionMode = EXEC_INSTANT;
PendingTradeRequest  g_pendingRequests[];
datetime             g_lastKnownBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
    tradeManager.SetExpertMagicNumber(InpExpertMagicNumber);
    tradeManager.SetDeviationInPoints(InpMaxSlippagePoints);
    tradeManager.SetTypeFillingBySymbol(_Symbol);
    tradeManager.SetAsyncMode(false);

    if (!symbolInformation.Name(_Symbol))
    {
        Print("ERROR: Unable to initialize symbol info for ", _Symbol);
        return(INIT_FAILED);
    }

    if (InpRiskPercent <= 0.0)
    {
        Print("ERROR: InpRiskPercent must be greater than 0.");
        return(INIT_PARAMETERS_INCORRECT);
    }

    g_isPanelCollapsed = InpStartPanelCollapsed;
    g_executionMode = InpExecutionMode;
    ArrayResize(g_pendingRequests, 0);
    g_lastKnownBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    BuildPanel();

    Print("ButtonTraderPro (Panel) initialized on ", _Symbol,
        " | Risk=", InpRiskPercent, "% | SL_Buffer=", InpStopLossBufferPoints,
        " | TP_Buffer=", InpTakeProfitBufferPoints,
        " | ExecMode=", ExecutionModeText());

    return(INIT_SUCCEEDED);
}

void OnDeinit(const int deinitReason)
{
    DeleteAllObjects();
    ChartRedraw();
}

//+------------------------------------------------------------------+
//| Tick handler: executes pending requests on new candle open       |
//+------------------------------------------------------------------+
void OnTick()
{
    datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    if (currentBarTime == g_lastKnownBarTime)
        return;

    g_lastKnownBarTime = currentBarTime;

    int pendingCount = ArraySize(g_pendingRequests);
    if (pendingCount == 0)
        return;

    for (int i = 0; i < pendingCount; i++)
    {
        if (!g_pendingRequests[i].isActive)
            continue;

        string buttonObjectName = g_pendingRequests[i].buttonObjectName;
        Print("Executing pending ", (g_pendingRequests[i].direction == ORDER_TYPE_BUY ? "BUY" : "SELL"),
            " request at new candle open.");

        bool isTradeExecuted = ExecuteTrade(g_pendingRequests[i].direction,
            g_pendingRequests[i].rewardToRiskMultiple);
        if (!isTradeExecuted)
            Print("Pending order for ", buttonObjectName, " was not executed and has expired.");

        // A next-candle request is valid for this candle only, whether the broker
        // accepts it or not.  Always return its button to its normal state.
        RestoreTradeButton(buttonObjectName);
    }

    ArrayResize(g_pendingRequests, 0);
    ChartRedraw();
}

//+==================================================================+
//|                       PANEL DRAWING CODE                         |
//+==================================================================+

void CreateRect(const string objectName, const int xPosition, const int yPosition,
    const int boxWidth, const int boxHeight, const color backgroundColor,
    const color borderColor)
{
    if (ObjectFind(0, objectName) < 0)
        ObjectCreate(0, objectName, OBJ_RECTANGLE_LABEL, 0, 0, 0);

    ObjectSetInteger(0, objectName, OBJPROP_CORNER, InpPanelAnchorCorner);
    ObjectSetInteger(0, objectName, OBJPROP_XDISTANCE, xPosition);
    ObjectSetInteger(0, objectName, OBJPROP_YDISTANCE, yPosition);
    ObjectSetInteger(0, objectName, OBJPROP_XSIZE, boxWidth);
    ObjectSetInteger(0, objectName, OBJPROP_YSIZE, boxHeight);
    ObjectSetInteger(0, objectName, OBJPROP_BGCOLOR, backgroundColor);
    ObjectSetInteger(0, objectName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
    ObjectSetInteger(0, objectName, OBJPROP_COLOR, borderColor);
    ObjectSetInteger(0, objectName, OBJPROP_WIDTH, 1);
    ObjectSetInteger(0, objectName, OBJPROP_BACK, false);
    ObjectSetInteger(0, objectName, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, objectName, OBJPROP_HIDDEN, true);
    ObjectSetInteger(0, objectName, OBJPROP_ZORDER, 0);
}

void CreateLabel(const string objectName, const int xPosition, const int yPosition,
    const string labelText, const color textColor, const int fontSize)
{
    if (ObjectFind(0, objectName) < 0)
        ObjectCreate(0, objectName, OBJ_LABEL, 0, 0, 0);

    ObjectSetInteger(0, objectName, OBJPROP_CORNER, InpPanelAnchorCorner);
    ObjectSetInteger(0, objectName, OBJPROP_XDISTANCE, xPosition);
    ObjectSetInteger(0, objectName, OBJPROP_YDISTANCE, yPosition);
    ObjectSetString(0, objectName, OBJPROP_TEXT, labelText);
    ObjectSetString(0, objectName, OBJPROP_FONT, InpButtonFontName);
    ObjectSetInteger(0, objectName, OBJPROP_FONTSIZE, fontSize);
    ObjectSetInteger(0, objectName, OBJPROP_COLOR, textColor);
    ObjectSetInteger(0, objectName, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, objectName, OBJPROP_HIDDEN, true);
    ObjectSetInteger(0, objectName, OBJPROP_ZORDER, 2);
}

void CreateButton(const string objectName, const int xPosition, const int yPosition,
    const int buttonWidth, const int buttonHeight, const string buttonText,
    const color backgroundColor, const int fontSize)
{
    if (ObjectFind(0, objectName) < 0)
        ObjectCreate(0, objectName, OBJ_BUTTON, 0, 0, 0);

    ObjectSetInteger(0, objectName, OBJPROP_CORNER, InpPanelAnchorCorner);
    ObjectSetInteger(0, objectName, OBJPROP_XDISTANCE, xPosition);
    ObjectSetInteger(0, objectName, OBJPROP_YDISTANCE, yPosition);
    ObjectSetInteger(0, objectName, OBJPROP_XSIZE, buttonWidth);
    ObjectSetInteger(0, objectName, OBJPROP_YSIZE, buttonHeight);
    ObjectSetString(0, objectName, OBJPROP_TEXT, buttonText);
    ObjectSetString(0, objectName, OBJPROP_FONT, InpButtonFontName);
    ObjectSetInteger(0, objectName, OBJPROP_FONTSIZE, fontSize);
    ObjectSetInteger(0, objectName, OBJPROP_COLOR, clrWhite);
    ObjectSetInteger(0, objectName, OBJPROP_BGCOLOR, backgroundColor);
    ObjectSetInteger(0, objectName, OBJPROP_BORDER_COLOR, clrBlack);
    ObjectSetInteger(0, objectName, OBJPROP_STATE, false);
    ObjectSetInteger(0, objectName, OBJPROP_HIDDEN, true);
    ObjectSetInteger(0, objectName, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, objectName, OBJPROP_ZORDER, 5);
}

string ExecutionModeText()
{
    return (g_executionMode == EXEC_INSTANT) ? "MODE: INSTANT" : "MODE: NEXT CANDLE";
}

color ExecutionModeColor()
{
    return (g_executionMode == EXEC_INSTANT) ? C'70,90,140' : C'140,110,40';
}

string TradeButtonOriginalText(const string buttonObjectName)
{
    if (buttonObjectName == BTN_BUY1)  return "BUY 1  (1:2)";
    if (buttonObjectName == BTN_BUY2)  return "BUY 2  (1:4)";
    if (buttonObjectName == BTN_SELL1) return "SELL 1 (1:2)";
    if (buttonObjectName == BTN_SELL2) return "SELL 2 (1:4)";
    return "";
}

color TradeButtonOriginalColor(const string buttonObjectName)
{
    if (buttonObjectName == BTN_BUY1)  return clrSeaGreen;
    if (buttonObjectName == BTN_BUY2)  return clrForestGreen;
    if (buttonObjectName == BTN_SELL1) return clrFireBrick;
    return clrCrimson;
}

int FindPendingRequest(const string buttonObjectName)
{
    for (int i = 0; i < ArraySize(g_pendingRequests); i++)
        if (g_pendingRequests[i].isActive && g_pendingRequests[i].buttonObjectName == buttonObjectName)
            return i;
    return -1;
}

bool IsTradeButtonArmed(const string buttonObjectName)
{
    return (FindPendingRequest(buttonObjectName) >= 0);
}

void UpdateTradeButtonAppearance(const string buttonObjectName)
{
    bool isArmed = IsTradeButtonArmed(buttonObjectName);
    ObjectSetString(0, buttonObjectName, OBJPROP_TEXT,
        isArmed ? "Cancel Order" : TradeButtonOriginalText(buttonObjectName));
    ObjectSetInteger(0, buttonObjectName, OBJPROP_BGCOLOR,
        isArmed ? C'210,140,25' : TradeButtonOriginalColor(buttonObjectName));
    ObjectSetInteger(0, buttonObjectName, OBJPROP_BORDER_COLOR,
        isArmed ? clrYellow : clrBlack);
    ObjectSetInteger(0, buttonObjectName, OBJPROP_STATE, false);
}

void RestoreTradeButton(const string buttonObjectName)
{
    // This deliberately does not inspect the pending array: during candle
    // processing the request is cleared only after its button is restored.
    ObjectSetString(0, buttonObjectName, OBJPROP_TEXT, TradeButtonOriginalText(buttonObjectName));
    ObjectSetInteger(0, buttonObjectName, OBJPROP_BGCOLOR, TradeButtonOriginalColor(buttonObjectName));
    ObjectSetInteger(0, buttonObjectName, OBJPROP_BORDER_COLOR, clrBlack);
    ObjectSetInteger(0, buttonObjectName, OBJPROP_STATE, false);
}

void CancelPendingRequest(const string buttonObjectName)
{
    int requestIndex = FindPendingRequest(buttonObjectName);
    if (requestIndex < 0)
        return;

    int lastIndex = ArraySize(g_pendingRequests) - 1;
    if (requestIndex != lastIndex)
        g_pendingRequests[requestIndex] = g_pendingRequests[lastIndex];
    ArrayResize(g_pendingRequests, lastIndex);

    RestoreTradeButton(buttonObjectName);
    Print("Pending order cancelled for ", buttonObjectName, ".");
    ChartRedraw();
}

void CancelAllPendingRequests()
{
    for (int i = 0; i < ArraySize(g_pendingRequests); i++)
        RestoreTradeButton(g_pendingRequests[i].buttonObjectName);

    ArrayResize(g_pendingRequests, 0);
    ChartRedraw();
}

void BuildPanel()
{
    int panelBaseX = InpPanelXOffset;
    int panelBaseY = InpPanelYOffset;

    // 5 rows: Mode, Buy1, Buy2, Sell1, Sell2
    int panelExpandedHeight = InpTitleBarHeightPixels + InpPanelInnerPadding + (5 * InpButtonHeightPixels) + (4 * InpButtonGapPixels) + InpPanelInnerPadding;
    int currentPanelHeight = g_isPanelCollapsed ? InpTitleBarHeightPixels : panelExpandedHeight;

    CreateRect(PNL_BG, panelBaseX, panelBaseY, InpPanelWidthPixels, currentPanelHeight, InpPanelBackgroundColor, clrGray);
    CreateRect(PNL_TITLE, panelBaseX, panelBaseY, InpPanelWidthPixels, InpTitleBarHeightPixels, InpTitleBackgroundColor, clrGray);
    CreateLabel(PNL_LABEL, panelBaseX + InpPanelInnerPadding, panelBaseY + 6, "TRADE PANEL", InpTitleTextColor, 9);

    int toggleButtonSize = InpTitleBarHeightPixels - 8;
    int toggleButtonX = panelBaseX + InpPanelWidthPixels - toggleButtonSize - 4;
    int toggleButtonY = panelBaseY + 4;
    CreateButton(PNL_TOGGLE, toggleButtonX, toggleButtonY, toggleButtonSize, toggleButtonSize,
        g_isPanelCollapsed ? "+" : "-", C'70,70,80', 11);

    int innerContentX = panelBaseX + InpPanelInnerPadding;
    int innerContentWidth = InpPanelWidthPixels - (2 * InpPanelInnerPadding);
    int firstRowY = panelBaseY + InpTitleBarHeightPixels + InpPanelInnerPadding;
    int rowVerticalStep = InpButtonHeightPixels + InpButtonGapPixels;

    CreateButton(BTN_MODE, innerContentX, firstRowY + 0 * rowVerticalStep, innerContentWidth, InpButtonHeightPixels, ExecutionModeText(), ExecutionModeColor(), InpButtonFontSize - 1);
    CreateButton(BTN_BUY1, innerContentX, firstRowY + 1 * rowVerticalStep, innerContentWidth, InpButtonHeightPixels, "BUY 1  (1:2)", clrSeaGreen, InpButtonFontSize);
    CreateButton(BTN_BUY2, innerContentX, firstRowY + 2 * rowVerticalStep, innerContentWidth, InpButtonHeightPixels, "BUY 2  (1:4)", clrForestGreen, InpButtonFontSize);
    CreateButton(BTN_SELL1, innerContentX, firstRowY + 3 * rowVerticalStep, innerContentWidth, InpButtonHeightPixels, "SELL 1 (1:2)", clrFireBrick, InpButtonFontSize);
    CreateButton(BTN_SELL2, innerContentX, firstRowY + 4 * rowVerticalStep, innerContentWidth, InpButtonHeightPixels, "SELL 2 (1:4)", clrCrimson, InpButtonFontSize);

    // Preserve armed-order feedback if the panel is rebuilt after a chart refresh.
    UpdateTradeButtonAppearance(BTN_BUY1);
    UpdateTradeButtonAppearance(BTN_BUY2);
    UpdateTradeButtonAppearance(BTN_SELL1);
    UpdateTradeButtonAppearance(BTN_SELL2);

    SetButtonsVisibility(!g_isPanelCollapsed);
    ChartRedraw();
}

void SetButtonsVisibility(const bool isPanelVisible)
{
    long timeframeVisibilityFlags = isPanelVisible ? OBJ_ALL_PERIODS : 0;
    ObjectSetInteger(0, BTN_MODE, OBJPROP_TIMEFRAMES, timeframeVisibilityFlags);
    ObjectSetInteger(0, BTN_BUY1, OBJPROP_TIMEFRAMES, timeframeVisibilityFlags);
    ObjectSetInteger(0, BTN_BUY2, OBJPROP_TIMEFRAMES, timeframeVisibilityFlags);
    ObjectSetInteger(0, BTN_SELL1, OBJPROP_TIMEFRAMES, timeframeVisibilityFlags);
    ObjectSetInteger(0, BTN_SELL2, OBJPROP_TIMEFRAMES, timeframeVisibilityFlags);
}

void ToggleCollapse()
{
    g_isPanelCollapsed = !g_isPanelCollapsed;
    ObjectSetInteger(0, PNL_TOGGLE, OBJPROP_STATE, false);
    BuildPanel();
}

void ToggleExecutionMode()
{
    // Pending orders belong to Next Candle mode only.  Do not allow an armed
    // request to survive a mode change and execute unexpectedly later.
    if (ArraySize(g_pendingRequests) > 0)
        CancelAllPendingRequests();

    g_executionMode = (g_executionMode == EXEC_INSTANT) ? EXEC_NEXT_CANDLE : EXEC_INSTANT;
    ObjectSetString(0, BTN_MODE, OBJPROP_TEXT, ExecutionModeText());
    ObjectSetInteger(0, BTN_MODE, OBJPROP_BGCOLOR, ExecutionModeColor());
    ObjectSetInteger(0, BTN_MODE, OBJPROP_STATE, false);
    Print("Execution mode changed -> ", ExecutionModeText());
    ChartRedraw();
}

void DeleteAllObjects()
{
    ObjectDelete(0, PNL_BG);
    ObjectDelete(0, PNL_TITLE);
    ObjectDelete(0, PNL_LABEL);
    ObjectDelete(0, PNL_TOGGLE);
    ObjectDelete(0, BTN_MODE);
    ObjectDelete(0, BTN_BUY1);
    ObjectDelete(0, BTN_BUY2);
    ObjectDelete(0, BTN_SELL1);
    ObjectDelete(0, BTN_SELL2);
}

//+==================================================================+
//|                       CHART EVENT HANDLER                        |
//+==================================================================+
void OnChartEvent(const int eventId, const long& longEventParam,
    const double& doubleEventParam, const string& stringEventParam)
{
    if (eventId != CHARTEVENT_OBJECT_CLICK)
        return;

    if (stringEventParam == PNL_TOGGLE)
    {
        ToggleCollapse();
        return;
    }

    if (g_isPanelCollapsed) return;

    if (stringEventParam == BTN_MODE)
    {
        ToggleExecutionMode();
    }
    else if (stringEventParam == BTN_BUY1)
        HandleTradeButtonClick(BTN_BUY1, ORDER_TYPE_BUY, 2.0);
    else if (stringEventParam == BTN_BUY2)
        HandleTradeButtonClick(BTN_BUY2, ORDER_TYPE_BUY, 4.0);
    else if (stringEventParam == BTN_SELL1)
        HandleTradeButtonClick(BTN_SELL1, ORDER_TYPE_SELL, 2.0);
    else if (stringEventParam == BTN_SELL2)
        HandleTradeButtonClick(BTN_SELL2, ORDER_TYPE_SELL, 4.0);
}

void ResetButton(const string buttonObjectName)
{
    ObjectSetInteger(0, buttonObjectName, OBJPROP_STATE, false);
    ChartRedraw();
}

//+------------------------------------------------------------------+
//| Handle an individual trade button click                          |
//+------------------------------------------------------------------+
void HandleTradeButtonClick(const string buttonObjectName,
    const ENUM_ORDER_TYPE tradeDirection,
    const double rewardToRiskMultiple)
{
    // A second click on an armed button cancels only that button's request.
    if (g_executionMode == EXEC_NEXT_CANDLE && IsTradeButtonArmed(buttonObjectName))
    {
        CancelPendingRequest(buttonObjectName);
        return;
    }

    HandleTradeRequest(buttonObjectName, tradeDirection, rewardToRiskMultiple);
    ResetButton(buttonObjectName);
}

//+------------------------------------------------------------------+
//| Route trade request based on selected execution mode             |
//+------------------------------------------------------------------+
void HandleTradeRequest(const string buttonObjectName,
    const ENUM_ORDER_TYPE tradeDirection,
    const double rewardToRiskMultiple)
{
    if (g_executionMode == EXEC_INSTANT)
    {
        ExecuteTrade(tradeDirection, rewardToRiskMultiple);
        return;
    }

    // One request may be armed per trade button.  This guard makes rapid or
    // repeated click events harmless instead of creating duplicate orders.
    if (IsTradeButtonArmed(buttonObjectName))
        return;

    int newIndex = ArraySize(g_pendingRequests);
    ArrayResize(g_pendingRequests, newIndex + 1);
    g_pendingRequests[newIndex].isActive = true;
    g_pendingRequests[newIndex].buttonObjectName = buttonObjectName;
    g_pendingRequests[newIndex].direction = tradeDirection;
    g_pendingRequests[newIndex].rewardToRiskMultiple = rewardToRiskMultiple;

    UpdateTradeButtonAppearance(buttonObjectName);
    ChartRedraw();
    Print("Trade request armed for ", buttonObjectName, " (",
        (tradeDirection == ORDER_TYPE_BUY ? "BUY" : "SELL"),
        " RR 1:", DoubleToString(rewardToRiskMultiple, 0),
        "). Click it again to cancel before the next candle.");
}

//+==================================================================+
//|                    RISK & LOT SIZE CALCULATION                   |
//+==================================================================+
double CalculateLotSize(const double stopLossDistanceInPrice)
{
    if (stopLossDistanceInPrice <= 0.0) return(0.0);

    double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double amountToRiskInCurrency = accountBalance * (InpRiskPercent / 100.0);
    double symbolTickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double symbolTickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    if (symbolTickValue <= 0.0 || symbolTickSize <= 0.0) return(0.0);

    double potentialLossPerLot = (stopLossDistanceInPrice / symbolTickSize) * symbolTickValue;
    if (potentialLossPerLot <= 0.0) return(0.0);

    double calculatedLotSize = amountToRiskInCurrency / potentialLossPerLot;
    return(NormalizeLot(calculatedLotSize));
}

double NormalizeLot(double rawLotSize)
{
    double minimumAllowedLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maximumAllowedLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double brokerLotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    if (brokerLotStep <= 0.0) brokerLotStep = 0.01;

    rawLotSize = MathFloor(rawLotSize / brokerLotStep) * brokerLotStep;
    if (rawLotSize < minimumAllowedLot) rawLotSize = minimumAllowedLot;
    if (rawLotSize > maximumAllowedLot) rawLotSize = maximumAllowedLot;

    int lotDecimalPlaces = (int)MathCeil(-MathLog10(brokerLotStep));
    if (lotDecimalPlaces < 0) lotDecimalPlaces = 0;
    return(NormalizeDouble(rawLotSize, lotDecimalPlaces));
}

//+==================================================================+
//|                      TRADE EXECUTION                             |
//+==================================================================+
bool ExecuteTrade(const ENUM_ORDER_TYPE tradeDirection, const double rewardToRiskMultiple)
{
    if (!symbolInformation.RefreshRates()) return(false);

    double symbolPointValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int    symbolPriceDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    long   brokerStopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    double minimumStopDistance = brokerStopsLevel * symbolPointValue;

    double twoBarsAgoHigh = iHigh(_Symbol, PERIOD_CURRENT, 2);
    double twoBarsAgoLow = iLow(_Symbol, PERIOD_CURRENT, 2);
    if (twoBarsAgoHigh == 0.0 || twoBarsAgoLow == 0.0) return(false);

    double stopLossBufferInPrice = InpStopLossBufferPoints * symbolPointValue;
    double takeProfitBufferInPrice = InpTakeProfitBufferPoints * symbolPointValue;

    double calculatedEntryPrice = 0.0, calculatedStopLossPrice = 0.0, calculatedTakeProfitPrice = 0.0, entryToStopLossDistance = 0.0;

    if (tradeDirection == ORDER_TYPE_BUY)
    {
        calculatedEntryPrice = symbolInformation.Ask();
        calculatedStopLossPrice = twoBarsAgoLow - stopLossBufferInPrice;
        entryToStopLossDistance = calculatedEntryPrice - calculatedStopLossPrice;
        if (entryToStopLossDistance <= 0.0) return(false);
        calculatedTakeProfitPrice = calculatedEntryPrice + (rewardToRiskMultiple * entryToStopLossDistance) - takeProfitBufferInPrice;
    }
    else if (tradeDirection == ORDER_TYPE_SELL)
    {
        calculatedEntryPrice = symbolInformation.Bid();
        calculatedStopLossPrice = twoBarsAgoHigh + stopLossBufferInPrice;
        entryToStopLossDistance = calculatedStopLossPrice - calculatedEntryPrice;
        if (entryToStopLossDistance <= 0.0) return(false);
        calculatedTakeProfitPrice = calculatedEntryPrice - (rewardToRiskMultiple * entryToStopLossDistance) + takeProfitBufferInPrice;
    }

    calculatedEntryPrice = NormalizeDouble(calculatedEntryPrice, symbolPriceDigits);
    calculatedStopLossPrice = NormalizeDouble(calculatedStopLossPrice, symbolPriceDigits);
    calculatedTakeProfitPrice = NormalizeDouble(calculatedTakeProfitPrice, symbolPriceDigits);

    if (minimumStopDistance > 0.0)
    {
        if (MathAbs(calculatedEntryPrice - calculatedStopLossPrice) < minimumStopDistance || MathAbs(calculatedTakeProfitPrice - calculatedEntryPrice) < minimumStopDistance) return(false);
    }

    double finalTradeVolume = CalculateLotSize(entryToStopLossDistance);
    if (finalTradeVolume <= 0.0) return(false);

    double requiredMarginForTrade = 0.0;
    if (OrderCalcMargin(tradeDirection, _Symbol, finalTradeVolume, calculatedEntryPrice, requiredMarginForTrade))
    {
        if (requiredMarginForTrade > AccountInfoDouble(ACCOUNT_MARGIN_FREE)) return(false);
    }

    bool isTradeExecuted = false;
    string tradeComment = (tradeDirection == ORDER_TYPE_BUY ? "BTP_Buy_RR" : "BTP_Sell_RR") + DoubleToString(rewardToRiskMultiple, 0);

    if (tradeDirection == ORDER_TYPE_BUY)
        isTradeExecuted = tradeManager.Buy(finalTradeVolume, _Symbol, calculatedEntryPrice, calculatedStopLossPrice, calculatedTakeProfitPrice, tradeComment);
    else
        isTradeExecuted = tradeManager.Sell(finalTradeVolume, _Symbol, calculatedEntryPrice, calculatedStopLossPrice, calculatedTakeProfitPrice, tradeComment);

    return(isTradeExecuted);
}
//+------------------------------------------------------------------+
