//+------------------------------------------------------------------+
//|                                              S2ATRTradingBot.mq5 |
//|                                  Copyright 2024, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
// TODOS:
//    - Implementing LTA identification and trading along the lta zone
//    - Implementing trend identification based on hh and lh or ll and lh structures
//    - Implementing moving sl after entry candle closed
//    - Moving the sl after a certain amount of pips reached and reducing more and more the offset
//    - Setting sl either on atr or low of previous candle and making it configurable
//    - Setting first the atr how it is set than after reaching a configurable amount of pips reduce the atr
//    
//    - Only consider S2 when there were more than one candles created a support or resistance not after one candle
//    [x] Identifying S5 Setups
//    [x] Letting multiple trades executing
//    [x] Implementing from to ranges 3 times: for london and us session and between
//    [x] Implementing SL setting with ATR_BASED, CANDLE_HL_BASED and NONE
//    [x] Implementing ENUMS for MA return like BULLISH, BEARISH and NONE
//    [ ] Implementing check of SL on ATR and if too low than switch to Candle LOW/HIGH
//    [ ] Implementing multiplication setting on trailing offset and entry
//    [ ] Implementing configuration for setting spread on entry and sl
//    [ ] Implementing moving sl after second candle closes in right direction
//    [ ] If a open position goes below the ma than close it
//    [ ] Implemting event gathering and skipping trades on important events
//    [ ] Continue trailing if the following candles closes below or above the ma
//    [ ] Implementing testing MA history values if current ma increased or decreased

//    Open Questions:
//    - How to identify the right stop loss before it starts to trail?
//    - How to identify the trend direction to ignore trading in opposite direction?
//    - Testing NASDAQ on 15M
//    - Stoploss based on MA?
//
#property copyright "Copyright 2024, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

#include <Trade/Trade.mqh>

enum SL_SETTING {
    SL_NONE,
    ATR_BASED,
    CANDLE_HL_BASED
};

enum MA_TREND {
    BULLISH,
    BEARISH,
    MA_NONE
};


struct MA_Return {
    double            slow;
    double            fast;
};


input group "ATR Settings"
input double ATR_Multiplier = 1.5;
input int ATR_Period = 14;
input ENUM_TIMEFRAMES ATR_Timeframe = PERIOD_M5;


input group "First Time Ranges"
input int First_Start_Hour = 7;
input int First_Start_Minute = 0;
input int First_End_Hour = 18;
input int First_End_Minute = 15;
input group "Second Time Ranges"
input int Second_Start_Hour = 0;
input int Second_Start_Minute = 0;
input int Second_End_Hour = 0;
input int Second_End_Minute = 0;
input group "Third Time Ranges"
input int Third_Start_Hour = 0;
input int Third_Start_Minute = 0;
input int Third_End_Hour = 0;
input int Third_End_Minute = 0;

input group "Trail Stop Settings"
input double Trail_Entry_Multiplication = 0.25;
input double Trail_Offset_Multiplication = 0.25;
input group "Moving Avergage Settings"
input int FastMa = 9;
input int SlowMa = 20;

input group "Entry Settings"
input bool Entry_With_SL = false;
input bool Target1To1 = false;
input double Max_SL_Points = 15.0;
input bool With_SL = true;
input double FixLotSize = 0.0;
input SL_SETTING SL_Setting = ATR_BASED;
input double Risk_Percent = 1;
input double Buffer_Distance = 1.0;
input bool Market_Order = false;
input double DistanceOfMa = 10;
input int SizeOfSmallCandle = 9;
input double BufferToSpread = 0.5;

input bool S2Setups = true;

input group "S2 Setups"
input bool S5Setups = true;
input double LTAMinimumDistance = 10;

input group "Execution Settings"
input int NumberOfCandlesClosedForPendingOrders = 2;
input bool TrailStopAfterCandleClosed = true;
input bool MultiTrading = true;
input bool Debug = false;



double lastOpenPrice = 0.0;
double lastClosePrice = 0.0;
double previousSupportPrice = 0.0;
double supportPrice = 0.0;
double previousResistancePrice = 0.0;
double resistancePrice = 0.0;

CTrade trade;


//Prints given message when debug is enabled
void Log(string message) {
    if(Debug) {
        Print(message);
    }
}

//Calculates the atr
double CalculateATR() {
    int handle = iATR(Symbol(), ATR_Timeframe, ATR_Period);
    double atr[];
    CopyBuffer(handle, 0, 0, 1, atr);
    return atr[0] * ATR_Multiplier;
}

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
MA_Return CalculateMAStr() {
    int handleFast = iMA(Symbol(), PERIOD_CURRENT, FastMa, 0, MODE_SMA, PRICE_CLOSE);
    int handleSlow = iMA(Symbol(), PERIOD_CURRENT, SlowMa, 0, MODE_SMA, PRICE_CLOSE);
    double maSlow[];
    double maFast[];
    CopyBuffer(handleFast, 0, 0, 1, maFast);
    CopyBuffer(handleSlow, 0, 0, 1, maSlow);

    MA_Return ma;
    ma.fast = maFast[0];
    ma.slow = maSlow[0];

    return ma;
}

//Calculates the ma
MA_TREND CalculateMA() {
    int handleFast = iMA(Symbol(), PERIOD_CURRENT, FastMa, 0, MODE_SMA, PRICE_CLOSE);
    int handleSlow = iMA(Symbol(), PERIOD_CURRENT, SlowMa, 0, MODE_SMA, PRICE_CLOSE);
    double maSlow[];
    double maFast[];
    CopyBuffer(handleFast, 0, 0, 1, maFast);
    CopyBuffer(handleSlow, 0, 0, 1, maSlow);

    bool isBullish = maFast[0] > maSlow[0] && (maFast[0] - maSlow[0] > DistanceOfMa);
    bool isBearish = maFast[0] < maSlow[0] && (maSlow[0] - maFast[0] > DistanceOfMa);

    double open = iOpen(_Symbol, PERIOD_CURRENT, 1);
    double close = iClose(_Symbol, PERIOD_CURRENT, 1);

    if(isBearish) {
        if(close > maFast[0] && IsInvertedHammer(1) == false) {
            isBearish = false;
        }
    } else if(isBullish) {
        if(close < maFast[0] && IsHammerCandle(1) == false) {
            isBullish = false;
        }
    }

    if(isBullish) {
        return BULLISH;
    } else if(isBearish) {
        return BEARISH;
    } else {
        return MA_NONE;
    }
}

//Checks if the trading occurs in the given time
bool InTradingHours() {
    MqlDateTime stm;
    datetime now = TimeCurrent(stm);

    int hour = stm.hour;
    int minute = stm.min;
    return (hour > First_Start_Hour || (hour == First_Start_Hour && minute >= First_Start_Minute)) &&
           (hour < First_End_Hour || (hour == First_End_Hour && minute <= First_End_Minute)) ||
           (Second_Start_Hour > 0 && (hour > Second_Start_Hour || (hour == Second_Start_Hour && minute >= Second_Start_Minute))) &&
           (Second_Start_Hour > 0 && (hour < Second_End_Hour || (hour == Second_End_Hour && minute <= Second_End_Minute))) ||
           (Third_Start_Hour > 0 && (hour > Third_Start_Hour || (hour == Third_Start_Hour && minute >= Third_Start_Minute))) &&
           (Third_Start_Hour > 0 && (hour < Third_End_Hour || (hour == Third_End_Hour && minute <= Third_End_Minute)));
}


//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsPositionOpen() {
    Log("PositionsTotal: " + PositionsTotal());
    return PositionsTotal() > 0;
}

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsEqual(double a, double b, double epsilon = 1e-6) {
    return fabs(a - b) < epsilon;
}

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsGreater(double a, double b, double epsilon = 0.001) {
    return (a - b) > epsilon;
}

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsLess(double a, double b, double epsilon = 0.001) {
    return (b - a) > epsilon;
}

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double GetMaximumLotSize() {
    double maxLot = 0;

    if(SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX, maxLot)) {
        Log("Maximum Lot size: " + maxLot);
    } else {
        Log("Error on getting maxmimum lot size for " + Symbol());
        return 999999;
    }

    double marginPerLot = 0;
    if(!OrderCalcMargin(ORDER_TYPE_BUY, Symbol(), 1.0, SymbolInfoDouble(Symbol(), SYMBOL_BID), marginPerLot)) {
        Log("Error on calculating margin per lot");
        return -1;
    }

// Current account size
    double accountSize = AccountInfoDouble(ACCOUNT_BALANCE);

// Maximum lot size based on account size
    double maxLotBasedOnBalance = accountSize / marginPerLot;
    Log("Maximum lot size based on balance: " + maxLotBasedOnBalance);

    return NormalizeDouble(MathMin(maxLot, maxLotBasedOnBalance), 1);
}


//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double CalculatePositionSize(double riskAmount, double entryPrice, double stopLossPrice) {

    double slPoints = MathAbs(entryPrice - stopLossPrice); // / SymbolInfoDouble(Symbol(), SYMBOL_POINT);
    double positionSize =  MathFloor(MathMin(NormalizeDouble(riskAmount / slPoints, 1), GetMaximumLotSize()));

    if(FixLotSize > 0) {
        positionSize = FixLotSize;
    }

    Log("PositionSize: " + positionSize + ", Points: " + MathAbs(entryPrice - stopLossPrice) + ", risk: " + riskAmount);
    return positionSize;
}

//Close all open positions
void CloseAll() {
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong posTicket = PositionGetTicket(i);
        if(PositionSelectByTicket(posTicket)) {
            if(PositionGetString(POSITION_SYMBOL) != _Symbol)
                continue;
            CTrade *Trade;
            Trade = new CTrade;

            if(Trade.PositionClose(posTicket)) {
                Log("Pos :" + posTicket + " was closed full");
            }
            delete Trade;
        }
    }
}

//Checks if any running sell positions exist
bool IsOpenSellPosition() {
    if(MultiTrading == true) {
        return false;
    }
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong posTicket = PositionGetTicket(i);
        if(PositionSelectByTicket(posTicket)) {
            if(PositionGetString(POSITION_SYMBOL) != _Symbol)
                continue;
            ENUM_POSITION_TYPE positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            if(positionType == POSITION_TYPE_SELL) {
                return true;
            }
        }
    }
    return false;
}

//Checks if any running buy positions exist
bool IsOpenBuyPosition() {
    if(MultiTrading == true) {
        return false;
    }
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong posTicket = PositionGetTicket(i);
        if(PositionSelectByTicket(posTicket)) {
            if(PositionGetString(POSITION_SYMBOL) != _Symbol)
                continue;
            ENUM_POSITION_TYPE positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            if(positionType == POSITION_TYPE_BUY) {
                return true;
            }
        }
    }
    return false;
}

//Checks if the candle for the given index is an inverted hammer candle. A candle with a small bottom body and a long top wick
bool IsInvertedHammer(int index) {
// Get candle attributes
    double open = iOpen(_Symbol, PERIOD_CURRENT, index);
    double close = iClose(_Symbol, PERIOD_CURRENT, index);
    double high = iHigh(_Symbol, PERIOD_CURRENT, index);
    double low = iLow(_Symbol, PERIOD_CURRENT, index);

// Calculation for candle component
    double bodySize = MathAbs(close - open);
    double upperShadow = high - MathMax(open, close);
    double lowerShadow = MathMin(open, close) - low;

// Criteria for inverted hammer candle
    bool isInvertedHammer =
        (upperShadow > 2 * bodySize) &&     // Upper shadow of the candle must be twice the sice of the body
        (lowerShadow <= 4 * bodySize) &&    // Lower shadow must be small
        (bodySize > 0);                     // There must be a body

    return isInvertedHammer;
}



//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsHammerCandle(int index) {
// Get candle attributes
    double open = iOpen(_Symbol, PERIOD_CURRENT, index);
    double close = iClose(_Symbol, PERIOD_CURRENT, index);
    double high = iHigh(_Symbol, PERIOD_CURRENT, index);
    double low = iLow(_Symbol, PERIOD_CURRENT, index);

// Calculation for candle component
    double bodySize = MathAbs(close - open);
    double upperShadow = high - MathMax(open, close);
    double lowerShadow = MathMin(open, close) - low;

// Criteria for inverted hammer candle
    bool isHammerCandle =
        (lowerShadow > 2 * bodySize) &&     // Upper shadow of the candle must be twice the sice of the body
        (upperShadow <= 4 * bodySize) &&    // Lower shadow must be small
        (bodySize > 0);                     // There must be a body

    return isHammerCandle;
}



//Checks if the candle for the given index is a doji candle
bool IsDoji(int index, double epsilon = 1.0) {
// Get the open and close price
    double open = iOpen(_Symbol, PERIOD_CURRENT, index);
    double close = iClose(_Symbol, PERIOD_CURRENT, index);

//Calculate the body size
    double bodySize = MathAbs(close - open);

// Criteria for the doji candle. If the body is smaller than epsilon
    return (bodySize < epsilon);
}

//Checks if the candle for the given index is equal or same size as the given size
bool IsSmallCandle(int index, double size) {
    double high = iHigh(_Symbol, PERIOD_CURRENT, index);
    double low = iLow(_Symbol, PERIOD_CURRENT, index);

    return high - low <= size;
}

//Validates the selling on different criterias
bool SellValidation() {
    MA_TREND ma = CalculateMA();

    bool validMA = ma == BEARISH;

    return
        IsOpenSellPosition() == false &&
        IsOpenBuyPosition() == false &&
        IsDoji(1) == false &&
        IsSmallCandle(1, SizeOfSmallCandle) == false &&
        IsHammerCandle(1) == false &&
        validMA;
}


//Validates the buying on different criterias
bool BuyValidation() {
    MA_TREND ma = CalculateMA();
    bool validMA = ma == BULLISH;

    return
        IsDoji(1) == false &&
        IsInvertedHammer(1) == false &&
        IsHammerCandle(1) == false &&
        IsSmallCandle(1, SizeOfSmallCandle) == false &&
        IsOpenBuyPosition() == false &&
        IsOpenSellPosition() == false && validMA;
}

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double CalculateSL(double entryPrice, double candleLH, double atr) {
    if(SL_Setting == ATR_BASED) {

        if(entryPrice < candleLH) {   //Bearish
            return entryPrice + atr;
        } else {                      //Bullish
            return entryPrice - atr;
        }

    } else if(SL_Setting == CANDLE_HL_BASED) {
        return candleLH;
    } else {
        return entryPrice;
    }
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {

    return(INIT_SUCCEEDED);
}
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {

}

int supportLines = 0;
int resistanceLines = 0;
double s5FirstResistance = 0;
double s5ResistanceBreakout = 0;
double s5FirstSupport = 0;
double s5SecondSupport = 0;
double s5PreviousResistance = 0;


//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void HandleS2Setups(double openPrice, double closePrice, double highPrice, double lowPrice, double riskAmount, double spread, double atrValue) {
    if (S2Setups == false) {
        return;
    }
    if(closePrice >= openPrice && (iClose(Symbol(), PERIOD_M5, 2) < iOpen(Symbol(), PERIOD_M5, 2) || openPrice == closePrice)) {
        // Condition for Bullish S2
        previousSupportPrice = supportPrice;
        supportPrice = iClose(Symbol(), PERIOD_M5, 2);
        Log("Bullish First Condition: prevSuppP: " + previousSupportPrice + ", suppP: " + supportPrice);

        if(previousResistancePrice != 0.0 &&
                previousSupportPrice != 0.0 &&
                resistancePrice > previousResistancePrice &&
                supportPrice > previousSupportPrice &&
                openPrice < (resistancePrice - Buffer_Distance) &&
                closePrice < (resistancePrice - Buffer_Distance) &&
                highPrice < (resistancePrice - Buffer_Distance) && S2Setups) {

            double entryPrice = highPrice + spread;
            double stopLossPrice = CalculateSL(entryPrice, lowPrice, atrValue);
            double takeProfitPrice = entryPrice + atrValue;

            //If set than the takeProfitPrice is at 1:1 RR
            if(Target1To1) {
                takeProfitPrice = entryPrice + (entryPrice - stopLossPrice);
            }

            //Check how big the stop loss is
            if(entryPrice - stopLossPrice > Max_SL_Points) {
                return;
            }

            double positionSize = NormalizeDouble(CalculatePositionSize(riskAmount, entryPrice, stopLossPrice), _Digits);

            if(BuyValidation()) {
                Log("BUY: " + positionSize + ", entryPrice: " + entryPrice + ", stopLoss: " + stopLossPrice + ", ATR: " + atrValue + ", TP: " + takeProfitPrice + ", IsOpenBuy: " + IsOpenBuyPosition());
                if(Market_Order) {
                    if(trade.PositionOpen(Symbol(), ORDER_TYPE_BUY, positionSize, entryPrice, (Entry_With_SL == true) ? stopLossPrice : 0.0, takeProfitPrice, "Bullish S2 Long")) {
                        Log("Bullish S2 Long Position Opened");
                    }
                } else {
                    if(trade.BuyStop(positionSize, entryPrice, Symbol(), (Entry_With_SL == true) ? stopLossPrice : 0.0, takeProfitPrice)) {
                        Log("Bullish S2 Long Position Opened");
                    }
                }
            }
        }

    } else if(closePrice <= openPrice && (iClose(Symbol(), PERIOD_M5, 2) > iOpen(Symbol(), PERIOD_M5, 2) || openPrice == closePrice)) {
        //Condition for bearish candle
        previousResistancePrice = resistancePrice;
        //Last bullish candle close price
        resistancePrice = iClose(Symbol(), PERIOD_M5, 2);

        Log("Bearish First Condition: prevResP: " + previousResistancePrice + ", resP: " + resistancePrice);

        if(previousResistancePrice != 0.0 &&
                previousSupportPrice != 0.0 &&
                resistancePrice < previousResistancePrice &&
                supportPrice < previousSupportPrice &&
                openPrice > (supportPrice + Buffer_Distance) &&
                closePrice > (supportPrice + Buffer_Distance) &&
                lowPrice > (supportPrice + Buffer_Distance) && S2Setups) {

            double entryPrice = lowPrice - spread;
            double stopLossPrice = CalculateSL(entryPrice, highPrice, atrValue);
            double takeProfitPrice = entryPrice - atrValue;
            if(Target1To1) {
                takeProfitPrice = entryPrice - (stopLossPrice - entryPrice);
            }

            if(stopLossPrice - entryPrice > Max_SL_Points) {
                return;
            }

            double positionSize = CalculatePositionSize(riskAmount, entryPrice, stopLossPrice);

            if(SellValidation()) {
                Print("SELL: " + positionSize + ", entryPrice: " + entryPrice + ", stopLoss: " + stopLossPrice + ", ATR: " + atrValue + ", TP: " + takeProfitPrice + ", IsOpenSell: " + IsOpenSellPosition());
                if(Market_Order) {
                    if(trade.PositionOpen(Symbol(), ORDER_TYPE_SELL, positionSize, entryPrice, (Entry_With_SL == true) ? stopLossPrice : 0.0, takeProfitPrice, "Bearish S2 Short")) {
                        Log("Bearish S2 Short Position Opened");
                    }
                } else {
                    if(trade.SellStop(positionSize, entryPrice, Symbol(), (Entry_With_SL == true) ? stopLossPrice : 0.0, takeProfitPrice)) {
                        Log("Bearish S2 Short Position Opened");
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void HandleS5Setups(double openPrice, double closePrice, double highPrice, double lowPrice, double riskAmount, double spread, double atrValue) {
    if (S5Setups == false) {
        return;
    }
    if(closePrice >= openPrice && (iClose(Symbol(), PERIOD_M5, 2) < iOpen(Symbol(), PERIOD_M5, 2) || openPrice == closePrice)) {
        supportPrice = iClose(Symbol(), PERIOD_M5, 2);

        if(supportPrice > 0.0) {
            if(supportLines >= 3) {
                ObjectDelete(0, "Support Line: 1");
                ObjectDelete(0, "Support Line: 2");
                ObjectDelete(0, "Support Line: 3");
                supportLines = 0;
            }

            double _S5SecondSupport = s5SecondSupport;
            double _S5FirstSupport = s5FirstSupport;
            double _S5ResistanceBreakout = s5ResistanceBreakout;
            double _SupportPrice = supportPrice;
            double _S5FirstResistance = s5FirstResistance;
            double _S5PreviousResistance = s5PreviousResistance;

            if(s5FirstSupport > 0 && supportPrice > s5FirstSupport) {
                s5FirstResistance = 0;
                s5FirstSupport = 0;
                s5SecondSupport = 0;
                s5ResistanceBreakout = 0;
            }

            //First support zone
            if(s5PreviousResistance > supportPrice && s5FirstSupport == 0.0) {
                s5FirstSupport = supportPrice;
                s5FirstResistance = s5PreviousResistance;
            }

            if(supportPrice < s5FirstSupport && s5SecondSupport == 0.0 && supportPrice > 0.0 && s5ResistanceBreakout > 0 && s5FirstResistance - closePrice > LTAMinimumDistance) {

                if(closePrice > s5ResistanceBreakout && closePrice < s5FirstResistance) {
                    s5FirstResistance = 0.0;
                    s5FirstSupport = 0.0;
                    s5ResistanceBreakout = 0.0;
                    s5SecondSupport = 0.0;

                    double entryPrice = highPrice + spread;
                    double stopLossPrice = CalculateSL(entryPrice, lowPrice, atrValue);
                    double positionSize = NormalizeDouble(CalculatePositionSize(riskAmount, entryPrice, stopLossPrice), _Digits);
                    double takeProfitPrice = entryPrice + atrValue;

                    Log("BUY S5: " + positionSize + ", entryPrice: " + entryPrice + ", stopLoss: " + stopLossPrice + ", ATR: " + atrValue + ", TP: " + takeProfitPrice + ", IsOpenBuy: " + IsOpenBuyPosition());
                    if(trade.BuyStop(positionSize, entryPrice, Symbol(), (Entry_With_SL == true) ? stopLossPrice : 0.0, takeProfitPrice)) {
                        Log("Bullish S5 Long Position Opened");
                    }

                }

                if(closePrice > s5ResistanceBreakout && closePrice > s5FirstResistance) {
                    s5FirstResistance = 0.0;
                    s5FirstSupport = 0.0;
                    s5ResistanceBreakout = 0.0;
                    s5SecondSupport = 0.0;
                }
            }

            supportLines = supportLines + 1;
            ObjectCreate(0,"Support Line: " + supportLines,OBJ_HLINE,0,0,supportPrice);
        }
    } else if(closePrice <= openPrice && (iClose(Symbol(), PERIOD_M5, 2) > iOpen(Symbol(), PERIOD_M5, 2) || openPrice == closePrice)) {
        resistancePrice = iClose(Symbol(), PERIOD_M5, 2);

        if(resistancePrice > 0) {
            s5PreviousResistance = resistancePrice;
            double _S5SecondSupport = s5SecondSupport;
            double _S5FirstSupport = s5FirstSupport;
            double _S5ResistanceBreakout = s5ResistanceBreakout;
            double _ResistancePrice = resistancePrice;
            double _S5FirstResistance = s5FirstResistance;
            if((s5ResistanceBreakout > 0 && resistancePrice > s5ResistanceBreakout) || (s5ResistanceBreakout > 0 && s5FirstSupport == 0) || (s5FirstResistance > 0 && resistancePrice > s5FirstResistance) || (s5ResistanceBreakout > 0 && s5FirstSupport > s5ResistanceBreakout) || (resistancePrice < s5FirstSupport) || (s5FirstSupport > 0 && s5FirstResistance - s5FirstSupport < LTAMinimumDistance) || (s5ResistanceBreakout>0 && resistancePrice < s5ResistanceBreakout)) {
                s5FirstResistance = 0;
                s5FirstSupport = 0;
                s5SecondSupport = 0;
                s5ResistanceBreakout = 0;
            }
            if(resistanceLines >= 3) {
                ObjectDelete(0, "Resistance Line: 1");
                ObjectDelete(0, "Resistance Line: 2");
                ObjectDelete(0, "Resistance Line: 3");
                resistanceLines = 0;
            }

            resistanceLines = resistanceLines + 1;

            //Second resistance after going down which is the breakout zone
            if(s5FirstSupport > 0 && resistancePrice > s5FirstSupport && s5FirstResistance - resistancePrice > LTAMinimumDistance) {
                s5ResistanceBreakout = resistancePrice;
            }

            ObjectCreate(0,"Resistance Line: " + resistanceLines,OBJ_HLINE,0,0,resistancePrice);
            ObjectSetInteger(0,"Resistance Line: " + resistanceLines,OBJPROP_COLOR,clrAliceBlue);

        }
    }
}

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void HandlePartialClosing(ulong ticket, double openPrice, double posVolume) {
//If setting for 1:1 RR is enabled than close 75% and move to BE

    double lotsToClose = posVolume * 0.75;
    lotsToClose = NormalizeDouble(lotsToClose, 1);

    if(trade.PositionClosePartial(ticket, lotsToClose)) {
        Log("Pos :" + ticket + " was closed 75% with " + lotsToClose);
        trade.PositionModify(ticket, openPrice, 0.0);
    }
}

void HandleTrailStop(double askPrice, double bidPrice, double atrValue) {

    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (PositionSelectByTicket(ticket)) {
            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double stopLoss = PositionGetDouble(POSITION_SL);
            double tp = PositionGetDouble(POSITION_TP);
            double startTrailing = atrValue * Trail_Entry_Multiplication ;
            double offsetTrailing = atrValue * Trail_Offset_Multiplication;
            ENUM_POSITION_TYPE positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            double posVolume = PositionGetDouble(POSITION_VOLUME);
            datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
            datetime currentTime = TimeCurrent();

            //Check if candle is still open
            if (currentTime < (openTime + PeriodSeconds(PERIOD_CURRENT)) && TrailStopAfterCandleClosed) {
                return;
            }

            double newStopLoss = 0.0;
            if (positionType == POSITION_TYPE_BUY) {
                newStopLoss = MathMax(stopLoss, NormalizeDouble(bidPrice - offsetTrailing, _Digits));

                double difference = bidPrice - openPrice;

                //The initial entry doesn't have a stop loss and therfore it will be set to new stop loss with adding 0.1 so that it is higher
                if (stopLoss == 0.0 && difference > 0) {
                    newStopLoss = NormalizeDouble(bidPrice - offsetTrailing, _Digits);
                    stopLoss = newStopLoss - 0.1;
                }

                //If it goes in the other direction and risk reached than just close
                //if (difference < 0 && stopLoss == 0.0) {
                //   double slPoints = MathAbs(Bid - openPrice);
                //   if ((slPoints * posVolume) >= risk_amount) {
                //      Log("Close because reached risk: " + ticket);
                //      trade.PositionClose(ticket);
                //   }
                //}

                // Activate trail stop only if price is greater than defined start trailing
                if (difference >= startTrailing  && IsGreater(newStopLoss, stopLoss)) {
                    Log("Modify: " + ticket + ", SL: " + stopLoss + " to: " + newStopLoss + ", startTrailing: " + (startTrailing * _Point));
                    trade.PositionModify(ticket, newStopLoss, 0.0);
                }


                //If setting for 1:1 RR is enabled than close 75% and move to BE
                stopLoss = PositionGetDouble(POSITION_SL);
                if (Is1To1(openPrice, bidPrice, openPrice - atrValue) && stopLoss < openPrice && bidPrice > openPrice) {
                    HandlePartialClosing(ticket, openPrice, posVolume);

                }
            } else if (positionType == POSITION_TYPE_SELL) {
                newStopLoss = MathMin(stopLoss, NormalizeDouble(askPrice + offsetTrailing, _Digits));


                //Price difference from openprice to current price
                double difference = openPrice - askPrice;

                if (stopLoss == 0.0 && difference > 0) {
                    newStopLoss = NormalizeDouble(askPrice + offsetTrailing, _Digits);
                    stopLoss = newStopLoss + 0.1;
                }

                //If it goes in the other direction and risk reached than just close
                //if (difference < 0 && stopLoss == 0.0) {
                //   double slPoints = MathAbs(Ask - openPrice);
                //   if ((slPoints * posVolume) >= risk_amount) {
                //      Log("Close because reached risk: " + ticket);
                //      trade.PositionClose(ticket);
                //   }
                //}

                if (difference >= startTrailing && IsLess(newStopLoss, stopLoss)) {
                    Log("Modify: " + ticket + ", SL: " + stopLoss + " to: " + newStopLoss + ", startTrailing: " + (startTrailing * _Point));
                    trade.PositionModify(ticket, newStopLoss, 0.0);
                }

                //If setting for 1:1 RR is enabled than close 75% and move to BE
                stopLoss = PositionGetDouble(POSITION_SL);
                if (Is1To1(openPrice, askPrice, openPrice + atrValue) && stopLoss > openPrice && askPrice < openPrice) {
                    HandlePartialClosing(ticket, openPrice, posVolume);
                }
            }
        }

    }
}


//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
    MqlTick tick;
    SymbolInfoTick(_Symbol,tick);
    double askPrice = tick.ask;
    double bidPrice = tick.bid;

    double atrValue = CalculateATR();
    double riskAmount = (AccountInfoDouble(ACCOUNT_EQUITY) / 100) * Risk_Percent;
    double openPrice = iOpen(Symbol(), PERIOD_M5, 1);
    double closePrice = iClose(Symbol(), PERIOD_M5, 1);
    double highPrice = iHigh(Symbol(), PERIOD_M5, 1);
    double lowPrice = iLow(Symbol(), PERIOD_M5, 1);
    double spread = askPrice - bidPrice + BufferToSpread;

// Check for new bar (compatible with both MQL4 and MQL5).
    static datetime dtBarCurrent  = WRONG_VALUE;
    datetime dtBarPrevious = dtBarCurrent;
    dtBarCurrent  = iTime(_Symbol, _Period, 0);
    bool bNewBarEvent  = (dtBarCurrent != dtBarPrevious);

// React to a new bar event and handle it.
    if(bNewBarEvent && InTradingHours()) {
        // Detect if this is the first tick received and handle it.
        /* For example, when it is first attached to a chart and
           the bar is somewhere in the middle of its progress and
           it's not actually the start of a new bar. */
        if(dtBarPrevious == WRONG_VALUE) {
            // Do something on first tick or middle of bar ...
        } else {
            CheckAndClosePendingOrders();
            // Do something when a normal bar starts ...

            HandleS2Setups(openPrice, closePrice, highPrice, lowPrice, riskAmount, spread, atrValue);
            HandleS5Setups(openPrice, closePrice, highPrice, lowPrice, riskAmount, spread, atrValue);
        }
    } else {
        // Do something else ...
    };
    HandleTrailStop(askPrice, bidPrice, atrValue);

}

//Check if the current price is on 1:1 with given stop loss and entry price
bool Is1To1(double entryPrice, double currentPrice, double stopLoss) {
    return MathAbs(currentPrice - entryPrice) >= MathAbs(stopLoss - entryPrice) && Target1To1;
}

//Checks open pending and close them if new candles closed either below or above the open price
void CheckAndClosePendingOrders() {
    int totalOrders = OrdersTotal();
    for(int i = 0; i < totalOrders; i++) {
        if(OrderSelect(OrderGetTicket(i))) {
            int type = OrderGetInteger(ORDER_TYPE);
            if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP) {
                double priceOpen = OrderGetDouble(ORDER_PRICE_OPEN);
                datetime time = (datetime)OrderGetInteger(ORDER_TIME_SETUP);

                MqlRates m_rates_m5[];
                int copied = CopyRates(Symbol(), PERIOD_M5, time, TimeCurrent(), m_rates_m5);
                int size=fmin(copied,10);
                int closedCandles = 0;
                for(int i=0;i<size;i++) {
                    if(type == ORDER_TYPE_BUY_STOP) {
                        if(m_rates_m5[i].close < priceOpen) {
                            closedCandles++;
                        }
                    } else if(type == ORDER_TYPE_SELL_STOP) {
                        if(m_rates_m5[i].close > priceOpen) {
                            closedCandles++;
                        }
                    }
                }

                //Delete pending order when candles closed below or above open price
                if(closedCandles >= NumberOfCandlesClosedForPendingOrders) {
                    CTrade *Trade;
                    Trade = new CTrade;
                    if(Trade.OrderDelete(OrderGetTicket(i))) {
                        Log("Order: " +  OrderGetTicket(i) + " deleted!");
                    }
                }
            }
        }
    }
}
//+------------------------------------------------------------------+
