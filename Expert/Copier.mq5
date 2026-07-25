#property copyright "Copyright 2024, hamid attari"
#property link      "https://t.me/hamid_attari_1985"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
#include <Arrays/ArrayLong.mqh>

//--- Input Parameters
enum ENUM_MODE
  {
   MODE_MASTER, // Master Mode
   MODE_SLAVE   // Slave Mode
  };

input ENUM_MODE Mode = MODE_SLAVE;               // EA Mode
input string ServerName = "Server1";   // Server Name
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
input int MagicNumber = 12345;                   // Magic Number (Slave Only)
input double Coef = 1.0;                         // Coef for Voliume

input double FixedVolume = 0; // Fixed Volume : if 0 then scaled volume
input double MaxVolume = 0; // Max Volume : if 0 then free scale
input double SkipVolume = 0.005; // Skip trade if Scaled volume is less than

input bool MasterHasPrefixOrSuffix = true;       // Master Has Prefix or Suffix
input string MasterSuffix = ".st";               // Suffix for master
input string MasterPrefix = "";                  // prefix for master

input bool SlaveHasPrefixOrSuffix = false;       // Slave Has Prefix or Suffix
input string SlaveSuffix = "";                   // Suffix for slave
input string SlavePrefix = "";                   // prefix for slave

input string SkipSymbols = ""; // Skip Symbols; Like: USDJPY, GBPUSD or Just JPY
input string MasterSlaveReplace = "us30:us30roll, us100:ndx"; // Replcae Master Symbol with Slave Symbol; Like: us30:us30roll, us100:ndx
//--- Global Variables

input bool AutomaticlyOpen = true; // Allow to open position by master
input bool AutomaticlyClose = true; // Allow to close position by master

input bool ManuallyChangeTpSl = true;

//--- Daily Loss Limit Feature -------------------------------------
// Maximum accumulated REALIZED loss (in account currency / USD) allowed for the
// current trading day. Once reached, the EA stops opening NEW trades until the
// next server-time day. Set to 0 to DISABLE the daily loss limit entirely.
input double MaxDailyLossUSD = 100.0;                 // Max Daily Loss (USD, 0 = disabled)
// If true, only losses on the chart symbol (_Symbol) count toward the daily limit.
// If false (default, recommended for this multi-symbol copier), losses from ALL
// symbols traded by this EA (matched by Magic Number) are accumulated together.
input bool DailyLossCurrentSymbolOnly = false;        // Daily Loss: current symbol only

string symbolArray[];
string symbolReplacementArray[];

int symbolSkipCounts;
int symbolReplacementCounts;
string serverPath;

CTrade trade;
CArrayLong copiedTickets;

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
  {
   serverPath = ServerName+".bin";
   symbolSkipCounts = StringSplit(SkipSymbols, ',', symbolArray);
   symbolReplacementCounts = StringSplit(MasterSlaveReplace, ',', symbolReplacementArray);

//Print(GetSlaveSymbol("US30.spot"));
//Print(GetSlaveSymbol("us30.st"));
//Print(GetSlaveSymbol("us100.st"));

   if(Mode == MODE_SLAVE)
     {
      trade.SetExpertMagicNumber(MagicNumber);
     }

   copiedTickets.Clear();
   EventSetMillisecondTimer(50);
   Print("EA Initialized - Mode: ", Mode == MODE_MASTER ? "Master" : "Slave");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool HasTradeOrPositionWithComment(string commentToCheck)
  {
// Get current time and time one week ago
   datetime currentTime = TimeCurrent();
   datetime oneWeekAgo = currentTime - 7 * 24 * 60 * 60; // Subtract 7 days in seconds

// Select trade history for the last week
   if(!HistorySelect(oneWeekAgo, currentTime))
     {
      Print("Error selecting history: ", GetLastError());
      return false;
     }

// Get total number of deals in the selected history
   int totalDeals = HistoryDealsTotal();

// Loop through all deals
   for(int i = 0; i < totalDeals; i++)
     {
      // Get the ticket of the deal
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0)
         continue; // Skip if ticket is invalid

      // Get the deal comment
      string dealComment = HistoryDealGetString(dealTicket, DEAL_COMMENT);

      // Check if the comment matches the specified comment
      if(dealComment == commentToCheck)
        {
         Print("Position already existed in the past.");
         return true; // Found a matching comment
        }
     }

   int totalPositions = PositionsTotal();
   for(int i = 0; i < totalPositions; i++)
     {
      ulong positionTicket = PositionGetTicket(i);
      if(PositionSelectByTicket(positionTicket))
        {
         string positionComment = PositionGetString(POSITION_COMMENT);
         if(positionComment == commentToCheck)
           {
            return true; // Found matching comment in open positions
           }
        }
     }

// No matching comment found
   return false;
  }

//+------------------------------------------------------------------+
//| Daily Loss Limit - helper functions                                |
//+------------------------------------------------------------------+
//| GetTodayLoss()                                                     |
//|   Returns the total loss (as a positive USD value) for the CURRENT |
//|   trading day (server time). This combines:                        |
//|     1) REALIZED loss from trades CLOSED today, and                  |
//|     2) FLOATING (unrealized) loss of currently OPEN positions.      |
//|   Because the history window always starts at the current day's    |
//|   00:00:00 server time, the realized part automatically resets to  |
//|   zero when a new trading day begins.                              |
//|                                                                    |
//|   Filters applied:                                                 |
//|     - EA Magic Number  (DEAL_MAGIC == MagicNumber)                 |
//|     - Current trading day (deals closed since today's midnight)     |
//|     - Current symbol, only when DailyLossCurrentSymbolOnly = true   |
//|                                                                    |
//|   Only CLOSING deals (DEAL_ENTRY_OUT) carry realized profit/loss.  |
//|   Only LOSING deals contribute; profitable deals are ignored so    |
//|   they never offset / reduce the accumulated daily loss.           |
//+------------------------------------------------------------------+
double GetTodayLoss()
  {
   double totalLoss = 0.0;

//--- Compute the start of the current trading day (00:00:00 server time)
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   datetime dayStart = StructToTime(dt);   // today's midnight (server time)
   datetime now      = TimeCurrent();

//--- Load only the deals that were closed during the current day
   if(!HistorySelect(dayStart, now))
     {
      Print("GetTodayLoss: error selecting history: ", GetLastError());
      return 0.0;
     }

   int totalDeals = HistoryDealsTotal();
   for(int i = 0; i < totalDeals; i++)
     {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0)
         continue; // skip invalid ticket

      //--- Filter: only deals opened by THIS EA (same magic number)
      if((long)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != MagicNumber)
         continue;

      //--- Filter: only closing deals hold the realized P/L of a trade
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT)
         continue;

      //--- Optional filter: restrict to the current chart symbol only
      if(DailyLossCurrentSymbolOnly &&
         HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
         continue;

      //--- Net realized result of the closed trade
      double profit     = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
      double swap       = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
      double commission = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      double net        = profit + swap + commission;

      //--- Only losing trades add to the daily loss (as a positive amount).
      //    Profitable trades are ignored and never offset the loss.
      if(net < 0.0)
         totalLoss += -net;
     }

//--- Add the FLOATING (unrealized) loss of currently OPEN positions that
//    belong to this EA. This way the daily loss reflects both already
//    closed trades AND the live losing exposure still on the books.
//    Same filters are applied: EA Magic Number and (optionally) the
//    current chart symbol. Only losing positions contribute; profitable
//    open positions are ignored so they never offset the loss.
   int totalPositions = PositionsTotal();
   for(int i = 0; i < totalPositions; i++)
     {
      ulong posTicket = PositionGetTicket(i);
      if(posTicket == 0)
         continue;

      if(!PositionSelectByTicket(posTicket))
         continue;

      //--- Filter: only positions opened by THIS EA (same magic number)
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      //--- Optional filter: restrict to the current chart symbol only
      if(DailyLossCurrentSymbolOnly &&
         PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      //--- Net floating result = profit + swap (commission already applied on entry)
      double posProfit = PositionGetDouble(POSITION_PROFIT);
      double posSwap   = PositionGetDouble(POSITION_SWAP);
      double posNet    = posProfit + posSwap;

      //--- Only losing open positions add to the daily loss (positive amount)
      if(posNet < 0.0)
         totalLoss += -posNet;
     }

   return totalLoss;
  }

//+------------------------------------------------------------------+
//| IsDailyLossLimitReached()                                          |
//|   Returns true when the accumulated daily loss has reached or       |
//|   exceeded MaxDailyLossUSD. When MaxDailyLossUSD <= 0 the feature   |
//|   is disabled and this always returns false.                       |
//+------------------------------------------------------------------+
bool IsDailyLossLimitReached()
  {
//--- Feature disabled when the limit is zero or negative
   if(MaxDailyLossUSD <= 0.0)
      return false;

   double loss = GetTodayLoss();

//--- Limit is hit when the loss is >= the configured threshold
   if(loss >= MaxDailyLossUSD)
     {
      Print("\U0001F6D1 Daily loss limit reached: today's loss = ", DoubleToString(loss, 2),
            " USD >= limit ", DoubleToString(MaxDailyLossUSD, 2),
            " USD. No new trades will be opened until the next trading day.");
      return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
//| CloseAllEAPositions()                                              |
//|   Closes ALL currently open positions that belong to this EA       |
//|   (matched by Magic Number, and optionally by the current chart     |
//|   symbol when DailyLossCurrentSymbolOnly = true). Used to flatten    |
//|   the account once the daily loss limit has been reached.          |
//|   Iterates from the last index downward because closing a position |
//|   removes it from the list and shifts the remaining indexes.       |
//+------------------------------------------------------------------+
void CloseAllEAPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      //--- Only positions opened by THIS EA (same magic number)
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      //--- Optional filter: restrict to the current chart symbol only
      if(DailyLossCurrentSymbolOnly &&
         PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      //--- Capture the master ticket (comment) BEFORE closing the position
      long masterTicket = StringToInteger(PositionGetString(POSITION_COMMENT));
      if(trade.PositionClose(ticket))
        {
         //--- Keep the copier bookkeeping in sync: drop the copied ticket
         int idx = copiedTickets.SearchLinear(masterTicket);
         if(idx != -1)
            copiedTickets.Delete(idx);
         Print("\U0001F6D1 Daily loss limit: closed position ", ticket, " on ", symbol);
        }
      else
        {
         Print("\u274C Daily loss limit: failed to close position ", ticket,
               " on ", symbol, " retcode=", trade.ResultRetcode());
        }
     }
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   GlobalVariablesDeleteAll();
   copiedTickets.Clear();
  }

//+------------------------------------------------------------------+
//| Get corresponding slave symbol                                     |
//+------------------------------------------------------------------+
string GetSlaveSymbol(string masterSymbol)
  {
   if(MasterHasPrefixOrSuffix)
     {
      StringReplace(masterSymbol, MasterSuffix, "");
      StringReplace(masterSymbol, MasterPrefix, "");
      //StringToUpper(masterSymbol);
     }

   if(SlaveHasPrefixOrSuffix)
     {
      masterSymbol = masterSymbol +  SlaveSuffix;
      masterSymbol =   SlavePrefix + masterSymbol;
     }

   for(int i = 0; i < symbolSkipCounts; i++)
     {
      string symbol = symbolArray[i];
      //StringToUpper(symbol);
      if(StringFind(masterSymbol,symbol) >= 0)
         return "";
     }

   for(int i = 0; i < symbolReplacementCounts; i++)
     {
      string symbolReplcaementPair = symbolReplacementArray[i];
      string symbolReplacementPairArray[];

      StringSplit(symbolReplcaementPair, ':', symbolReplacementPairArray);

      string masterSymbolPair = symbolReplacementPairArray[0];
      string slaveSymbolPair = symbolReplacementPairArray[1];

      StringTrimLeft(masterSymbolPair);
      StringTrimLeft(slaveSymbolPair);

      //StringToUpper(masterSymbolPair);
      //StringToUpper(slaveSymbolPair);

      if(StringFind(masterSymbol,masterSymbolPair) >= 0)
         return slaveSymbolPair;
     }

   return masterSymbol;
  }

//+------------------------------------------------------------------+
//| Timer function                                                     |
//+------------------------------------------------------------------+
void OnTimer()
  {
//Print(FILE_NAME);
   if(Mode == MODE_MASTER)
     {
      int file = FileOpen(serverPath, FILE_WRITE|FILE_BIN|FILE_COMMON);
      if(file != INVALID_HANDLE)
        {
         for(int i = 0; i < PositionsTotal(); i++)
           {
            ulong ticket = PositionGetTicket(i);
            if(PositionSelectByTicket(ticket))
              {
               string symbol = PositionGetString(POSITION_SYMBOL);
               // Write positions for both master symbols

               FileWriteLong(file, ticket);
               int length = StringLen(symbol);
               FileWriteInteger(file, length);
               FileWriteString(file, symbol);
               FileWriteDouble(file, PositionGetDouble(POSITION_VOLUME));
               FileWriteInteger(file, (int)PositionGetInteger(POSITION_TYPE));
               FileWriteDouble(file, PositionGetDouble(POSITION_PRICE_OPEN));
               FileWriteDouble(file, PositionGetDouble(POSITION_SL));
               FileWriteDouble(file, PositionGetDouble(POSITION_TP));
              }
           }
         FileClose(file);
        }
     }
   else
      if(Mode == MODE_SLAVE)
        {
         //--- Daily loss guard: if the limit is reached, flatten ALL EA
         //    positions and skip opening/managing new copies for this cycle.
         if(IsDailyLossLimitReached())
           {
            CloseAllEAPositions();
            return;
           }

         CArrayLong currentMasterTickets;
         currentMasterTickets.Clear();

         int file = FileOpen(serverPath, FILE_READ|FILE_BIN|FILE_COMMON);
         if(file != INVALID_HANDLE)
           {
            while(!FileIsEnding(file))
              {
               if(!AutomaticlyOpen)
                  break;

               long masterTicket = FileReadLong(file);
               int length = FileReadInteger(file);
               string masterSymbol = FileReadString(file, length);
               double masterScaledVolume = FileReadDouble(file) * Coef;

               bool skipOnce = false;
               if(masterScaledVolume < SkipVolume)
                  skipOnce = true;

               double maxVolume = NormalizeDouble(masterScaledVolume, 2);

               if(maxVolume < 0.01)
                  maxVolume = 0.01;

               if(MaxVolume > 0)
                  maxVolume = maxVolume >= MaxVolume ? MaxVolume : maxVolume;

               double volume = FixedVolume == 0 ?  maxVolume : FixedVolume;

               ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)FileReadInteger(file);
               double openPrice = FileReadDouble(file);
               double sl = FileReadDouble(file);
               double tp = FileReadDouble(file);

               string slaveSymbol = GetSlaveSymbol(masterSymbol);
               if(slaveSymbol == "")
                  continue;  // Skip if no matching slave symbol

               currentMasterTickets.Add(masterTicket);

               string comment = IntegerToString(masterTicket);

               string initVolumeName = "init_volume_" + (string)masterTicket;

               // Check if ticket already copied
               if(copiedTickets.SearchLinear(masterTicket) == -1)
                 {
                  GlobalVariableSet(initVolumeName, volume);

                  Print("New position detected: ", masterSymbol, " -> ", slaveSymbol);
                  // Open new position

                  copiedTickets.Add(masterTicket);

                  if(HasTradeOrPositionWithComment(comment))
                     skipOnce = true;

                  //--- Daily Loss Limit guard: if today's accumulated loss has
                  //    reached MaxDailyLossUSD, do NOT open any new trade. Existing
                  //    positions and their management (SL/TP, trailing, breakeven,
                  //    partial close, closing/copying) are handled elsewhere and
                  //    remain fully active. This only blocks NEW entries.
                  if(!skipOnce && IsDailyLossLimitReached())
                    {
                     Print("Skipping new trade for master ticket ", masterTicket,
                           " (", slaveSymbol, ") - daily loss limit reached.");
                     skipOnce = true;
                    }

                  if(!skipOnce)
                    {
                     if(posType == POSITION_TYPE_BUY)
                       {
                        if(trade.Buy(volume, slaveSymbol, 0, sl, tp,comment))
                          {
                           Print("Opened Buy position for ticket: ", masterTicket, " on ", slaveSymbol);
                          }
                       }
                     else
                        if(posType == POSITION_TYPE_SELL)
                          {
                           //test
                           if(trade.Sell(volume, slaveSymbol, 0, sl, tp, IntegerToString(masterTicket)))
                             {
                              Print("Opened Sell position for ticket: ", masterTicket, " on ", slaveSymbol);
                             }
                          }
                    }
                 }
               else
                 {
                  // Update existing position if needed
                  for(int i = 0; i < PositionsTotal(); i++)
                    {
                     ulong ticket = PositionGetTicket(i);
                     double initVol = GlobalVariableGet(initVolumeName);

                     if(PositionSelectByTicket(ticket))
                       {
                        if(PositionGetString(POSITION_SYMBOL) == slaveSymbol &&
                           PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
                           StringToInteger(PositionGetString(POSITION_COMMENT)) == masterTicket)
                          {
                           if(initVol != volume)
                             {
                              double closePartialVol = NormalizeDouble(initVol - volume, 2);

                              PartialCloseByTicket(ticket, closePartialVol);
                              GlobalVariableSet(initVolumeName, volume);

                              Print("New Position Partially Closed: ", ticket, " with ", closePartialVol, " lot");
                             }

                           double positionSl = PositionGetDouble(POSITION_SL);
                           double positionTp = PositionGetDouble(POSITION_TP);

//                           if(ManuallyChangeTpSl && (positionSl == 0 && positionSl != sl))
//                             {
//                              trade.PositionModify(ticket, sl, tp);
//
//                              Print("Position SL Updated: ", ticket);
//                             }
//
//                           if(ManuallyChangeTpSl && (positionTp == 0 && positionTp != tp))
//                             {
//                              trade.PositionModify(ticket, sl, tp);
//
//                              Print("Position TP Updated: ", ticket);
//                             }

                           if(!ManuallyChangeTpSl && (positionSl != sl ||  positionTp != tp))
                             {
                              trade.PositionModify(ticket, sl, tp);

                              Print("Position SL & TP Updated: ", ticket, " SL: ",sl, " TP: ",tp);
                             }

                           break;
                          }
                       }
                    }
                 }
              }
            FileClose(file);

            if(AutomaticlyClose)
              {
               // Close positions that don't exist in master anymore
               for(int i = 0; i < PositionsTotal(); i++)
                 {
                  ulong ticket = PositionGetTicket(i);
                  if(PositionSelectByTicket(ticket))
                    {
                     string symbol = PositionGetString(POSITION_SYMBOL);
                     if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
                       {
                        string positionComment = PositionGetString(POSITION_COMMENT);
                        long masterTicket = StringToInteger(positionComment);

                        if(currentMasterTickets.SearchLinear(masterTicket) == -1 && masterTicket != 0)
                          {
                           if(trade.PositionClose(ticket))
                             {
                              //GlobalVariableDel(initVolumeName);
                              copiedTickets.Delete(copiedTickets.SearchLinear(masterTicket));
                              Print("Closed position for ticket: ", masterTicket, " on ", symbol);
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
//|                                                                  |
//+------------------------------------------------------------------+
bool PartialCloseByTicket(ulong ticket, double volumeToClose)
  {
   if(!PositionSelectByTicket(ticket))
     {
      Print("❌ Ticket not found: ", ticket);
      return false;
     }

   string symbol = PositionGetString(POSITION_SYMBOL);
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_BID)
                  : SymbolInfoDouble(symbol, SYMBOL_ASK);

   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action   = TRADE_ACTION_DEAL;
   request.symbol   = symbol;
   request.volume   = volumeToClose;
   request.price    = NormalizeDouble(price, _Digits);
   request.deviation= 10;
   request.magic    = PositionGetInteger(POSITION_MAGIC);
   request.position = ticket;
   request.type     = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   request.comment  = PositionGetString(POSITION_COMMENT); // حفظ کامنت

   if(!OrderSend(request, result))
     {
      Print("❌ PartialCloseByTicket Error: ", result.retcode, " ", result.comment);
      return false;
     }

   if(result.retcode != TRADE_RETCODE_DONE)
     {
      Print("❌ Order failed: ", result.retcode, " ", result.comment);
      return false;
     }

   Print("✅ Partial close done for ticket ", ticket, " with volume: ", volumeToClose);
   return true;
  }


//+------------------------------------------------------------------+
//| Trade event handler                                               |
//+------------------------------------------------------------------+
void OnTrade()
  {
  }

//+------------------------------------------------------------------+
//| ChartEvent handler                                                |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,
                  const long& lparam,
                  const double& dparam,
                  const string& sparam)
  {
  }
//+------------------------------------------------------------------+
