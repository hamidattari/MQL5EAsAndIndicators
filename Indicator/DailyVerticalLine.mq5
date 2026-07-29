//+------------------------------------------------------------------+
//|                                              DailyRefHighLow.mq5 |
//|                                     Copyright 2026, AI Assistant |
//|                                                                  |
//|  For every trading day visible on the chart:                     |
//|   1. Draws a vertical reference line at a user-defined time.     |
//|   2. Scans the N completed candles (default 20) immediately      |
//|      BEFORE the reference candle -- starting with the candle     |
//|      directly preceding it -- and finds swing levels using the   |
//|      selected Swing Detection Method:                            |
//|                                                                  |
//|      METHOD 1 (Highest High / Lowest Low):                       |
//|        * The highest High of the window.                         |
//|        * The lowest  Low  of the window.                         |
//|                                                                  |
//|      METHOD 2 (Alternate swing update rules):                    |
//|        * Start from the Method 1 base swings.                    |
//|        * If the Low formed BEFORE the High and, after that       |
//|          High, >= X bearish candles (cumulative, not             |
//|          necessarily consecutive) appear before the reference    |
//|          time -> the Low is UPDATED to the lowest Low of the     |
//|          candles after that High.                                |
//|        * If the High formed BEFORE the Low and, after that       |
//|          Low, >= X bullish candles (cumulative) appear before    |
//|          the reference time -> the High is UPDATED to the        |
//|          highest High of the candles after that Low.             |
//|                                                                  |
//|   3. Drawing Mode selects how an updated swing is displayed:     |
//|        * Update Main Lines: the main High/Low line moves to the  |
//|          final updated value.                                    |
//|        * Additional Third Line: main lines keep the base swing   |
//|          values and the updated level is drawn as a separate,    |
//|          independently styled Intermediate Swing Line.           |
//|                                                                  |
//|   4. All horizontal lines span ONLY their trading day            |
//|      (day start -> day end) and never bleed into the next day.   |
//|   5. Every historical day keeps its own independent lines.       |
//|                                                                  |
//|   6. NAVIGATION PANEL: separate collapsible panel with           |
//|      << Prev / Next >> chart navigation to a specific daily      |
//|      time, plus a Reset button to jump back to the last candle.  |
//|                                                                  |
//|   7. DRAGGABLE LINES: the High, Intermediate and Low horizontal  |
//|      lines are selectable and can be dragged on the chart.       |
//|      The dragged position becomes the new active price level     |
//|      (it is never overwritten by recalculation), and an optional |
//|      price label -- placed immediately before the reference      |
//|      time -- shows the current price in real time.               |
//+------------------------------------------------------------------+
#property copyright "AI Assistant"
#property link      ""
#property version   "2.20"
#property description "Daily vertical reference line + per-day swing High/Low lines (two detection methods, day-bounded, optional intermediate swing line) + draggable price levels with live labels + Prev/Next/Reset navigation panel."
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0

//+------------------------------------------------------------------+
//| Enums                                                            |
//+------------------------------------------------------------------+
enum ENUM_TIMEZONES
  {
   TZ_UTC,           // UTC
   TZ_NEW_YORK,      // New York
   TZ_LONDON,        // London
   TZ_TEHRAN_NO_DST, // Tehran No DST
   TZ_TEHRAN_DST,    // Tehran With DST
   TZ_BROKER,        // Broker Server Time
   TZ_CUSTOM         // Custom UTC Offset
  };

enum ENUM_SWING_METHOD
  {
   SWING_METHOD_1,   // Method 1: Highest High / Lowest Low
   SWING_METHOD_2,   // Method 2: Alternate Swing Update Rules
   SWING_METHOD_3    // Method 3: Reference Candle High/Low
  };

enum ENUM_DRAW_MODE
  {
   DRAW_UPDATE_MAIN, // Update Main High/Low Lines
   DRAW_THIRD_LINE   // Draw Updated Level as Third Line
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
//--- General
input group           "=== General ==="
input bool            InpEnable             = true;            // Enable Indicator
input int             InpHour               = 9;               // Reference Hour (0-23)
input int             InpMinute             = 30;              // Reference Minute (0-59)
input ENUM_TIMEZONES  InpTimeZone           = TZ_BROKER;       // Time Zone Selection
input double          InpCustomOffset       = 0.0;             // Custom UTC Offset (hours, e.g. 5.5)

//--- High/Low detection
input group           "=== High/Low Detection ==="
input ENUM_SWING_METHOD InpSwingMethod      = SWING_METHOD_1;  // Swing Detection Method
input int             InpLookbackBars       = 20;              // Lookback Bars (completed candles before reference)
input int             InpUpdateCandles      = 3;               // Method 2: Min Bullish/Bearish Candles for Update

//--- Drawing behaviour for Method 2 updates
input group           "=== Method 2: Drawing Rules ==="
input ENUM_DRAW_MODE  InpDrawMode           = DRAW_UPDATE_MAIN;// Updated Swing Drawing Mode
input bool            InpDrawIntermediate   = true;            // Draw Intermediate Swing Line (Third Line mode)
input color           InpInterHighColor     = clrCrimson;      // Intermediate High Line Color
input color           InpInterLowColor      = clrMediumBlue;   // Intermediate Low Line Color
input ENUM_LINE_STYLE InpInterStyle         = STYLE_DOT;       // Intermediate Line Style
input int             InpInterWidth         = 1;               // Intermediate Line Width

//--- Vertical reference line
input group           "=== Vertical Reference Line ==="
input color           InpVLineColor         = clrDodgerBlue;   // Vertical Line Color
input ENUM_LINE_STYLE InpVLineStyle         = STYLE_SOLID;     // Vertical Line Style
input int             InpVLineWidth         = 1;               // Vertical Line Width
input bool            InpVLineBackground    = true;            // Draw Vertical Line in Background

//--- High line
input group           "=== High Line ==="
input color           InpHighColor          = clrTomato;       // High Line Color
input ENUM_LINE_STYLE InpHighStyle          = STYLE_SOLID;     // High Line Style

//--- Low line
input group           "=== Low Line ==="
input color           InpLowColor           = clrLimeGreen;    // Low Line Color
input ENUM_LINE_STYLE InpLowStyle           = STYLE_SOLID;     // Low Line Style

//--- Shared horizontal-line settings
input group           "=== Horizontal Lines: Shared ==="
input int             InpHLineWidth         = 2;               // Horizontal Lines Width
input bool            InpHLineBackground    = false;           // Draw Horizontal Lines in Background
input bool            InpShowLabel          = true;            // Show Price Label on Lines

//--- Draggable lines & per-line price labels
input group           "=== Price Labels (before reference time) ==="
input bool            InpShowHighPriceLabel  = true;           // Show High Line Price Label
input bool            InpShowInterPriceLabel = true;           // Show Intermediate Line Price Label
input bool            InpShowLowPriceLabel   = true;           // Show Low Line Price Label
input int             InpPriceLabelFontSize  = 9;              // Price Label Font Size
input string          InpPriceLabelFontName  = "Arial";        // Price Label Font Name

//--- Navigation panel position & appearance
input group           "=== Navigation Panel ==="
input bool            InpShowNavPanel       = true;            // Show Navigation Panel
input ENUM_BASE_CORNER InpPanelCorner       = CORNER_LEFT_UPPER; // Anchor corner
input int             InpPanelXOffset       = 12;              // Panel X offset from corner (pixels)
input int             InpPanelYOffset       = 370;             // Panel Y offset from corner (pixels)
input bool            InpStartCollapsed     = false;           // Start with panel collapsed?
input int             InpPanelWidth         = 320;             // Panel width  (pixels)
input int             InpButtonHeight       = 34;              // Button height (pixels)
input int             InpButtonGap          = 6;               // Gap between buttons (pixels)
input int             InpPanelPadding       = 8;               // Inner padding (pixels)
input int             InpTitleBarHeight     = 26;              // Title bar height (pixels)
input int             InpButtonFontSize     = 10;              // Font size on buttons
input string          InpButtonFontName     = "Arial Bold";    // Font name
input color           InpPanelBgColor       = C'40,40,45';     // Panel background color
input color           InpTitleBgColor       = C'25,25,30';     // Title bar background color
input color           InpTitleTextColor     = clrWhite;        // Title text color

//--- Naming
input group           "=== Advanced ==="
input string          InpPrefix             = "DRHL_";         // Prefix for Indicator Objects

//+------------------------------------------------------------------+
//| Global variables                                                 |
//+------------------------------------------------------------------+
int g_brokerToGmtOffsetSeconds = 0;   // Broker <-> GMT offset in seconds

//========================= NAV PANEL OBJECT NAMES ===================//
#define NAVPNL_BG      "DRHL_NavPanel_BG"
#define NAVPNL_TITLE   "DRHL_NavPanel_Title"
#define NAVPNL_LABEL   "DRHL_NavPanel_Label"
#define NAVPNL_TOGGLE  "DRHL_NavPanel_Toggle"
#define NAVBTN_PREV    "DRHL_NavPrev"
#define NAVBTN_NEXT    "DRHL_NavNext"
#define NAVBTN_RESET   "DRHL_NavReset"

//--- Navigation panel runtime state
bool     g_isNavPanelCollapsed       = false;
datetime g_currentNavigationTargetTime = 0;

//--- Manual drag overrides: dragged line name -> user-defined price.
//    Once a line is dragged, its price is pinned here and recalculation
//    never overwrites it: the dragged level IS the active level.
string g_manualLineNames[];
double g_manualLinePrices[];

//+------------------------------------------------------------------+
//| Manual-override helpers                                          |
//+------------------------------------------------------------------+
bool GetManualPrice(const string lineName, double &manualPrice)
  {
   for(int i = 0; i < ArraySize(g_manualLineNames); i++)
      if(g_manualLineNames[i] == lineName)
        {
         manualPrice = g_manualLinePrices[i];
         return true;
        }
   return false;
  }

void SetManualPrice(const string lineName, const double manualPrice)
  {
   for(int i = 0; i < ArraySize(g_manualLineNames); i++)
      if(g_manualLineNames[i] == lineName)
        {
         g_manualLinePrices[i] = manualPrice;
         return;
        }
   int newSize = ArraySize(g_manualLineNames) + 1;
   ArrayResize(g_manualLineNames,  newSize);
   ArrayResize(g_manualLinePrices, newSize);
   g_manualLineNames [newSize - 1] = lineName;
   g_manualLinePrices[newSize - 1] = manualPrice;
  }

void ClearManualPrices()
  {
   ArrayFree(g_manualLineNames);
   ArrayFree(g_manualLinePrices);
  }

//+------------------------------------------------------------------+
//| Object name helpers (one unique name per day => historical days  |
//| keep their own lines and are never overwritten by newer days).   |
//+------------------------------------------------------------------+
string VLineName(datetime startOfDayTime) { return InpPrefix + "V_" + TimeToString(startOfDayTime, TIME_DATE); }
string HighName(datetime startOfDayTime)  { return InpPrefix + "H_" + TimeToString(startOfDayTime, TIME_DATE); }
string LowName(datetime startOfDayTime)   { return InpPrefix + "L_" + TimeToString(startOfDayTime, TIME_DATE); }
string InterName(datetime startOfDayTime) { return InpPrefix + "I_" + TimeToString(startOfDayTime, TIME_DATE); }
string HighLabelName(datetime startOfDayTime)  { return InpPrefix + "HT_" + TimeToString(startOfDayTime, TIME_DATE); }
string LowLabelName(datetime startOfDayTime)   { return InpPrefix + "LT_" + TimeToString(startOfDayTime, TIME_DATE); }
string InterLabelName(datetime startOfDayTime) { return InpPrefix + "IT_" + TimeToString(startOfDayTime, TIME_DATE); }

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- Navigation panel works even when the indicator drawing is disabled
   g_currentNavigationTargetTime = 0;
   g_isNavPanelCollapsed = InpStartCollapsed;
   if(InpShowNavPanel)
      BuildNavPanel();

   //--- Mouse-move events are needed for real-time price-label updates
   //    while a horizontal line is being dragged.
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);

   if(!InpEnable)
      return(INIT_SUCCEEDED);

   //--- Validate time inputs
   if(InpHour < 0 || InpHour > 23 || InpMinute < 0 || InpMinute > 59)
     {
      Print("Invalid time: hour must be 0-23 and minute 0-59.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   //--- Validate lookback input
   if(InpLookbackBars < 1)
     {
      Print("Lookback Bars must be >= 1.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   //--- Validate Method 2 threshold
   if(InpUpdateCandles < 1)
     {
      Print("Method 2 candle threshold must be >= 1.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   //--- Current Broker <-> GMT offset (whole seconds)
   g_brokerToGmtOffsetSeconds = (int)(TimeTradeServer() - TimeGMT());

   //--- Fresh start: remove any objects left over from previous runs
   ClearManualPrices();
   DeleteObjects();

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Custom indicator deinitialization function                       |
//+------------------------------------------------------------------+
void OnDeinit(const int deinitReason)
  {
   DeleteObjects();
   DeleteNavPanelObjects();
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Delete all indicator-owned line objects (keeps the nav panel;    |
//| panel objects use their own dedicated names and are removed by   |
//| DeleteNavPanelObjects).                                          |
//+------------------------------------------------------------------+
void DeleteObjects()
  {
   ObjectsDeleteAll(0, InpPrefix + "V_");
   ObjectsDeleteAll(0, InpPrefix + "H_");
   ObjectsDeleteAll(0, InpPrefix + "L_");
   ObjectsDeleteAll(0, InpPrefix + "I_");
   ObjectsDeleteAll(0, InpPrefix + "HT_");
   ObjectsDeleteAll(0, InpPrefix + "LT_");
   ObjectsDeleteAll(0, InpPrefix + "IT_");
  }

//+------------------------------------------------------------------+
//| Return the broker-time midnight of the day that contains timeToRound |
//+------------------------------------------------------------------+
datetime DayStart(datetime timeToRound)
  {
   return timeToRound - (timeToRound % 86400);
  }

//+==================================================================+
//|                   NAVIGATION PANEL DRAWING CODE                  |
//+==================================================================+
void CreateRect(const string objectName, const int xPosition, const int yPosition,
                const int boxWidth, const int boxHeight, const color backgroundColor,
                const color borderColor)
  {
   if(ObjectFind(0, objectName) < 0)
      ObjectCreate(0, objectName, OBJ_RECTANGLE_LABEL, 0, 0, 0);

   ObjectSetInteger(0, objectName, OBJPROP_CORNER,     InpPanelCorner);
   ObjectSetInteger(0, objectName, OBJPROP_XDISTANCE,  xPosition);
   ObjectSetInteger(0, objectName, OBJPROP_YDISTANCE,  yPosition);
   ObjectSetInteger(0, objectName, OBJPROP_XSIZE,      boxWidth);
   ObjectSetInteger(0, objectName, OBJPROP_YSIZE,      boxHeight);
   ObjectSetInteger(0, objectName, OBJPROP_BGCOLOR,    backgroundColor);
   ObjectSetInteger(0, objectName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, objectName, OBJPROP_COLOR,      borderColor);
   ObjectSetInteger(0, objectName, OBJPROP_WIDTH,      1);
   ObjectSetInteger(0, objectName, OBJPROP_BACK,       false);
   ObjectSetInteger(0, objectName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, objectName, OBJPROP_HIDDEN,     true);
   ObjectSetInteger(0, objectName, OBJPROP_ZORDER,     0);
  }

void CreateLabel(const string objectName, const int xPosition, const int yPosition,
                 const string labelText, const color textColor, const int fontSize)
  {
   if(ObjectFind(0, objectName) < 0)
      ObjectCreate(0, objectName, OBJ_LABEL, 0, 0, 0);

   ObjectSetInteger(0, objectName, OBJPROP_CORNER,     InpPanelCorner);
   ObjectSetInteger(0, objectName, OBJPROP_XDISTANCE,  xPosition);
   ObjectSetInteger(0, objectName, OBJPROP_YDISTANCE,  yPosition);
   ObjectSetString (0, objectName, OBJPROP_TEXT,       labelText);
   ObjectSetString (0, objectName, OBJPROP_FONT,       InpButtonFontName);
   ObjectSetInteger(0, objectName, OBJPROP_FONTSIZE,   fontSize);
   ObjectSetInteger(0, objectName, OBJPROP_COLOR,      textColor);
   ObjectSetInteger(0, objectName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, objectName, OBJPROP_HIDDEN,     true);
   ObjectSetInteger(0, objectName, OBJPROP_ZORDER,     2);
  }

void CreateButton(const string objectName, const int xPosition, const int yPosition,
                  const int buttonWidth, const int buttonHeight, const string buttonText,
                  const color backgroundColor, const int fontSize)
  {
   if(ObjectFind(0, objectName) < 0)
      ObjectCreate(0, objectName, OBJ_BUTTON, 0, 0, 0);

   ObjectSetInteger(0, objectName, OBJPROP_CORNER,      InpPanelCorner);
   ObjectSetInteger(0, objectName, OBJPROP_XDISTANCE,   xPosition);
   ObjectSetInteger(0, objectName, OBJPROP_YDISTANCE,   yPosition);
   ObjectSetInteger(0, objectName, OBJPROP_XSIZE,       buttonWidth);
   ObjectSetInteger(0, objectName, OBJPROP_YSIZE,       buttonHeight);
   ObjectSetString (0, objectName, OBJPROP_TEXT,        buttonText);
   ObjectSetString (0, objectName, OBJPROP_FONT,        InpButtonFontName);
   ObjectSetInteger(0, objectName, OBJPROP_FONTSIZE,    fontSize);
   ObjectSetInteger(0, objectName, OBJPROP_COLOR,       clrWhite);
   ObjectSetInteger(0, objectName, OBJPROP_BGCOLOR,     backgroundColor);
   ObjectSetInteger(0, objectName, OBJPROP_BORDER_COLOR, clrBlack);
   ObjectSetInteger(0, objectName, OBJPROP_STATE,       false);
   ObjectSetInteger(0, objectName, OBJPROP_HIDDEN,      true);
   ObjectSetInteger(0, objectName, OBJPROP_SELECTABLE,  false);
   ObjectSetInteger(0, objectName, OBJPROP_ZORDER,      5);
  }

void BuildNavPanel()
  {
   int panelBaseX = InpPanelXOffset;
   int panelBaseY = InpPanelYOffset;

   // 2 rows: Prev/Next, Reset
   int panelExpandedHeight = InpTitleBarHeight + InpPanelPadding + (2 * InpButtonHeight) + (1 * InpButtonGap) + InpPanelPadding;
   int currentPanelHeight = g_isNavPanelCollapsed ? InpTitleBarHeight : panelExpandedHeight;

   CreateRect(NAVPNL_BG, panelBaseX, panelBaseY, InpPanelWidth, currentPanelHeight, InpPanelBgColor, clrGray);
   CreateRect(NAVPNL_TITLE, panelBaseX, panelBaseY, InpPanelWidth, InpTitleBarHeight, InpTitleBgColor, clrGray);
   CreateLabel(NAVPNL_LABEL, panelBaseX + InpPanelPadding, panelBaseY + 6, "NAVIGATION", InpTitleTextColor, 9);

   int toggleButtonSize = InpTitleBarHeight - 8;
   int toggleButtonX    = panelBaseX + InpPanelWidth - toggleButtonSize - 4;
   int toggleButtonY    = panelBaseY + 4;
   CreateButton(NAVPNL_TOGGLE, toggleButtonX, toggleButtonY, toggleButtonSize, toggleButtonSize,
                g_isNavPanelCollapsed ? "+" : "-", C'70,70,80', 11);

   int innerContentX  = panelBaseX + InpPanelPadding;
   int innerContentWidth  = InpPanelWidth - (2 * InpPanelPadding);
   int firstRowY  = panelBaseY + InpTitleBarHeight + InpPanelPadding;
   int rowVerticalStep    = InpButtonHeight + InpButtonGap;

   int halfButtonWidth = (innerContentWidth - InpButtonGap) / 2;
   int remainingButtonWidth = innerContentWidth - halfButtonWidth - InpButtonGap;
   CreateButton(NAVBTN_PREV, innerContentX, firstRowY + 0*rowVerticalStep, halfButtonWidth, InpButtonHeight, "<< Prev", C'60,90,120', InpButtonFontSize - 1);
   CreateButton(NAVBTN_NEXT, innerContentX + halfButtonWidth + InpButtonGap, firstRowY + 0*rowVerticalStep, remainingButtonWidth, InpButtonHeight, "Next >>", C'60,90,120', InpButtonFontSize - 1);

   // Full-width Reset button below Prev/Next
   CreateButton(NAVBTN_RESET, innerContentX, firstRowY + 1*rowVerticalStep, innerContentWidth, InpButtonHeight, "Reset", C'120,90,40', InpButtonFontSize - 1);

   SetNavButtonsVisibility(!g_isNavPanelCollapsed);
   ChartRedraw();
  }

void SetNavButtonsVisibility(const bool isPanelVisible)
  {
   long timeframeVisibilityFlags = isPanelVisible ? OBJ_ALL_PERIODS : 0;
   ObjectSetInteger(0, NAVBTN_PREV,  OBJPROP_TIMEFRAMES, timeframeVisibilityFlags);
   ObjectSetInteger(0, NAVBTN_NEXT,  OBJPROP_TIMEFRAMES, timeframeVisibilityFlags);
   ObjectSetInteger(0, NAVBTN_RESET, OBJPROP_TIMEFRAMES, timeframeVisibilityFlags);
  }

void ToggleCollapse()
  {
   g_isNavPanelCollapsed = !g_isNavPanelCollapsed;
   ObjectSetInteger(0, NAVPNL_TOGGLE, OBJPROP_STATE, false);
   BuildNavPanel();
  }

void DeleteNavPanelObjects()
  {
   ObjectDelete(0, NAVPNL_BG);
   ObjectDelete(0, NAVPNL_TITLE);
   ObjectDelete(0, NAVPNL_LABEL);
   ObjectDelete(0, NAVPNL_TOGGLE);
   ObjectDelete(0, NAVBTN_PREV);
   ObjectDelete(0, NAVBTN_NEXT);
   ObjectDelete(0, NAVBTN_RESET);
  }

//+==================================================================+
//|                DRAGGABLE-LINE EVENT SUPPORT                      |
//+==================================================================+
//| Identify which family a dragged object belongs to.               |
//| Returns: 'H' = High, 'L' = Low, 'I' = Intermediate, 0 = other.   |
//+------------------------------------------------------------------+
ushort GetLineFamily(const string objectName, datetime &dayStartTime)
  {
   dayStartTime = 0;

   string highPrefix  = InpPrefix + "H_";
   string lowPrefix   = InpPrefix + "L_";
   string interPrefix = InpPrefix + "I_";

   string datePart = "";
   ushort family   = 0;

   if(StringFind(objectName, highPrefix) == 0)
     { family = 'H'; datePart = StringSubstr(objectName, StringLen(highPrefix)); }
   else if(StringFind(objectName, lowPrefix) == 0)
     { family = 'L'; datePart = StringSubstr(objectName, StringLen(lowPrefix)); }
   else if(StringFind(objectName, interPrefix) == 0)
     { family = 'I'; datePart = StringSubstr(objectName, StringLen(interPrefix)); }
   else
      return 0;

   dayStartTime = StringToTime(datePart);  // "yyyy.mm.dd" -> midnight
   dayStartTime = DayStart(dayStartTime);
   return family;
  }

//+------------------------------------------------------------------+
//| Handle a finished / in-progress drag of one of our lines:        |
//|  * Re-level the trend line (both anchors get the same price and  |
//|    the time anchors are snapped back to the day boundaries).     |
//|  * Pin the dragged price as the active level for that line.      |
//|  * Refresh tooltip, label text and the on-chart price label.     |
//+------------------------------------------------------------------+
void HandleLineDrag(const string objectName)
  {
   datetime dayStartTime = 0;
   ushort   family       = GetLineFamily(objectName, dayStartTime);
   if(family == 0 || dayStartTime == 0)
      return;

   if(ObjectFind(0, objectName) < 0)
      return;

   //--- The user may have dropped either anchor anywhere: use the
   //    price of anchor 0 as the new level and force the line flat
   //    and back inside its own day.
   double newLevelPrice = ObjectGetDouble(0, objectName, OBJPROP_PRICE, 0);
   newLevelPrice = NormalizeDouble(newLevelPrice, _Digits);

   datetime dayEndTime = dayStartTime + 86400 - 1;

   ObjectSetInteger(0, objectName, OBJPROP_TIME,  0, dayStartTime);
   ObjectSetInteger(0, objectName, OBJPROP_TIME,  1, dayEndTime);
   ObjectSetDouble (0, objectName, OBJPROP_PRICE, 0, newLevelPrice);
   ObjectSetDouble (0, objectName, OBJPROP_PRICE, 1, newLevelPrice);

   //--- The dragged position becomes the new active price level:
   //    pin it so recalculation never overwrites it.
   SetManualPrice(objectName, newLevelPrice);

   //--- Refresh displayed price info
   string lineTypeText = (family == 'H') ? "High" : (family == 'L') ? "Low" : "Intermediate";
   ObjectSetString(0, objectName, OBJPROP_TOOLTIP,
                   lineTypeText + " (manual)  (" + DoubleToString(newLevelPrice, _Digits) + ")");
   if(InpShowLabel)
      ObjectSetString(0, objectName, OBJPROP_TEXT, DoubleToString(newLevelPrice, _Digits));

   //--- Real-time on-chart price label update
   UpdatePriceLabelForLine(family, dayStartTime, newLevelPrice);

   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Create / move / remove the price label of one line family.       |
//| The label is anchored immediately BEFORE the reference time of   |
//| its trading day, at the line's current price.                    |
//+------------------------------------------------------------------+
void UpdatePriceLabelForLine(const ushort family, const datetime dayStartTime, const double levelPrice)
  {
   string labelName  = "";
   bool   showLabel  = false;
   color  labelColor = clrWhite;
   
   //--- Define a variable for the anchor point, defaulting to center-right
   ENUM_ANCHOR_POINT anchor = ANCHOR_RIGHT; 

   if(family == 'H')
     { 
      labelName  = HighLabelName(dayStartTime);  
      showLabel  = InpShowHighPriceLabel;  
      labelColor = InpHighColor; 
      //--- Anchor at the bottom of the text so it appears ABOVE the line
      anchor     = ANCHOR_RIGHT_LOWER; 
     }
   else if(family == 'L')
     { 
      labelName  = LowLabelName(dayStartTime);   
      showLabel  = InpShowLowPriceLabel;   
      labelColor = InpLowColor;  
      //--- Anchor at the top of the text so it appears BELOW the line
      anchor     = ANCHOR_RIGHT_UPPER; 
     }
   else if(family == 'I')
     {
      labelName  = InterLabelName(dayStartTime);
      showLabel  = InpShowInterPriceLabel;
      //--- Match the intermediate line's current color when possible
      string interLineName = InterName(dayStartTime);
      labelColor = (ObjectFind(0, interLineName) >= 0)
                   ? (color)ObjectGetInteger(0, interLineName, OBJPROP_COLOR)
                   : InpInterHighColor;
      //--- Keep intermediate label centered vertically
      anchor     = ANCHOR_RIGHT; 
     }
   else
      return;

   if(!showLabel)
     {
      if(ObjectFind(0, labelName) >= 0)
         ObjectDelete(0, labelName);
      return;
     }

   //--- Anchor: immediately before the reference time of this day
   datetime referenceBrokerTime = GetTargetBrokerTime(dayStartTime, InpHour, InpMinute);
   datetime labelAnchorTime     = referenceBrokerTime - PeriodSeconds(_Period);
   if(labelAnchorTime < dayStartTime)
      labelAnchorTime = dayStartTime;

   if(ObjectFind(0, labelName) < 0)
     {
      if(!ObjectCreate(0, labelName, OBJ_TEXT, 0, labelAnchorTime, levelPrice))
         return;
     }
   else
     {
      ObjectSetInteger(0, labelName, OBJPROP_TIME,  0, labelAnchorTime);
      ObjectSetDouble (0, labelName, OBJPROP_PRICE, 0, levelPrice);
     }

   ObjectSetString (0, labelName, OBJPROP_TEXT,       DoubleToString(levelPrice, _Digits));
   ObjectSetString (0, labelName, OBJPROP_FONT,       InpPriceLabelFontName);
   ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE,   InpPriceLabelFontSize);
   ObjectSetInteger(0, labelName, OBJPROP_COLOR,      labelColor);
   
   //--- Apply the dynamic anchor point here
   ObjectSetInteger(0, labelName, OBJPROP_ANCHOR,     anchor); 
   
   ObjectSetInteger(0, labelName, OBJPROP_BACK,       false);
   ObjectSetInteger(0, labelName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, labelName, OBJPROP_HIDDEN,     true);
  }

//+------------------------------------------------------------------+
//| Remove the price label of one line family (used when the line    |
//| itself disappears, e.g. a stale intermediate line).              |
//+------------------------------------------------------------------+
void DeletePriceLabelForLine(const ushort family, const datetime dayStartTime)
  {
   string labelName = "";
   if(family == 'H')      labelName = HighLabelName(dayStartTime);
   else if(family == 'L') labelName = LowLabelName(dayStartTime);
   else if(family == 'I') labelName = InterLabelName(dayStartTime);
   else return;

   if(ObjectFind(0, labelName) >= 0)
      ObjectDelete(0, labelName);
  }

//+==================================================================+
//|                       CHART EVENT HANDLER                        |
//+==================================================================+
void OnChartEvent(const int eventId, const long &longEventParam,
                  const double &doubleEventParam, const string &stringEventParam)
  {
   //--- Draggable horizontal lines: the price updates in real time
   //    while the object is moved and when the drag completes.
   if(eventId == CHARTEVENT_OBJECT_DRAG || eventId == CHARTEVENT_OBJECT_CHANGE)
     {
      HandleLineDrag(stringEventParam);
      // fall through: nav-panel handling below is click-only
     }

   if(!InpShowNavPanel)
      return;

   if(eventId != CHARTEVENT_OBJECT_CLICK)
      return;

   if(stringEventParam == NAVPNL_TOGGLE)
     {
      ToggleCollapse();
      return;
     }

   if(g_isNavPanelCollapsed) return;

   if(stringEventParam == NAVBTN_PREV)
     {
      NavigateChart(-1);
      ResetButton(NAVBTN_PREV);
     }
   else if(stringEventParam == NAVBTN_NEXT)
     {
      NavigateChart(1);
      ResetButton(NAVBTN_NEXT);
     }
   else if(stringEventParam == NAVBTN_RESET)
     {
      ResetNavigation();
      ResetButton(NAVBTN_RESET);
     }
  }

void ResetButton(const string buttonObjectName)
  {
   ObjectSetInteger(0, buttonObjectName, OBJPROP_STATE, false);
   ChartRedraw();
  }

//+==================================================================+
//|                      CHART NAVIGATION                            |
//+==================================================================+
void NavigateChart(int daysToNavigate)
  {
   // Turn off Autoscroll so incoming ticks don't violently snap the chart back to present
   ChartSetInteger(0, CHART_AUTOSCROLL, false);

   // Initialize base tracking time if missing or after a Reset:
   // Use the latest available bar instead of TimeCurrent() to guarantee 
   // it works robustly on weekends when the market is closed.
   if(g_currentNavigationTargetTime == 0)
     {
      g_currentNavigationTargetTime = iTime(_Symbol, _Period, 0);
     }

   // Identify the day of our current anchor
   datetime currentAnchorDayStart = DayStart(g_currentNavigationTargetTime);
   int currentBarIndex = iBarShift(_Symbol, _Period, g_currentNavigationTargetTime, false);
   if(currentBarIndex < 0) currentBarIndex = 0;

   datetime newTargetTime = 0;
   int foundBarIndex = -1;
   int totalBars = iBars(_Symbol, _Period);

   // --- DATA-DRIVEN NAVIGATION ---
   // Instead of adding/subtracting 86400 seconds (which breaks on weekends/holidays),
   // we scan the actual chart history to find the previous/next trading day.
   if(daysToNavigate < 0) // Prev
     {
      int daysFound = 0;
      datetime trackingDay = currentAnchorDayStart;
      
      for(int i = currentBarIndex; i < totalBars; i++)
        {
         datetime barDay = DayStart(iTime(_Symbol, _Period, i));
         if(barDay < trackingDay)
           {
            daysFound++;
            trackingDay = barDay;
            if(daysFound == MathAbs(daysToNavigate))
              {
               newTargetTime = GetTargetBrokerTime(trackingDay, InpHour, InpMinute);
               foundBarIndex = iBarShift(_Symbol, _Period, newTargetTime, false);
               break;
              }
           }
        }
     }
   else if(daysToNavigate > 0) // Next
     {
      int daysFound = 0;
      datetime trackingDay = currentAnchorDayStart;
      
      for(int i = currentBarIndex; i >= 0; i--)
        {
         datetime barDay = DayStart(iTime(_Symbol, _Period, i));
         if(barDay > trackingDay)
           {
            daysFound++;
            trackingDay = barDay;
            if(daysFound == daysToNavigate)
              {
               newTargetTime = GetTargetBrokerTime(trackingDay, InpHour, InpMinute);
               foundBarIndex = iBarShift(_Symbol, _Period, newTargetTime, false);
               break;
              }
           }
        }
     }

   // --- If a valid previous/next trading day was found in the chart data ---
   if(newTargetTime != 0 && foundBarIndex >= 0)
     {
      // Save newly resolved time for successive clicks
      g_currentNavigationTargetTime = newTargetTime;

      int visibleBarsOnChart = (int)ChartGetInteger(0, CHART_VISIBLE_BARS);

      // We want the 'foundBarIndex' exactly in the middle of our view.
      // We calculate where the right edge of our view needs to be to achieve this.
      int rightEdgeBarIndex = foundBarIndex - (visibleBarsOnChart / 2);

      // Clamping prevents attempting to scroll into unformed future bars
      if(rightEdgeBarIndex < 0) rightEdgeBarIndex = 0;

      // A negative shift pushes the chart backward (left) from CHART_END (bar 0)
      ChartNavigate(0, CHART_END, -rightEdgeBarIndex);

      // --- SHIFT Y-AXIS TO TARGET BAR PRICE ---
      if(ChartGetInteger(0, CHART_SCALEFIX))
        {
         double chartFixedMaxPrice = ChartGetDouble(0, CHART_FIXED_MAX);
         double chartFixedMinPrice = ChartGetDouble(0, CHART_FIXED_MIN);
         double chartPriceScaleHeight = chartFixedMaxPrice - chartFixedMinPrice;

         double targetBarClosePrice = iClose(_Symbol, _Period, foundBarIndex);

         if(targetBarClosePrice > 0.0 && chartPriceScaleHeight > 0.0)
           {
            ChartSetDouble(0, CHART_FIXED_MAX, targetBarClosePrice + (chartPriceScaleHeight / 2.0));
            ChartSetDouble(0, CHART_FIXED_MIN, targetBarClosePrice - (chartPriceScaleHeight / 2.0));
           }
        }
     }

   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Reset: jump back to the last (current) candle and clear nav state|
//| After Reset, the next << Prev click navigates to the last day.   |
//+------------------------------------------------------------------+
void ResetNavigation()
  {  
   // Clear all manually moved prices
   ClearManualPrices();

   // Delete current chart lines for redrawing
   DeleteObjects();
   
   // Clear stored Prev/Next state -> navigation restarts from "today"
   g_currentNavigationTargetTime = 0;

   // Bring the chart view back to the most recent candle (like NavigateChart(today))
   ChartSetInteger(0, CHART_AUTOSCROLL, false);
   ChartNavigate(0, CHART_END, 0);

   // If a fixed scale is enabled, re-center the Y-axis on the latest close
   if(ChartGetInteger(0, CHART_SCALEFIX))
     {
      double chartFixedMaxPrice = ChartGetDouble(0, CHART_FIXED_MAX);
      double chartFixedMinPrice = ChartGetDouble(0, CHART_FIXED_MIN);
      double chartPriceScaleHeight = chartFixedMaxPrice - chartFixedMinPrice;

      double latestClosePrice = iClose(_Symbol, _Period, 0);
      if(latestClosePrice > 0.0 && chartPriceScaleHeight > 0.0)
        {
         ChartSetDouble(0, CHART_FIXED_MAX, latestClosePrice + (chartPriceScaleHeight / 2.0));
         ChartSetDouble(0, CHART_FIXED_MIN, latestClosePrice - (chartPriceScaleHeight / 2.0));
        }
     }

   // Re-enable autoscroll so the chart keeps following new candles
   ChartSetInteger(0, CHART_AUTOSCROLL, true);

   ChartRedraw();
   Print("DRHL: Navigation reset -> chart back to last candle.");
  }

//+------------------------------------------------------------------+
//| Custom indicator iteration function                              |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double   &open[],
                const double   &high[],
                const double   &low[],
                const double   &close[],
                const long     &tick_volume[],
                const long     &volume[],
                const int      &spread[])
  {
   if(!InpEnable || rates_total <= 1)
      return(rates_total);

   //---------------------------------------------------------------
   // Decide which bars to (re)scan:
   //  * First run / history reload -> scan every bar.
   //  * Subsequent ticks           -> re-scan only a short tail
   //    (from yesterday 00:00) so live ticks never re-walk the
   //    whole history, while today's levels appear automatically
   //    once the reference candle forms.
   //---------------------------------------------------------------
   int scanStartIndex = 0;
   if(prev_calculated > 0)
     {
      datetime scanTailStartTime = DayStart(time[rates_total - 1]) - 86400; // yesterday 00:00
      scanStartIndex = prev_calculated - 1;
      while(scanStartIndex > 0 && time[scanStartIndex] >= scanTailStartTime)
         scanStartIndex--;
     }

   //---------------------------------------------------------------
   // Walk the slice; process each trading day exactly once,
   // independently of every other day.
   //---------------------------------------------------------------
   for(int rateIndex = scanStartIndex; rateIndex < rates_total; rateIndex++)
     {
      bool isNewTradingDay = (rateIndex == 0) || (DayStart(time[rateIndex]) != DayStart(time[rateIndex - 1]));
      if(!isNewTradingDay)
         continue;

      datetime currentDayStartTime = DayStart(time[rateIndex]);

      //--- Broker-time instant of the requested vertical-line time
      datetime targetBrokerDatetime = GetTargetBrokerTime(currentDayStartTime, InpHour, InpMinute);

      //--- 1) Vertical reference line
      DrawVerticalLine(currentDayStartTime, targetBrokerDatetime);

      //--- 2) Swing High/Low detection + day-bounded horizontal lines
      ProcessDayLevels(currentDayStartTime, targetBrokerDatetime, rates_total, time, open, high, low, close);
     }

   ChartRedraw(0);
   return(rates_total);
  }

//+------------------------------------------------------------------+
//| Draw / refresh the vertical reference line for one day           |
//+------------------------------------------------------------------+
void DrawVerticalLine(datetime dayStartTime, datetime targetDatetime)
  {
   string verticalLineName = VLineName(dayStartTime);

   if(ObjectFind(0, verticalLineName) < 0)
     {
      if(!ObjectCreate(0, verticalLineName, OBJ_VLINE, 0, targetDatetime, 0))
         return;
     }
   else
     {
      // Refresh anchor (e.g. when DST rolls or inputs change)
      ObjectSetInteger(0, verticalLineName, OBJPROP_TIME, 0, targetDatetime);
     }

   ObjectSetInteger(0, verticalLineName, OBJPROP_COLOR,      InpVLineColor);
   ObjectSetInteger(0, verticalLineName, OBJPROP_STYLE,      InpVLineStyle);
   ObjectSetInteger(0, verticalLineName, OBJPROP_WIDTH,      InpVLineWidth);
   ObjectSetInteger(0, verticalLineName, OBJPROP_BACK,       InpVLineBackground);
   ObjectSetInteger(0, verticalLineName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, verticalLineName, OBJPROP_HIDDEN,     true);
   ObjectSetString (0, verticalLineName, OBJPROP_TOOLTIP,
                    "Reference: " + TimeToString(targetDatetime, TIME_DATE|TIME_MINUTES));
  }

//+------------------------------------------------------------------+
//| Locate the reference candle: the last bar whose open time is     |
//| <= targetDatetime (i.e. the candle that corresponds to the       |
//| vertical-line time). Returns -1 when targetDatetime is outside   |
//| the loaded history.                                              |
//+------------------------------------------------------------------+
int FindReferenceIndex(datetime targetDatetime,
                       int totalRates,
                       const datetime &time[])
  {
   if(totalRates <= 0)                  return -1;
   if(targetDatetime < time[0])               return -1;
   if(targetDatetime > time[totalRates - 1]) return -1;

   //--- Binary search: last index with time[idx] <= targetDatetime
   int searchLowIndex = 0, searchHighIndex = totalRates - 1, foundReferenceIndex = -1;
   while(searchLowIndex <= searchHighIndex)
     {
      int searchMidIndex = (searchLowIndex + searchHighIndex) / 2;
      if(time[searchMidIndex] <= targetDatetime) { foundReferenceIndex = searchMidIndex; searchLowIndex = searchMidIndex + 1; }
      else                       { searchHighIndex = searchMidIndex - 1; }
     }
   return foundReferenceIndex;
  }

//+------------------------------------------------------------------+
//| For one trading day:                                             |
//|  * Locate the reference candle at the vertical-line time.        |
//|  * Detect swing High/Low over the InpLookbackBars candles        |
//|    immediately preceding it (ref_idx-1 .. ref_idx-Lookback).     |
//|    The candle directly before the reference candle IS included. |
//|  * Apply Method 2 update rules when selected.                    |
//|  * Draw High/Low (and optional intermediate) horizontal lines    |
//|    strictly bounded to [day 00:00 .. day 23:59:59].              |
//|  * Lines that were manually dragged keep their dragged price.    |
//+------------------------------------------------------------------+
void ProcessDayLevels(datetime dayStartTime,
                      datetime targetDatetime,
                      int totalRates,
                      const datetime &time[],
                      const double &open[],
                      const double &high[],
                      const double &low[],
                      const double &close[])
  {
   //--- Locate the reference bar for this day
   int referenceBarIndex = FindReferenceIndex(targetDatetime, totalRates, time);
   if(referenceBarIndex <= 0)
      return; // Reference not covered by history, or no candles before it

   //================================================================
   //  METHOD 3: High/Low are simply the reference candle's High/Low
   //================================================================
   if(InpSwingMethod == SWING_METHOD_3)
     {
      datetime dayEndTimeM3 = dayStartTime + 86400 - 1;

      double refHighPrice = high[referenceBarIndex];
      double refLowPrice  = low[referenceBarIndex];

      //--- High line
      DrawDailyHorizontalLine(HighName(dayStartTime),
                              dayStartTime, dayEndTimeM3,
                              refHighPrice,
                              InpHighColor, InpHighStyle, InpHLineWidth,
                              "Ref Candle High @ " + TimeToString(time[referenceBarIndex], TIME_DATE|TIME_MINUTES)
                              + "  (" + DoubleToString(refHighPrice, _Digits) + ")");

      //--- Low line
      DrawDailyHorizontalLine(LowName(dayStartTime),
                              dayStartTime, dayEndTimeM3,
                              refLowPrice,
                              InpLowColor, InpLowStyle, InpHLineWidth,
                              "Ref Candle Low @ " + TimeToString(time[referenceBarIndex], TIME_DATE|TIME_MINUTES)
                              + "  (" + DoubleToString(refLowPrice, _Digits) + ")");

      //--- Price labels for High/Low lines
      RefreshLinePriceLabel('H', dayStartTime, HighName(dayStartTime));
      RefreshLinePriceLabel('L', dayStartTime, LowName(dayStartTime));

      //--- No intermediate line for Method 3: remove any stale one
      string interNameM3 = InterName(dayStartTime);
      if(ObjectFind(0, interNameM3) >= 0)
         ObjectDelete(0, interNameM3);
      DeletePriceLabelForLine('I', dayStartTime);

      return; // Method 3 is complete; skip Method 1/2 logic
     }
     
   //--- Window: the Lookback completed candles BEFORE the reference
   int searchStartIndex = referenceBarIndex - 1;                              // candle right before reference (included)
   int searchEndIndex   = MathMax(referenceBarIndex - InpLookbackBars, 0);    // inclusive lower bound

   //--- Base swings (Method 1): highest High / lowest Low of window
   int    highestHighIndex = -1, lowestLowIndex = -1;
   double highestHighPrice = -DBL_MAX, lowestLowPrice = DBL_MAX;

   for(int scanIndex = searchStartIndex; scanIndex >= searchEndIndex; scanIndex--)
     {
      if(high[scanIndex] > highestHighPrice) { highestHighPrice = high[scanIndex]; highestHighIndex = scanIndex; }
      if(low[scanIndex]  < lowestLowPrice) { lowestLowPrice = low[scanIndex];  lowestLowIndex = scanIndex; }
     }

   if(highestHighIndex < 0 || lowestLowIndex < 0)
      return;

   //--- Final (possibly updated) levels
   double finalHighPrice = highestHighPrice,  finalLowPrice = lowestLowPrice;
   int    finalHighIndex = highestHighIndex, finalLowIndex = lowestLowIndex;

   //--- Method 2: alternate swing update rules
   bool   isUpdatedSwingFound    = false;   // an updated swing level exists
   bool   isUpdatedSwingALow   = false;   // true -> updated Low, false -> updated High
   double updatedSwingPrice    = 0.0;
   int    updatedSwingIndex      = -1;

   bool isNewHighFound = false;
   bool isNewLowFound = false;

   if(InpSwingMethod == SWING_METHOD_2 && highestHighIndex != lowestLowIndex)
     {
      if(lowestLowIndex < highestHighIndex)
        {
         //--- Confirmed Low first, then High found afterwards.
         //    Count bearish candles from the High candle ITSELF (included)
         //    up to the candle before the reference time (cumulative,
         //    not necessarily consecutive).
         int bearishCandleCount = 0;
         for(int scanIndex = highestHighIndex; scanIndex <= searchStartIndex; scanIndex++)   // starts AT the High candle
            if(close[scanIndex] < open[scanIndex])
               bearishCandleCount++;

         if(bearishCandleCount >= InpUpdateCandles)
           {
            //--- Update the Low: lowest Low of the range from the High candle onward
            double newLowestLowPrice = DBL_MAX; int newLowestLowIndex = -1;
            for(int scanIndex = highestHighIndex; scanIndex <= searchStartIndex; scanIndex++)
               if(low[scanIndex] < newLowestLowPrice) { newLowestLowPrice = low[scanIndex]; newLowestLowIndex = scanIndex; }

            if(newLowestLowIndex >= 0)
              {
               isNewLowFound = true;
               isUpdatedSwingFound  = true;
               isUpdatedSwingALow = true;
               updatedSwingPrice  = newLowestLowPrice;
               updatedSwingIndex    = newLowestLowIndex;
              }
           }
        }
      else // highestHighIndex < lowestLowIndex
        {
         //--- Confirmed High first, then Low found afterwards.
         //    Count bullish candles from the Low candle ITSELF (included)
         //    up to the candle before the reference time.
         int bullishCandleCount = 0;
         for(int scanIndex = lowestLowIndex; scanIndex <= searchStartIndex; scanIndex++)     // starts AT the Low candle
            if(close[scanIndex] > open[scanIndex])
               bullishCandleCount++;

         if(bullishCandleCount >= InpUpdateCandles)
           {
            //--- Update the High: highest High of the range from the Low candle onward
            double newHighestHighPrice = -DBL_MAX; int newHighestHighIndex = -1;
            for(int scanIndex = lowestLowIndex; scanIndex <= searchStartIndex; scanIndex++)
               if(high[scanIndex] > newHighestHighPrice) { newHighestHighPrice = high[scanIndex]; newHighestHighIndex = scanIndex; }

            if(newHighestHighIndex >= 0)
              {
               isNewHighFound = true;
               isUpdatedSwingFound  = true;
               isUpdatedSwingALow = false;
               updatedSwingPrice  = newHighestHighPrice;
               updatedSwingIndex    = newHighestHighIndex;
              }
           }
        }
     }

   //--- Apply drawing mode
   bool shouldDrawThirdLine = false;
   if(isUpdatedSwingFound)
     {
      if(InpDrawMode == DRAW_UPDATE_MAIN)
        {
         //--- Main line moves to the final updated value
         if(isUpdatedSwingALow) { finalLowPrice  = updatedSwingPrice; finalLowIndex  = updatedSwingIndex; }
         else           { finalHighPrice = updatedSwingPrice; finalHighIndex = updatedSwingIndex; }
        }
      else if(InpDrawIntermediate)
        {
         //--- Main lines keep base swings; updated level -> third line
         shouldDrawThirdLine = true;
        }
     }

   //--- Day boundaries: lines live ONLY inside this day
   datetime currentDayEndTime = dayStartTime + 86400 - 1;

   //--- High line
   DrawDailyHorizontalLine(HighName(dayStartTime),
                           dayStartTime, currentDayEndTime,
                           finalHighPrice,
                           InpHighColor, InpHighStyle, InpHLineWidth,
                           "High @ " + TimeToString(time[finalHighIndex], TIME_DATE|TIME_MINUTES)
                           + "  (" + DoubleToString(finalHighPrice, _Digits) + ")");

   //--- Low line
   DrawDailyHorizontalLine(LowName(dayStartTime),
                           dayStartTime, currentDayEndTime,
                           finalLowPrice,
                           InpLowColor, InpLowStyle, InpHLineWidth,
                           "Low @ " + TimeToString(time[finalLowIndex], TIME_DATE|TIME_MINUTES)
                           + "  (" + DoubleToString(finalLowPrice, _Digits) + ")");

   //--- Price labels for High/Low lines (reflect actual line price,
   //    including any manual drag override)
   RefreshLinePriceLabel('H', dayStartTime, HighName(dayStartTime));
   RefreshLinePriceLabel('L', dayStartTime, LowName(dayStartTime));

   //--- Intermediate (third) line -- create or remove as needed so
   //    tail re-scans never leave stale objects behind.
   string intermediateLineName = InterName(dayStartTime);
   if(shouldDrawThirdLine)
     {
      color intermediateLineColor = clrWhite;
      if(isNewHighFound) intermediateLineColor =  InpInterHighColor;
      if(isNewLowFound) intermediateLineColor =  InpInterLowColor;

      DrawDailyHorizontalLine(intermediateLineName,
                              dayStartTime, currentDayEndTime,
                              updatedSwingPrice,
                              intermediateLineColor, InpInterStyle, InpInterWidth,
                              (isUpdatedSwingALow ? "Updated Low @ " : "Updated High @ ")
                              + TimeToString(time[updatedSwingIndex], TIME_DATE|TIME_MINUTES)
                              + "  (" + DoubleToString(updatedSwingPrice, _Digits) + ")");

      RefreshLinePriceLabel('I', dayStartTime, intermediateLineName);
     }
   else if(ObjectFind(0, intermediateLineName) >= 0)
     {
      ObjectDelete(0, intermediateLineName);
      DeletePriceLabelForLine('I', dayStartTime);
     }
   else
     {
      DeletePriceLabelForLine('I', dayStartTime);
     }
  }

//+------------------------------------------------------------------+
//| Sync a line's price label with the line's CURRENT price          |
//| (which may be a manually dragged level).                         |
//+------------------------------------------------------------------+
void RefreshLinePriceLabel(const ushort family, const datetime dayStartTime, const string lineName)
  {
   if(ObjectFind(0, lineName) < 0)
     {
      DeletePriceLabelForLine(family, dayStartTime);
      return;
     }
   double currentLinePrice = ObjectGetDouble(0, lineName, OBJPROP_PRICE, 0);
   UpdatePriceLabelForLine(family, dayStartTime, currentLinePrice);
  }

//+------------------------------------------------------------------+
//| Draw / refresh a horizontal segment bounded to one day.          |
//| Uses OBJ_TREND with rays disabled so the line stops exactly at   |
//| the day's end (OBJ_HLINE would span the entire chart).           |
//| Lines are SELECTABLE so the user can drag them; a manually       |
//| dragged price is pinned and never overwritten here.              |
//+------------------------------------------------------------------+
void DrawDailyHorizontalLine(const string lineName,
                             datetime startTime,
                             datetime endTime,
                             double   levelPrice,
                             color    lineColor,
                             ENUM_LINE_STYLE lineStyle,
                             int      lineWidth,
                             const string tooltipText)
  {
   //--- If the user dragged this line, the dragged position is the
   //    new active price level: keep it instead of the computed one.
   double manualPrice = 0.0;
   bool   hasManualOverride = GetManualPrice(lineName, manualPrice);
   double effectivePrice    = hasManualOverride ? manualPrice : levelPrice;

   if(ObjectFind(0, lineName) < 0)
     {
      if(!ObjectCreate(0, lineName, OBJ_TREND, 0, startTime, effectivePrice, endTime, effectivePrice))
         return;
     }
   else
     {
     // Added condition: if the line is being moved (selected), its price should not be reset by new ticks.
     if(!ObjectGetInteger(0, lineName, OBJPROP_SELECTED))
        {
         // Refresh anchors/levelPrice in case bars around the reference changed
         ObjectSetInteger(0, lineName, OBJPROP_TIME,  0, startTime);
         ObjectSetInteger(0, lineName, OBJPROP_TIME,  1, endTime);
         ObjectSetDouble (0, lineName, OBJPROP_PRICE, 0, effectivePrice);
         ObjectSetDouble (0, lineName, OBJPROP_PRICE, 1, effectivePrice);
        }
     }

   ObjectSetInteger(0, lineName, OBJPROP_COLOR,      lineColor);
   ObjectSetInteger(0, lineName, OBJPROP_STYLE,      lineStyle);
   ObjectSetInteger(0, lineName, OBJPROP_WIDTH,      lineWidth);
   ObjectSetInteger(0, lineName, OBJPROP_BACK,       InpHLineBackground);
   ObjectSetInteger(0, lineName, OBJPROP_RAY_LEFT,   false);
   ObjectSetInteger(0, lineName, OBJPROP_RAY_RIGHT,  false);
   ObjectSetInteger(0, lineName, OBJPROP_RAY,        false);
   ObjectSetInteger(0, lineName, OBJPROP_SELECTABLE, true);
   ObjectSetInteger(0, lineName, OBJPROP_HIDDEN,     false);
   ObjectSetString (0, lineName, OBJPROP_TOOLTIP,
                    hasManualOverride
                    ? tooltipText + "  [dragged to " + DoubleToString(effectivePrice, _Digits) + "]"
                    : tooltipText);

   if(InpShowLabel)
      ObjectSetString(0, lineName, OBJPROP_TEXT, DoubleToString(effectivePrice, _Digits));
  }

//+------------------------------------------------------------------+
//| Calculate the target time in Broker Server Time                  |
//+------------------------------------------------------------------+
datetime GetTargetBrokerTime(datetime brokerDayStartTime, int targetHour, int targetMinute)
  {
   // If the user selected Broker time, no timezone conversion is needed
   if(InpTimeZone == TZ_BROKER)
      return brokerDayStartTime + targetHour * 3600 + targetMinute * 60;

   // Construct the target time as if it were local to the chosen timezone
   datetime localTargetDatetime      = brokerDayStartTime + targetHour * 3600 + targetMinute * 60;
   int      timezoneOffsetSeconds = 0;

   switch(InpTimeZone)
     {
      case TZ_UTC:
         timezoneOffsetSeconds = 0;
         break;
      case TZ_TEHRAN_NO_DST:
         timezoneOffsetSeconds = 3 * 3600 + 1800; // Fixed +3:30 (no DST)
         break;
      case TZ_TEHRAN_DST:
         // +4:30 (16200 seconds) in Summer, +3:30 (12600 seconds) in Winter
         timezoneOffsetSeconds = IsTehran_DST(localTargetDatetime) ? 4 * 3600 + 1800 : 3 * 3600 + 1800;
         break;
      case TZ_CUSTOM:
         timezoneOffsetSeconds = (int)(InpCustomOffset * 3600.0);
         break;
      case TZ_NEW_YORK:
         timezoneOffsetSeconds = IsUS_DST(localTargetDatetime) ? -4 * 3600 : -5 * 3600;
         break;
      case TZ_LONDON:
         timezoneOffsetSeconds = IsEU_DST(localTargetDatetime) ?  1 * 3600 :  0;
         break;
     }

   // 1) Convert the requested local time to GMT
   datetime targetGmtDatetime    = localTargetDatetime - timezoneOffsetSeconds;
   // 2) Convert GMT to Broker Server Time
   datetime targetBrokerDatetime = targetGmtDatetime + g_brokerToGmtOffsetSeconds;

   return targetBrokerDatetime;
  }

//+------------------------------------------------------------------+
//| Check Iran Daylight Saving Time (Tehran)                         |
//| Starts: ~March 21/22 (Midnight entering 2nd of Farvardin)        |
//| Ends:   ~September 21/22 (Midnight entering 31st of Shahrivar)   |
//+------------------------------------------------------------------+
bool IsTehran_DST(datetime timeToCheck)
  {
   MqlDateTime timeStruct;
   TimeToStruct(timeToCheck, timeStruct);

   // Months definitively inside the DST period: April (4) to August (8)
   if(timeStruct.mon > 3 && timeStruct.mon < 9) return true;
   
   // Months definitively outside the DST period: October (10) to February (2)
   if(timeStruct.mon < 3 || timeStruct.mon > 9) return false;

   // March: DST usually starts on March 21st or 22nd
   if(timeStruct.mon == 3)
     {
      // Assume DST is active from March 22nd onwards
      if(timeStruct.day >= 22) return true;
      return false;
     }

   // September: DST usually ends on September 21st or 22nd
   if(timeStruct.mon == 9)
     {
      // Assume DST is active until September 21st, then reverts to standard time
      if(timeStruct.day <= 21) return true;
      return false;
     }

   return false;
  }
  
//+------------------------------------------------------------------+
//| Check US Daylight Saving Time (New York)                         |
//| Starts: 2nd Sunday in March (02:00)                              |
//| Ends:   1st Sunday in November (02:00)                           |
//+------------------------------------------------------------------+
bool IsUS_DST(datetime timeToCheck)
  {
   MqlDateTime timeStruct;
   TimeToStruct(timeToCheck, timeStruct);

   if(timeStruct.mon > 3 && timeStruct.mon < 11) return true;
   if(timeStruct.mon < 3 || timeStruct.mon > 11) return false;

   int firstDayOfWeek = (timeStruct.day_of_week - (timeStruct.day - 1) % 7 + 7) % 7;
   int firstSundayDate  = (firstDayOfWeek == 0) ? 1 : (8 - firstDayOfWeek);

   if(timeStruct.mon == 3) // Starts on the 2nd Sunday
     {
      int secondSundayDate = firstSundayDate + 7;
      if(timeStruct.day > secondSundayDate) return true;
      if(timeStruct.day < secondSundayDate) return false;
      return (timeStruct.hour >= 2);
     }

   // November: ends on the 1st Sunday
   if(timeStruct.day > firstSundayDate) return false;
   if(timeStruct.day < firstSundayDate) return true;
   return (timeStruct.hour < 2);
  }

//+------------------------------------------------------------------+
//| Check EU Daylight Saving Time (London)                           |
//| Starts: Last Sunday in March (01:00 GMT)                         |
//| Ends:   Last Sunday in October (02:00 BST)                       |
//+------------------------------------------------------------------+
bool IsEU_DST(datetime timeToCheck)
  {
   MqlDateTime timeStruct;
   TimeToStruct(timeToCheck, timeStruct);

   if(timeStruct.mon > 3 && timeStruct.mon < 10) return true;
   if(timeStruct.mon < 3 || timeStruct.mon > 10) return false;

   int firstDayOfWeek = (timeStruct.day_of_week - (timeStruct.day - 1) % 7 + 7) % 7;
   int firstSundayDate  = (firstDayOfWeek == 0) ? 1 : (8 - firstDayOfWeek);

   int lastSundayDate = firstSundayDate;
   while(lastSundayDate + 7 <= 31) lastSundayDate += 7; // March & October both have 31 days

   if(timeStruct.mon == 3)
     {
      if(timeStruct.day > lastSundayDate) return true;
      if(timeStruct.day < lastSundayDate) return false;
      return (timeStruct.hour >= 1);
     }

   // October
   if(timeStruct.day > lastSundayDate) return false;
   if(timeStruct.day < lastSundayDate) return true;
   return (timeStruct.hour < 2);
  }
//+------------------------------------------------------------------+
