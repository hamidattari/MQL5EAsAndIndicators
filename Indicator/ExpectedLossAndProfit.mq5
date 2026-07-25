//+------------------------------------------------------------------+
//|                                                      ProjectName |
//|                                      Copyright 2020, CompanyName |
//|                                       http://www.companyname.net |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property strict

input string comment_filter = ""; // Filter by comment, empty = all
input int corner = 0;
input int x_distance = 10;
input int y_distance = 20;
input color profit_color = clrLime;
input color loss_color = clrRed;
input int font_size = 14;

double expectedProfit = 0;
double expectedLoss = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   EventSetTimer(5);
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectDelete(0, "PendingProfitLabel");
   ObjectDelete(0, "PendingLossLabel");
  }
//+------------------------------------------------------------------+
void OnTimer()
  {
   CalculatePendingExpected();
   DrawLabels();
  }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void CalculatePendingExpected()
  {
   expectedProfit = 0;
   expectedLoss = 0;
   int total = OrdersTotal();

   for(int i = 0; i < total; i++)
     {
      if(OrderGetTicket(i))
        {
         if(OrderGetInteger(ORDER_TYPE) >= ORDER_TYPE_BUY_LIMIT &&
            OrderGetInteger(ORDER_TYPE) <= ORDER_TYPE_SELL_STOP)
           {
            string symbol = OrderGetString(ORDER_SYMBOL);
            if(symbol != _Symbol)
               continue;

            string comment = OrderGetString(ORDER_COMMENT);
            if(comment_filter != "" && comment != comment_filter)
               continue;

            double volume = OrderGetDouble(ORDER_VOLUME_CURRENT);
            double price_open = OrderGetDouble(ORDER_PRICE_OPEN);
            double sl = OrderGetDouble(ORDER_SL);
            double tp = OrderGetDouble(ORDER_TP);
            double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
            double tick_size  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
            int type = (int)OrderGetInteger(ORDER_TYPE);

            if(sl > 0)
              {
               double sl_diff = (type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP) ?
                                (price_open - sl) : (sl - price_open);
               expectedLoss += (sl_diff / tick_size) * tick_value * volume;
              }

            if(tp > 0)
              {
               double tp_diff = (type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP) ?
                                (tp - price_open) : (price_open - tp);
               expectedProfit += (tp_diff / tick_size) * tick_value * volume;
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
void DrawLabels()
  {
   string profit_text = "Expected Profit: " + DoubleToString(expectedProfit, 2) + " USD";
   string loss_text   = "Expected Loss: " + DoubleToString(expectedLoss, 2) + " USD";

// Profit Label
   if(ObjectFind(0, "PendingProfitLabel") != -1)
      ObjectDelete(0, "PendingProfitLabel");

   ObjectCreate(0, "PendingProfitLabel", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, "PendingProfitLabel", OBJPROP_CORNER, corner);
   ObjectSetInteger(0, "PendingProfitLabel", OBJPROP_XDISTANCE, x_distance);
   ObjectSetInteger(0, "PendingProfitLabel", OBJPROP_YDISTANCE, y_distance);
   ObjectSetInteger(0, "PendingProfitLabel", OBJPROP_COLOR, profit_color);
   ObjectSetInteger(0, "PendingProfitLabel", OBJPROP_FONTSIZE, font_size);
   ObjectSetString(0, "PendingProfitLabel", OBJPROP_TEXT, profit_text);

// Loss Label
   if(ObjectFind(0, "PendingLossLabel") != -1)
      ObjectDelete(0, "PendingLossLabel");

   ObjectCreate(0, "PendingLossLabel", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, "PendingLossLabel", OBJPROP_CORNER, corner);
   ObjectSetInteger(0, "PendingLossLabel", OBJPROP_XDISTANCE, x_distance);
   ObjectSetInteger(0, "PendingLossLabel", OBJPROP_YDISTANCE, y_distance + 25);
   ObjectSetInteger(0, "PendingLossLabel", OBJPROP_COLOR, loss_color);
   ObjectSetInteger(0, "PendingLossLabel", OBJPROP_FONTSIZE, font_size);
   ObjectSetString(0, "PendingLossLabel", OBJPROP_TEXT, loss_text);
  }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Custom indicator iteration function                              |
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
//--- return value of prev_calculated for next call
   return(rates_total);
  }
//+------------------------------------------------------------------+
