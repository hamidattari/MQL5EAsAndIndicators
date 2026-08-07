//+------------------------------------------------------------------+
//|                                              TelegramCopier.mq5  |
//|                 Master-Slave Trade Copier via Telegram Bridge    |
//+------------------------------------------------------------------+
#property copyright "Gemini"
//+------------------------------------------------------------------+
//| ARCHITECTURE                                                     |
//|                                                                  |
//| Master : sends every trade signal as a JSON message to a         |
//|          Telegram channel using TelegramBotToken.                |
//|                                                                  |
//| Slave  : polls the same channel using SlaveBotToken (falling     |
//|          back to TelegramBotToken if SlaveBotToken is left       |
//|          empty) via getUpdates.  Crucially, every getUpdates     |
//|          call is made WITHOUT an offset parameter (offset=0),    |
//|          so Telegram is NEVER told to confirm/acknowledge any    |
//|          update. Per the Telegram Bot API, passing an offset     |
//|          permanently deletes ("purges") from Telegram's servers  |
//|          every update whose update_id is lower than that offset. |
//|          By never sending an offset at all, no Slave can ever    |
//|          cause updates to be purged for the other Slaves – every |
//|          Slave keeps receiving the FULL set of currently pending |
//|          updates (Telegram retains at most 100 pending updates,  |
//|          for up to 24 hours) on every poll.                      |
//|                                                                  |
//|          Each Slave then filters that full list LOCALLY, using   |
//|          its own last-seen update_id stored in a namespaced MT5  |
//|          Global Variable (keyed by SlaveID), skipping anything   |
//|          it has already processed. This is what prevents a      |
//|          Slave from re-executing a signal it already handled.    |
//|                                                                  |
//|          All Slaves can share ONE SlaveBotToken (or none, in     |
//|          which case TelegramBotToken is reused for polling).     |
//|          Because no getUpdates call ever advances Telegram's own |
//|          server-side offset, there is no race between Slaves:    |
//|          each one independently sees, and locally filters, the   |
//|          same pending update list.                                |
//|                                                                  |
//| SlaveID: MUST be unique per Slave instance ("1","2","NY", ...).  |
//|          Controls Global Variable namespace only – not the bot.  |
//+------------------------------------------------------------------+
#property link      "https://core.telegram.org/bots/api"
#property version   "1.40"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

enum ENUM_COPIER_MODE
{
    MODE_MASTER = 0,
    MODE_SLAVE = 1
};

input group "=== General Settings ==="
input ENUM_COPIER_MODE CopierMode = MODE_MASTER;
// Master uses TelegramBotToken to SEND signals to the channel.
// Slave uses SlaveBotToken to READ signals from the channel.
// Both bots must be members/admins of the same channel.
input string          TelegramBotToken = "8803974844:AAHO24wtCBeEhUarInOj_M5LEKON-fp2VFs";
input string          SlaveBotToken = ""; // Optional. All Slaves may share this one token. Leave empty to reuse TelegramBotToken for polling.
input string          TelegramChatID = "-1004483905925";
input bool            EnableCopying = true;
// Each Slave instance MUST have a unique SlaveID so that their own
// last-seen update_id cursor in Global Variables never collides.
// The Master ignores this value.
input string          SlaveID = "1";  // Unique ID for this Slave instance

input group "=== Risk & Execution (Slave Only) ==="
input double LotMultiplier = 1.0;
input bool   FixedLotMode = false;
input double FixedLotSize = 0.01;
input double MinLot = 0.01;
input double MaxLot = 10.0;
input ulong  MaxSlippage = 10;

input group "=== Symbol Mapping ==="
input string SymbolMappingList = "EURUSD=EURUSD.a,XAUUSD=GOLD";

//+------------------------------------------------------------------+
struct STrackedTrade
{
    ulong             ticket;
    string            symbol;
    string            type;
    double            volume;
    double            sl;
    double            tp;
    double            price;
    ulong             magic;
};

CTrade        trade;
CPositionInfo positionInfo;
CSymbolInfo   symbolInfo;

//+------------------------------------------------------------------+
//| Helper Class: JSON Builder & Parser                              |
//+------------------------------------------------------------------+
class CSimpleJSON
{
public:
    static string  BuildMessage(string action, string symbol, string type,
        double entry, double sl, double tp, double vol,
        ulong ticket, ulong magic)
    {
        string json = "{";
        json += "\"action\":\"" + action + "\",";
        json += "\"symbol\":\"" + symbol + "\",";
        json += "\"type\":\"" + type + "\",";
        json += "\"entry\":" + DoubleToString(entry, 5) + ",";
        json += "\"sl\":" + DoubleToString(sl, 5) + ",";
        json += "\"tp\":" + DoubleToString(tp, 5) + ",";
        json += "\"volume\":" + DoubleToString(vol, 2) + ",";
        // Tickets/magic are ulong – encode as quoted strings to survive double round-trip.
        json += "\"ticket\":\"" + IntegerToString(ticket) + "\",";
        json += "\"magic\":\"" + IntegerToString(magic) + "\"";
        json += "}";
        return json;
    }

    static string  ExtractString(string json, string key)
    {
        string searchKey = "\"" + key + "\":\"";
        int start = StringFind(json, searchKey);
        if (start < 0) return "";
        start += StringLen(searchKey);
        int end = StringFind(json, "\"", start);
        if (end < 0)  return "";
        return StringSubstr(json, start, end - start);
    }

    static double  ExtractNumber(string json, string key)
    {
        string searchKey = "\"" + key + "\":";
        int start = StringFind(json, searchKey);
        if (start < 0) return 0.0;
        start += StringLen(searchKey);
        int end1 = StringFind(json, ",", start);
        int end2 = StringFind(json, "}", start);
        int end = (end1 > 0 && (end1 < end2 || end2 < 0)) ? end1 : end2;
        if (end < 0)  return 0.0;
        return StringToDouble(StringSubstr(json, start, end - start));
    }

    // Find the real end of a JSON string value, respecting escaped quotes.
    // startPos must point to the first character after the opening quote.
    static bool    ExtractJSONStringValue(string json, int startPos, string& value)
    {
        value = "";
        bool escaped = false;
        int  length = StringLen(json);
        for (int i = startPos; i < length; i++)
        {
            ushort ch = (ushort)StringGetCharacter(json, i);
            if (ch == '"' && !escaped)
            {
                value = StringSubstr(json, startPos, i - startPos);
                return true;
            }
            escaped = (ch == '\\' && !escaped);
        }
        return false;
    }

    // Extract a ulong stored as a quoted JSON string ("key":"NNN") or bare number.
    static ulong   ExtractUlong(string json, string key)
    {
        string val = ExtractString(json, key);
        if (val != "") return (ulong)StringToInteger(val);
        // Fallback: bare numeric form
        string searchKey = "\"" + key + "\":";
        int start = StringFind(json, searchKey);
        if (start < 0) return 0;
        start += StringLen(searchKey);
        int end1 = StringFind(json, ",", start);
        int end2 = StringFind(json, "}", start);
        int end = (end1 > 0 && (end1 < end2 || end2 < 0)) ? end1 : end2;
        if (end < 0) return 0;
        return (ulong)StringToInteger(StringSubstr(json, start, end - start));
    }
};

//+------------------------------------------------------------------+
//| CSymbolMapper                                                    |
//+------------------------------------------------------------------+
class CSymbolMapper
{
    string masterSymbols[];
    string slaveSymbols[];
    int    mapCount;
public:
    CSymbolMapper() { mapCount = 0; }
    void     Initialize(string mappings)
    {
        mapCount = 0;
        string pairs[];
        int count = StringSplit(mappings, ',', pairs);
        ArrayResize(masterSymbols, count);
        ArrayResize(slaveSymbols, count);
        for (int i = 0; i < count; i++)
        {
            string pair[];
            if (StringSplit(pairs[i], '=', pair) == 2)
            {
                masterSymbols[mapCount] = pair[0];
                slaveSymbols[mapCount] = pair[1];
                mapCount++;
            }
        }
    }
    string   GetSlaveSymbol(string masterSymbol)
    {
        for (int i = 0; i < mapCount; i++)
            if (masterSymbols[i] == masterSymbol)
                return slaveSymbols[i];
        if (SymbolSelect(masterSymbol, true))
            return masterSymbol;
        Print("Slave: Symbol not found on this broker: '", masterSymbol,
            "' – add a mapping in SymbolMappingList");
        return "";
    }
};

//+------------------------------------------------------------------+
//| CPersistentStorage                                               |
//| All keys are prefixed with SlaveID so each Slave instance has    |
//| its own independent namespace in MT5 Global Variables.           |
//+------------------------------------------------------------------+
class CPersistentStorage
{
    static string  Prefix() { return "TCopier_" + SlaveID + "_"; }
public:
    // Ticket mapping
    static void    SaveTicketMapping(ulong mTicket, ulong sTicket)
    {
        GlobalVariableSet(Prefix() + IntegerToString(mTicket), (double)sTicket);
    }
    static ulong   GetSlaveTicket(ulong mTicket)
    {
        string v = Prefix() + IntegerToString(mTicket);
        return GlobalVariableCheck(v) ? (ulong)GlobalVariableGet(v) : 0;
    }
    static void    RemoveTicketMapping(ulong mTicket)
    {
        GlobalVariableDel(Prefix() + IntegerToString(mTicket));
    }

    // Last-seen update_id cursor – per Slave, per computer.
    // Never shared with other Slaves; never sent to Telegram as an
    // offset, so it never causes Telegram to purge updates.
    static void    SaveLastUpdateID(long uid)
    {
        GlobalVariableSet(Prefix() + "LastUID", (double)uid);
    }
    static long    GetLastUpdateID()
    {
        string v = Prefix() + "LastUID";
        return GlobalVariableCheck(v) ? (long)GlobalVariableGet(v) : 0;
    }
};

//+------------------------------------------------------------------+
//| CTelegramClient                                                  |
//+------------------------------------------------------------------+
class CTelegramClient
{
private:
    string baseUrl, token, chatID;
public:
    void     Initialize(string botToken, string targetChatID)
    {
        token = botToken;
        chatID = targetChatID;
        baseUrl = "https://api.telegram.org/bot" + token;
    }

    string   UrlEncode(string value)
    {
        string e = value;
        StringReplace(e, "%", "%25");
        StringReplace(e, "\\", "%5C");
        StringReplace(e, "\"", "%22");
        StringReplace(e, "{", "%7B");
        StringReplace(e, "}", "%7D");
        StringReplace(e, ":", "%3A");
        StringReplace(e, ",", "%2C");
        StringReplace(e, "&", "%26");
        StringReplace(e, "=", "%3D");
        StringReplace(e, "+", "%2B");
        StringReplace(e, " ", "%20");
        return e;
    }

    bool     SendMessage(string text)
    {
        char post[], result[];
        string headers;
        string url = baseUrl + "/sendMessage?chat_id=" + chatID + "&text=" + UrlEncode(text);
        int res = WebRequest("GET", url, "", "", 5000, post, ArraySize(post), result, headers);
        if (res == 200) return true;
        Print("Telegram Send Error: ", res);
        return false;
    }

    // ---------------------------------------------------------------
    // GetUpdates — the key behaviour for multi-Slave support:
    //
    // We deliberately NEVER pass an "offset" parameter (equivalently,
    // offset=0). Per the Telegram Bot API, supplying offset=N tells
    // Telegram "I have confirmed everything below N – you may delete
    // it", and Telegram immediately purges those updates from ALL
    // bots' pending queues, including any other Slave's. If any Slave
    // sent its own (possibly higher) offset, it would silently erase
    // updates that a slower Slave has not processed yet. That is
    // exactly the bug this design avoids.
    //
    // By never sending an offset, every call returns the FULL list of
    // currently pending updates (Telegram keeps at most 100 pending
    // updates, retained for up to 24 hours). Each Slave then filters
    // that full list LOCALLY against its own last-seen update_id
    // (stored in a namespaced Global Variable), so it only acts on
    // updates it has not already processed. No Slave ever causes
    // Telegram to purge anything, so there is no race between Slaves
    // – all Slaves see the same pending updates, independent of each
    // other's progress.
    // ---------------------------------------------------------------
    string   GetUpdates()
    {
        char post[], result[];
        string headers;
        // No offset parameter is sent (equivalent to offset=0), so this
        // call never confirms/purges updates on Telegram's side. Every
        // Slave receives the full pending update list on every poll and
        // filters locally by its own lastUpdateId cursor.
        string url = baseUrl + "/getUpdates?timeout=1&allowed_updates=%5B%22channel_post%22%5D";
        Print("Slave[", SlaveID, "]: GetUpdates (no offset – full pending list)");
        int res = WebRequest("GET", url, "", "", 5000, post, ArraySize(post), result, headers);
        if (res != 200)
        {
            Print("Slave[", SlaveID, "]: GetUpdates HTTP error=", res,
                " (check WebRequest whitelist & SlaveBotToken)");
            return "";
        }
        string body = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
        Print("Slave[", SlaveID, "]: GetUpdates response -> ",
            (StringLen(body) == 0 ? "(empty)" : body));
        return body;
    }
};

//+------------------------------------------------------------------+
//| CMasterTradeMonitor                                              |
//+------------------------------------------------------------------+
class CMasterTradeMonitor
{
private:
    CTelegramClient* telegram;
    STrackedTrade    tracked[];

    int   FindIndex(ulong ticket)
    {
        for (int i = 0; i < ArraySize(tracked); i++)
            if (tracked[i].ticket == ticket) return i;
        return -1;
    }

public:
    void  Initialize(CTelegramClient* tgClient)
    {
        telegram = tgClient;
        int total = PositionsTotal();
        ArrayResize(tracked, total);
        for (int i = 0; i < total; i++)
        {
            if (positionInfo.SelectByIndex(i))
            {
                tracked[i].ticket = positionInfo.Ticket();
                tracked[i].symbol = positionInfo.Symbol();
                tracked[i].type = (positionInfo.PositionType() == POSITION_TYPE_BUY) ? "BUY" : "SELL";
                tracked[i].volume = positionInfo.Volume();
                tracked[i].sl = positionInfo.StopLoss();
                tracked[i].tp = positionInfo.TakeProfit();
                tracked[i].price = positionInfo.PriceOpen();
                tracked[i].magic = positionInfo.Magic();
            }
        }
    }

    void  OnTimerEvent()
    {
        if (!EnableCopying) return;

        int  currentTotal = PositionsTotal();
        int  trackedSize = ArraySize(tracked);
        bool activeFlags[];
        ArrayResize(activeFlags, trackedSize);
        ArrayInitialize(activeFlags, false);

        // PHASE 1: Modifications & Partial Closes
        for (int i = 0; i < currentTotal; i++)
        {
            if (!positionInfo.SelectByIndex(i)) continue;
            ulong ticket = positionInfo.Ticket();
            int   index = FindIndex(ticket);
            if (index < 0) continue;

            activeFlags[index] = true;

            // Partial Close
            if (positionInfo.Volume() < tracked[index].volume)
            {
                double closedVol = tracked[index].volume - positionInfo.Volume();
                string msg = CSimpleJSON::BuildMessage("PARTIAL_CLOSE",
                    positionInfo.Symbol(), tracked[index].type,
                    positionInfo.PriceOpen(), positionInfo.StopLoss(),
                    positionInfo.TakeProfit(), closedVol,
                    ticket, positionInfo.Magic());
                if (telegram.SendMessage(msg))
                {
                    tracked[index].volume = positionInfo.Volume();
                    Print("Master: PARTIAL_CLOSE sent. Tkt:", ticket);
                }
            }

            // SL/TP Modification
            double point = SymbolInfoDouble(positionInfo.Symbol(), SYMBOL_POINT);
            if (MathAbs(positionInfo.StopLoss() - tracked[index].sl) > point ||
                MathAbs(positionInfo.TakeProfit() - tracked[index].tp) > point)
            {
                string msg = CSimpleJSON::BuildMessage("MODIFY",
                    positionInfo.Symbol(), tracked[index].type,
                    positionInfo.PriceOpen(), positionInfo.StopLoss(),
                    positionInfo.TakeProfit(), positionInfo.Volume(),
                    ticket, positionInfo.Magic());
                if (telegram.SendMessage(msg))
                {
                    tracked[index].sl = positionInfo.StopLoss();
                    tracked[index].tp = positionInfo.TakeProfit();
                    Print("Master: MODIFY sent. Tkt:", ticket);
                }
            }
        }

        // PHASE 2: Closed Trades
        for (int i = trackedSize - 1; i >= 0; i--)
        {
            if (!activeFlags[i])
            {
                string msg = CSimpleJSON::BuildMessage("CLOSE",
                    tracked[i].symbol, tracked[i].type,
                    tracked[i].price, tracked[i].sl, tracked[i].tp,
                    tracked[i].volume, tracked[i].ticket, tracked[i].magic);
                if (telegram.SendMessage(msg))
                {
                    Print("Master: CLOSE sent. Tkt:", tracked[i].ticket);
                    for (int j = i; j < ArraySize(tracked) - 1; j++)
                        tracked[j] = tracked[j + 1];
                    ArrayResize(tracked, ArraySize(tracked) - 1);
                }
            }
        }

        // PHASE 3: New Trades
        for (int i = 0; i < currentTotal; i++)
        {
            if (!positionInfo.SelectByIndex(i)) continue;
            ulong ticket = positionInfo.Ticket();
            if (FindIndex(ticket) >= 0) continue;

            string typeStr = (positionInfo.PositionType() == POSITION_TYPE_BUY) ? "BUY" : "SELL";
            string msg = CSimpleJSON::BuildMessage("OPEN",
                positionInfo.Symbol(), typeStr,
                positionInfo.PriceOpen(), positionInfo.StopLoss(),
                positionInfo.TakeProfit(), positionInfo.Volume(),
                ticket, positionInfo.Magic());
            if (telegram.SendMessage(msg))
            {
                int newSize = ArraySize(tracked) + 1;
                ArrayResize(tracked, newSize);
                tracked[newSize - 1].ticket = ticket;
                tracked[newSize - 1].symbol = positionInfo.Symbol();
                tracked[newSize - 1].type = typeStr;
                tracked[newSize - 1].volume = positionInfo.Volume();
                tracked[newSize - 1].sl = positionInfo.StopLoss();
                tracked[newSize - 1].tp = positionInfo.TakeProfit();
                tracked[newSize - 1].price = positionInfo.PriceOpen();
                tracked[newSize - 1].magic = positionInfo.Magic();
                Print("Master: OPEN sent. Tkt:", ticket);
            }
        }
    }
};

//+------------------------------------------------------------------+
//| CSlaveTradeExecutor                                              |
//+------------------------------------------------------------------+
class CSlaveTradeExecutor
{
private:
    CTelegramClient* telegram;
    CSymbolMapper* mapper;
    long             lastUpdateId;  // this Slave's own cursor – never shared, never sent to Telegram as an offset

    double  CalculateLot(double masterLot)
    {
        double lot = FixedLotMode ? FixedLotSize : (masterLot * LotMultiplier);
        if (lot < MinLot) lot = MinLot;
        if (lot > MaxLot) lot = MaxLot;
        return NormalizeDouble(lot, 2);
    }

    void  ExecuteTrade(string action, string masterSym, string type,
        double entry, double sl, double tp, double vol,
        ulong masterTicket, ulong magic)
    {
        Print("Slave[", SlaveID, "]: ExecuteTrade -> action=", action,
            " sym=", masterSym, " type=", type,
            " entry=", entry, " sl=", sl, " tp=", tp, " vol=", vol,
            " masterTkt=", masterTicket, " magic=", magic);

        string slaveSym = mapper.GetSlaveSymbol(masterSym);
        if (slaveSym == "")
        {
            Print("Slave[", SlaveID, "]: Rejected – no symbol mapping for '", masterSym, "'");
            return;
        }

        trade.SetExpertMagicNumber(magic);
        trade.SetDeviationInPoints(MaxSlippage);

        int    digits = (int)SymbolInfoInteger(slaveSym, SYMBOL_DIGITS);
        double slaveSL = (sl > 0.0) ? NormalizeDouble(sl, digits) : 0.0;
        double slaveTP = (tp > 0.0) ? NormalizeDouble(tp, digits) : 0.0;

        if (action == "OPEN")
        {
            if (CPersistentStorage::GetSlaveTicket(masterTicket) > 0)
            {
                Print("Slave[", SlaveID, "]: OPEN skipped – duplicate masterTicket ", masterTicket);
                return;
            }
            double exeLot = CalculateLot(vol);
            Print("Slave[", SlaveID, "]: Opening ", type, " ", exeLot,
                " lots of ", slaveSym, " SL=", slaveSL, " TP=", slaveTP);
            if (type == "BUY" && trade.Buy(exeLot, slaveSym, 0, slaveSL, slaveTP))
                CPersistentStorage::SaveTicketMapping(masterTicket, trade.ResultOrder());
            else if (type == "SELL" && trade.Sell(exeLot, slaveSym, 0, slaveSL, slaveTP))
                CPersistentStorage::SaveTicketMapping(masterTicket, trade.ResultOrder());
            else
                Print("Slave[", SlaveID, "]: Order failed – retcode=", trade.ResultRetcode(),
                    " comment=", trade.ResultComment());
        }
        else if (action == "MODIFY")
        {
            ulong slaveTkt = CPersistentStorage::GetSlaveTicket(masterTicket);
            Print("Slave[", SlaveID, "]: MODIFY slaveTkt=", slaveTkt,
                " SL=", slaveSL, " TP=", slaveTP);
            if (slaveTkt > 0)
                trade.PositionModify(slaveTkt, slaveSL, slaveTP);
            else
                Print("Slave[", SlaveID, "]: MODIFY skipped – no ticket for masterTicket ", masterTicket);
        }
        else if (action == "PARTIAL_CLOSE")
        {
            ulong slaveTkt = CPersistentStorage::GetSlaveTicket(masterTicket);
            Print("Slave[", SlaveID, "]: PARTIAL_CLOSE slaveTkt=", slaveTkt,
                " lot=", CalculateLot(vol));
            if (slaveTkt > 0)
                trade.PositionClosePartial(slaveTkt, CalculateLot(vol));
            else
                Print("Slave[", SlaveID, "]: PARTIAL_CLOSE skipped – no ticket for masterTicket ", masterTicket);
        }
        else if (action == "CLOSE")
        {
            ulong slaveTkt = CPersistentStorage::GetSlaveTicket(masterTicket);
            Print("Slave[", SlaveID, "]: CLOSE slaveTkt=", slaveTkt);
            if (slaveTkt > 0 && trade.PositionClose(slaveTkt))
                CPersistentStorage::RemoveTicketMapping(masterTicket);
            else if (slaveTkt == 0)
                Print("Slave[", SlaveID, "]: CLOSE skipped – no ticket for masterTicket ", masterTicket);
            else
                Print("Slave[", SlaveID, "]: CLOSE failed – retcode=", trade.ResultRetcode());
        }
        else
            Print("Slave[", SlaveID, "]: Unknown action '", action, "' – ignored");
    }

    // Parse one update object from the getUpdates response.
    // Returns the signal JSON string if a valid channel_post is found,
    // otherwise returns "".
    string  ParseUpdateForSignal(string response, int uidKeyPos, int nextUpdatePos)
    {
        // The channel_post key must appear after this update's update_id value
        // and before the next update_id (i.e. within this update's JSON object).
        int channelPostPos = StringFind(response, "\"channel_post\":", uidKeyPos);
        if (channelPostPos < 0) return "";
        if (nextUpdatePos >= 0 && channelPostPos >= nextUpdatePos) return "";

        int textPos = StringFind(response, "\"text\":\"", channelPostPos);
        if (textPos < 0) return "";
        if (nextUpdatePos >= 0 && textPos >= nextUpdatePos) return "";

        string msgJson;
        if (!CSimpleJSON::ExtractJSONStringValue(response, textPos + 8, msgJson)) return "";
        StringReplace(msgJson, "\\\"", "\"");
        return msgJson;
    }

public:
    void  Initialize(CTelegramClient* tgClient, CSymbolMapper* symMapper)
    {
        telegram = tgClient;
        mapper = symMapper;
        // Restore this Slave's own cursor from its namespaced Global Variable.
        // This cursor is used ONLY for local filtering – it is never sent to
        // Telegram as a getUpdates offset.
        lastUpdateId = CPersistentStorage::GetLastUpdateID();
        Print("Slave[", SlaveID, "]: Initialized. lastUpdateId=", lastUpdateId);
    }

    void  OnTimerEvent()
    {
        if (!EnableCopying) return;

        // Call GetUpdates WITHOUT any offset. Telegram will therefore return
        // the full list of currently pending updates (up to 100, retained for
        // up to 24h) instead of only "new" ones, and it will NOT purge/confirm
        // anything on its side. Each Slave then filters this full list locally
        // against its own lastUpdateId cursor below, so every Slave (whether
        // using a shared SlaveBotToken or none at all) independently sees and
        // acts on every signal exactly once, regardless of other Slaves'
        // progress.
        string response = telegram.GetUpdates();
        if (response == "") return;

        int searchFrom = 0;
        while (true)
        {
            int uidKeyPos = StringFind(response, "\"update_id\":", searchFrom);
            if (uidKeyPos < 0) break;

            int digitStart = uidKeyPos + 12; // len("\"update_id\":") == 12

            int commaPos = StringFind(response, ",", digitStart);
            int bracePos = StringFind(response, "}", digitStart);
            int digitEnd;
            if (commaPos < 0 && bracePos < 0)
            {
                Print("Slave[", SlaveID, "]: Malformed response – no ',' or '}' after update_id");
                break;
            }
            else if (commaPos < 0)  digitEnd = bracePos;
            else if (bracePos < 0)  digitEnd = commaPos;
            else                   digitEnd = (commaPos < bracePos) ? commaPos : bracePos;

            long uId = (long)StringToInteger(StringSubstr(response, digitStart, digitEnd - digitStart));
            searchFrom = digitEnd;  // advance past this update_id value for next iteration

            Print("Slave[", SlaveID, "]: update_id=", uId, " lastUpdateId=", lastUpdateId);

            if (uId <= lastUpdateId)
            {
                Print("Slave[", SlaveID, "]: Already processed update_id=", uId, " – skipping");
                continue;
            }

            // This is a new update (per THIS Slave's local cursor only).
            // Update cursor immediately so even if ExecuteTrade fails we never
            // re-process this update_id. This cursor is local-only and is never
            // transmitted to Telegram, so it can never purge updates for other
            // Slaves.
            lastUpdateId = uId;
            CPersistentStorage::SaveLastUpdateID(lastUpdateId);

            int nextUpdatePos = StringFind(response, "\"update_id\":", searchFrom);
            string msgJson = ParseUpdateForSignal(response, uidKeyPos, nextUpdatePos);

            if (msgJson == "")
            {
                Print("Slave[", SlaveID, "]: update_id=", uId,
                    " – no channel_post signal found, skipping");
                continue;
            }

            Print("Slave[", SlaveID, "]: Signal JSON: ", msgJson);
            string action = CSimpleJSON::ExtractString(msgJson, "action");
            if (action == "")
            {
                Print("Slave[", SlaveID, "]: No 'action' field – not a trade signal: ", msgJson);
                continue;
            }

            ExecuteTrade(action,
                CSimpleJSON::ExtractString(msgJson, "symbol"),
                CSimpleJSON::ExtractString(msgJson, "type"),
                CSimpleJSON::ExtractNumber(msgJson, "entry"),
                CSimpleJSON::ExtractNumber(msgJson, "sl"),
                CSimpleJSON::ExtractNumber(msgJson, "tp"),
                CSimpleJSON::ExtractNumber(msgJson, "volume"),
                CSimpleJSON::ExtractUlong(msgJson, "ticket"),
                CSimpleJSON::ExtractUlong(msgJson, "magic"));
        }
    }
};

//+------------------------------------------------------------------+
CTelegramClient     tgClient;
CTelegramClient     slaveClient;
CSymbolMapper       symMapper;
CMasterTradeMonitor masterMonitor;
CSlaveTradeExecutor slaveExecutor;

//+------------------------------------------------------------------+
int OnInit()
{
    if (CopierMode == MODE_MASTER)
    {
        tgClient.Initialize(TelegramBotToken, TelegramChatID);
        masterMonitor.Initialize(&tgClient);
        EventSetTimer(1);
    }
    else
    {
        // SlaveBotToken is optional. If left empty, TelegramBotToken is reused
        // for polling. All Slaves on any computer can share the same polling
        // token (whether SlaveBotToken or the fallback TelegramBotToken) – no
        // getUpdates call ever sends an offset, so each Slave independently
        // reads the full pending update list and filters it locally by its own
        // cursor.
        string pollToken = (SlaveBotToken != "") ? SlaveBotToken : TelegramBotToken;
        Print("Slave[", SlaveID, "]: Polling with token prefix '",
            StringSubstr(pollToken, 0, 10), "...'");
        slaveClient.Initialize(pollToken, TelegramChatID);
        symMapper.Initialize(SymbolMappingList);
        slaveExecutor.Initialize(&slaveClient, &symMapper);
        EventSetTimer(2);
    }
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    EventKillTimer();
}

//+------------------------------------------------------------------+
void OnTimer()
{
    if (CopierMode == MODE_MASTER)
        masterMonitor.OnTimerEvent();
    else
        slaveExecutor.OnTimerEvent();
}
//+------------------------------------------------------------------+
