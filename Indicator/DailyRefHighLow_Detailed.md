# Detailed Code Review Template – DailyRefHighLow.mq5

> Generated from the uploaded source file.

## Statistics

- File size: 61,116 characters
- Total lines: 1,365
- Detected functions: 38

## Detected Functions

## GetManualPrice

- Return Type: `bool`
- Parameters: `const string lineName, double &manualPrice`

Detailed analysis required from source review.

## SetManualPrice

- Return Type: `void`
- Parameters: `const string lineName, const double manualPrice`

Detailed analysis required from source review.

## ClearManualPrices

- Return Type: `void`
- Parameters: ``

Detailed analysis required from source review.

## VLineName

- Return Type: `string`
- Parameters: `datetime startOfDayTime`

Detailed analysis required from source review.

## HighName

- Return Type: `string`
- Parameters: `datetime startOfDayTime`

Detailed analysis required from source review.

## LowName

- Return Type: `string`
- Parameters: `datetime startOfDayTime`

Detailed analysis required from source review.

## InterName

- Return Type: `string`
- Parameters: `datetime startOfDayTime`

Detailed analysis required from source review.

## HighLabelName

- Return Type: `string`
- Parameters: `datetime startOfDayTime`

Detailed analysis required from source review.

## LowLabelName

- Return Type: `string`
- Parameters: `datetime startOfDayTime`

Detailed analysis required from source review.

## InterLabelName

- Return Type: `string`
- Parameters: `datetime startOfDayTime`

Detailed analysis required from source review.

## OnInit

- Return Type: `int`
- Parameters: ``

Detailed analysis required from source review.

## OnDeinit

- Return Type: `void`
- Parameters: `const int deinitReason`

Detailed analysis required from source review.

## DeleteObjects

- Return Type: `void`
- Parameters: ``

Detailed analysis required from source review.

## DayStart

- Return Type: `datetime`
- Parameters: `datetime timeToRound`

Detailed analysis required from source review.

## CreateRect

- Return Type: `void`
- Parameters: `const string objectName, const int xPosition, const int yPosition,
                const int boxWidth, const int boxHeight, const color backgroundColor,
                const color borderColor`

Detailed analysis required from source review.

## CreateLabel

- Return Type: `void`
- Parameters: `const string objectName, const int xPosition, const int yPosition,
                 const string labelText, const color textColor, const int fontSize`

Detailed analysis required from source review.

## CreateButton

- Return Type: `void`
- Parameters: `const string objectName, const int xPosition, const int yPosition,
                  const int buttonWidth, const int buttonHeight, const string buttonText,
                  const color backgroundColor, const int fontSize`

Detailed analysis required from source review.

## BuildNavPanel

- Return Type: `void`
- Parameters: ``

Detailed analysis required from source review.

## SetNavButtonsVisibility

- Return Type: `void`
- Parameters: `const bool isPanelVisible`

Detailed analysis required from source review.

## ToggleCollapse

- Return Type: `void`
- Parameters: ``

Detailed analysis required from source review.

## DeleteNavPanelObjects

- Return Type: `void`
- Parameters: ``

Detailed analysis required from source review.

## HandleLineDrag

- Return Type: `void`
- Parameters: `const string objectName`

Detailed analysis required from source review.

## UpdatePriceLabelForLine

- Return Type: `void`
- Parameters: `const ushort family, const datetime dayStartTime, const double levelPrice`

Detailed analysis required from source review.

## DeletePriceLabelForLine

- Return Type: `void`
- Parameters: `const ushort family, const datetime dayStartTime`

Detailed analysis required from source review.

## OnChartEvent

- Return Type: `void`
- Parameters: `const int eventId, const long &longEventParam,
                  const double &doubleEventParam, const string &stringEventParam`

Detailed analysis required from source review.

## ResetButton

- Return Type: `void`
- Parameters: `const string buttonObjectName`

Detailed analysis required from source review.

## NavigateChart

- Return Type: `void`
- Parameters: `int daysToNavigate`

Detailed analysis required from source review.

## ResetNavigation

- Return Type: `void`
- Parameters: ``

Detailed analysis required from source review.

## OnCalculate

- Return Type: `int`
- Parameters: `const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double   &open[],
                const double   &high[],
                const double   &low[],
                const double   &close[],
                const long     &tick_volume[],
                const long     &volume[],
                const int      &spread[]`

Detailed analysis required from source review.

## DrawVerticalLine

- Return Type: `void`
- Parameters: `datetime dayStartTime, datetime targetDatetime`

Detailed analysis required from source review.

## FindReferenceIndex

- Return Type: `int`
- Parameters: `datetime targetDatetime,
                       int totalRates,
                       const datetime &time[]`

Detailed analysis required from source review.

## ProcessDayLevels

- Return Type: `void`
- Parameters: `datetime dayStartTime,
                      datetime targetDatetime,
                      int totalRates,
                      const datetime &time[],
                      const double &open[],
                      const double &high[],
                      const double &low[],
                      const double &close[]`

Detailed analysis required from source review.

## RefreshLinePriceLabel

- Return Type: `void`
- Parameters: `const ushort family, const datetime dayStartTime, const string lineName`

Detailed analysis required from source review.

## DrawDailyHorizontalLine

- Return Type: `void`
- Parameters: `const string lineName,
                             datetime startTime,
                             datetime endTime,
                             double   levelPrice,
                             color    lineColor,
                             ENUM_LINE_STYLE lineStyle,
                             int      lineWidth,
                             const string tooltipText`

Detailed analysis required from source review.

## GetTargetBrokerTime

- Return Type: `datetime`
- Parameters: `datetime brokerDayStartTime, int targetHour, int targetMinute`

Detailed analysis required from source review.

## IsTehran_DST

- Return Type: `bool`
- Parameters: `datetime timeToCheck`

Detailed analysis required from source review.

## IsUS_DST

- Return Type: `bool`
- Parameters: `datetime timeToCheck`

Detailed analysis required from source review.

## IsEU_DST

- Return Type: `bool`
- Parameters: `datetime timeToCheck`

Detailed analysis required from source review.
