=== HIGH/LOW DETECTION ANALYSIS ===

The provided code identifies daily High and Low swing levels relative to a user-defined daily reference time (e.g., 09:30). The detection mechanism operates on a per-trading-day basis through three distinct detection methods:

---

### 1. Reference Point Determination

* **Target Reference Time:** Calculated for each trading day based on user-specified hours, minutes, and time zone offset rules (converting UTC, NY, London, Tehran, or Custom times to broker time).
* **Reference Candle:** The candle whose open time is less than or equal to the target reference time.
* **Lookback Window:** A range of $N$ completed candles (default: 20) situated **immediately prior** to the reference candle. The candle directly preceding the reference candle is included in this window.

---

### 2. Swing Detection Methods

#### **Method 1: Highest High / Lowest Low (Base Swings)**

1. **High Selection:** Scans all $N$ completed candles in the lookback window to find the absolute highest `High` price and notes the candle on which it occurred.
2. **Low Selection:** Scans all $N$ completed candles in the lookback window to find the absolute lowest `Low` price and notes the candle on which it occurred.

#### **Method 2: Alternate Swing Update Rules (Dynamic Swings)**

Starts with the Base High and Base Low found in Method 1 and checks sequence order:

* **Case A: Low formed BEFORE the High (Chronologically)**
1. Identifies all candles occurring *after* the Base High candle up to the last candle in the lookback window (the candle right before the reference candle).
2. Counts cumulative **bearish** candles ($\text{Close} < \text{Open}$) in this range.
3. If the count of bearish candles is $\ge X$ (default: 3):
* The Low is **updated** to the lowest `Low` among the candles occurring *after* the Base High.




* **Case B: High formed BEFORE the Low (Chronologically)**
1. Identifies all candles occurring *after* the Base Low candle up to the last candle in the lookback window.
2. Counts cumulative **bullish** candles ($\text{Close} > \text{Open}$) in this range.
3. If the count of bullish candles is $\ge X$ (default: 3):
* The High is **updated** to the highest `High` among the candles occurring *after* the Base Low.




* **Handling Updated Swings (Drawing Modes):**
* *Update Main Lines Mode:* Replaces the primary High or Low value with the updated level.
* *Third Line Mode:* Retains the primary Base High and Base Low, and outputs the updated swing level as a separate intermediate line.



#### **Method 3: Reference Candle High / Low**

1. Directly selects the single reference candle (the candle corresponding to the reference time).
2. Sets the High level to the reference candle's `High`.
3. Sets the Low level to the reference candle's `Low`.
4. Bypasses all lookback windows and update rules.

---

=== RECREATION PROMPT ===

Create an algorithm that identifies daily High and Low swing price levels on a financial price chart according to a user-defined daily reference time and configurable detection rules.

### **Algorithm Parameters**

1. **Reference Time:** Time of day specified in hours and minutes, adjusted for the chart's time zone.
2. **Lookback Candles ($N$):** Number of completed candles to analyze before the reference candle (default: 20).
3. **Update Candle Threshold ($X$):** Number of required confirmation candles for Method 2 (default: 3).
4. **Detection Method:** Method 1, Method 2, or Method 3.
5. **Update Mode (for Method 2):** "Update Main" or "Separate Intermediate Line".

---

### **Step-by-Step Execution Logic**

#### **Step 1: Identify the Reference Candle & Lookback Window**

For every trading day on the chart:

1. Locate the **Reference Candle**, which is the single candle whose open time is equal to or immediately precedes the specified daily **Reference Time**.
2. Define the **Lookback Window** as the range of $N$ consecutive completed candles directly preceding the Reference Candle (excluding the Reference Candle itself, starting with the candle immediately before it and going back $N$ candles).

---

#### **Step 2: Swing Detection Logic**

##### **If Detection Method = Method 3:**

* **High Level:** The highest price (`High`) of the Reference Candle.
* **Low Level:** The lowest price (`Low`) of the Reference Candle.
* Terminate calculation for this day.

##### **If Detection Method = Method 1:**

1. **Base High:** The highest `High` price found among all candles in the Lookback Window. Record the specific candle position where this High occurred.
2. **Base Low:** The lowest `Low` price found among all candles in the Lookback Window. Record the specific candle position where this Low occurred.

##### **If Detection Method = Method 2:**

1. Calculate the **Base High** and **Base Low** along with their candle positions using **Method 1**.
2. Compare the chronological order of the Base High and Base Low:
* **Scenario A: Base Low occurred BEFORE Base High**
1. Examine all candles situated chronologically *after* the Base High candle up to the end of the Lookback Window.
2. Count how many of these candles closed lower than they opened ($\text{Close} < \text{Open}$, bearish).
3. If the count of bearish candles is greater than or equal to $X$:
* Identify an **Updated Low** as the lowest `Low` price among all candles in that post-High range.




* **Scenario B: Base High occurred BEFORE Base Low**
1. Examine all candles situated chronologically *after* the Base Low candle up to the end of the Lookback Window.
2. Count how many of these candles closed higher than they opened ($\text{Close} > \text{Open}$, bullish).
3. If the count of bullish candles is greater than or equal to $X$:
* Identify an **Updated High** as the highest `High` price among all candles in that post-Low range.







---

#### **Step 3: Output Assignment**

* **Method 1:** Output the Base High as the High level and Base Low as the Low level.
* **Method 2 (Update Main Mode):**
* If an Updated Low was identified, set the Low level to the Updated Low price.
* If an Updated High was identified, set the High level to the Updated High price.
* Keep non-updated levels at their Base values.


* **Method 2 (Separate Intermediate Line Mode):**
* Keep the primary High level at the Base High price.
* Keep the primary Low level at the Base Low price.
* If an Updated High or Updated Low was identified, output it as an additional "Intermediate Swing" level.


* **Method 3:** Output the Reference Candle's High and Low levels directly.