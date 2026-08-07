//+------------------------------------------------------------------+
//|                                              TelegramCopier.mq5  |
//|                 Master-Slave Trade Copier via Telegram Bridge    |
//+------------------------------------------------------------------+
#property copyright "Gemini"
//+------------------------------------------------------------------+
//| ARCHITECTURE                                                     |
//|                                                                  |
//| Master : sends every trade signal as a JSON message to a         |
//|          Telegram channel using MasterTelegramBotToken.          |
//|                                                                  |
//| Slave  : polls the same channel using SlaveTelegramBotToken (falling|
//|          back to MasterTelegramBotToken if SlaveTelegramBotToken is left|
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
//|          Global Variable (keyed by SlaveInstanceID), skipping anything|
//|          it has already processed. This is what prevents a      |
//|          Slave from re-executing a signal it already handled.    |
//|                                                                  |
//|          All Slaves can share ONE SlaveTelegramBotToken (or none, in|
//|          which case MasterTelegramBotToken is reused for polling).|
//|          Because no getUpdates call ever advances Telegram's own |
//|          server-side offset, there is no race between Slaves:    |
//|          each one independently sees, and locally filters, the   |
//|          same pending update list.                                |
//|                                                                  |
//| SlaveInstanceID: MUST be unique per Slave instance ("1","2","NY", ...).|
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
input ENUM_COPIER_MODE SystemCopierMode = MODE_MASTER;
// Master uses MasterTelegramBotToken to SEND signals to the channel.
// Slave uses SlaveTelegramBotToken to READ signals from the channel.
// Both bots must be members/admins of the same channel.
input string          MasterTelegramBotToken = "8803974844:AAHO24wtCBeEhUarInOj_M5LEKON-fp2VFs";
input string          SlaveTelegramBotToken = "8953861635:AAEmAl0SJtitcXXicyZ9IhJ4USc5lfYJ4IE";
input string          TargetTelegramChatID = "-1004483905925";
input bool            IsCopyingEnabled = true;
// Each Slave instance MUST have a unique SlaveInstanceID so that their own
// last-seen update_id cursor in Global Variables never collides.
// The Master ignores this value.
input string          SlaveInstanceID = "1";  // Unique ID for this Slave instance

input group "=== Risk & Execution (Slave Only) ==="
input double VolumeMultiplier = 1.0;
input bool   UseFixedVolumeMode = false;
input double FixedVolumeSize = 0.01;
input double MinimumVolume = 0.01;
input double MaximumVolume = 10.0;
input ulong  MaximumSlippagePoints = 10;

input group "=== Symbol Conversion System (Slave Only) ==="
// --- Method A: Automatic Prefix/Suffix conversion -------------------
// The Slave strips MasterSymbolPrefix/MasterSymbolSuffix off the incoming Master
// symbol, then adds SlaveSymbolPrefix/SlaveSymbolSuffix, to derive the Slave symbol.
// Example: MasterSymbolSuffix=".m", SlaveSymbolSuffix=".pro"  =>  EURUSD.m -> EURUSD.pro
input string MasterSymbolPrefix = "";     // Prefix used by the Master broker (e.g. "")
input string MasterSymbolSuffix = ".m";   // Suffix used by the Master broker (e.g. ".m")
input string SlaveSymbolPrefix = "";     // Prefix used by THIS (Slave) broker
input string SlaveSymbolSuffix = ".pro"; // Suffix used by THIS (Slave) broker

// --- Method B: Explicit symbol-to-symbol mapping --------------------
// Unlimited number of "MASTER=SLAVE" mappings, one per line (commas are
// also accepted as separators). Exact matches here ALWAYS take priority
// over the automatic Prefix/Suffix conversion above - use this for
// symbols whose name genuinely differs between brokers (indices, CFDs,
// crypto, etc.) where no simple prefix/suffix rule applies.
// Example:
//   GER40=DE40
//   US30=DJI30
//   XBRUSD=UKOIL
//   BTCUSD=BTCUSDT
input string ExplicitSymbolMappingList = "GER40=DE40,US30=DJI30,XBRUSD=UKOIL,BTCUSD=BTCUSDT";

//+------------------------------------------------------------------+
struct STrackedTrade
{
    ulong             orderTicket;
    string            tradeSymbol;
    string            orderType;
    double            tradeVolume;
    double            stopLossPrice;
    double            takeProfitPrice;
    double            openPrice;
    ulong             magicNumber;
};

CTrade        tradeExecutor;
CPositionInfo positionInformation;
CSymbolInfo   symbolInformation;

//+------------------------------------------------------------------+
//| Helper Class: JSON Builder & Parser                              |
//+------------------------------------------------------------------+
class CSimpleJSON
{
public:
    static string  BuildMessage(string tradeAction, string tradeSymbol, string tradeType,
        double entryPrice, double stopLossPrice, double takeProfitPrice, double tradeVolume,
        ulong orderTicket, ulong magicNumber)
    {
        string jsonPayload = "{";
        jsonPayload += "\"action\":\"" + tradeAction + "\",";
        jsonPayload += "\"symbol\":\"" + tradeSymbol + "\",";
        jsonPayload += "\"type\":\"" + tradeType + "\",";
        jsonPayload += "\"entry\":" + DoubleToString(entryPrice, 5) + ",";
        jsonPayload += "\"sl\":" + DoubleToString(stopLossPrice, 5) + ",";
        jsonPayload += "\"tp\":" + DoubleToString(takeProfitPrice, 5) + ",";
        jsonPayload += "\"volume\":" + DoubleToString(tradeVolume, 2) + ",";
        // Tickets/magic are ulong – encode as quoted strings to survive double round-trip.
        jsonPayload += "\"ticket\":\"" + IntegerToString(orderTicket) + "\",";
        jsonPayload += "\"magic\":\"" + IntegerToString(magicNumber) + "\"";
        jsonPayload += "}";
        return jsonPayload;
    }

    static string  ExtractString(string jsonPayload, string searchKeyName)
    {
        string formattedSearchKey = "\"" + searchKeyName + "\":\"";
        int startIndex = StringFind(jsonPayload, formattedSearchKey);
        if (startIndex < 0) return "";
        startIndex += StringLen(formattedSearchKey);
        int endIndex = StringFind(jsonPayload, "\"", startIndex);
        if (endIndex < 0)  return "";
        return StringSubstr(jsonPayload, startIndex, endIndex - startIndex);
    }

    static double  ExtractNumber(string jsonPayload, string searchKeyName)
    {
        string formattedSearchKey = "\"" + searchKeyName + "\":";
        int startIndex = StringFind(jsonPayload, formattedSearchKey);
        if (startIndex < 0) return 0.0;
        startIndex += StringLen(formattedSearchKey);
        int commaEndIndex = StringFind(jsonPayload, ",", startIndex);
        int braceEndIndex = StringFind(jsonPayload, "}", startIndex);
        int finalEndIndex = (commaEndIndex > 0 && (commaEndIndex < braceEndIndex || braceEndIndex < 0)) ? commaEndIndex : braceEndIndex;
        if (finalEndIndex < 0)  return 0.0;
        return StringToDouble(StringSubstr(jsonPayload, startIndex, finalEndIndex - startIndex));
    }

    // Find the real end of a JSON string value, respecting escaped quotes.
    // startingPosition must point to the first character after the opening quote.
    static bool    ExtractJSONStringValue(string jsonPayload, int startingPosition, string& extractedValue)
    {
        extractedValue = "";
        bool isCharacterEscaped = false;
        int  payloadLength = StringLen(jsonPayload);
        for (int charIndex = startingPosition; charIndex < payloadLength; charIndex++)
        {
            ushort currentCharacter = (ushort)StringGetCharacter(jsonPayload, charIndex);
            if (currentCharacter == '"' && !isCharacterEscaped)
            {
                extractedValue = StringSubstr(jsonPayload, startingPosition, charIndex - startingPosition);
                return true;
            }
            isCharacterEscaped = (currentCharacter == '\\' && !isCharacterEscaped);
        }
        return false;
    }

    // Extract a ulong stored as a quoted JSON string ("key":"NNN") or bare number.
    static ulong   ExtractUlong(string jsonPayload, string searchKeyName)
    {
        string stringValue = ExtractString(jsonPayload, searchKeyName);
        if (stringValue != "") return (ulong)StringToInteger(stringValue);
        // Fallback: bare numeric form
        string formattedSearchKey = "\"" + searchKeyName + "\":";
        int startIndex = StringFind(jsonPayload, formattedSearchKey);
        if (startIndex < 0) return 0;
        startIndex += StringLen(formattedSearchKey);
        int commaEndIndex = StringFind(jsonPayload, ",", startIndex);
        int braceEndIndex = StringFind(jsonPayload, "}", startIndex);
        int finalEndIndex = (commaEndIndex > 0 && (commaEndIndex < braceEndIndex || braceEndIndex < 0)) ? commaEndIndex : braceEndIndex;
        if (finalEndIndex < 0) return 0;
        return (ulong)StringToInteger(StringSubstr(jsonPayload, startIndex, finalEndIndex - startIndex));
    }
};

//+------------------------------------------------------------------+
//| CSymbolMapper - Symbol Conversion System                         |
//|                                                                  |
//| Converts an incoming Master symbol into the correct Slave symbol |
//| using two complementary methods, in strict priority order:       |
//|                                                                  |
//|   Step 1) Explicit symbol-to-symbol mapping (exact match).       |
//|           Always wins when present. Use for symbols whose name   |
//|           genuinely differs between brokers, e.g.:               |
//|              GER40=DE40, US30=DJI30, BTCUSD=BTCUSDT              |
//|                                                                  |
//|   Step 2) Automatic Prefix/Suffix conversion. Strips the         |
//|           Master's prefix/suffix off the symbol, then applies    |
//|           the Slave's own prefix/suffix, e.g.:                   |
//|              MasterSymbolSuffix=".m", SlaveSymbolSuffix=".pro"               |
//|              EURUSD.m -> EURUSD -> EURUSD.pro                    |
//|                                                                  |
//|   Step 3) Verify the resulting symbol actually exists in this    |
//|           broker's Market Watch before it is ever used to trade. |
//|                                                                  |
//| All trade-copying logic (open/modify/partial-close/close/manage) |
//| MUST call GetMappedSymbol() to obtain the Slave symbol before    |
//| touching the trade module - never trade on the raw Master symbol.|
//+------------------------------------------------------------------+
class CSymbolMapper
{
private:
    // Explicit mapping table: parallel arrays of Master -> Slave symbols.
    string masterSymbolArray[];
    string slaveSymbolArray[];
    int    mappingCount;

    // Prefix/Suffix conversion parameters.
    string internalMasterPrefix, internalMasterSuffix, internalSlavePrefix, internalSlaveSuffix;

    // Adds one explicit mapping pair, trimming whitespace and skipping
    // blank/incomplete entries.
    void  AddMapping(string sourceMasterSymbol, string targetSlaveSymbol)
    {
        StringTrimLeft(sourceMasterSymbol);  StringTrimRight(sourceMasterSymbol);
        StringTrimLeft(targetSlaveSymbol);   StringTrimRight(targetSlaveSymbol);
        if (sourceMasterSymbol == "" || targetSlaveSymbol == "") return;

        int newArraySize = mappingCount + 1;
        ArrayResize(masterSymbolArray, newArraySize);
        ArrayResize(slaveSymbolArray, newArraySize);
        masterSymbolArray[mappingCount] = sourceMasterSymbol;
        slaveSymbolArray[mappingCount] = targetSlaveSymbol;
        mappingCount++;
    }

    // Parses a block of "MASTER=SLAVE" pairs. Supports an UNLIMITED
    // number of mappings, one per line (newline-separated, the
    // documented/preferred format). Commas are also treated as
    // separators, which keeps the legacy single-line SymbolMappingList
    // format working unchanged (backward compatibility).
    void  ParseMappingBlock(string mappingBlockText)
    {
        if (mappingBlockText == "") return;
        StringReplace(mappingBlockText, "\r\n", ",");
        StringReplace(mappingBlockText, "\r", ",");
        StringReplace(mappingBlockText, "\n", ","); // still accept newlines if pasted

        string splitLinesArray[];
        int totalLines = StringSplit(mappingBlockText, ',', splitLinesArray);
        for (int lineIndex = 0; lineIndex < totalLines; lineIndex++)
        {
            string currentLineText = splitLinesArray[lineIndex];
            StringTrimLeft(currentLineText); StringTrimRight(currentLineText);
            if (currentLineText == "") continue;
            string symbolPairArray[];
            if (StringSplit(currentLineText, '=', symbolPairArray) == 2)
                AddMapping(symbolPairArray[0], symbolPairArray[1]);
            else
                Print("Slave: Ignoring malformed symbol mapping line: '", currentLineText, "'");
        }
    }

public:
    CSymbolMapper() { mappingCount = 0; }

    //-----------------------------------------------------------------
    // Initialize
    //   explicitMappingString : new "one mapping per line" MASTER=SLAVE list
    //                      (ExplicitSymbolMappingList input).
    //   legacyMappings   : old SymbolMappingList input value, merged in
    //                      for backward compatibility with existing
    //                      configurations.
    //   masterPrefixStr/masterSuffixStr  : Prefix/Suffix used by the MASTER broker -
    //                      stripped off the incoming symbol.
    //   slavePrefixStr/slaveSuffixStr  : Prefix/Suffix used by the SLAVE (this)
    //                      broker - appended after stripping.
    //-----------------------------------------------------------------
    void  Initialize(string explicitMappingString,
        string masterPrefixStr, string masterSuffixStr,
        string slavePrefixStr, string slaveSuffixStr)
    {
        mappingCount = 0;
        ArrayResize(masterSymbolArray, 0);
        ArrayResize(slaveSymbolArray, 0);

        ParseMappingBlock(explicitMappingString);

        internalMasterPrefix = masterPrefixStr;
        internalMasterSuffix = masterSuffixStr;
        internalSlavePrefix = slavePrefixStr;
        internalSlaveSuffix = slaveSuffixStr;

        Print("Slave: Symbol Conversion System initialized. ",
            mappingCount, " explicit mapping(s). MasterPrefix='", internalMasterPrefix,
            "' MasterSuffix='", internalMasterSuffix, "' SlavePrefix='", internalSlavePrefix,
            "' SlaveSuffix='", internalSlaveSuffix, "'");
    }

    //-----------------------------------------------------------------
    // FindExplicitMapping
    //   Explicit symbol mapping logic: exact, case-sensitive lookup of
    //   inputMasterSymbol in the mapping table. This ALWAYS takes priority
    //   over Prefix/Suffix conversion (see GetMappedSymbol below), since
    //   it is used precisely for symbols that don't follow a simple
    //   prefix/suffix rule (e.g. GER40 -> DE40).
    //-----------------------------------------------------------------
    bool  FindExplicitMapping(string inputMasterSymbol, string& outputSlaveSymbol)
    {
        for (int mappingIndex = 0; mappingIndex < mappingCount; mappingIndex++)
        {
            if (masterSymbolArray[mappingIndex] == inputMasterSymbol)
            {
                outputSlaveSymbol = slaveSymbolArray[mappingIndex];
                return true;
            }
        }
        return false;
    }

    //-----------------------------------------------------------------
    // ApplyPrefixSuffixConversion
    //   Prefix/Suffix replacement logic: removes the Master broker's
    //   prefix/suffix from inputMasterSymbol (if present) to recover the
    //   underlying "clean" symbol name, then applies the Slave broker's
    //   own prefix/suffix on top of it.
    //   Example: MasterSymbolSuffix=".m", SlaveSymbolSuffix=".pro"
    //            EURUSD.m -> EURUSD -> EURUSD.pro
    //-----------------------------------------------------------------
    string ApplyPrefixSuffixConversion(string inputMasterSymbol)
    {
        string coreSymbolName = inputMasterSymbol;

        // Remove Master prefix, if the symbol actually starts with it.
        if (internalMasterPrefix != "" && StringFind(coreSymbolName, internalMasterPrefix) == 0)
            coreSymbolName = StringSubstr(coreSymbolName, StringLen(internalMasterPrefix));

        // Remove Master suffix, if the symbol actually ends with it.
        if (internalMasterSuffix != "")
        {
            int suffixStartPosition = StringLen(coreSymbolName) - StringLen(internalMasterSuffix);
            if (suffixStartPosition >= 0 && StringSubstr(coreSymbolName, suffixStartPosition) == internalMasterSuffix)
                coreSymbolName = StringSubstr(coreSymbolName, 0, suffixStartPosition);
        }

        // Apply Slave prefix/suffix to the cleaned core symbol.
        return internalSlavePrefix + coreSymbolName + internalSlaveSuffix;
    }

    //-----------------------------------------------------------------
    // SymbolExists
    //   Verifies the resulting symbol actually exists / is tradable on
    //   this (Slave) broker, adding it to Market Watch if required.
    //-----------------------------------------------------------------
    bool  SymbolExists(string symbolToCheck)
    {
        if (symbolToCheck == "") return false;
        return SymbolSelect(symbolToCheck, true);
    }

    //-----------------------------------------------------------------
    // GetMappedSymbol - single entry point for ALL trade-copying logic.
    // Every incoming Master symbol MUST be passed through this function
    // before opening, modifying, closing, or otherwise managing a trade.
    //
    // Mapping priority order:
    //   Step 1: Explicit mapping list       (exact match - always wins)
    //   Step 2: Automatic Prefix/Suffix conversion (fallback)
    //   Step 3: Verify the resulting symbol exists in Market Watch
    //-----------------------------------------------------------------
    string GetMappedSymbol(string inputMasterSymbol)
    {
        string resolvedSlaveSymbol;

        // Step 1: explicit mapping has priority over prefix/suffix conversion.
        if (FindExplicitMapping(inputMasterSymbol, resolvedSlaveSymbol))
        {
            if (SymbolExists(resolvedSlaveSymbol))
                return resolvedSlaveSymbol;
            Print("Slave: Explicit mapping '", inputMasterSymbol, "' -> '", resolvedSlaveSymbol,
                "' not found in Market Watch on this broker.");
            return "";
        }

        // Step 2: no explicit mapping - fall back to automatic conversion.
        resolvedSlaveSymbol = ApplyPrefixSuffixConversion(inputMasterSymbol);

        // Step 3: verify the converted symbol actually exists here.
        if (SymbolExists(resolvedSlaveSymbol))
            return resolvedSlaveSymbol;

        // Last resort fallback: try the raw, unconverted Master symbol name
        // (helps when Master and Slave happen to share the same naming).
        if (SymbolExists(inputMasterSymbol))
            return inputMasterSymbol;

        Print("Slave: Symbol not found on this broker after conversion: '",
            inputMasterSymbol, "' -> '", resolvedSlaveSymbol, "'. Check MasterSymbolPrefix/",
            "MasterSymbolSuffix/SlaveSymbolPrefix/SlaveSymbolSuffix inputs or add an explicit ",
            "mapping in ExplicitSymbolMappingList.");
        return "";
    }

    // Backward-compatible alias for older code paths.
    string GetSlaveSymbol(string inputMasterSymbol) { return GetMappedSymbol(inputMasterSymbol); }
};

//+------------------------------------------------------------------+
//| CPersistentStorage                                               |
//| All keys are prefixed with SlaveInstanceID so each Slave instance has    |
//| its own independent namespace in MT5 Global Variables.           |
//+------------------------------------------------------------------+
class CPersistentStorage
{
    static string  Prefix() { return "TCopier_" + SlaveInstanceID + "_"; }
public:
    // Ticket mapping
    static void    SaveTicketMapping(ulong masterOrderTicket, ulong slaveOrderTicket)
    {
        GlobalVariableSet(Prefix() + IntegerToString(masterOrderTicket), (double)slaveOrderTicket);
    }
    static ulong   GetSlaveTicket(ulong masterOrderTicket)
    {
        string globalVariableName = Prefix() + IntegerToString(masterOrderTicket);
        return GlobalVariableCheck(globalVariableName) ? (ulong)GlobalVariableGet(globalVariableName) : 0;
    }
    static void    RemoveTicketMapping(ulong masterOrderTicket)
    {
        GlobalVariableDel(Prefix() + IntegerToString(masterOrderTicket));
    }

    // Last-seen update_id cursor – per Slave, per computer.
    // Never shared with other Slaves; never sent to Telegram as an
    // offset, so it never causes Telegram to purge updates.
    static void    SaveLastUpdateID(long updateIdentifier)
    {
        GlobalVariableSet(Prefix() + "LastUID", (double)updateIdentifier);
    }
    static long    GetLastUpdateID()
    {
        string globalVariableName = Prefix() + "LastUID";
        return GlobalVariableCheck(globalVariableName) ? (long)GlobalVariableGet(globalVariableName) : 0;
    }
};

//+------------------------------------------------------------------+
//| CTelegramClient                                                  |
//+------------------------------------------------------------------+
class CTelegramClient
{
private:
    string apiBaseUrl, botAuthenticationToken, targetChatIdentifier;
public:
    void     Initialize(string inputBotToken, string inputChatIdentifier)
    {
        botAuthenticationToken = inputBotToken;
        targetChatIdentifier = inputChatIdentifier;
        apiBaseUrl = "https://api.telegram.org/bot" + botAuthenticationToken;
    }

    string   UrlEncode(string rawStringValue)
    {
        string encodedStringValue = rawStringValue;
        StringReplace(encodedStringValue, "%", "%25");
        StringReplace(encodedStringValue, "\\", "%5C");
        StringReplace(encodedStringValue, "\"", "%22");
        StringReplace(encodedStringValue, "{", "%7B");
        StringReplace(encodedStringValue, "}", "%7D");
        StringReplace(encodedStringValue, ":", "%3A");
        StringReplace(encodedStringValue, ",", "%2C");
        StringReplace(encodedStringValue, "&", "%26");
        StringReplace(encodedStringValue, "=", "%3D");
        StringReplace(encodedStringValue, "+", "%2B");
        StringReplace(encodedStringValue, " ", "%20");
        return encodedStringValue;
    }

    bool     SendMessage(string messageText)
    {
        char postDataArray[], resultDataArray[];
        string responseHeaders;
        string requestUrl = apiBaseUrl + "/sendMessage?chat_id=" + targetChatIdentifier + "&text=" + UrlEncode(messageText);
        int httpResponseCode = WebRequest("GET", requestUrl, "", "", 5000, postDataArray, ArraySize(postDataArray), resultDataArray, responseHeaders);
        if (httpResponseCode == 200) return true;
        Print("Telegram Send Error: ", httpResponseCode);
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
        char postDataArray[], resultDataArray[];
        string responseHeaders;
        // No offset parameter is sent (equivalent to offset=0), so this
        // call never confirms/purges updates on Telegram's side. Every
        // Slave receives the full pending update list on every poll and
        // filters locally by its own lastUpdateId cursor.
        string requestUrl = apiBaseUrl + "/getUpdates?timeout=1&allowed_updates=%5B%22channel_post%22%5D";
        Print("Slave[", SlaveInstanceID, "]: GetUpdates (no offset – full pending list)");
        int httpResponseCode = WebRequest("GET", requestUrl, "", "", 5000, postDataArray, ArraySize(postDataArray), resultDataArray, responseHeaders);
        if (httpResponseCode != 200)
        {
            Print("Slave[", SlaveInstanceID, "]: GetUpdates HTTP error=", httpResponseCode,
                " (check WebRequest whitelist & SlaveTelegramBotToken)");
            return "";
        }
        string responseBodyString = CharArrayToString(resultDataArray, 0, WHOLE_ARRAY, CP_UTF8);
        Print("Slave[", SlaveInstanceID, "]: GetUpdates response -> ",
            (StringLen(responseBodyString) == 0 ? "(empty)" : responseBodyString));
        return responseBodyString;
    }
};

//+------------------------------------------------------------------+
//| CMasterTradeMonitor                                              |
//+------------------------------------------------------------------+
class CMasterTradeMonitor
{
private:
    CTelegramClient* telegramClientInstance;
    STrackedTrade    trackedTradesArray[];

    int   FindIndex(ulong searchTicket)
    {
        for (int tradeIndex = 0; tradeIndex < ArraySize(trackedTradesArray); tradeIndex++)
            if (trackedTradesArray[tradeIndex].orderTicket == searchTicket) return tradeIndex;
        return -1;
    }

public:
    void  Initialize(CTelegramClient* telegramClientInstancePtr)
    {
        telegramClientInstance = telegramClientInstancePtr;
        int totalOpenPositions = PositionsTotal();
        ArrayResize(trackedTradesArray, totalOpenPositions);
        for (int positionIndex = 0; positionIndex < totalOpenPositions; positionIndex++)
        {
            if (positionInformation.SelectByIndex(positionIndex))
            {
                trackedTradesArray[positionIndex].orderTicket = positionInformation.Ticket();
                trackedTradesArray[positionIndex].tradeSymbol = positionInformation.Symbol();
                trackedTradesArray[positionIndex].orderType = (positionInformation.PositionType() == POSITION_TYPE_BUY) ? "BUY" : "SELL";
                trackedTradesArray[positionIndex].tradeVolume = positionInformation.Volume();
                trackedTradesArray[positionIndex].stopLossPrice = positionInformation.StopLoss();
                trackedTradesArray[positionIndex].takeProfitPrice = positionInformation.TakeProfit();
                trackedTradesArray[positionIndex].openPrice = positionInformation.PriceOpen();
                trackedTradesArray[positionIndex].magicNumber = positionInformation.Magic();
            }
        }
    }

    void  OnTimerEvent()
    {
        if (!IsCopyingEnabled) return;

        int  totalCurrentPositions = PositionsTotal();
        int  totalTrackedTrades = ArraySize(trackedTradesArray);
        bool isActiveTradeArray[];
        ArrayResize(isActiveTradeArray, totalTrackedTrades);
        ArrayInitialize(isActiveTradeArray, false);

        // PHASE 1: Modifications & Partial Closes
        for (int loopIndex = 0; loopIndex < totalCurrentPositions; loopIndex++)
        {
            if (!positionInformation.SelectByIndex(loopIndex)) continue;
            ulong currentPositionTicket = positionInformation.Ticket();
            int   trackedTradeIndex = FindIndex(currentPositionTicket);
            if (trackedTradeIndex < 0) continue;

            isActiveTradeArray[trackedTradeIndex] = true;

            // Partial Close
            if (positionInformation.Volume() < trackedTradesArray[trackedTradeIndex].tradeVolume)
            {
                double closedVolumeAmount = trackedTradesArray[trackedTradeIndex].tradeVolume - positionInformation.Volume();
                string jsonMessageString = CSimpleJSON::BuildMessage("PARTIAL_CLOSE",
                    positionInformation.Symbol(), trackedTradesArray[trackedTradeIndex].orderType,
                    positionInformation.PriceOpen(), positionInformation.StopLoss(),
                    positionInformation.TakeProfit(), closedVolumeAmount,
                    currentPositionTicket, positionInformation.Magic());
                if (telegramClientInstance.SendMessage(jsonMessageString))
                {
                    trackedTradesArray[trackedTradeIndex].tradeVolume = positionInformation.Volume();
                    Print("Master: PARTIAL_CLOSE sent. Tkt:", currentPositionTicket);
                }
            }

            // SL/TP Modification
            double symbolPointValue = SymbolInfoDouble(positionInformation.Symbol(), SYMBOL_POINT);
            if (MathAbs(positionInformation.StopLoss() - trackedTradesArray[trackedTradeIndex].stopLossPrice) > symbolPointValue ||
                MathAbs(positionInformation.TakeProfit() - trackedTradesArray[trackedTradeIndex].takeProfitPrice) > symbolPointValue)
            {
                string jsonMessageString = CSimpleJSON::BuildMessage("MODIFY",
                    positionInformation.Symbol(), trackedTradesArray[trackedTradeIndex].orderType,
                    positionInformation.PriceOpen(), positionInformation.StopLoss(),
                    positionInformation.TakeProfit(), positionInformation.Volume(),
                    currentPositionTicket, positionInformation.Magic());
                if (telegramClientInstance.SendMessage(jsonMessageString))
                {
                    trackedTradesArray[trackedTradeIndex].stopLossPrice = positionInformation.StopLoss();
                    trackedTradesArray[trackedTradeIndex].takeProfitPrice = positionInformation.TakeProfit();
                    Print("Master: MODIFY sent. Tkt:", currentPositionTicket);
                }
            }
        }

        // PHASE 2: Closed Trades
        for (int loopIndex = totalTrackedTrades - 1; loopIndex >= 0; loopIndex--)
        {
            if (!isActiveTradeArray[loopIndex])
            {
                string jsonMessageString = CSimpleJSON::BuildMessage("CLOSE",
                    trackedTradesArray[loopIndex].tradeSymbol, trackedTradesArray[loopIndex].orderType,
                    trackedTradesArray[loopIndex].openPrice, trackedTradesArray[loopIndex].stopLossPrice, trackedTradesArray[loopIndex].takeProfitPrice,
                    trackedTradesArray[loopIndex].tradeVolume, trackedTradesArray[loopIndex].orderTicket, trackedTradesArray[loopIndex].magicNumber);
                if (telegramClientInstance.SendMessage(jsonMessageString))
                {
                    Print("Master: CLOSE sent. Tkt:", trackedTradesArray[loopIndex].orderTicket);
                    for (int shiftIndex = loopIndex; shiftIndex < ArraySize(trackedTradesArray) - 1; shiftIndex++)
                        trackedTradesArray[shiftIndex] = trackedTradesArray[shiftIndex + 1];
                    ArrayResize(trackedTradesArray, ArraySize(trackedTradesArray) - 1);
                }
            }
        }

        // PHASE 3: New Trades
        for (int loopIndex = 0; loopIndex < totalCurrentPositions; loopIndex++)
        {
            if (!positionInformation.SelectByIndex(loopIndex)) continue;
            ulong currentPositionTicket = positionInformation.Ticket();
            if (FindIndex(currentPositionTicket) >= 0) continue;

            string positionTypeString = (positionInformation.PositionType() == POSITION_TYPE_BUY) ? "BUY" : "SELL";
            string jsonMessageString = CSimpleJSON::BuildMessage("OPEN",
                positionInformation.Symbol(), positionTypeString,
                positionInformation.PriceOpen(), positionInformation.StopLoss(),
                positionInformation.TakeProfit(), positionInformation.Volume(),
                currentPositionTicket, positionInformation.Magic());
            if (telegramClientInstance.SendMessage(jsonMessageString))
            {
                int newArraySize = ArraySize(trackedTradesArray) + 1;
                ArrayResize(trackedTradesArray, newArraySize);
                trackedTradesArray[newArraySize - 1].orderTicket = currentPositionTicket;
                trackedTradesArray[newArraySize - 1].tradeSymbol = positionInformation.Symbol();
                trackedTradesArray[newArraySize - 1].orderType = positionTypeString;
                trackedTradesArray[newArraySize - 1].tradeVolume = positionInformation.Volume();
                trackedTradesArray[newArraySize - 1].stopLossPrice = positionInformation.StopLoss();
                trackedTradesArray[newArraySize - 1].takeProfitPrice = positionInformation.TakeProfit();
                trackedTradesArray[newArraySize - 1].openPrice = positionInformation.PriceOpen();
                trackedTradesArray[newArraySize - 1].magicNumber = positionInformation.Magic();
                Print("Master: OPEN sent. Tkt:", currentPositionTicket);
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
    CTelegramClient* telegramClientInstance;
    CSymbolMapper* symbolMapperInstance;
    long             lastProcessedUpdateIdentifier;  // this Slave's own cursor – never shared, never sent to Telegram as an offset

    double  CalculateLot(double masterVolume)
    {
        double calculatedVolume = UseFixedVolumeMode ? FixedVolumeSize : (masterVolume * VolumeMultiplier);
        if (calculatedVolume < MinimumVolume) calculatedVolume = MinimumVolume;
        if (calculatedVolume > MaximumVolume) calculatedVolume = MaximumVolume;
        return NormalizeDouble(calculatedVolume, 2);
    }

    void  ExecuteTrade(string tradeActionType, string masterSymbolName, string tradeType,
        double entryPrice, double stopLossPrice, double takeProfitPrice, double tradeVolume,
        ulong masterOrderTicket, ulong magicNumber)
    {
        Print("Slave[", SlaveInstanceID, "]: ExecuteTrade -> action=", tradeActionType,
            " sym=", masterSymbolName, " type=", tradeType,
            " entry=", entryPrice, " sl=", stopLossPrice, " tp=", takeProfitPrice, " vol=", tradeVolume,
            " masterTkt=", masterOrderTicket, " magic=", magicNumber);

        // Every incoming Master symbol MUST pass through the Symbol
        // Conversion System before any trade action (open/modify/
        // partial-close/close) is taken.
        string resolvedSlaveSymbol = symbolMapperInstance.GetMappedSymbol(masterSymbolName);
        if (resolvedSlaveSymbol == "")
        {
            Print("Slave[", SlaveInstanceID, "]: Rejected – could not resolve Slave symbol for '", masterSymbolName, "'");
            return;
        }

        tradeExecutor.SetExpertMagicNumber(magicNumber);
        tradeExecutor.SetDeviationInPoints(MaximumSlippagePoints);

        int    symbolPriceDigits = (int)SymbolInfoInteger(resolvedSlaveSymbol, SYMBOL_DIGITS);
        double normalizedSlaveStopLoss = (stopLossPrice > 0.0) ? NormalizeDouble(stopLossPrice, symbolPriceDigits) : 0.0;
        double normalizedSlaveTakeProfit = (takeProfitPrice > 0.0) ? NormalizeDouble(takeProfitPrice, symbolPriceDigits) : 0.0;

        if (tradeActionType == "OPEN")
        {
            if (CPersistentStorage::GetSlaveTicket(masterOrderTicket) > 0)
            {
                Print("Slave[", SlaveInstanceID, "]: OPEN skipped – duplicate masterTicket ", masterOrderTicket);
                return;
            }
            double executionVolume = CalculateLot(tradeVolume);
            Print("Slave[", SlaveInstanceID, "]: Opening ", tradeType, " ", executionVolume,
                " lots of ", resolvedSlaveSymbol, " SL=", normalizedSlaveStopLoss, " TP=", normalizedSlaveTakeProfit);
            if (tradeType == "BUY" && tradeExecutor.Buy(executionVolume, resolvedSlaveSymbol, 0, normalizedSlaveStopLoss, normalizedSlaveTakeProfit))
                CPersistentStorage::SaveTicketMapping(masterOrderTicket, tradeExecutor.ResultOrder());
            else if (tradeType == "SELL" && tradeExecutor.Sell(executionVolume, resolvedSlaveSymbol, 0, normalizedSlaveStopLoss, normalizedSlaveTakeProfit))
                CPersistentStorage::SaveTicketMapping(masterOrderTicket, tradeExecutor.ResultOrder());
            else
                Print("Slave[", SlaveInstanceID, "]: Order failed – retcode=", tradeExecutor.ResultRetcode(),
                    " comment=", tradeExecutor.ResultComment());
        }
        else if (tradeActionType == "MODIFY")
        {
            ulong slaveOrderTicket = CPersistentStorage::GetSlaveTicket(masterOrderTicket);
            Print("Slave[", SlaveInstanceID, "]: MODIFY slaveTkt=", slaveOrderTicket,
                " SL=", normalizedSlaveStopLoss, " TP=", normalizedSlaveTakeProfit);
            if (slaveOrderTicket > 0)
                tradeExecutor.PositionModify(slaveOrderTicket, normalizedSlaveStopLoss, normalizedSlaveTakeProfit);
            else
                Print("Slave[", SlaveInstanceID, "]: MODIFY skipped – no ticket for masterTicket ", masterOrderTicket);
        }
        else if (tradeActionType == "PARTIAL_CLOSE")
        {
            ulong slaveOrderTicket = CPersistentStorage::GetSlaveTicket(masterOrderTicket);
            Print("Slave[", SlaveInstanceID, "]: PARTIAL_CLOSE slaveTkt=", slaveOrderTicket,
                " lot=", CalculateLot(tradeVolume));
            if (slaveOrderTicket > 0)
                tradeExecutor.PositionClosePartial(slaveOrderTicket, CalculateLot(tradeVolume));
            else
                Print("Slave[", SlaveInstanceID, "]: PARTIAL_CLOSE skipped – no ticket for masterTicket ", masterOrderTicket);
        }
        else if (tradeActionType == "CLOSE")
        {
            ulong slaveOrderTicket = CPersistentStorage::GetSlaveTicket(masterOrderTicket);
            Print("Slave[", SlaveInstanceID, "]: CLOSE slaveTkt=", slaveOrderTicket);
            if (slaveOrderTicket > 0 && tradeExecutor.PositionClose(slaveOrderTicket))
                CPersistentStorage::RemoveTicketMapping(masterOrderTicket);
            else if (slaveOrderTicket == 0)
                Print("Slave[", SlaveInstanceID, "]: CLOSE skipped – no ticket for masterTicket ", masterOrderTicket);
            else
                Print("Slave[", SlaveInstanceID, "]: CLOSE failed – retcode=", tradeExecutor.ResultRetcode());
        }
        else
            Print("Slave[", SlaveInstanceID, "]: Unknown action '", tradeActionType, "' – ignored");
    }

    // Parse one update object from the getUpdates response.
    // Returns the signal JSON string if a valid channel_post is found,
    // otherwise returns "".
    string  ParseUpdateForSignal(string jsonResponseString, int updateIdKeyPosition, int nextUpdateKeyPosition)
    {
        // The channel_post key must appear after this update's update_id value
        // and before the next update_id (i.e. within this update's JSON object).
        int channelPostKeyPosition = StringFind(jsonResponseString, "\"channel_post\":", updateIdKeyPosition);
        if (channelPostKeyPosition < 0) return "";
        if (nextUpdateKeyPosition >= 0 && channelPostKeyPosition >= nextUpdateKeyPosition) return "";

        int textKeyPosition = StringFind(jsonResponseString, "\"text\":\"", channelPostKeyPosition);
        if (textKeyPosition < 0) return "";
        if (nextUpdateKeyPosition >= 0 && textKeyPosition >= nextUpdateKeyPosition) return "";

        string extractedMessageJson;
        if (!CSimpleJSON::ExtractJSONStringValue(jsonResponseString, textKeyPosition + 8, extractedMessageJson)) return "";
        StringReplace(extractedMessageJson, "\\\"", "\"");
        return extractedMessageJson;
    }

public:
    void  Initialize(CTelegramClient* telegramClientInstancePtr, CSymbolMapper* symbolMapperInstancePtr)
    {
        telegramClientInstance = telegramClientInstancePtr;
        symbolMapperInstance = symbolMapperInstancePtr;
        // Restore this Slave's own cursor from its namespaced Global Variable.
        // This cursor is used ONLY for local filtering – it is never sent to
        // Telegram as a getUpdates offset.
        lastProcessedUpdateIdentifier = CPersistentStorage::GetLastUpdateID();
        Print("Slave[", SlaveInstanceID, "]: Initialized. lastUpdateId=", lastProcessedUpdateIdentifier);
    }

    void  OnTimerEvent()
    {
        if (!IsCopyingEnabled) return;

        // Call GetUpdates WITHOUT any offset. Telegram will therefore return
        // the full list of currently pending updates (up to 100, retained for
        // up to 24h) instead of only "new" ones, and it will NOT purge/confirm
        // anything on its side. Each Slave then filters this full list locally
        // against its own lastUpdateId cursor below, so every Slave (whether
        // using a shared SlaveTelegramBotToken or none at all) independently sees and
        // acts on every signal exactly once, regardless of other Slaves'
        // progress.
        string jsonResponseString = telegramClientInstance.GetUpdates();
        if (jsonResponseString == "") return;

        int searchStartPosition = 0;
        while (true)
        {
            int updateIdKeyPosition = StringFind(jsonResponseString, "\"update_id\":", searchStartPosition);
            if (updateIdKeyPosition < 0) break;

            int digitStartPosition = updateIdKeyPosition + 12; // len("\"update_id\":") == 12

            int commaCharacterPosition = StringFind(jsonResponseString, ",", digitStartPosition);
            int braceCharacterPosition = StringFind(jsonResponseString, "}", digitStartPosition);
            int digitEndPosition;
            if (commaCharacterPosition < 0 && braceCharacterPosition < 0)
            {
                Print("Slave[", SlaveInstanceID, "]: Malformed response – no ',' or '}' after update_id");
                break;
            }
            else if (commaCharacterPosition < 0)  digitEndPosition = braceCharacterPosition;
            else if (braceCharacterPosition < 0)  digitEndPosition = commaCharacterPosition;
            else                   digitEndPosition = (commaCharacterPosition < braceCharacterPosition) ? commaCharacterPosition : braceCharacterPosition;

            long currentUpdateIdentifier = (long)StringToInteger(StringSubstr(jsonResponseString, digitStartPosition, digitEndPosition - digitStartPosition));
            searchStartPosition = digitEndPosition;  // advance past this update_id value for next iteration

            Print("Slave[", SlaveInstanceID, "]: update_id=", currentUpdateIdentifier, " lastUpdateId=", lastProcessedUpdateIdentifier);

            if (currentUpdateIdentifier <= lastProcessedUpdateIdentifier)
            {
                Print("Slave[", SlaveInstanceID, "]: Already processed update_id=", currentUpdateIdentifier, " – skipping");
                continue;
            }

            // This is a new update (per THIS Slave's local cursor only).
            // Update cursor immediately so even if ExecuteTrade fails we never
            // re-process this update_id. This cursor is local-only and is never
            // transmitted to Telegram, so it can never purge updates for other
            // Slaves.
            lastProcessedUpdateIdentifier = currentUpdateIdentifier;
            CPersistentStorage::SaveLastUpdateID(lastProcessedUpdateIdentifier);

            int nextUpdateKeyPosition = StringFind(jsonResponseString, "\"update_id\":", searchStartPosition);
            string extractedMessageJson = ParseUpdateForSignal(jsonResponseString, updateIdKeyPosition, nextUpdateKeyPosition);

            if (extractedMessageJson == "")
            {
                Print("Slave[", SlaveInstanceID, "]: update_id=", currentUpdateIdentifier,
                    " – no channel_post signal found, skipping");
                continue;
            }

            Print("Slave[", SlaveInstanceID, "]: Signal JSON: ", extractedMessageJson);
            string extractedTradeAction = CSimpleJSON::ExtractString(extractedMessageJson, "action");
            if (extractedTradeAction == "")
            {
                Print("Slave[", SlaveInstanceID, "]: No 'action' field – not a trade signal: ", extractedMessageJson);
                continue;
            }

            ExecuteTrade(extractedTradeAction,
                CSimpleJSON::ExtractString(extractedMessageJson, "symbol"),
                CSimpleJSON::ExtractString(extractedMessageJson, "type"),
                CSimpleJSON::ExtractNumber(extractedMessageJson, "entry"),
                CSimpleJSON::ExtractNumber(extractedMessageJson, "sl"),
                CSimpleJSON::ExtractNumber(extractedMessageJson, "tp"),
                CSimpleJSON::ExtractNumber(extractedMessageJson, "volume"),
                CSimpleJSON::ExtractUlong(extractedMessageJson, "ticket"),
                CSimpleJSON::ExtractUlong(extractedMessageJson, "magic"));
        }
    }
};

//+------------------------------------------------------------------+
CTelegramClient     masterTelegramClient;
CTelegramClient     slaveTelegramClient;
CSymbolMapper       globalSymbolMapper;
CMasterTradeMonitor globalMasterMonitor;
CSlaveTradeExecutor globalSlaveExecutor;

//+------------------------------------------------------------------+
int OnInit()
{
    if (SystemCopierMode == MODE_MASTER)
    {
        masterTelegramClient.Initialize(MasterTelegramBotToken, TargetTelegramChatID);
        globalMasterMonitor.Initialize(&masterTelegramClient);
        EventSetTimer(1);
    }
    else
    {
        // SlaveTelegramBotToken is not optional. Try to use another bot token
        // for polling. All Slaves on any computer can share the same polling
        // token (whether SlaveTelegramBotToken or the fallback MasterTelegramBotToken) – no
        // getUpdates call ever sends an offset, so each Slave independently
        // reads the full pending update list and filters it locally by its own
        // cursor.
        string activePollingToken = (SlaveTelegramBotToken != "") ? SlaveTelegramBotToken : MasterTelegramBotToken;
        Print("Slave[", SlaveInstanceID, "]: Polling with token prefix '",
            StringSubstr(activePollingToken, 0, 10), "...'");
        slaveTelegramClient.Initialize(activePollingToken, TargetTelegramChatID);
        // Initialize the Symbol Conversion System: explicit mapping list
        // (new + legacy, merged) plus Master/Slave prefix & suffix rules.
        globalSymbolMapper.Initialize(ExplicitSymbolMappingList,
            MasterSymbolPrefix, MasterSymbolSuffix,
            SlaveSymbolPrefix, SlaveSymbolSuffix);
        globalSlaveExecutor.Initialize(&slaveTelegramClient, &globalSymbolMapper);
        EventSetTimer(2);
    }
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int deinitializationReason)
{
    EventKillTimer();
}

//+------------------------------------------------------------------+
void OnTimer()
{
    if (SystemCopierMode == MODE_MASTER)
        globalMasterMonitor.OnTimerEvent();
    else
        globalSlaveExecutor.OnTimerEvent();
}
//+------------------------------------------------------------------+