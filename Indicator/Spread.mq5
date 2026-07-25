//+------------------------------------------------------------------+
//|                    Spread Display MT5                            |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property strict

input color   TextColor  = clrLime;
input string  FontName   = "Consolas";

// محل نمایش
// CORNER_LEFT_UPPER = 0
// CORNER_RIGHT_UPPER = 1
// CORNER_LEFT_LOWER = 2
// CORNER_RIGHT_LOWER = 3
input ENUM_BASE_CORNER Corner = CORNER_LEFT_UPPER;

input int FontSize   = 15;
input int X_Distance = 20;
input int Y_Distance = 20;

string LabelName = "SpreadDisplay";

//+------------------------------------------------------------------+
int OnInit()
{
   ObjectCreate(0, LabelName, OBJ_LABEL, 0, 0, 0);

   ObjectSetInteger(0, LabelName, OBJPROP_CORNER, Corner);
   ObjectSetInteger(0, LabelName, OBJPROP_XDISTANCE, X_Distance);
   ObjectSetInteger(0, LabelName, OBJPROP_YDISTANCE, Y_Distance);

   ObjectSetInteger(0, LabelName, OBJPROP_COLOR, TextColor);
   ObjectSetInteger(0, LabelName, OBJPROP_FONTSIZE, FontSize);
   ObjectSetString(0, LabelName, OBJPROP_FONT, FontName);

   return(INIT_SUCCEEDED);
}
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectDelete(0, LabelName);
}
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
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double spread_points = (ask - bid) / _Point;

   string txt = StringFormat("Spread: %02.0f", spread_points);

   ObjectSetString(0, LabelName, OBJPROP_TEXT, txt);

   ObjectSetInteger(0, LabelName, OBJPROP_COLOR, TextColor);
   ObjectSetInteger(0, LabelName, OBJPROP_FONTSIZE, FontSize);
   ObjectSetString(0, LabelName, OBJPROP_FONT, FontName);
   
   return(rates_total);
}
//+------------------------------------------------------------------+