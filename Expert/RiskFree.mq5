//+------------------------------------------------------------------+
//|                                                     RiskFreeEA.mq5 |
//|                                      Created by Grok, xAI         |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Grok, xAI"
#property link      "https://x.ai"
#property version   "1.14"

//--- Input Parameters
input color InpLineColor = clrYellow;         // Color of Risk-Free Line
input ENUM_LINE_STYLE InpLineStyle = STYLE_DOT; // Style of Risk-Free Line
input int InpLineWidth = 1;                   // Width of Risk-Free Line
input bool InpShowPipPercent = true;          // Show Pip, Percent, and RR on Line
input bool CloseHalfPositionOnRiskFree = false; // Close half Position On Riskfree
// Structure to track line info
struct LineInfo
  {
   ulong             ticket;
   double            lastPrice;
   bool              isSelected;
   bool              isManuallyMoved; // Flag to track manual movement
  };

// Array to store line information
LineInfo lineInfoArray[];

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
  {
// Enable chart event handling
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);
   ChartSetInteger(0, CHART_EVENT_OBJECT_CREATE, true);
   ArrayResize(lineInfoArray, 0);
   Print("EA initialized, version 1.14");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
  {
// First check line status to update manually moved prices
   CheckLineStatus();

// Process all open positions
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
        {
         ProcessPosition(ticket);
        }
     }

// Process all pending orders
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
        {
         ProcessPendingOrder(ticket);
        }
     }

// Clean up objects for closed positions or canceled orders
   CleanUpObjects();
  }

//+------------------------------------------------------------------+
//| Process open position                                             |
//+------------------------------------------------------------------+
void ProcessPosition(ulong ticket)
  {
   double sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
   string symbol = PositionGetString(POSITION_SYMBOL);
   long posType = PositionGetInteger(POSITION_TYPE);

// Check if SL and TP are set
   if(sl == 0 || tp == 0)
     {
      Print("Position ", ticket, ": SL or TP not set, skipping");
      return;
     }

// Calculate RR
   double rr = CalculateRR(openPrice, sl, tp, posType);
   if(rr < 2)
     {
      Print("Position ", ticket, ": RR=", rr, " < 2, skipping");
      return; // Only process if RR >= 2
     }

// Calculate Risk-Free level
   double riskFreePercent = GetRiskFreePercent(rr);
   double riskFreePrice = CalculateRiskFreePrice(openPrice, tp, riskFreePercent, posType);

// Check if line was manually moved
   int index = -1;
   for(int i = 0; i < ArraySize(lineInfoArray); i++)
     {
      if(lineInfoArray[i].ticket == ticket)
        {
         index = i;
         break;
        }
     }
   if(index >= 0 && lineInfoArray[index].isManuallyMoved)
     {
      riskFreePrice = lineInfoArray[index].lastPrice;
      Print("Position ", ticket, ": Using manually moved price: ", riskFreePrice);
      // Recalculate percent based on manually moved price
      double distanceToTP = MathAbs(tp - openPrice);
      double distanceToRF = MathAbs(riskFreePrice - openPrice);
      riskFreePercent = (distanceToTP > 0) ? distanceToRF / distanceToTP : 0;
     }

// Draw risk-free line for open position
   Print("Position ", ticket, ": Drawing line at price: ", riskFreePrice, ", Percent: ", riskFreePercent);
   DrawRiskFreeLine(ticket, symbol, riskFreePrice, riskFreePercent, rr);

// Check if price has reached the risk-free level
   bool isRiskFreeTriggered = (posType == POSITION_TYPE_BUY && currentPrice >= riskFreePrice) ||
                              (posType == POSITION_TYPE_SELL && currentPrice <= riskFreePrice);
   if(isRiskFreeTriggered)
     {
      Print("Position ", ticket, ": Risk-free triggered at price: ", riskFreePrice);
      // Move SL to breakeven (open price)
      MoveSLToBreakeven(ticket, openPrice, symbol);

      if(CloseHalfPositionOnRiskFree)
        {
         // Close half of the position
         CloseHalfPosition(ticket, symbol);
        }
     }
  }

//+------------------------------------------------------------------+
//| Process pending order                                             |
//+------------------------------------------------------------------+
void ProcessPendingOrder(ulong ticket)
  {
   double sl = OrderGetDouble(ORDER_SL);
   double tp = OrderGetDouble(ORDER_TP);
   double openPrice = OrderGetDouble(ORDER_PRICE_OPEN);
   string symbol = OrderGetString(ORDER_SYMBOL);
   long orderType = OrderGetInteger(ORDER_TYPE);

// Check if SL and TP are set
   if(sl == 0 || tp == 0)
     {
      Print("Order ", ticket, ": SL or TP not set, skipping");
      return;
     }

// Determine position type for RR calculation
   long posType = (orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_BUY_STOP) ?
                  POSITION_TYPE_BUY : POSITION_TYPE_SELL;

// Calculate RR
   double rr = CalculateRR(openPrice, sl, tp, posType);
   if(rr < 2)
     {
      Print("Order ", ticket, ": RR=", rr, " < 2, skipping");
      return; // Only process if RR >= 2
     }

// Calculate Risk-Free level
   double riskFreePercent = GetRiskFreePercent(rr);
   double riskFreePrice = CalculateRiskFreePrice(openPrice, tp, riskFreePercent, posType);

// Check if line was manually moved
   int index = -1;
   for(int i = 0; i < ArraySize(lineInfoArray); i++)
     {
      if(lineInfoArray[i].ticket == ticket)
        {
         index = i;
         break;
        }
     }
   if(index >= 0 && lineInfoArray[index].isManuallyMoved)
     {
      riskFreePrice = lineInfoArray[index].lastPrice;
      Print("Order ", ticket, ": Using manually moved price: ", riskFreePrice);
      // Recalculate percent based on manually moved price
      double distanceToTP = MathAbs(tp - openPrice);
      double distanceToRF = MathAbs(riskFreePrice - openPrice);
      riskFreePercent = (distanceToTP > 0) ? distanceToRF / distanceToTP : 0;
     }

// Draw risk-free line for pending order
   Print("Order ", ticket, ": Drawing line at price: ", riskFreePrice, ", Percent: ", riskFreePercent);
   DrawRiskFreeLine(ticket, symbol, riskFreePrice, riskFreePercent, rr);
  }

//+------------------------------------------------------------------+
//| Calculate Risk-to-Reward Ratio                                    |
//+------------------------------------------------------------------+
double CalculateRR(double openPrice, double sl, double tp, long posType)
  {
   double risk = MathAbs(openPrice - sl);
   double reward = MathAbs(tp - openPrice);
   if(risk == 0)
     {
      Print("CalculateRR: Risk is zero, returning 0");
      return 0;
     }
   return reward / risk;
  }

//+------------------------------------------------------------------+
//| Get Risk-Free Percentage based on RR                              |
//+------------------------------------------------------------------+
double GetRiskFreePercent(double rr)
  {
   if(rr >= 4)
      return 0.75;  // 75% for RR >= 4
   if(rr >= 3)
      return 0.66;  // 66% for RR >= 3
   return 0.50;              // 50% for RR >= 2
  }

//+------------------------------------------------------------------+
//| Calculate Risk-Free Price                                         |
//+------------------------------------------------------------------+
double CalculateRiskFreePrice(double openPrice, double tp, double percent, long posType)
  {
   double distance = MathAbs(tp - openPrice) * percent;
   return (posType == POSITION_TYPE_BUY) ? openPrice + distance : openPrice - distance;
  }

//+------------------------------------------------------------------+
//| Move Stop Loss to Breakeven                                       |
//+------------------------------------------------------------------+
void MoveSLToBreakeven(ulong ticket, double breakevenPrice, string symbol)
  {
   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.symbol = symbol;
   request.sl = breakevenPrice;
   request.tp = PositionGetDouble(POSITION_TP);

   if(!OrderSend(request, result))
     {
      Print("Failed to move SL to breakeven for ticket ", ticket, ". Error: ", GetLastError());
     }
   else
     {
      Print("Moved SL to breakeven for ticket ", ticket, " at price: ", breakevenPrice);
     }
  }

//+------------------------------------------------------------------+
//| Close Half of the Position                                        |
//+------------------------------------------------------------------+
void CloseHalfPosition(ulong ticket, string symbol)
  {
   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);

   double totalVolume = PositionGetDouble(POSITION_VOLUME);
   double minVolume = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double volumeStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double halfVolume = totalVolume / 2;

// Round volume to nearest valid step
   halfVolume = MathMax(minVolume, MathRound(halfVolume / volumeStep) * volumeStep);
   if(halfVolume <= 0 || halfVolume > totalVolume)
     {
      Print("CloseHalfPosition for ticket ", ticket, ": Invalid volume ", halfVolume, ", Total: ", totalVolume, ", Min: ", minVolume);
      return;
     }

   request.action = TRADE_ACTION_DEAL;
   request.position = ticket;
   request.symbol = symbol;
   request.volume = halfVolume;
   request.type = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   request.price = SymbolInfoDouble(symbol, SYMBOL_BID);
   request.type_filling = ORDER_FILLING_FOK; // Changed to FOK for stricter execution

   Print("Attempting to close half position for ticket ", ticket, ": Volume=", halfVolume, ", Type=", request.type, ", Price=", request.price);
   if(!OrderSend(request, result))
     {
      Print("Failed to close half position for ticket ", ticket, ". Error: ", GetLastError(), ", Result Code: ", result.retcode);
     }
   else
     {
      Print("Closed half position for ticket ", ticket, ", Volume: ", halfVolume, ", Deal: ", result.deal);
     }
  }

//+------------------------------------------------------------------+
//| Draw Risk-Free Line on Chart                                      |
//+------------------------------------------------------------------+
void DrawRiskFreeLine(ulong ticket, string symbol, double price, double percent, double rr)
  {
   string lineName = "RiskFree_" + IntegerToString(ticket);
   double openPrice = PositionSelectByTicket(ticket) ? PositionGetDouble(POSITION_PRICE_OPEN) : OrderGetDouble(ORDER_PRICE_OPEN);
   double pips = CalculatePips(symbol, price, openPrice);

// Create or update horizontal line
   if(!ObjectCreate(0, lineName, OBJ_HLINE, 0, 0, price))
     {
      ObjectSetDouble(0, lineName, OBJPROP_PRICE, price);
     }

   ObjectSetInteger(0, lineName, OBJPROP_COLOR, InpLineColor);
   ObjectSetInteger(0, lineName, OBJPROP_STYLE, InpLineStyle);
   ObjectSetInteger(0, lineName, OBJPROP_WIDTH, InpLineWidth);
   ObjectSetInteger(0, lineName, OBJPROP_SELECTABLE, true);
   ObjectSetInteger(0, lineName, OBJPROP_ZORDER, 100);
   ObjectSetInteger(0, lineName, OBJPROP_BACK, false);

// Check current selection state
   bool isSelected = ObjectGetInteger(0, lineName, OBJPROP_SELECTED);
   bool isSelectable = ObjectGetInteger(0, lineName, OBJPROP_SELECTABLE);
   Print("Line ", lineName, ": Selectable=", isSelectable, ", Selected=", isSelected, ", Price=", price);

// Update line info array
   int index = -1;
   for(int i = 0; i < ArraySize(lineInfoArray); i++)
     {
      if(lineInfoArray[i].ticket == ticket)
        {
         index = i;
         break;
        }
     }
   if(index == -1)
     {
      ArrayResize(lineInfoArray, ArraySize(lineInfoArray) + 1);
      index = ArraySize(lineInfoArray) - 1;
      lineInfoArray[index].ticket = ticket;
      lineInfoArray[index].isSelected = false;
      lineInfoArray[index].isManuallyMoved = false;
     }
// Only update lastPrice if not manually moved to prevent overwriting
   if(!lineInfoArray[index].isManuallyMoved)
     {
      lineInfoArray[index].lastPrice = price;
      Print("Line ", lineName, ": Updated lastPrice to ", price, " (not manually moved)");
     }
   if(lineInfoArray[index].isSelected)
     {
      ObjectSetInteger(0, lineName, OBJPROP_SELECTED, true);
     }
   else
     {
      ObjectSetInteger(0, lineName, OBJPROP_SELECTED, isSelected);
      lineInfoArray[index].isSelected = isSelected;
     }

// Add text label if enabled
   if(InpShowPipPercent)
     {
      string textName = lineName + "_Text";
      string text = StringFormat("RF: %.1f pips, %.0f%%, RR: %.1f", pips, percent * 100, rr);

      if(!ObjectCreate(0, textName, OBJ_TEXT, 0, TimeCurrent(), price))
        {
         ObjectSetDouble(0, textName, OBJPROP_PRICE, price);
         ObjectSetInteger(0, textName, OBJPROP_TIME, TimeCurrent());
        }

      ObjectSetString(0, textName, OBJPROP_TEXT, text);
      ObjectSetInteger(0, textName, OBJPROP_COLOR, InpLineColor);
      ObjectSetInteger(0, textName, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, textName, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, textName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, textName, OBJPROP_ZORDER, 100);
      Print("Drew label for ", lineName, ": ", text, " at price: ", price);
     }
   else
     {
      Print("Label not drawn for ", lineName, ": InpShowPipPercent is false");
     }

   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Calculate Pips                                                    |
//+------------------------------------------------------------------+
double CalculatePips(string symbol, double price1, double price2)
  {
   double difference = MathAbs(price1 - price2) / Point();
   return difference / 10;
  }

//+------------------------------------------------------------------+
//| Check line status and price changes                               |
//+------------------------------------------------------------------+
void CheckLineStatus()
  {
   for(int i = 0; i < ArraySize(lineInfoArray); i++)
     {
      string lineName = "RiskFree_" + IntegerToString(lineInfoArray[i].ticket);
      if(ObjectFind(0, lineName) >= 0)
        {
         // Check current price
         double currentPrice = ObjectGetDouble(0, lineName, OBJPROP_PRICE);
         bool priceChanged = MathAbs(currentPrice - lineInfoArray[i].lastPrice) > 0.00001;

         // Check selection state
         bool isSelected = ObjectGetInteger(0, lineName, OBJPROP_SELECTED);
         if(isSelected != lineInfoArray[i].isSelected)
           {
            lineInfoArray[i].isSelected = isSelected;
            Print("Line ", lineName, " selection changed: Selected=", isSelected);
           }
         if(lineInfoArray[i].isSelected)
           {
            ObjectSetInteger(0, lineName, OBJPROP_SELECTED, true);
           }

         // Update risk-free calculations if price changed
         if(priceChanged)
           {
            Print("Line ", lineName, " manually moved to price: ", currentPrice, ", was: ", lineInfoArray[i].lastPrice);
            lineInfoArray[i].lastPrice = currentPrice;
            lineInfoArray[i].isManuallyMoved = true;

            // Recalculate pips, percent, and RR based on new price
            double openPrice, sl, tp;
            long posType;
            string symbol;
            bool isPosition = PositionSelectByTicket(lineInfoArray[i].ticket);
            if(isPosition)
              {
               openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
               sl = PositionGetDouble(POSITION_SL);
               tp = PositionGetDouble(POSITION_TP);
               posType = PositionGetInteger(POSITION_TYPE);
               symbol = PositionGetString(POSITION_SYMBOL);
              }
            else
               if(OrderSelect(lineInfoArray[i].ticket))
                 {
                  openPrice = OrderGetDouble(ORDER_PRICE_OPEN);
                  sl = OrderGetDouble(ORDER_SL);
                  tp = OrderGetDouble(ORDER_TP);
                  symbol = OrderGetString(ORDER_SYMBOL);
                  long orderType = OrderGetInteger(ORDER_TYPE);
                  posType = (orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_BUY_STOP) ?
                            POSITION_TYPE_BUY : POSITION_TYPE_SELL;
                 }
               else
                 {
                  Print("Line ", lineName, ": Failed to select position or order, ticket=", lineInfoArray[i].ticket);
                  continue;
                 }

            // Calculate pips
            double pips = CalculatePips(symbol, currentPrice, openPrice);

            // Calculate new percent based on new risk-free price
            double distanceToTP = MathAbs(tp - openPrice);
            double distanceToRF = MathAbs(currentPrice - openPrice);
            double percent = (distanceToTP > 0) ? distanceToRF / distanceToTP : 0;

            // Calculate RR (unchanged, based on original SL and TP)
            double rr = CalculateRR(openPrice, sl, tp, posType);

            // Update text label if enabled
            if(InpShowPipPercent)
              {
               string textName = lineName + "_Text";
               if(ObjectFind(0, textName) >= 0)
                 {
                  string text = StringFormat("RF: %.1f pips, %.0f%%, RR: %.1f", pips, percent * 100, rr);
                  ObjectSetString(0, textName, OBJPROP_TEXT, text);
                  ObjectSetDouble(0, textName, OBJPROP_PRICE, currentPrice);
                  Print("Updated label for ", lineName, ": ", text, " at price: ", currentPrice);
                 }
               else
                 {
                  Print("Failed to update label for ", lineName, ": Text object not found");
                 }
              }
            else
              {
               Print("Label not updated for ", lineName, ": InpShowPipPercent is false");
              }
           }
        }
      else
        {
         Print("Line ", lineName, ": Object not found on chart");
        }
     }
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Rebuild objects after timeframe change                            |
//+------------------------------------------------------------------+
void RebuildObjects()
  {
   Print("Rebuilding objects due to timeframe change");
   for(int i = 0; i < ArraySize(lineInfoArray); i++)
     {
      ulong ticket = lineInfoArray[i].ticket;
      string lineName = "RiskFree_" + IntegerToString(ticket);
      string symbol;
      double openPrice, sl, tp;
      long posType;

      bool isPosition = PositionSelectByTicket(ticket);
      if(isPosition)
        {
         symbol = PositionGetString(POSITION_SYMBOL);
         openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         sl = PositionGetDouble(POSITION_SL);
         tp = PositionGetDouble(POSITION_TP);
         posType = PositionGetInteger(POSITION_TYPE);
        }
      else
         if(OrderSelect(ticket))
           {
            symbol = OrderGetString(ORDER_SYMBOL);
            openPrice = OrderGetDouble(ORDER_PRICE_OPEN);
            sl = OrderGetDouble(ORDER_SL);
            tp = OrderGetDouble(ORDER_TP);
            long orderType = OrderGetInteger(ORDER_TYPE);
            posType = (orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_BUY_STOP) ?
                      POSITION_TYPE_BUY : POSITION_TYPE_SELL;
           }
         else
           {
            Print("RebuildObjects: Failed to select position or order for ticket ", ticket);
            continue;
           }

      if(sl == 0 || tp == 0)
        {
         Print("RebuildObjects: SL or TP not set for ticket ", ticket);
         continue;
        }

      double rr = CalculateRR(openPrice, sl, tp, posType);
      if(rr < 2)
        {
         Print("RebuildObjects: RR=", rr, " < 2 for ticket ", ticket);
         continue;
        }

      double riskFreePercent = GetRiskFreePercent(rr);
      double riskFreePrice = lineInfoArray[i].isManuallyMoved ? lineInfoArray[i].lastPrice : CalculateRiskFreePrice(openPrice, tp, riskFreePercent, posType);
      if(lineInfoArray[i].isManuallyMoved)
        {
         double distanceToTP = MathAbs(tp - openPrice);
         double distanceToRF = MathAbs(riskFreePrice - openPrice);
         riskFreePercent = (distanceToTP > 0) ? distanceToRF / distanceToTP : 0;
        }

      Print("Rebuilding line for ticket ", ticket, " at price: ", riskFreePrice);
      DrawRiskFreeLine(ticket, symbol, riskFreePrice, riskFreePercent, rr);
     }
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Clean up objects for closed positions or canceled orders          |
//+------------------------------------------------------------------+
void CleanUpObjects()
  {
   for(int i = ObjectsTotal(0, 0, -1) - 1; i >= 0; i--)
     {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, "RiskFree_") < 0)
         continue;

      // Extract ticket number from object name
      string ticketStr = StringSubstr(name, StringFind(name, "_") + 1);
      ulong ticket = StringToInteger(ticketStr);

      // Check if position or order still exists
      bool positionExists = PositionSelectByTicket(ticket);
      bool orderExists = OrderSelect(ticket);

      if(!positionExists && !orderExists)
        {
         Print("Cleaning up objects for ticket ", ticket, ": Position and order no longer exist");
         ObjectDelete(0, name);
         ObjectDelete(0, name + "_Text");
         // Remove from lineInfoArray
         for(int j = 0; j < ArraySize(lineInfoArray); j++)
           {
            if(lineInfoArray[j].ticket == ticket)
              {
               for(int k = j; k < ArraySize(lineInfoArray) - 1; k++)
                 {
                  lineInfoArray[k] = lineInfoArray[k + 1];
                 }
               ArrayResize(lineInfoArray, ArraySize(lineInfoArray) - 1);
               break;
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Chart event handler                                               |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_OBJECT_CLICK)
     {
      // Check if a RiskFree line is clicked
      if(StringFind(sparam, "RiskFree_") >= 0 && StringFind(sparam, "_Text") < 0)
        {
         // Ensure the line remains selectable
         ObjectSetInteger(0, sparam, OBJPROP_SELECTED, true);
         for(int i = 0; i < ArraySize(lineInfoArray); i++)
           {
            string lineName = "RiskFree_" + IntegerToString(lineInfoArray[i].ticket);
            if(lineName == sparam)
              {
               lineInfoArray[i].isSelected = true;
               break;
              }
           }
         Print("Line ", sparam, " clicked, set to selectable, Selected=",
               ObjectGetInteger(0, sparam, OBJPROP_SELECTED));
         ChartRedraw(0);
        }
     }
   else
      if(id == CHARTEVENT_CHART_CHANGE)
        {
         Print("Chart timeframe changed, rebuilding objects");
         RebuildObjects();
        }
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
// Remove all objects created by EA
   for(int i = ObjectsTotal(0, 0, -1) - 1; i >= 0; i--)
     {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, "RiskFree_") >= 0)
         ObjectDelete(0, name);
     }
   ArrayFree(lineInfoArray);
   Print("EA deinitialized, reason: ", reason);
  }
//+------------------------------------------------------------------+
