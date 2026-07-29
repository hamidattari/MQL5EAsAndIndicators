# Architecture Documentation: Daily Levels Breakout EA (v2.0)

## 1. Executive Summary

`DailyLevelsBreakout_EA.mq5` is a MetaTrader 5 Expert Advisor designed around a **multi-session breakout strategy**. The architecture isolates up to 4 independent trading sessions per day. Each session computes its own dynamic High/Low levels, maintains its own state machine, manages chart objects interactively, and executes trade management rules independently.

---

## 2. High-Level System Architecture