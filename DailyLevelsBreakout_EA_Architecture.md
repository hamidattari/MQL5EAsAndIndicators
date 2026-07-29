# DailyLevelsBreakout_EA Architecture & System Reference

## 1. Overview

### Purpose of the EA

**DailyLevelsBreakout_EA** is a breakout Expert Advisor (EA) for MetaTrader 5 (MQL5) designed to trade intraday breakouts from dynamically calculated High and Low price boundaries. It aims to capture momentum away from established consolidation or reference zones while maintaining strict per-session risk and trade management controls.

### High-Level Summary

The program operates across **4 fully independent intraday trading sessions**. Each session calculates its own upper (`definedHigh`) and lower (`definedLow`) price levels based on one of **3 selectable detection methods**.

Once a breakout candle closes outside these boundaries, the EA validates the breakout using range and origin filters before executing market orders.

#### Tiered Reward-to-Risk Model

- **Trade 1:** Targets **1:2 RR**
  - If TP is hit or the trade closes manually without hitting SL, the session halts for the day.
- **Trade 2:** Allowed only if Trade 1 hits SL
  - Targets **1:4 RR**
- **Maximum:** 2 trades per session per day

#### UI & Interactivity

Traders can:

- Manually drag High/Low breakout lines directly on the chart.
- Instantly update internal levels and labels.
- Use a built-in **Reset Button** to restore original algorithmic levels.

---

## 2. Core Architecture

### Main Components & Responsibilities

| Component                     | Responsibility                                 |
|-------------------------------|------------------------------------------------|
| Event Handlers                | `OnInit`, `OnDeinit`, `OnTick`, `OnChartEvent` |
| Session & State Manager       | `SessionData` struct, activity/state helpers   |
| Level Calculation Engine      | Methods 1, 2, and 3 level detection            |
| Signal & Trade Engine         | Breakout filters, RR logic, order execution    |
| UI & Interactive Chart System | Selectable lines, price labels, reset button   |

### Data Flow Pipeline

#### `OnInit()`

- Initializes the 4 `SessionData` instances.
- Configures broker slippage and filling rules.
- Creates Reset button.
- Performs initial level calculation if attached mid-day.

#### `OnTick()`

1. **UpdateTradeState**
   - Monitors trade closures (SL, TP, manual).

2. **IsNewBar**
   - Restricts level updates and signal evaluation to new bars.

3. **UpdateSessionLevels**
   - Calculates and draws levels when reference time is reached.

4. **CheckEntrySignal**
   - Evaluates breakout conditions and executes trades.

#### `OnChartEvent()`

Handles:

- `CHARTEVENT_OBJECT_DRAG`
- `CHARTEVENT_OBJECT_CHANGE`
- `CHARTEVENT_OBJECT_CLICK`

Used for:

- Line dragging
- Label updates
- Reset button interaction

---

## 3. Key Structures & Globals

### SessionData Structure

```
struct SessionData
{
   bool      enable;
   int       refH, refM;
   int       endH, endM;
   color     lineColor;

   bool      levelsSet;
   datetime  levelsDay;
   double    definedHigh;
   double    definedLow;
   double    originalHigh;
   double    originalLow;
   datetime  refBarTime;
   datetime  lineStartTime;

   int       tradesToday;
   bool      trade1HitSL;
   bool      haltTrading;
};
```

### Primary Global Variables

| Variable                    | Description              |
|-----------------------------|--------------------------|
| `CTrade g_trade`            | Trade execution wrapper  |
| `datetime g_lastBarTime`    | Detects bar transitions  |
| `OBJ_PREFIX = "DLB_"`       | Prefix for chart objects |
| `SessionData g_sessions[4]` | Session storage array    |

---

## 4. Session System

### Independent Multi-Session Operation

Each session operates independently:

- Session 1 activity does not affect Sessions 2–4.
- Separate levels, trades, and state tracking.

```text
Day Start (00:00)
  │
  ├─► Session 1 Ref Time → Calculate Levels → Trading Window
  ├─► Session 2 Ref Time → Calculate Levels → Trading Window
  ├─► Session 3 Ref Time → Calculate Levels → Trading Window
  └─► Session 4 Ref Time → Calculate Levels → Trading Window
```

### Lifecycle & State Tracking

#### Reference Time (`refH`, `refM`)

Defines when level calculation occurs.

#### Trading Window (`endH`, `endM`)

Controls entry eligibility.

If end time ≤ start time:

- Session extends automatically to:
  - Next enabled session reference time, or
  - End of day (24:00)

#### Daily Reset

When a new day begins:

- Remove old chart objects.
- `tradesToday = 0`
- `trade1HitSL = false`
- `haltTrading = false`
- Recalculate levels.

---

## 5. Level Detection Methods

### Method 1: Base High/Low of Lookback Window (`METHOD_1`)

#### Mechanism

Searches over `InpLookbackN` bars preceding the reference candle.

#### Formula

```
High = iHighest(MODE_HIGH, InpLookbackN, refShift + 1);
Low  = iLowest(MODE_LOW, InpLookbackN, refShift + 1);
```

#### Usage

Captures absolute extremes of the recent consolidation range.

---

### Method 2: Base + Confirmation Candle Update (`METHOD_2`)

#### Mechanism

Starts from Method 1 extremes and dynamically adjusts the opposite boundary.

#### Logic (`UPDATE_MAIN_HL`)

##### High Occurred Before Low

```text
highShift < lowShift
```

- Count bearish candles.
- If bearish count ≥ `InpUpdateX`
  - Recalculate `definedLow`.

##### Low Occurred Before High

```text
lowShift < highShift
```

- Count bullish candles.
- If bullish count ≥ `InpUpdateX`
  - Recalculate `definedHigh`.

---

### Method 3: Reference Candle High/Low (`METHOD_3`)

#### Mechanism

Uses only the reference candle.

#### Validation

```
refShift > 0
```

#### Formula

```
High = iHigh(refShift);
Low  = iLow(refShift);
```

#### Usage

Suitable for Opening Range Breakout (ORB) strategies.

---

## 6. Trade Management Logic

### Entry Filters (`CheckEntrySignal`)

Before opening a trade:

#### 1. Reference Bar Filter

```
c1time > refBarTime
```

Breakouts must occur after the reference candle.

#### 2. Range Quality Filter

```
rangeCandle < rangeLevels
```

Avoids entering after oversized candles.

#### 3. Origin Filter

```
definedLow <= Open1 <= definedHigh
```

Breakout candle must originate inside the channel.

### Buy Signal

```
Close1 > definedHigh
```

and

```
(Close1 - definedHigh) >
(High1 - Close1)
```

### Sell Signal

```
Close1 < definedLow
```

and

```
(definedLow - Close1) >
(Close1 - Low1)
```

---

### Tiered RR & Session Limits

| Trade   | Condition            | RR  |                              Result |
|---------|----------------------|-----|-------------------------------------|
| Trade 1 | First valid breakout | 1:2 | TP/manual close → halt session      |
| Trade 1 | Hits SL              | 1:2 | Enables Trade 2                     |
| Trade 2 | After Trade 1 SL     | 1:4 | Session halts regardless of outcome |

---

### Closed Deal Tracking (`UpdateTradeState`)

Monitors:

```
HistoryDealsTotal()
```

Checks:

```
DEAL_ENTRY_OUT
```

If:

```
DEAL_REASON_SL
```

Then:

```
trade1HitSL = true;
```

Otherwise:

```
haltTrading = true;
```

---

## 7. Chart Objects & UI

### Object Architecture

Objects use the prefix:

```text
DLB_S{x}_
```

#### Reference Vertical Line

- Type: `OBJ_VLINE`
- Anchored at `refBarTime`

#### High/Low Lines

- Type: `OBJ_TREND`
- Fully selectable
- User-draggable

#### Price Labels

- Type: `OBJ_TEXT`
- Display exact level price.

---

### Layout Example

```text
                 [High Price Label]

────────────────── High Line ──────────────────
                     │
                     │ Reference Line
                     │
────────────────── Low Line ───────────────────

                  [Low Price Label]
```

---

### Interactive Dragging

When a user drags a line:

1. Event detected.
2. New price is read.
3. Horizontal alignment enforced.
4. `definedHigh` or `definedLow` updated.
5. Label repositioned immediately.

---

### Reset Button

#### Creation

```
CreateResetButton()
```

Creates:

```text
DLB_ResetBtn
```

#### Action

```
CHARTEVENT_OBJECT_CLICK
```

calls:

```
ResetLevelsToOriginal()
```

#### Result

Restores:

```
definedHigh = originalHigh;
definedLow  = originalLow;
```

and redraws chart objects.

---

## 8. Risk & Order Execution

### Lot Sizing (`CalcLots`)

#### Fixed Lot Mode

```
InpUseRiskPercent = false
```

Returns:

```
InpFixedLot
```

#### Risk Percentage Mode

```
InpUseRiskPercent = true
```

##### Formula

```text
RiskMoney =
AccountBalance × InpRiskPercent / 100
```

```text
LossPerLot =
(slDistance / TickSize) × TickValue
```

```text
Lots =
RiskMoney / LossPerLot
```

#### Normalisation

Volume is:

- Rounded to broker step size.
- Clamped between:
  - `SYMBOL_VOLUME_MIN`
  - `SYMBOL_VOLUME_MAX`

---

### Stop Loss & Take Profit

#### Buy Orders

```
SL = Low2 - (InpSLBufferPoints * Point)
```

```
TP = Entry +
     ((Entry - SL) * RR) -
     (InpTPBufferPoints * Point)
```

#### Sell Orders

```
SL = High2 + (InpSLBufferPoints * Point)
```

```
TP = Entry -
     ((SL - Entry) * RR) +
     (InpTPBufferPoints * Point)
```

### Broker Validation

Before sending orders:

```
Entry ↔ SL
Entry ↔ TP
```

must exceed:

```
SYMBOL_TRADE_STOPS_LEVEL
```

---

### Magic Number System

Each session uses its own Magic Number:

```text
Magic = InpMagic + sIdx
```

Example:

| Session   | Magic    |
|-----------|----------|
| Session 1 | 20260729 |
| Session 2 | 20260730 |
| Session 3 | 20260731 |
| Session 4 | 20260732 |

---

## 9. Event Handlers

| Event Handler | Trigger | Responsibilities |
|---------------|----------|------------------|
| `OnInit()` | Attach / Compile | Configure sessions, create UI, initial calculations |
| `OnDeinit()` | Remove / Close | Delete all chart objects |
| `OnTick()` | Price updates | Trade monitoring, level updates, signal checks |
| `OnChartEvent()` | User interactions | Line dragging, label updates, reset actions |

---

## 10. File Structure Summary

```text
DailyLevelsBreakout_EA.mq5
 ├── 1. Enums & Input Parameters
 │       ├── ENUM_DETECTION_METHOD
 │       ├── ENUM_UPDATE_MODE
 │       └── Inputs
 │
 ├── 2. Global Variables & Data Structures
 │       ├── CTrade g_trade
 │       ├── g_lastBarTime
 │       ├── OBJ_PREFIX
 │       └── SessionData g_sessions[4]
 │
 ├── 3. Standard MQL5 Event Handlers
 │       ├── OnInit()
 │       ├── OnDeinit()
 │       ├── OnTick()
 │       └── OnChartEvent()
 │
 ├── 4. Bar & State Tracking
 │       ├── IsNewBar()
 │       └── UpdateTradeState()
 │
 ├── 5. Level Detection & Breakout Logic
 │       ├── UpdateSessionLevels()
 │       └── CheckEntrySignal()
 │
 ├── 6. Order Execution & Risk Management
 │       ├── ExecuteTrade()
 │       └── CalcLots()
 │
 ├── 7. Session Activity Helpers
 │       ├── IsSessionActiveForTrading()
 │       ├── GetNextSessionRefTime()
 │       └── HasOpenPositionForSession()
 │
 ├── 8. Chart Object Drawing & Manipulation
 │       ├── DrawSessionLevelLines()
 │       ├── UpdateSessionPriceLabel()
 │       └── DeleteSessionObjects()
 │
 └── 9. UI & Interactivity
         ├── UpdateLevelsFromChartLines()
         ├── CreateResetButton()
         └── ResetLevelsToOriginal()
```

---
**Document:** DailyLevelsBreakout_EA Architecture & System Reference