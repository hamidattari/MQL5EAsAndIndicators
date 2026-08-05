//+------------------------------------------------------------------+
//|                                                CopierSlave.mq5  |
//|            Trade Copier – SLAVE side (HTTP relay from VPS)      |
//+------------------------------------------------------------------+
// Continuously long-polls the TradeCopierServer for trade commands
// and executes them on this account (copy broker).
//
// Requirements
// ────────────
// 1. MT5 menu Tools ► Options ► Expert Advisors ► Allow WebRequest for:
//       http://<VPS_IP>:5000
// 2. AutoTrading must be enabled (green button in toolbar).
// 3. TradeCopierServer must be running on the VPS.
// 4. ServerUrl and AuthToken must match appsettings.json on the VPS.
//+------------------------------------------------------------------+
#property copyright "TradeCopier"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

// ── Input parameters ──────────────────────────────────────────────
input group "=== Server Connection ==="
input string ServerUrl = "http://195.248.240.96:5000"; // VPS IP:port (no trailing slash)
input string AuthToken = "CHANGE_ME";
// Unique ID for this slave. Every slave on every machine MUST have a different
// value — the server uses this to maintain a separate queue per slave so that
// ALL slaves receive every trade command (fan-out).
// Suggested: use your broker account number, e.g. "12345678"
input string SlaveID = "slave1";
input bool   EnableCopying = true;

input group "=== Risk & Execution ==="
input double LotMultiplier = 1.0;    // Slave lot = Master lot × this
input bool   FixedLotMode = false;  // If true, always use FixedLotSize
input double FixedLotSize = 0.01;
input double MinLot = 0.01;
input double MaxLot = 10.0;
input ulong  MaxSlippage = 10;

input group "=== Symbol Mapping ==="
// ── Tier 1: Explicit map ──────────────────────────────────────────
// Comma-separated MASTER=SLAVE pairs checked first, before any
// automatic rules. Example: EURUSD=EURUSD.a,XAUUSD=GOLD
// Leave blank to rely on the automatic tiers below.
input string SymbolMappingList = "";

// ── Tier 2: Prefix / Suffix swap ─────────────────────────────────
// If the master symbol carries a broker prefix or suffix, strip it
// and add this broker's own prefix/suffix.
// Example: master sends "eURUSD", MasterPrefix="e", SlavePrefix=""
//          → strips "e", result "UUSD"… so set both correctly.
// Leave blank if your broker uses no prefix/suffix.
input string MasterPrefix = "";   // Prefix on master symbols  (e.g. "m.")
input string MasterSuffix = "";   // Suffix on master symbols  (e.g. ".r")
input string SlavePrefix = "";   // Prefix to add on slave    (e.g. "")
input string SlaveSuffix = "";   // Suffix to add on slave    (e.g. ".ec")

// ── Tier 3: Alias map ─────────────────────────────────────────────
// For symbols whose base name differs between brokers (e.g. gold is
// "XAUUSD" on master but "GOLD" on slave).
// Format: comma-separated MASTERBASE=SLAVEBASE pairs applied AFTER
// the prefix/suffix has been stripped from the master symbol.
// Example: XAUUSD=GOLD,XAGUSD=SILVER
input string AliasMapList = "";   // e.g. "XAUUSD=GOLD,XAGUSD=SILVER"

// ── Globals ───────────────────────────────────────────────────────
CTrade        tradeExecutor;
CPositionInfo positionInfo;

// Tier-1 explicit mapping table
string explicitMasterSymbols[];
string explicitSlaveSymbols[];
int    explicitMappingCount = 0;

// Tier-3 alias table (base name substitutions)
string aliasMasterSymbols[];
string aliasSlaveSymbols[];
int    aliasMappingCount = 0;

//+------------------------------------------------------------------+
//| Resolve a master symbol to its slave equivalent                 |
//|                                                                  |
//| Resolution order:                                               |
//|  1. Explicit map  (SymbolMappingList) – exact master→slave      |
//|  2. Prefix/suffix swap + alias        (Tier 2 + Tier 3)         |
//|  3. Bare symbol as-is on slave broker (SymbolSelect check)       |
//+------------------------------------------------------------------+
string ResolveSlaveSymbol(string masterSymbol)
{
    // ── Tier 1: explicit map ──────────────────────────────────────
    for (int mappingIndex = 0; mappingIndex < explicitMappingCount; mappingIndex++)
        if (explicitMasterSymbols[mappingIndex] == masterSymbol)
        {
            Print("Slave: Symbol map (explicit): ", masterSymbol, " → ", explicitSlaveSymbols[mappingIndex]);
            return explicitSlaveSymbols[mappingIndex];
        }

    // ── Tier 2: strip master prefix/suffix to get the base name ──
    string baseSymbol = masterSymbol;
    if (MasterPrefix != "" && StringFind(baseSymbol, MasterPrefix) == 0)
        baseSymbol = StringSubstr(baseSymbol, StringLen(MasterPrefix));
    if (MasterSuffix != "")
    {
        int suffixPosition = StringLen(baseSymbol) - StringLen(MasterSuffix);
        if (suffixPosition > 0 && StringSubstr(baseSymbol, suffixPosition) == MasterSuffix)
            baseSymbol = StringSubstr(baseSymbol, 0, suffixPosition);
    }

    // ── Tier 3: alias substitution on the base name ───────────────
    string slaveBaseSymbol = baseSymbol;
    for (int mappingIndex = 0; mappingIndex < aliasMappingCount; mappingIndex++)
        if (aliasMasterSymbols[mappingIndex] == baseSymbol)
        {
            slaveBaseSymbol = aliasSlaveSymbols[mappingIndex];
            break;
        }

    // Re-attach slave broker's own prefix/suffix
    string candidateSymbol = SlavePrefix + slaveBaseSymbol + SlaveSuffix;

    if (SymbolSelect(candidateSymbol, true))
    {
        Print("Slave: Symbol map (auto): ", masterSymbol, " → ", candidateSymbol);
        return candidateSymbol;
    }

    // ── Fallback: try the master symbol exactly as received ───────
    if (SymbolSelect(masterSymbol, true))
    {
        Print("Slave: Symbol map (passthrough): ", masterSymbol);
        return masterSymbol;
    }

    Print("Slave: Symbol not found for master='", masterSymbol,
        "' candidate='", candidateSymbol,
        "' – check SymbolMappingList, Prefix/Suffix, or AliasMapList inputs");
    return "";
}

//+------------------------------------------------------------------+
//| Parse a "KEY=VALUE,KEY=VALUE" string into two parallel arrays   |
//+------------------------------------------------------------------+
void ParseKeyValuePairs(string sourceString, string& outKeys[], string& outValues[], int& outCount)
{
    outCount = 0;
    ArrayResize(outKeys, 0);
    ArrayResize(outValues, 0);
    if (sourceString == "")
        return;
    string pairTokens[];
    int pairCount = StringSplit(sourceString, ',', pairTokens);
    for (int pairIndex = 0; pairIndex < pairCount; pairIndex++)
    {
        string keyValueTokens[];
        if (StringSplit(pairTokens[pairIndex], '=', keyValueTokens) == 2)
        {
            ArrayResize(outKeys, outCount + 1);
            ArrayResize(outValues, outCount + 1);
            outKeys[outCount] = keyValueTokens[0];
            outValues[outCount] = keyValueTokens[1];
            outCount++;
        }
    }
}

//+------------------------------------------------------------------+
//| Initialise all mapping tables                                   |
//+------------------------------------------------------------------+
void InitializeSymbolMappings()
{
    // Tier-1 explicit map
    ParseKeyValuePairs(SymbolMappingList, explicitMasterSymbols, explicitSlaveSymbols, explicitMappingCount);
    Print("Slave: Explicit map entries: ", explicitMappingCount);

    // Tier-3 alias map
    ParseKeyValuePairs(AliasMapList, aliasMasterSymbols, aliasSlaveSymbols, aliasMappingCount);
    Print("Slave: Alias map entries:    ", aliasMappingCount);

    // Log prefix/suffix config
    Print("Slave: Prefix/Suffix  master='", MasterPrefix, "' + base + '", MasterSuffix,
        "'  →  slave='", SlavePrefix, "' + base + '", SlaveSuffix, "'");
}

//+------------------------------------------------------------------+
//| Lot size calculation                                             |
//+------------------------------------------------------------------+
double CalculateLotSize(double masterVolume)
{
    double calculatedLot = FixedLotMode ? FixedLotSize : (masterVolume * LotMultiplier);
    calculatedLot = MathMax(MinLot, MathMin(MaxLot, calculatedLot));
    return NormalizeDouble(calculatedLot, 2);
}

//+------------------------------------------------------------------+
//| Persistent ticket mapping via Global Variables                  |
//+------------------------------------------------------------------+
void SaveTicketMapping(ulong masterTicket, ulong slaveTicket)
{
    GlobalVariableSet("TC2_" + IntegerToString(masterTicket), (double)slaveTicket);
}

ulong GetSlaveTicket(ulong masterTicket)
{
    string globalVarKey = "TC2_" + IntegerToString(masterTicket);
    return GlobalVariableCheck(globalVarKey) ? (ulong)GlobalVariableGet(globalVarKey) : 0;
}

void DeleteTicketMapping(ulong masterTicket)
{
    GlobalVariableDel("TC2_" + IntegerToString(masterTicket));
}

//+------------------------------------------------------------------+
//| Simple JSON string extractor (key with string value)            |
//+------------------------------------------------------------------+
string ExtractJsonString(string jsonString, string targetKey)
{
    string searchPattern = "\"" + targetKey + "\":\"";
    int startIndex = StringFind(jsonString, searchPattern);
    if (startIndex < 0) return "";
    startIndex += StringLen(searchPattern);
    int endIndex = StringFind(jsonString, "\"", startIndex);
    return (endIndex > startIndex) ? StringSubstr(jsonString, startIndex, endIndex - startIndex) : "";
}

//+------------------------------------------------------------------+
//| Simple JSON number extractor                                    |
//+------------------------------------------------------------------+
double ExtractJsonNumber(string jsonString, string targetKey)
{
    string searchPattern = "\"" + targetKey + "\":";
    int startIndex = StringFind(jsonString, searchPattern);
    if (startIndex < 0) return 0.0;
    startIndex += StringLen(searchPattern);
    int commaIndex = StringFind(jsonString, ",", startIndex);
    int braceIndex = StringFind(jsonString, "}", startIndex);
    int endIndex = (commaIndex > 0 && (commaIndex < braceIndex || braceIndex < 0)) ? commaIndex : braceIndex;
    return (endIndex > startIndex) ? StringToDouble(StringSubstr(jsonString, startIndex, endIndex - startIndex)) : 0.0;
}

//+------------------------------------------------------------------+
//| Execute one trade command from the relay server                 |
//+------------------------------------------------------------------+
void ExecuteTradeCommand(string jsonCommand)
{
    Print("Slave: Received command: ", jsonCommand);

    string actionType = ExtractJsonString(jsonCommand, "action");
    string masterSymbol = ExtractJsonString(jsonCommand, "symbol");
    string tradeType = ExtractJsonString(jsonCommand, "type");
    double entryPrice = ExtractJsonNumber(jsonCommand, "entry");
    double stopLoss = ExtractJsonNumber(jsonCommand, "sl");
    double takeProfit = ExtractJsonNumber(jsonCommand, "tp");
    double masterVolume = ExtractJsonNumber(jsonCommand, "volume");
    // masterTicket / magicNumber are quoted strings to preserve ulong precision
    ulong  masterTicket = (ulong)StringToInteger(ExtractJsonString(jsonCommand, "ticket"));
    ulong  magicNumber = (ulong)StringToInteger(ExtractJsonString(jsonCommand, "magic"));

    Print("Slave: action=", actionType, " sym=", masterSymbol, " type=", tradeType,
        " entry=", entryPrice, " sl=", stopLoss, " tp=", takeProfit, " vol=", masterVolume,
        " masterTicket=", masterTicket, " magic=", magicNumber);

    if (actionType == "" || masterSymbol == "")
    {
        Print("Slave: Command missing action or symbol – ignored");
        return;
    }

    string slaveSymbol = ResolveSlaveSymbol(masterSymbol);
    if (slaveSymbol == "")
        return;

    tradeExecutor.SetExpertMagicNumber(magicNumber);
    tradeExecutor.SetDeviationInPoints(MaxSlippage);

    int    priceDigits = (int)SymbolInfoInteger(slaveSymbol, SYMBOL_DIGITS);
    double slaveStopLoss = (stopLoss > 0.0) ? NormalizeDouble(stopLoss, priceDigits) : 0.0;
    double slaveTakeProfit = (takeProfit > 0.0) ? NormalizeDouble(takeProfit, priceDigits) : 0.0;

    if (actionType == "OPEN")
    {
        if (GetSlaveTicket(masterTicket) > 0)
        {
            Print("Slave: OPEN skipped – duplicate masterTicket=", masterTicket);
            return;
        }
        double executionLotSize = CalculateLotSize(masterVolume);
        Print("Slave: Placing ", tradeType, " ", executionLotSize, " lots of ", slaveSymbol,
            " SL=", slaveStopLoss, " TP=", slaveTakeProfit);
        bool executionSuccess = (tradeType == "BUY") ? tradeExecutor.Buy(executionLotSize, slaveSymbol, 0, slaveStopLoss, slaveTakeProfit)
            : (tradeType == "SELL") ? tradeExecutor.Sell(executionLotSize, slaveSymbol, 0, slaveStopLoss, slaveTakeProfit)
            : false;
        if (executionSuccess)
        {
            SaveTicketMapping(masterTicket, tradeExecutor.ResultOrder());
            Print("Slave: OPEN placed slaveTicket=", tradeExecutor.ResultOrder());
        }
        else
            Print("Slave: OPEN failed retcode=", tradeExecutor.ResultRetcode(),
                " comment=", tradeExecutor.ResultComment());
    }
    else if (actionType == "MODIFY")
    {
        ulong slaveTicket = GetSlaveTicket(masterTicket);
        if (slaveTicket == 0) { Print("Slave: MODIFY – no slave ticket for masterTicket=", masterTicket); return; }
        if (!tradeExecutor.PositionModify(slaveTicket, slaveStopLoss, slaveTakeProfit))
            Print("Slave: MODIFY failed retcode=", tradeExecutor.ResultRetcode());
        else
            Print("Slave: MODIFY done slaveTicket=", slaveTicket);
    }
    else if (actionType == "PARTIAL_CLOSE")
    {
        ulong slaveTicket = GetSlaveTicket(masterTicket);
        if (slaveTicket == 0) { Print("Slave: PARTIAL_CLOSE – no slave ticket for masterTicket=", masterTicket); return; }
        double partialCloseVolume = CalculateLotSize(masterVolume);
        if (!tradeExecutor.PositionClosePartial(slaveTicket, partialCloseVolume))
            Print("Slave: PARTIAL_CLOSE failed retcode=", tradeExecutor.ResultRetcode());
        else
            Print("Slave: PARTIAL_CLOSE done slaveTicket=", slaveTicket, " lot=", partialCloseVolume);
    }
    else if (actionType == "CLOSE")
    {
        ulong slaveTicket = GetSlaveTicket(masterTicket);
        if (slaveTicket == 0) { Print("Slave: CLOSE – no slave ticket for masterTicket=", masterTicket); return; }
        if (tradeExecutor.PositionClose(slaveTicket))
        {
            DeleteTicketMapping(masterTicket);
            Print("Slave: CLOSE done slaveTicket=", slaveTicket);
        }
        else
            Print("Slave: CLOSE failed retcode=", tradeExecutor.ResultRetcode());
    }
    else
        Print("Slave: Unknown action '", actionType, "' – ignored");
}

//+------------------------------------------------------------------+
//| Poll the relay server for the next trade command                |
//| Uses a 7-second WebRequest timeout so the long-poll (5 s on    |
//| the server) completes before MT5 times the request out.         |
//+------------------------------------------------------------------+
void PollServerForCommands()
{
    uchar  requestBody[];
    uchar  responseBuffer[];
    string responseHeaders;
    string requestHeaders = "Authorization: Bearer " + AuthToken + "\r\n";

    // Send our unique SlaveID as a query parameter so the server delivers
    // commands from this slave's private queue (fan-out architecture).
    int httpStatusCode = WebRequest("GET",
        ServerUrl + "/poll?id=" + SlaveID,
        requestHeaders,
        7000,    // timeout ms – must exceed server LongPollTimeoutSeconds (5 s)
        requestBody,
        responseBuffer,
        responseHeaders);
    if (httpStatusCode != 200)
    {
        Print("Slave: GET /poll failed HTTP=", httpStatusCode);
        return;
    }

    string responseString = CharArrayToString(responseBuffer);
    Print("Slave: GET /poll response: ", responseString);

    // Server returns {} when the long-poll timed out with no command.
    // A real command will contain "action".
    if (StringFind(responseString, "\"action\"") < 0)
        return;   // Nothing to do this poll cycle

    ExecuteTradeCommand(responseString);
}

//+------------------------------------------------------------------+
//| Unregister this slave from the server (called on EA removal)    |
//+------------------------------------------------------------------+
void UnregisterSlaveFromServer()
{
    uchar  requestBody[];
    uchar  responseBuffer[];
    string responseHeaders;
    string requestHeaders = "Authorization: Bearer " + AuthToken + "\r\n";
    WebRequest("DELETE",
        ServerUrl + "/slave?id=" + SlaveID,
        requestHeaders, 5000, requestBody, responseBuffer, responseHeaders);
    Print("Slave: Unregistered SlaveID=", SlaveID);
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
    if (SlaveID == "" || SlaveID == "slave1")
        Print("Slave: WARNING – SlaveID is '", SlaveID,
            "'. Set a unique SlaveID (e.g. your account number) in EA inputs.");
    InitializeSymbolMappings();
    // Use millisecond timer so the next poll fires immediately
    // after the previous WebRequest returns — no extra delay between polls.
    EventSetMillisecondTimer(1);
    Print("Slave: Started. Server=", ServerUrl, " SlaveID=", SlaveID);
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    EventKillTimer();
    UnregisterSlaveFromServer();   // Remove our queue from the server cleanly.
}

//+------------------------------------------------------------------+
//| OnTimer                                                          |
//+------------------------------------------------------------------+
void OnTimer()
{
    if (!EnableCopying)
        return;
    PollServerForCommands();
}
//+------------------------------------------------------------------+