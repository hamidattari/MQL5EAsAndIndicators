//+------------------------------------------------------------------+
//|                                               LiveRR_Monitor.mq5 |
//|            Live Risk-to-Reward Monitor for Open Positions        |
//|                                                                  |
//|  Displays the live R:R ratio of every open position that has a  |
//|  valid Stop Loss, directly on the chart, updating in real time. |
//|                                                                  |
//|  R:R  = (distance from entry to current price)                  |
//|         / (distance from entry to stop loss)                    |
//|                                                                  |
//|  Compatible with MetaTrader 5 Build 5000+                       |
//+------------------------------------------------------------------+
#property copyright   "LiveRR Monitor"
#property version     "1.00"
#property description "Shows live Risk-to-Reward (R:R) ratio for all open positions with a Stop Loss."
#property indicator_chart_window
#property indicator_plots 0

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
enum ENUM_LABEL_SIDE
{
    SIDE_RIGHT = 0,   // Right of price
    SIDE_LEFT = 1,   // Left of price
    SIDE_ABOVE = 2,   // Above price
    SIDE_BELOW = 3    // Below price
};

enum ENUM_UPDATE_MODE
{
    UPDATE_EVERY_TICK = 0,   // Every tick
    UPDATE_TIMER = 1    // Timer interval
};

//+------------------------------------------------------------------+
//| Input parameters                                                 |
//+------------------------------------------------------------------+
input group "=== Scope ==="
input bool              InpCurrentSymbolOnly = true;           // Show positions of chart symbol only
input bool              InpShowNoSL = false;          // Show "No SL" for positions without Stop Loss

input group "=== Font & Style ==="
input string            InpFontName = "Verdana";      // Font name
input int               InpFontSize = 11;             // Font size
input color             InpFontColorPos = clrLime;        // Font color (positive R:R)
input color             InpFontColorNeg = clrOrangeRed;   // Font color (negative R:R)
input color             InpFontColorNoSL = clrGray;        // Font color (No SL)
input bool              InpFontBold = false;           // Bold text

input group "=== Position & Layout ==="
input ENUM_LABEL_SIDE   InpLabelSide = SIDE_BELOW;     // Label position relative to price
input int               InpOffsetXBars = 2;              // X offset (bars from current bar)
input int               InpOffsetYPoints = 60;             // Y offset (points from price)
input int               InpStackGapPoints = 60;             // Vertical gap between stacked labels (points)

input group "=== Background ==="
input bool              InpShowBackground = true;           // Enable background panel
input color             InpBackgroundColor = C'20,20,30';    // Background color
input color             InpBorderColor = clrDimGray;     // Background border color

input group "=== Extra Information ==="
input bool              InpShowSymbol = false;           // Show symbol
input bool              InpShowDirection = false;           // Show Buy/Sell
input bool              InpShowLots = false;           // Show lot size
input bool              InpShowMagic = false;          // Show magic number
input bool              InpShowTicket = false;          // Show ticket number
input bool              InpShowProfitCcy = false;           // Show profit (currency)
input bool              InpShowProfitPips = false;           // Show profit (pips)

input group "=== Refresh ==="
input ENUM_UPDATE_MODE  InpUpdateMode = UPDATE_EVERY_TICK; // Update mode
input int               InpTimerMillis = 500;            // Timer interval (ms), if timer mode

//+------------------------------------------------------------------+
//| Constants                                                        |
//+------------------------------------------------------------------+
#define OBJ_PREFIX "LiveRR_"    // Prefix for all chart objects created here

//+------------------------------------------------------------------+
//| Structure describing one displayed label                        |
//+------------------------------------------------------------------+
struct SLabelInfo
{
    ulong             ticket;      // position ticket
    string            text_name;   // text object name
    string            bg_name;     // background object name
    bool              used;        // touched during current refresh
};

SLabelInfo g_labels[];            // registry of managed labels

//+------------------------------------------------------------------+
//| Custom indicator initialization                                  |
//+------------------------------------------------------------------+
int OnInit()
{
    // Timer is used either as the main refresh driver (timer mode) or as
    // a safety net so labels update even when the chart symbol has no ticks.
    int millis = (InpUpdateMode == UPDATE_TIMER) ? MathMax(100, InpTimerMillis) : 1000;
    EventSetMillisecondTimer(millis);

    RefreshLabels();
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Custom indicator deinitialization                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    EventKillTimer();
    DeleteAllObjects();
    ChartRedraw();
}

//+------------------------------------------------------------------+
//| Tick-driven refresh                                              |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
    const int prev_calculated,
    const datetime& time[],
    const double& open[],
    const double& high[],
    const double& low[],
    const double& close[],
    const long& tick_volume[],
    const long& volume[],
    const int& spread[])
{
    if (InpUpdateMode == UPDATE_EVERY_TICK)
        RefreshLabels();
    return(rates_total);
}

//+------------------------------------------------------------------+
//| Timer-driven refresh                                             |
//+------------------------------------------------------------------+
void OnTimer()
{
    RefreshLabels();
}

//+------------------------------------------------------------------+
//| Main refresh routine: sync labels with open positions            |
//+------------------------------------------------------------------+
void RefreshLabels()
{
    // Mark all existing labels as unused; anything still unused at the
    // end belongs to a closed position and will be deleted.
    for (int i = 0; i < ArraySize(g_labels); i++)
        g_labels[i].used = false;

    const string chart_symbol = _Symbol;
    int stack_index = 0; // for vertical stacking to reduce overlap

    int total = PositionsTotal();
    for (int i = 0; i < total; i++)
    {
        ulong ticket = PositionGetTicket(i);
        if (ticket == 0 || !PositionSelectByTicket(ticket))
            continue;

        string pos_symbol = PositionGetString(POSITION_SYMBOL);
        if (InpCurrentSymbolOnly && pos_symbol != chart_symbol)
            continue;
        // Labels are drawn in chart (time/price) coordinates, so positions on
        // other symbols can only be shown meaningfully on their own chart.
        if (!InpCurrentSymbolOnly && pos_symbol != chart_symbol)
            continue;

        double entry = PositionGetDouble(POSITION_PRICE_OPEN);
        double sl = PositionGetDouble(POSITION_SL);
        double current = PositionGetDouble(POSITION_PRICE_CURRENT);
        long   type = PositionGetInteger(POSITION_TYPE);

        bool has_sl = (sl > 0.0);

        // --- Compute live R:R -----------------------------------------
        double rr = 0.0;
        bool rr_valid = false;
        if (has_sl)
        {
            double risk, reward;
            if (type == POSITION_TYPE_BUY)
            {
                risk = entry - sl;      // positive when SL below entry
                reward = current - entry;
            }
            else
            {
                risk = sl - entry;      // positive when SL above entry
                reward = entry - current;
            }
            if (risk > 0.0)
            {
                rr = reward / risk;
                rr_valid = true;
            }
        }

        if (!has_sl && !InpShowNoSL)
            continue;

        // --- Build label text -----------------------------------------
        string text = BuildLabelText(pos_symbol, ticket, type, rr, rr_valid);

        // --- Choose color ----------------------------------------------
        color clr;
        if (!rr_valid)              clr = InpFontColorNoSL;
        else if (rr >= 0.0)         clr = InpFontColorPos;
        else                       clr = InpFontColorNeg;

        // --- Compute anchor coordinates --------------------------------
        datetime anchor_time;
        double   anchor_price;
        ComputeAnchor(current, stack_index, anchor_time, anchor_price);
        stack_index++;

        // --- Create/update objects -------------------------------------
        UpsertLabel(ticket, text, clr, anchor_time, anchor_price);
    }

    // Remove labels for positions that no longer exist
    PurgeUnused();
    ChartRedraw();
}

//+------------------------------------------------------------------+
//| Build the multi-line label text for one position                 |
//+------------------------------------------------------------------+
string BuildLabelText(const string symbol, const ulong ticket,
    const long type, const double rr, const bool rr_valid)
{
    string line1 = "";
    if (InpShowSymbol)
        line1 += symbol;
    if (InpShowDirection)
        line1 += (line1 == "" ? "" : " ") + string(type == POSITION_TYPE_BUY ? "BUY" : "SELL");
    if (InpShowLots)
        line1 += (line1 == "" ? "" : " ") + DoubleToString(PositionGetDouble(POSITION_VOLUME), 2);

    string line2 = rr_valid ? StringFormat("RR: %.2fR", rr) : "RR: No SL";

    string extras = "";
    if (InpShowProfitPips)
    {
        double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
        int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
        double pip = (digits == 3 || digits == 5) ? point * 10.0 : point;
        double entry = PositionGetDouble(POSITION_PRICE_OPEN);
        double current = PositionGetDouble(POSITION_PRICE_CURRENT);
        double pips = (type == POSITION_TYPE_BUY ? current - entry : entry - current) / pip;
        extras += StringFormat("Profit: %+.1f pips", pips);
    }
    if (InpShowProfitCcy)
    {
        double profit = PositionGetDouble(POSITION_PROFIT)
            + PositionGetDouble(POSITION_SWAP);
        string ccy = AccountInfoString(ACCOUNT_CURRENCY);
        extras += (extras == "" ? "" : "  ")
            + StringFormat("(%+.2f %s)", profit, ccy);
    }

    string meta = "";
    if (InpShowMagic)
        meta += StringFormat("Magic: %I64d", PositionGetInteger(POSITION_MAGIC));
    if (InpShowTicket)
        meta += (meta == "" ? "" : "  ") + StringFormat("#%I64u", ticket);

    // Assemble non-empty lines
    string text = "";
    if (line1 != "") text += line1 + "\n";
    text += line2;
    if (extras != "") text += "\n" + extras;
    if (meta != "") text += "\n" + meta;
    return(text);
}

//+------------------------------------------------------------------+
//| Compute time/price anchor for a label, with stacking             |
//+------------------------------------------------------------------+
void ComputeAnchor(const double price, const int stack_index,
    datetime& out_time, double& out_price)
{
    datetime bar_time = iTime(_Symbol, _Period, 0);
    int period_sec = PeriodSeconds(_Period);

    int x_bars = MathMax(1, InpOffsetXBars);
    double y_off = InpOffsetYPoints * _Point;

    switch (InpLabelSide)
    {
    case SIDE_RIGHT:
        out_time = bar_time + (datetime)(x_bars * period_sec);
        out_price = price + y_off;
        break;
    case SIDE_LEFT:
        out_time = bar_time - (datetime)(x_bars * period_sec);
        out_price = price + y_off;
        break;
    case SIDE_ABOVE:
        out_time = bar_time + (datetime)(x_bars * period_sec);
        out_price = price + MathAbs(y_off) + _Point;
        break;
    case SIDE_BELOW:
    default:
        out_time = bar_time + (datetime)(x_bars * period_sec);
        out_price = price - MathAbs(y_off) - _Point;
        break;
    }

    // Stack subsequent labels vertically so they do not overlap
    out_price += stack_index * InpStackGapPoints * _Point;
}

//+------------------------------------------------------------------+
//| Create or update the label objects for one ticket                |
//+------------------------------------------------------------------+
void UpsertLabel(const ulong ticket, const string text, const color clr,
    const datetime time, const double price)
{
    int idx = FindLabel(ticket);
    if (idx < 0)
    {
        // Register a new label entry
        idx = ArraySize(g_labels);
        ArrayResize(g_labels, idx + 1);
        g_labels[idx].ticket = ticket;
        g_labels[idx].text_name = OBJ_PREFIX + "TXT_" + (string)ticket;
        g_labels[idx].bg_name = OBJ_PREFIX + "BG_" + (string)ticket;
    }
    g_labels[idx].used = true;

    const string tname = g_labels[idx].text_name;
    const string bname = g_labels[idx].bg_name;

    // --- Background (rectangle behind text) ---------------------------
    if (InpShowBackground)
    {
        if (ObjectFind(0, bname) < 0)
        {
            ObjectCreate(0, bname, OBJ_RECTANGLE, 0, 0, 0, 0, 0);
            ObjectSetInteger(0, bname, OBJPROP_BACK, true);
            ObjectSetInteger(0, bname, OBJPROP_FILL, true);
            ObjectSetInteger(0, bname, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, bname, OBJPROP_HIDDEN, true);
        }
        // Size the rectangle roughly around the text block
        int lines = 1;
        for (int c = 0; c < StringLen(text); c++)
            if (StringGetCharacter(text, c) == '\n') lines++;
        double h = lines * (InpFontSize + 6) * PixelToPrice();
        int period_sec = PeriodSeconds(_Period);
        int width_bars = MathMax(4, StringLen(text) / MathMax(1, lines) / 2);

        ObjectSetInteger(0, bname, OBJPROP_TIME, 0, time - (datetime)(period_sec));
        ObjectSetDouble(0, bname, OBJPROP_PRICE, 0, price + h * 0.5);
        ObjectSetInteger(0, bname, OBJPROP_TIME, 1, time + (datetime)(width_bars * period_sec));
        ObjectSetDouble(0, bname, OBJPROP_PRICE, 1, price - h * 0.5);
        ObjectSetInteger(0, bname, OBJPROP_COLOR, InpBackgroundColor);
    }
    else if (ObjectFind(0, bname) >= 0)
        ObjectDelete(0, bname);

    // --- Text ----------------------------------------------------------
    if (ObjectFind(0, tname) < 0)
    {
        ObjectCreate(0, tname, OBJ_TEXT, 0, time, price);
        ObjectSetInteger(0, tname, OBJPROP_SELECTABLE, false);
        ObjectSetInteger(0, tname, OBJPROP_HIDDEN, true);
        ObjectSetInteger(0, tname, OBJPROP_BACK, false);
        ObjectSetInteger(0, tname, OBJPROP_ANCHOR,
            InpLabelSide == SIDE_LEFT ? ANCHOR_RIGHT : ANCHOR_LEFT);
    }
    // Update only changed properties (avoids flicker: objects are moved,
    // never deleted and re-created, while the position stays open).
    ObjectSetInteger(0, tname, OBJPROP_TIME, 0, time);
    ObjectSetDouble(0, tname, OBJPROP_PRICE, 0, price);
    ObjectSetString(0, tname, OBJPROP_TEXT, text);
    ObjectSetString(0, tname, OBJPROP_FONT,
        InpFontBold ? InpFontName + " Bold" : InpFontName);
    ObjectSetInteger(0, tname, OBJPROP_FONTSIZE, InpFontSize);
    ObjectSetInteger(0, tname, OBJPROP_COLOR, clr);
}

//+------------------------------------------------------------------+
//| Approximate price-per-pixel on the current chart                 |
//+------------------------------------------------------------------+
double PixelToPrice()
{
    double max = ChartGetDouble(0, CHART_PRICE_MAX);
    double min = ChartGetDouble(0, CHART_PRICE_MIN);
    long   px = ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
    if (px <= 0 || max <= min)
        return(_Point);
    return((max - min) / (double)px);
}

//+------------------------------------------------------------------+
//| Find label registry index by ticket, -1 if not found             |
//+------------------------------------------------------------------+
int FindLabel(const ulong ticket)
{
    for (int i = 0; i < ArraySize(g_labels); i++)
        if (g_labels[i].ticket == ticket)
            return(i);
    return(-1);
}

//+------------------------------------------------------------------+
//| Delete objects of labels not touched in the last refresh         |
//+------------------------------------------------------------------+
void PurgeUnused()
{
    for (int i = ArraySize(g_labels) - 1; i >= 0; i--)
    {
        if (g_labels[i].used)
            continue;
        ObjectDelete(0, g_labels[i].text_name);
        ObjectDelete(0, g_labels[i].bg_name);
        // Remove entry from registry
        for (int j = i; j < ArraySize(g_labels) - 1; j++)
            g_labels[j] = g_labels[j + 1];
        ArrayResize(g_labels, ArraySize(g_labels) - 1);
    }
}

//+------------------------------------------------------------------+
//| Delete every object created by this indicator                    |
//+------------------------------------------------------------------+
void DeleteAllObjects()
{
    ObjectsDeleteAll(0, OBJ_PREFIX);
    ArrayFree(g_labels);
}
//+------------------------------------------------------------------+
