//+------------------------------------------------------------------+
//| Indicator to display expected profit/loss based on TP and SL   |
//+------------------------------------------------------------------+
#property strict
#property indicator_chart_window

input int LossDistanceX = 10;
input int LossDistanceY = 150;
input int ProfitDistanceX = 10;
input int ProfitDistanceY = 125;

input int FontSize   = 15;

input color ProfitColor = clrLime;
input color LossColor   = clrRed;

// Function to calculate expected profit and loss separately
void CalculateExpectedProfitLoss(double &expectedProfit, double &expectedLoss)
  {
   expectedProfit = 0;
   expectedLoss = 0;
   int totalPositions = PositionsTotal();

   for(int i = 0; i < totalPositions; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
        {
         string symbol = PositionGetString(POSITION_SYMBOL);
         
         if(symbol == _Symbol)
           {
            double volume = PositionGetDouble(POSITION_VOLUME);
            double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double stopLoss = PositionGetDouble(POSITION_SL);
            double takeProfit = PositionGetDouble(POSITION_TP);
            
            double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
            double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);

            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            double profitValue = 0;
            double lossValue   = 0;

            if(type == POSITION_TYPE_BUY)
              {
               if(takeProfit > 0)
                  profitValue = ((takeProfit - entryPrice) / tickSize) * tickValue * volume;
               if(stopLoss > 0)
                  lossValue = ((stopLoss - entryPrice) / tickSize) * tickValue * volume;
              }
            else if(type == POSITION_TYPE_SELL)
              {
               if(takeProfit > 0)
                  profitValue = ((entryPrice - takeProfit) / tickSize) * tickValue * volume;
               if(stopLoss > 0)
                  lossValue = ((entryPrice - stopLoss) / tickSize) * tickValue * volume;
              }

            expectedProfit += profitValue;
            expectedLoss   += lossValue;
           }
        }
     }
  }

// Function to create or update label
void UpdateLabel()
  {
   double expectedProfit, expectedLoss;
   CalculateExpectedProfitLoss(expectedProfit, expectedLoss);

   string profitText = "Expected Profit: " + (expectedProfit <= 0 ? "-" : "+") + DoubleToString(expectedProfit, 2);
   string lossText   = "Expected Loss:   " + (expectedLoss >= 0 ? "+" : "") + DoubleToString(expectedLoss, 2);

   ObjectSetInteger(0, "ProfitLabel", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, "ProfitLabel", OBJPROP_XDISTANCE, ProfitDistanceX);
   ObjectSetInteger(0, "ProfitLabel", OBJPROP_YDISTANCE, ProfitDistanceY);
   ObjectSetString(0, "ProfitLabel", OBJPROP_TEXT, profitText);
   ObjectSetInteger(0, "ProfitLabel", OBJPROP_COLOR, ProfitColor);
   ObjectSetInteger(0, "ProfitLabel", OBJPROP_FONTSIZE, FontSize);
   ObjectSetString(0, "ProfitLabel", OBJPROP_FONT, "Consolas");

   ObjectSetInteger(0, "LossLabel", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, "LossLabel", OBJPROP_XDISTANCE, LossDistanceX);
   ObjectSetInteger(0, "LossLabel", OBJPROP_YDISTANCE, LossDistanceY);
   ObjectSetString(0, "LossLabel", OBJPROP_TEXT, lossText);
   ObjectSetInteger(0, "LossLabel", OBJPROP_COLOR, LossColor);
   ObjectSetInteger(0, "LossLabel", OBJPROP_FONTSIZE, FontSize);
   ObjectSetString(0, "LossLabel", OBJPROP_FONT, "Consolas");
  }

int OnInit()
  {
   string currentBroker = AccountInfoString(ACCOUNT_SERVER);
   long currentAccount = AccountInfoInteger(ACCOUNT_LOGIN);
   Print("Broker:" + currentBroker + ", Account: " + currentAccount);

   ObjectCreate(0, "ProfitLabel", OBJ_LABEL, 0, 0, 0);
   ObjectCreate(0, "LossLabel", OBJ_LABEL, 0, 0, 0);

   UpdateLabel();
   EventSetTimer(5);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectDelete(0, "ProfitLabel");
   ObjectDelete(0, "LossLabel");
  }

void OnTimer()
  {
   UpdateLabel();
  }

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
   UpdateLabel();
   return(rates_total);
  }