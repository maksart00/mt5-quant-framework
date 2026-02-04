#property copyright "ArtemMaksimov"
#property version   "2.00"
#include <Trade\Trade.mqh>

//--- Enums
enum ENUM_DIRECTION {
   DIR_BOTH = 0, // Both Sides
   DIR_LONG = 1, // Long Only
   DIR_SHORT = 2 // Short Only
};

//--- Input Parameters
input group "=== Risk Management ==="
input double   RiskPercent      = 1.0;      // Риск на сделку (% от Equity)
input double   MaxDailyLoss     = 2.0;      // Дневной лимит потерь (%)
input double   MinRR            = 2.0;      // Мин. R:R (Take Profit / Stop Loss)

input group "=== Strategy Logic ==="
input ENUM_DIRECTION TradeMode  = DIR_BOTH; // Режим торговли
input int      SwingBars        = 20;       // Глубина поиска Swing High/Low
input bool     RequireFVG       = true;     // Требовать вход из FVG (mitigation)
input int      FVG_Tolerance    = 50;       // Допуск входа (пунктов) от края FVG
input int      MagicNumber      = 777001;   // Magic Number

input group "=== Time & Spread ==="
input int      StartHour        = 8;        // London Open (пример)
input int      EndHour          = 18;       // NY Session Close
input int      MaxSpreadPts     = 20;       // Макс спред (в поинтах)

//--- Global Objects
CTrade trade;
double InitialDailyEquity;
int    CurrentDayOfYear;

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_FOK); // Или IOC, зависит от ликвидности брокера
   trade.SetDeviationInPoints(10);
   
   InitialDailyEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   CurrentDayOfYear = DayOfYear();
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Main Loop                                                        |
//+------------------------------------------------------------------+
void OnTick() {
   // 1. Проверка нового дня для сброса лимита риска
   if(DayOfYear() != CurrentDayOfYear) {
      InitialDailyEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      CurrentDayOfYear = DayOfYear();
   }

   // 2. Hard Equity Stop (Лимит потерь на день)
   if(AccountInfoDouble(ACCOUNT_EQUITY) < InitialDailyEquity * (1.0 - MaxDailyLoss/100.0)) {
      Comment("Daily Loss Limit Hit. Trading Halted.");
      return;
   }

   // 3. Фильтр времени и спреда
   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.hour < StartHour || dt.hour >= EndHour) return;
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > MaxSpreadPts) return;

   // 4. Проверка открытых позиций (только одна позиция за раз)
   if(PositionSelectByMagic(_Symbol, MagicNumber)) return;

   // --- INSTITUTIONAL ANALYSIS START ---
   
   // 5. Определение структуры (Market Structure)
   int highIndex = iHighest(_Symbol, _Period, MODE_HIGH, SwingBars, 1);
   int lowIndex  = iLowest(_Symbol, _Period, MODE_LOW, SwingBars, 1);
   
   if(highIndex == -1 || lowIndex == -1) return;

   double swingHigh = iHigh(_Symbol, _Period, highIndex);
   double swingLow  = iLow(_Symbol, _Period, lowIndex);
   
   // Определяем Bias (предвзятость)
   bool bullishStructure = (highIndex < lowIndex); // Хай свежее Лоу = аптренд
   
   // 6. Фильтр Направления (ПО ЗАПРОСУ)
   if(TradeMode == DIR_LONG && !bullishStructure) return;  // Хотим лонг, но структура медвежья -> ждем
   if(TradeMode == DIR_SHORT && bullishStructure) return;  // Хотим шорт, но структура бычья -> ждем
   
   // Если мы хотим торговать ТОЛЬКО лонг, мы вообще игнорируем сигналы на продажу
   bool allowBuy = (TradeMode != DIR_SHORT);
   bool allowSell = (TradeMode != DIR_LONG);

   // 7. Поиск точки входа (Premium/Discount + FVG)
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double midPrice = (swingHigh + swingLow) / 2.0;
   
   bool signalBuy = false;
   bool signalSell = false;
   
   // BUY Logic: Цена в Discount (< 50%) И структура бычья
   if(allowBuy && bullishStructure && ask < midPrice) {
      if(!RequireFVG || IsPriceInBullishFVG(3)) { // Проверка FVG за последние 3 бара
         signalBuy = true;
      }
   }
   
   // SELL Logic: Цена в Premium (> 50%) И структура медвежья
   if(allowSell && !bullishStructure && bid > midPrice) {
      if(!RequireFVG || IsPriceInBearishFVG(3)) {
         signalSell = true;
      }
   }

   // 8. Исполнение
   if(signalBuy) {
      double sl = swingLow; 
      double tp = swingHigh;
      OpenTrade(ORDER_TYPE_BUY, ask, sl, tp);
   }
   else if(signalSell) {
      double sl = swingHigh; 
      double tp = swingLow;
      OpenTrade(ORDER_TYPE_SELL, bid, sl, tp);
   }
}

//+------------------------------------------------------------------+
//| Helper: Внутри ли мы Бычьего FVG?                                |
//+------------------------------------------------------------------+
bool IsPriceInBullishFVG(int lookback) {
   // Мы ищем свечу [i], где Low[i] > High[i+2] - это дыра.
   // И текущая цена (Ask) должна быть ВНУТРИ этой дыры или касаться её.
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   for(int i=1; i<=lookback; i++) {
      double candleLow = iLow(_Symbol, _Period, i);
      double prevHigh  = iHigh(_Symbol, _Period, i+2);
      
      if(candleLow > prevHigh) { // FVG Обнаружен
         // Проверяем, "зашла" ли цена в этот гэп для теста
         if(currentAsk <= candleLow && currentAsk >= prevHigh) return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Helper: Внутри ли мы Медвежьего FVG?                             |
//+------------------------------------------------------------------+
bool IsPriceInBearishFVG(int lookback) {
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   for(int i=1; i<=lookback; i++) {
      double candleHigh = iHigh(_Symbol, _Period, i);
      double prevLow    = iLow(_Symbol, _Period, i+2);
      
      if(candleHigh < prevLow) { // FVG Обнаружен
         if(currentBid >= candleHigh && currentBid <= prevLow) return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Helper: Открытие позиции с расчетом риска                        |
//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE type, double entry, double sl, double tp) {
   if(sl == 0) return;
   
   double distSL = MathAbs(entry - sl);
   if(distSL == 0) return;
   
   double potentialProfit = MathAbs(tp - entry);
   if(potentialProfit / distSL < MinRR) return; // Фильтр R:R

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * (RiskPercent / 100.0);
   
   // Точный расчет стоимости тика
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize == 0 || tickValue == 0) return;
   
   double pointsRisk = distSL / _Point; // Риск в поинтах
   // Формула: Lot = RiskMoney / (RiskPoints * TickValuePerPoint)
   // TickValue обычно дается за TickSize. Приводим к пункту.
   double valuePerPoint = tickValue * (_Point / tickSize); 
   
   double lot = riskMoney / (pointsRisk * valuePerPoint);
   
   // Нормализация лота
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / step) * step;
   
   if(lot < minLot) return; // Не хватает денег на мин. лот
   if(lot > SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX)) lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   
   trade.PositionOpen(_Symbol, type, lot, entry, sl, tp, "SmartMoney Algo");
}

//+------------------------------------------------------------------+
//| Helper: Проверка позиции по MagicNumber                          |
//+------------------------------------------------------------------+
bool PositionSelectByMagic(string symbol, int magic) {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) == symbol && PositionGetInteger(POSITION_MAGIC) == magic)
            return true;
      }
   }
   return false;
}

int DayOfYear() {
   MqlDateTime dt;
   TimeCurrent(dt);
   return dt.day_of_year;
}