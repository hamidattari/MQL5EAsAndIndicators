//+------------------------------------------------------------------+
//|                                               CopierMaster.mq5  |
//|            Trade Copier – MASTER side (HTTP relay to VPS)       |
//+------------------------------------------------------------------+
// Monitors open positions on this account and pushes every event
// (OPEN / MODIFY / PARTIAL_CLOSE / CLOSE) to the TradeCopierServer
// running on the VPS via a simple HTTP POST.
//
// Requirements
// ────────────
// 1. MT5 menu Tools ► Options ► Expert Advisors ► Allow WebRequest for:
//       http://<VPS_IP>:5000
// 2. TradeCopierServer must be running on the VPS.
// 3. ServerUrl and AuthToken must match what is in appsettings.json.
//+------------------------------------------------------------------+
#property copyright "TradeCopier"
#property version   "2.00"
#property strict

#include <Trade\PositionInfo.mqh>

// ── Input parameters ──────────────────────────────────────────────
input group "=== Server Connection ==="
input string ServerUrl = "http://195.248.240.96:5000";  // VPS IP:port (no trailing slash)
input string AuthToken = "CHANGE_ME";
input bool   EnableCopying = true;

// ── Tracked position snapshot ─────────────────────────────────────
struct STrackedTrade
{
    ulong  positionTicket;
    string symbolName;
    string tradeType;     // "BUY" or "SELL"
    double tradeVolume;
    double stopLoss;
    double takeProfit;
    double openPrice;
    ulong  magicNumber;
};

CPositionInfo  positionInfo;
STrackedTrade  trackedTrades[];

//+------------------------------------------------------------------+
//| Build a compact JSON trade command string                        |
//+------------------------------------------------------------------+
string BuildJsonPayload(string actionType, string symbolName, string tradeType,
    double openPrice, double stopLoss, double takeProfit,
    double tradeVolume, ulong positionTicket, ulong magicNumber)
{
    // positionTicket and magicNumber are encoded as quoted strings to preserve ulong precision
    // across the JSON double round-trip.
    return "{\"action\":\"" + actionType + "\","
        + "\"symbol\":\"" + symbolName + "\","
        + "\"type\":\"" + tradeType + "\","
        + "\"entry\":" + DoubleToString(openPrice, 5) + ","
        + "\"sl\":" + DoubleToString(stopLoss, 5) + ","
        + "\"tp\":" + DoubleToString(takeProfit, 5) + ","
        + "\"volume\":" + DoubleToString(tradeVolume, 2) + ","
        + "\"ticket\":\"" + IntegerToString(positionTicket) + "\","
        + "\"magic\":\"" + IntegerToString(magicNumber) + "\"}";
}

//+------------------------------------------------------------------+
//| Send a JSON payload to POST /trade on the relay server           |
//+------------------------------------------------------------------+
bool SendTradePayload(string payloadJson)
{
    // Convert JSON string to byte array (UTF-8)
    uchar requestBody[];
    StringToCharArray(payloadJson, requestBody, 0, StringLen(payloadJson));

    uchar  responseBuffer[];
    string responseHeaders;
    string requestHeaders = "Content-Type: application/json\r\n"
        "Authorization: Bearer " + AuthToken + "\r\n";

    int httpStatusCode = WebRequest("POST",
        ServerUrl + "/trade",
        requestHeaders,
        5000,           // timeout ms
        requestBody,
        responseBuffer,
        responseHeaders);
    if (httpStatusCode == 200)
        return true;

    Print("Master: POST /trade failed, HTTP=", httpStatusCode, " body=", payloadJson);
    return false;
}

//+------------------------------------------------------------------+
//| Find index of a ticket in the tracked array (-1 if not found)   |
//+------------------------------------------------------------------+
int FindTrackedTradeIndex(ulong targetTicket)
{
    for (int index = 0; index < ArraySize(trackedTrades); index++)
        if (trackedTrades[index].positionTicket == targetTicket)
            return index;
    return -1;
}

//+------------------------------------------------------------------+
//| Snapshot all currently open positions at startup                 |
//+------------------------------------------------------------------+
void SnapshotOpenPositions()
{
    int totalPositions = PositionsTotal();
    ArrayResize(trackedTrades, totalPositions);
    for (int positionIndex = 0; positionIndex < totalPositions; positionIndex++)
    {
        if (!positionInfo.SelectByIndex(positionIndex))
            continue;
        trackedTrades[positionIndex].positionTicket = positionInfo.Ticket();
        trackedTrades[positionIndex].symbolName = positionInfo.Symbol();
        trackedTrades[positionIndex].tradeType = (positionInfo.PositionType() == POSITION_TYPE_BUY) ? "BUY" : "SELL";
        trackedTrades[positionIndex].tradeVolume = positionInfo.Volume();
        trackedTrades[positionIndex].stopLoss = positionInfo.StopLoss();
        trackedTrades[positionIndex].takeProfit = positionInfo.TakeProfit();
        trackedTrades[positionIndex].openPrice = positionInfo.PriceOpen();
        trackedTrades[positionIndex].magicNumber = positionInfo.Magic();
    }
    Print("Master: Snapshot – tracking ", ArraySize(trackedTrades), " open position(s)");
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
    SnapshotOpenPositions();
    EventSetTimer(1);   // poll every 1 second
    Print("Master: Started. Server=", ServerUrl);
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) { EventKillTimer(); }

//+------------------------------------------------------------------+
//| OnTimer – main monitoring loop                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
    if (!EnableCopying)
        return;

    int currentPositionCount = PositionsTotal();
    int trackedTradeCount = ArraySize(trackedTrades);

    // activePositionFlags[i] = true when trackedTrades[i] still has an open position
    bool activePositionFlags[];
    ArrayResize(activePositionFlags, trackedTradeCount);
    ArrayInitialize(activePositionFlags, false);

    // ── PHASE 1: Modifications & Partial Closes ───────────────────
    for (int positionIndex = 0; positionIndex < currentPositionCount; positionIndex++)
    {
        if (!positionInfo.SelectByIndex(positionIndex))
            continue;

        ulong currentTicket = positionInfo.Ticket();
        int   trackedIndex = FindTrackedTradeIndex(currentTicket);
        if (trackedIndex < 0)
            continue;   // new trade – handled in phase 3

        activePositionFlags[trackedIndex] = true;

        // Partial close?
        if (positionInfo.Volume() < trackedTrades[trackedIndex].tradeVolume)
        {
            double closedVolume = trackedTrades[trackedIndex].tradeVolume - positionInfo.Volume();
            string jsonPayload = BuildJsonPayload("PARTIAL_CLOSE", positionInfo.Symbol(), trackedTrades[trackedIndex].tradeType,
                positionInfo.PriceOpen(), positionInfo.StopLoss(), positionInfo.TakeProfit(),
                closedVolume, currentTicket, positionInfo.Magic());
            if (SendTradePayload(jsonPayload))
            {
                trackedTrades[trackedIndex].tradeVolume = positionInfo.Volume();
                Print("Master: PARTIAL_CLOSE sent ticket=", currentTicket);
            }
        }

        // SL/TP modification?
        double symbolPoint = SymbolInfoDouble(positionInfo.Symbol(), SYMBOL_POINT);
        if (MathAbs(positionInfo.StopLoss() - trackedTrades[trackedIndex].stopLoss) > symbolPoint ||
            MathAbs(positionInfo.TakeProfit() - trackedTrades[trackedIndex].takeProfit) > symbolPoint)
        {
            string jsonPayload = BuildJsonPayload("MODIFY", positionInfo.Symbol(), trackedTrades[trackedIndex].tradeType,
                positionInfo.PriceOpen(), positionInfo.StopLoss(), positionInfo.TakeProfit(),
                positionInfo.Volume(), currentTicket, positionInfo.Magic());
            if (SendTradePayload(jsonPayload))
            {
                trackedTrades[trackedIndex].stopLoss = positionInfo.StopLoss();
                trackedTrades[trackedIndex].takeProfit = positionInfo.TakeProfit();
                Print("Master: MODIFY sent ticket=", currentTicket);
            }
        }
    }

    // ── PHASE 2: Closed Trades ────────────────────────────────────
    for (int tradeIndex = trackedTradeCount - 1; tradeIndex >= 0; tradeIndex--)
    {
        if (activePositionFlags[tradeIndex])
            continue;

        string jsonPayload = BuildJsonPayload("CLOSE", trackedTrades[tradeIndex].symbolName, trackedTrades[tradeIndex].tradeType,
            trackedTrades[tradeIndex].openPrice, trackedTrades[tradeIndex].stopLoss, trackedTrades[tradeIndex].takeProfit,
            trackedTrades[tradeIndex].tradeVolume, trackedTrades[tradeIndex].positionTicket, trackedTrades[tradeIndex].magicNumber);
        if (SendTradePayload(jsonPayload))
        {
            Print("Master: CLOSE sent ticket=", trackedTrades[tradeIndex].positionTicket);
            // Remove the entry by shifting the array
            for (int shiftIndex = tradeIndex; shiftIndex < ArraySize(trackedTrades) - 1; shiftIndex++)
                trackedTrades[shiftIndex] = trackedTrades[shiftIndex + 1];
            ArrayResize(trackedTrades, ArraySize(trackedTrades) - 1);
        }
    }

    // ── PHASE 3: New Trades ───────────────────────────────────────
    for (int positionIndex = 0; positionIndex < currentPositionCount; positionIndex++)
    {
        if (!positionInfo.SelectByIndex(positionIndex))
            continue;

        ulong currentTicket = positionInfo.Ticket();
        if (FindTrackedTradeIndex(currentTicket) >= 0)
            continue;   // already tracked

        string tradeTypeString = (positionInfo.PositionType() == POSITION_TYPE_BUY) ? "BUY" : "SELL";
        string jsonPayload = BuildJsonPayload("OPEN", positionInfo.Symbol(), tradeTypeString,
            positionInfo.PriceOpen(), positionInfo.StopLoss(), positionInfo.TakeProfit(),
            positionInfo.Volume(), currentTicket, positionInfo.Magic());
        if (SendTradePayload(jsonPayload))
        {
            int newTrackedSize = ArraySize(trackedTrades) + 1;
            ArrayResize(trackedTrades, newTrackedSize);
            trackedTrades[newTrackedSize - 1].positionTicket = currentTicket;
            trackedTrades[newTrackedSize - 1].symbolName = positionInfo.Symbol();
            trackedTrades[newTrackedSize - 1].tradeType = tradeTypeString;
            trackedTrades[newTrackedSize - 1].tradeVolume = positionInfo.Volume();
            trackedTrades[newTrackedSize - 1].stopLoss = positionInfo.StopLoss();
            trackedTrades[newTrackedSize - 1].takeProfit = positionInfo.TakeProfit();
            trackedTrades[newTrackedSize - 1].openPrice = positionInfo.PriceOpen();
            trackedTrades[newTrackedSize - 1].magicNumber = positionInfo.Magic();
            Print("Master: OPEN sent ticket=", currentTicket);
        }
    }
}
//+------------------------------------------------------------------+