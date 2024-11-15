//+------------------------------------------------------------------+
//|                                              S2ATRTradingBot.mq5 |
//|                                  Copyright 2024, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
/*
TODOS:
   - Implementing LTA identification and trading along the lta zone
   - Implementing trend identification based on hh and lh or ll and lh structures
   - Implementing moving sl after entry candle closed
   - Moving the sl after a certain amount of pips reached and reducing more and more the offset
   - Setting sl either on atr or low of previous candle and making it configurable
   - Setting first the atr how it is set than after reaching a configurable amount of pips reduce the atr

   - Only consider S2 when there were more than one candles created a support or resistance not after one candle
   [x] Identifying S5 Setups
   [x] Letting multiple trades executing
   [x] Implementing from to ranges 3 times: for london and us session and between
   [x] Implementing SL setting with ATR_BASED, CANDLE_HL_BASED and NONE
   [x] Implementing ENUMS for MA return like BULLISH, BEARISH and NONE
   [ ] Implementing check of SL on ATR and if too low than switch to Candle LOW/HIGH
   [ ] Implementing multiplication setting on trailing offset and entry
   [ ] Implementing configuration for setting spread on entry and sl
   [ ] Implementing moving sl after second candle closes in right direction
   [ ] If a open position goes below the ma than close it
   [ ] Implemting event gathering and skipping trades on important events
   [ ] Continue trailing if the following candles closes below or above the ma
   [ ] Implementing testing MA history values if current ma increased or decreased
   [ ] Trail with bigger offset when candles are above fast ma or under slow ma or even trail along the ma
   [x] Implementing waiting for a wick creation before setting the stop entry
   [x] Implementing ma trend recognizion by analysing the last x ma entries if they were all above or under
   [ ] On Candles which don't have an end wick wait for wick creation before entering
   [ ] Adding range breakout. First identify range on 1m and on breakout start trading
   [ ] Add trailing along the closing candles low. Start with sl under low and move on next candles to next low. See https://www.mql5.com/en/articles/15311

   Open Questions:
   - How to identify the right stop loss before it starts to trail?
   - How to identify the trend direction to ignore trading in opposite direction?
   - Testing NASDAQ on 15M
   - Stoploss based on MA?

*/
#property copyright "Copyright 2024, MetaQuotes Ltd."
#property link "https://www.mql5.com"
#property version "1.00"

#include <Arrays\ArrayObj.mqh>
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
    double           slow;
    double           fast;
    bool             allFastGreaterSlow;
    bool             allFastLowerSlow;
    double           maFast[];
    double           maSlow[];
};

enum ENUM_POSITION_STATE {
    PENDING,
    TRIGGERED,
    CLOSED
};

enum ENUM_ENTRY_TYPE {
    MARKET_ORDER_ENTRY,
    STOP_ENTRY,
    WICK_CREATION_ENTRY
};

CTrade trade;
class TradePosition {
    ulong            order;
    ulong            position;
    ENUM_ORDER_TYPE  orderType;
    double           drawDown;
    double           profit;
    double           entryPrice;
    double           slPrice;
    double           tpPrice;
    double           volume;
    int              wickCreationWaitInSeconds;
    datetime         creationTime;
    datetime         entryTime;
    datetime         closeTime;
    bool             entered;
    long             creationTimeMsc;
    
    bool             closed;

    ENUM_POSITION_STATE state;

public:
                     TradePosition(void) {};
                     TradePosition(ulong order, ENUM_ORDER_TYPE orderType, double volume, double entryPrice, double slPrice, double tpPrice, datetime creationTime) {
        this.order        = order;
        this.entryPrice   = entryPrice;
        this.slPrice      = slPrice;
        this.tpPrice      = tpPrice;
        this.creationTime = creationTime;
        this.orderType    = orderType;
        this.volume = volume;
        this.wickCreationWaitInSeconds = 0;
        this.entered = false;
        this.closed = false;
    }

    bool             IsPending() {
        return entryTime == 0;
    }

    void             SetPositionTicket(ulong position) {
        this.position = position;
    }

    void             SetEntryTime(datetime entryTime) {
        this.entryTime = entryTime;
    }

    void             SetEntryPrice(double entryPrice) {
        this.entryPrice = entryPrice;
    }

    void             SetOrder(ulong order) {
        this.order = order;
    }

    ulong            GetOrder() {
        return order;
    }

    ENUM_ORDER_TYPE  GetOrderType() {
        return this.orderType;
    }

    ulong            GetPosition() {
        return position;
    }

    void SetWickCreationWaitDuration(int seconds) {
        wickCreationWaitInSeconds = seconds;
    }

    bool IsWaitForWickCreation() {
        return wickCreationWaitInSeconds > 0;
    }

    void CheckEntry(long timeMsc, double openPrice, double lowPrice, double highPrice) {
        if (wickCreationWaitInSeconds == 0 || entered || closed) {
            return;
        }
        if (timeMsc >= (creationTimeMsc + (wickCreationWaitInSeconds * 1000))) {
            if (orderType == ORDER_TYPE_BUY) {
                //Candle flipped
                if (highPrice > openPrice && highPrice < entryPrice) {
                    //If SL should be candle low
                    //slPrice = lowPrice;
                    if(trade.BuyStop(volume, entryPrice, Symbol(), (Entry_With_SL == true) ? slPrice : 0.0, tpPrice)) {
                        Log("Long S2 Wickwait Position Opened");
                        entered = true;
                    }
                }
                if (lowPrice < iLow(Symbol(), PERIOD_CURRENT, 1)) {
                    closed = true;
                }
            } else if (orderType == ORDER_TYPE_SELL) {
                //Candle flipped
                if (lowPrice < openPrice && lowPrice > entryPrice) {
                    //If SL should be candle low
                    //slPrice = lowPrice;
                    if(trade.SellStop(volume, entryPrice, Symbol(), (Entry_With_SL == true) ? slPrice : 0.0, tpPrice)) {
                        Log("Short S2 Wickwait Position Opened");
                        entered = true;
                    }
                }
                if (highPrice > iHigh(Symbol(), PERIOD_CURRENT, 1)) {
                    closed = true;
                }
            }
        }
    }

    void SetCreationTimeMsc(long timeMsc) {
        creationTimeMsc = timeMsc;
    }
};


class TradingPositions {

private:
    TradePosition    tradingPositions[];
    int              size;
    int              reservedSize;

public:
                     TradingPositions(void) {
        reservedSize = 1000;
        ArrayResize(tradingPositions, reservedSize);
        size = 0;
    }
    void             Add(TradePosition &tradingPosition) {
        size++;
        if (size > reservedSize) {
            reservedSize = reservedSize + 100;
            ArrayResize(tradingPositions, reservedSize);
        }
        tradingPositions[size - 1] = tradingPosition;
    }

    int              Size() {
        return size;
    }

    TradePosition*   At(int index) {
        return &tradingPositions[index];
    }

};



//ObjArray<TradePosition*> tradePositions;
TradingPositions tradePositions;

input group "ATR Settings"
input double ATR_Multiplier = 1.5;
input int                               ATR_Period     = 14;
input ENUM_TIMEFRAMES                   ATR_Timeframe  = PERIOD_M5;

input group "First Time Ranges"
input int First_Start_Hour   = 7;
input int                                 First_Start_Minute = 0;
input int                                 First_End_Hour     = 18;
input int                                 First_End_Minute   = 15;

input group "Second Time Ranges"
input int Second_Start_Hour   = 0;
input int                                  Second_Start_Minute = 0;
input int                                  Second_End_Hour     = 0;
input int                                  Second_End_Minute   = 0;

input group "Third Time Ranges"
input int Third_Start_Hour   = 0;
input int                                 Third_Start_Minute = 0;
input int                                 Third_End_Hour     = 0;
input int                                 Third_End_Minute   = 0;

input group "Trail Stop Settings"
input double                                Trail_Entry_Multiplication  = 0.25;
input double                                Trail_Offset_Multiplication = 0.25;
input bool                                  Start_Trailing_After_Candle_Closed  = true;
input bool                                  Trail_Along_Candle_Low = true;

input group "Moving Avergage Settings"
input int                                        Fast_MA                      = 9;
input int                                        Slow_MA                      = 20;
input int                                        Number_Of_Previous_Candles_For_MA = 6;
input double                                     Minimum_Distance_Between_MAs                = 10;

input group "Entry Settings" 
input bool                              Entry_With_SL   = false;
input bool                              Entry_With_TP   = true;
input bool                              Target1To1      = false;
input double                            Max_SL_Points   = 15.0;
input double                            Fix_Lot_Size      = 0.0;
input SL_SETTING                        SL_Setting      = ATR_BASED;
input double                            Risk_Percent    = 1;
input ENUM_ENTRY_TYPE                   Entry_Type    = STOP_ENTRY;
input int                               Seconds_To_Wait_For_Wick = 3;
input double                            Add_Points_To_Spread    = 0.0;
input int                               MagicNumber = 123123;

input group "Filter Candles"
input int    Minimum_Size_Of_Candle = 9;
input bool   Candles_Without_Endwick_Buy = true;
input bool   Candles_Without_Endwick_Sell = false;
input bool   Inverted_Hammer_Candle_Buy = false;
input bool   Hammer_Candle_Sell = false;


input group "S2 Setups"
input bool                              S2Setups = true;
input double                            Buffer_Distance = 1.0;

input group "S5 Setups"
input bool S5Setups           = true;
input double                       LTAMinimumDistance = 10;

input group "Execution Settings" input int NumberOfCandlesClosedForPendingOrders = 2;
input bool                                 MultiTrading                          = true;
input bool                                 Debug                                 = false;

double lastOpenPrice           = 0.0;
double lastClosePrice          = 0.0;
double previousSupportPrice    = 0.0;
double supportPrice            = 0.0;
double previousResistancePrice = 0.0;
double resistancePrice         = 0.0;



// Prints given message when debug is enabled
void Log(string message) {
    if(Debug) {
        Print(message);
    }
}

// Calculates the atr
double CalculateATR() {
    int    handle = iATR(Symbol(), ATR_Timeframe, ATR_Period);
    double atr[];
    CopyBuffer(handle, 0, 0, 1, atr);
    return atr[0] * ATR_Multiplier;
}

// Calculates the ma
MA_Return CalculateMA() {
    int    handleFast = iMA(Symbol(), PERIOD_CURRENT, Fast_MA, 0, MODE_SMA, PRICE_CLOSE);
    int    handleSlow = iMA(Symbol(), PERIOD_CURRENT, Slow_MA, 0, MODE_SMA, PRICE_CLOSE);
    double maSlow[];
    double maFast[];
    CopyBuffer(handleFast, 0, 0, Number_Of_Previous_Candles_For_MA, maFast);
    CopyBuffer(handleSlow, 0, 0, Number_Of_Previous_Candles_For_MA, maSlow);

    MA_Return ma;
    ma.slow               = maSlow[Number_Of_Previous_Candles_For_MA - 1];
    ma.fast               = maFast[Number_Of_Previous_Candles_For_MA - 1];
    ma.allFastGreaterSlow = true;
    ma.allFastLowerSlow   = true;
    //CopyBuffer(handleFast, 0, 0, Number_Of_Previous_Candles_For_MA, ma.maFast);
    //CopyBuffer(handleSlow, 0, 0, Number_Of_Previous_Candles_For_MA, ma.maSlow);

    for(int i = 0; i < Number_Of_Previous_Candles_For_MA; i++) {
        if(maFast[i] < maSlow[i]) {
            ma.allFastGreaterSlow = false;
        }
        if(maFast[i] > maSlow[i]) {
            ma.allFastLowerSlow = false;
        }
    }

    return ma;
}

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
MA_TREND ValidateMA(MA_Return &maReturn) {
    bool isBullish = maReturn.allFastGreaterSlow && (maReturn.fast - maReturn.slow > Minimum_Distance_Between_MAs);   // maFast > maSlow && (maFast - maSlow > DistanceOfMa);
    bool isBearish = maReturn.allFastLowerSlow && (maReturn.slow - maReturn.fast > Minimum_Distance_Between_MAs);     // maFast < maSlow && (maSlow - maFast > DistanceOfMa);

    double open  = iOpen(_Symbol, PERIOD_CURRENT, 1);
    double close = iClose(_Symbol, PERIOD_CURRENT, 1);

// Special condition if candle closed inside the ma zone except the inverted hammer or hammer candle
    if(isBearish) {
        if(close > maReturn.fast && IsInvertedHammer(1) == false) {
            isBearish = false;
        }
    } else if(isBullish) {
        if(close < maReturn.fast && IsHammerCandle(1) == false) {
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

// Checks if the trading occurs in the given time
bool InTradingHours() {
    MqlDateTime stm;
    datetime    now = TimeCurrent(stm);

    int hour   = stm.hour;
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
    Print("Account Size:" + accountSize + ", riskAmount: " + riskAmount);

// Maximum lot size based on account size
    double maxLotBasedOnBalance = accountSize / marginPerLot;
    Log("Maximum lot size based on balance: " + maxLotBasedOnBalance);

    return NormalizeDouble(MathMin(maxLot, maxLotBasedOnBalance), 1);
}

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double CalculatePositionSize(double riskAmount, double entryPrice, double stopLossPrice) {

    double slPoints     = MathAbs(entryPrice - stopLossPrice);   // / SymbolInfoDouble(Symbol(), SYMBOL_POINT);
    //Round off the calculated lot size
    double positionSize = MathFloor(MathMin(NormalizeDouble(riskAmount / slPoints, 1), GetMaximumLotSize()));

    if(Fix_Lot_Size > 0) {
        positionSize = Fix_Lot_Size;
    }

    Log("PositionSize: " + positionSize + ", Points: " + MathAbs(entryPrice - stopLossPrice) + ", risk: " + riskAmount);
    return positionSize;
}

// Close all open positions
void CloseAll() {
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong posTicket = PositionGetTicket(i);
        if(PositionSelectByTicket(posTicket)) {
            if(PositionGetString(POSITION_SYMBOL) != _Symbol) {
                continue;
            }
            CTrade *Trade;
            Trade = new CTrade;

            if(Trade.PositionClose(posTicket)) {
                Log("Pos :" + posTicket + " was closed full");
            }
            delete Trade;
        }
    }
}

// Checks if any running sell positions exist
bool IsOpenSellPosition() {
    if(MultiTrading == true) {
        return false;
    }
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong posTicket = PositionGetTicket(i);
        if(PositionSelectByTicket(posTicket)) {
            if(PositionGetString(POSITION_SYMBOL) != _Symbol) {
                continue;
            }
            ENUM_POSITION_TYPE positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            if(positionType == POSITION_TYPE_SELL) {
                return true;
            }
        }
    }
    return false;
}

// Checks if any running buy positions exist
bool IsOpenBuyPosition() {
    if(MultiTrading == true) {
        return false;
    }
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong posTicket = PositionGetTicket(i);
        if(PositionSelectByTicket(posTicket)) {
            if(PositionGetString(POSITION_SYMBOL) != _Symbol) {
                continue;
            }
            ENUM_POSITION_TYPE positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            if(positionType == POSITION_TYPE_BUY) {
                return true;
            }
        }
    }
    return false;
}

// Checks if the candle for the given index is an inverted hammer candle. A candle with a small bottom body and a long top wick
bool IsInvertedHammer(int index) {
    double open  = iOpen(_Symbol, PERIOD_CURRENT, index);
    double close = iClose(_Symbol, PERIOD_CURRENT, index);
    double high  = iHigh(_Symbol, PERIOD_CURRENT, index);
    double low   = iLow(_Symbol, PERIOD_CURRENT, index);

// Calculation for candle component
    double bodySize    = MathAbs(close - open);
    double upperShadow = high - MathMax(open, close);
    double lowerShadow = MathMin(open, close) - low;

// Criteria for inverted hammer candle
    bool isInvertedHammer =
        (upperShadow > 2 * bodySize) &&    // Upper shadow of the candle must be twice the sice of the body
        (lowerShadow <= 4 * bodySize) &&   // Lower shadow must be small
        (bodySize > 0);                    // There must be a body

    return isInvertedHammer;
}

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsHammerCandle(int index) {
// Get candle attributes
    double open  = iOpen(_Symbol, PERIOD_CURRENT, index);
    double close = iClose(_Symbol, PERIOD_CURRENT, index);
    double high  = iHigh(_Symbol, PERIOD_CURRENT, index);
    double low   = iLow(_Symbol, PERIOD_CURRENT, index);

// Calculation for candle component
    double bodySize    = MathAbs(close - open);
    double upperShadow = high - MathMax(open, close);
    double lowerShadow = MathMin(open, close) - low;

// Criteria for inverted hammer candle
    bool isHammerCandle =
        (lowerShadow > 2 * bodySize) &&    // Upper shadow of the candle must be twice the sice of the body
        (upperShadow <= 4 * bodySize) &&   // Lower shadow must be small
        (bodySize > 0);                    // There must be a body

    return isHammerCandle;
}

// Checks if the candle for the given index is a doji candle
bool IsDoji(int index, double epsilon = 1.0) {
// Get the open and close price
    double open  = iOpen(_Symbol, PERIOD_CURRENT, index);
    double close = iClose(_Symbol, PERIOD_CURRENT, index);

// Calculate the body size
    double bodySize = MathAbs(close - open);

// Criteria for the doji candle. If the body is smaller than epsilon
    return (bodySize < epsilon);
}

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsWithoutEndWick(int index) {
    double open  = iOpen(_Symbol, PERIOD_CURRENT, index);
    double close = iClose(_Symbol, PERIOD_CURRENT, index);
    double high  = iHigh(_Symbol, PERIOD_CURRENT, index);
    double low   = iLow(_Symbol, PERIOD_CURRENT, index);

// Bullish
    if(close > open) {
        if(close == high) {
            return true;
        }
    } else {
        if(close == low) {
            return true;
        }
    }
    return false;
}

// Checks if the candle for the given index is equal or same size as the given size
bool IsSmallCandle(int index, double size) {
    double high = iHigh(_Symbol, PERIOD_CURRENT, index);
    double low  = iLow(_Symbol, PERIOD_CURRENT, index);

    return high - low <= size;
}

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool OpenedUnderPreviousCandle(int index) {
    double openCurrent   = iOpen(_Symbol, PERIOD_CURRENT, index);
    double closePrevious = iClose(_Symbol, PERIOD_CURRENT, index - 1);
    return closePrevious - openCurrent > 1.0;
}

// Validates the selling on different criterias
bool SellValidation(MA_Return &ma) {
    MA_TREND maTrend = ValidateMA(ma);

    bool validMA = maTrend == BEARISH;
    bool validSell = false;

    bool isOpenSellPosition = IsOpenSellPosition();
    bool isOpenBuyPosition = IsOpenBuyPosition();
    bool isSmallCandle = IsSmallCandle(1, Minimum_Size_Of_Candle);
    bool isHammerCandle = IsHammerCandle(1);
    bool isWithoutEndWick = IsWithoutEndWick(1);

    validSell = isOpenBuyPosition == false &&
                isOpenSellPosition == false &&
                isSmallCandle == false &&
                isHammerCandle == Hammer_Candle_Sell &&
                isWithoutEndWick == Candles_Without_Endwick_Sell &&
                validMA;

    if (Debug) {
        double highPrice  = iHigh(_Symbol, PERIOD_CURRENT, 1);
        string description = "SELL " + "\n" + "IsSC: " + isSmallCandle + "\n" + "IsH: " + isHammerCandle + "\n" + "IsWEWick: " + isWithoutEndWick + "\n" + "ValidMA "+ validMA;
        ObjectCreate(0, description, OBJ_ARROW_SELL, 0, iTime(_Symbol, PERIOD_CURRENT, 1), highPrice);
        ObjectSetInteger(0, description, OBJPROP_COLOR, clrRed);
    }

    return validSell;
}

// Validates the buying on different criterias
bool BuyValidation(MA_Return &ma) {
    MA_TREND maTrend = ValidateMA(ma);
    bool     validMA = maTrend == BULLISH;
    bool isOpenBuyPosition = IsOpenBuyPosition();
    bool isOpenSellPosition = IsOpenSellPosition();
    bool isSmallCandle = IsSmallCandle(1, Minimum_Size_Of_Candle);
    bool isInvertedHammer = IsInvertedHammer(1);
    bool isWithoutEndWick = IsWithoutEndWick(1);

    bool validBuy = isInvertedHammer == Inverted_Hammer_Candle_Buy &&
                    isSmallCandle == false &&
                    isOpenBuyPosition == false &&
                    isOpenSellPosition == false &&
                    isWithoutEndWick == Candles_Without_Endwick_Buy &&
                    validMA;

    if (Debug) {
        double lowPrice  = iLow(_Symbol, PERIOD_CURRENT, 1);
        string description = "Buy " + "\n" + "IsSC: " + isSmallCandle + "\n" + "IsIH: " + isInvertedHammer + "\n" + "IsWEWick: " + isWithoutEndWick + "\n" + "ValidMA "+ validMA;
        ObjectCreate(0, description, OBJ_ARROW_BUY, 0, iTime(_Symbol, PERIOD_CURRENT, 1), lowPrice);
        ObjectSetInteger(0, description, OBJPROP_COLOR, clrGreen);
    }
    return validBuy;
}

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
double CalculateSL(double entryPrice, double candleLH, double atr) {
    if(SL_Setting == ATR_BASED) {
        if(entryPrice < candleLH) {   // Bearish
            return entryPrice + atr;
        } else {   // Bullish
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
    riskAmount = (AccountInfoDouble(ACCOUNT_EQUITY) / 100) * Risk_Percent;
    accountSize = AccountInfoDouble(ACCOUNT_BALANCE);
    trade.SetExpertMagicNumber(MagicNumber);
    Log("OnInit risk amount: "+ riskAmount + ", account size: " + accountSize + ", magic: " + MagicNumber );
    return (INIT_SUCCEEDED);
}
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
}

int    supportLines         = 0;
int    resistanceLines      = 0;
double s5FirstResistance    = 0;
double s5ResistanceBreakout = 0;
double s5FirstSupport       = 0;
double s5SecondSupport      = 0;
double s5PreviousResistance = 0;
double lastAtrValue         = 0;
double riskAmount           = 0;
double accountSize          = 0;

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void HandleS2Setups(datetime time, long timeMsc, double openPrice, double closePrice, double highPrice, double lowPrice, double riskAmount, double spread, double atrValue, MA_Return &ma) {
    if(S2Setups == false) {
        return;
    }
    if(closePrice >= openPrice && (iClose(Symbol(), PERIOD_M5, 2) < iOpen(Symbol(), PERIOD_M5, 2) || openPrice == closePrice)) {
        // Condition for Bullish S2
        previousSupportPrice = supportPrice;
        supportPrice         = iClose(Symbol(), PERIOD_M5, 2);
        //Log("Bullish First Condition: prevSuppP: " + previousSupportPrice + ", suppP: " + supportPrice);

        if(previousResistancePrice != 0.0 &&
                previousSupportPrice != 0.0 &&
                resistancePrice > previousResistancePrice &&
                supportPrice > previousSupportPrice &&
                openPrice < (resistancePrice - Buffer_Distance) &&
                closePrice < (resistancePrice - Buffer_Distance) &&
                highPrice < (resistancePrice - Buffer_Distance) && S2Setups) {

            double entryPrice      = highPrice + spread;
            double stopLossPrice   = CalculateSL(entryPrice, lowPrice, atrValue);
            double takeProfitPrice = entryPrice + atrValue;

            // If set than the takeProfitPrice is at 1:1 RR
            if(Target1To1) {
                takeProfitPrice = entryPrice + (entryPrice - stopLossPrice);
            }

            // Check how big the stop loss is
            if(entryPrice - stopLossPrice > Max_SL_Points) {
                return;
            }

            double positionSize = NormalizeDouble(CalculatePositionSize(riskAmount, entryPrice, stopLossPrice), _Digits);

            if(BuyValidation(ma)) {
                Log("BUY: " + positionSize + ", entryPrice: " + entryPrice + ", stopLoss: " + stopLossPrice + ", ATR: " + atrValue + ", TP: " + takeProfitPrice + ", IsOpenBuy: " + IsOpenBuyPosition());
                if(Entry_Type == MARKET_ORDER_ENTRY) {
                    if(trade.PositionOpen(Symbol(), ORDER_TYPE_BUY, positionSize, entryPrice, (Entry_With_SL == true) ? stopLossPrice : 0.0, (Entry_With_TP == true) ? takeProfitPrice : 0.0, "Bullish S2 Long")) {
                        Log("Bullish S2 Long Position Opened");
                    }
                } else if (Entry_Type == STOP_ENTRY) {
                    if(trade.BuyStop(positionSize, entryPrice, Symbol(), (Entry_With_SL == true) ? stopLossPrice : 0.0, takeProfitPrice)) {
                        Log("Bullish S2 Long Position Opened");
                    }
                } else if (Entry_Type == WICK_CREATION_ENTRY) {
                    TradePosition position = TradePosition(-1, ORDER_TYPE_BUY, positionSize, entryPrice, stopLossPrice, (Entry_With_TP == true) ? takeProfitPrice : 0.0, TimeCurrent());
                    position.SetWickCreationWaitDuration(Seconds_To_Wait_For_Wick);
                    position.SetCreationTimeMsc(timeMsc);
                    tradePositions.Add(position);
                }
            }
        }
    } else if(closePrice <= openPrice && (iClose(Symbol(), PERIOD_M5, 2) > iOpen(Symbol(), PERIOD_M5, 2) || openPrice == closePrice)) {
        // Condition for bearish candle
        previousResistancePrice = resistancePrice;
        // Last bullish candle close price
        resistancePrice = iClose(Symbol(), PERIOD_M5, 2);

        //Log("Bearish First Condition: prevResP: " + previousResistancePrice + ", resP: " + resistancePrice);

        if(previousResistancePrice != 0.0 &&
                previousSupportPrice != 0.0 &&
                resistancePrice < previousResistancePrice &&
                supportPrice < previousSupportPrice &&
                openPrice > (supportPrice + Buffer_Distance) &&
                closePrice > (supportPrice + Buffer_Distance) &&
                lowPrice > (supportPrice + Buffer_Distance) && S2Setups) {

            double entryPrice      = lowPrice - spread;
            double stopLossPrice   = CalculateSL(entryPrice, highPrice, atrValue);
            double takeProfitPrice = entryPrice - atrValue;
            if(Target1To1) {
                takeProfitPrice = entryPrice - (stopLossPrice - entryPrice);
            }

            if(stopLossPrice - entryPrice > Max_SL_Points) {
                return;
            }

            double positionSize = CalculatePositionSize(riskAmount, entryPrice, stopLossPrice);


            if(SellValidation(ma)) {
                Print("SELL: " + positionSize + ", entryPrice: " + entryPrice + ", stopLoss: " + stopLossPrice + ", ATR: " + atrValue + ", TP: " + takeProfitPrice + ", IsOpenSell: " + IsOpenSellPosition());
                if(Entry_Type == MARKET_ORDER_ENTRY) {
                    if(trade.PositionOpen(Symbol(), ORDER_TYPE_SELL, positionSize, entryPrice, (Entry_With_SL == true) ? stopLossPrice : 0.0, takeProfitPrice, "Bearish S2 Short")) {
                        Log("Bearish S2 Short Position Opened");
                    }
                } else if (Entry_Type == STOP_ENTRY) {
                    if(trade.SellStop(positionSize, entryPrice, Symbol(), (Entry_With_SL == true) ? stopLossPrice : 0.0, takeProfitPrice)) {
                        Log("Bearish S2 Short Position Opened");
                    }
                } else if (Entry_Type == WICK_CREATION_ENTRY) {
                    TradePosition position = TradePosition(-1, ORDER_TYPE_SELL, positionSize, entryPrice, stopLossPrice, takeProfitPrice, TimeCurrent());
                    position.SetWickCreationWaitDuration(Seconds_To_Wait_For_Wick);
                    position.SetCreationTimeMsc(timeMsc);
                    tradePositions.Add(position);
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void HandleS5Setups(double openPrice, double closePrice, double highPrice, double lowPrice, double riskAmount, double spread, double atrValue, MA_Return &ma) {
    if(S5Setups == false) {
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

            double _S5SecondSupport      = s5SecondSupport;
            double _S5FirstSupport       = s5FirstSupport;
            double _S5ResistanceBreakout = s5ResistanceBreakout;
            double _SupportPrice         = supportPrice;
            double _S5FirstResistance    = s5FirstResistance;
            double _S5PreviousResistance = s5PreviousResistance;

            if(s5FirstSupport > 0 && supportPrice > s5FirstSupport) {
                s5FirstResistance    = 0;
                s5FirstSupport       = 0;
                s5SecondSupport      = 0;
                s5ResistanceBreakout = 0;
            }

            // First support zone
            if(s5PreviousResistance > supportPrice && s5FirstSupport == 0.0) {
                s5FirstSupport    = supportPrice;
                s5FirstResistance = s5PreviousResistance;
            }

            if(supportPrice < s5FirstSupport && s5SecondSupport == 0.0 && supportPrice > 0.0 && s5ResistanceBreakout > 0 && s5FirstResistance - closePrice > LTAMinimumDistance) {

                if(closePrice > s5ResistanceBreakout && closePrice < s5FirstResistance) {
                    s5FirstResistance    = 0.0;
                    s5FirstSupport       = 0.0;
                    s5ResistanceBreakout = 0.0;
                    s5SecondSupport      = 0.0;

                    double entryPrice      = highPrice + spread;
                    double stopLossPrice   = CalculateSL(entryPrice, lowPrice, atrValue);
                    double positionSize    = NormalizeDouble(CalculatePositionSize(riskAmount, entryPrice, stopLossPrice), _Digits);
                    double takeProfitPrice = entryPrice + atrValue;

                    Log("BUY S5: " + positionSize + ", entryPrice: " + entryPrice + ", stopLoss: " + stopLossPrice + ", ATR: " + atrValue + ", TP: " + takeProfitPrice + ", IsOpenBuy: " + IsOpenBuyPosition());
                    if(trade.BuyStop(positionSize, entryPrice, Symbol(), (Entry_With_SL == true) ? stopLossPrice : 0.0, takeProfitPrice)) {
                        Log("Bullish S5 Long Position Opened");
                    }
                }

                if(closePrice > s5ResistanceBreakout && closePrice > s5FirstResistance) {
                    s5FirstResistance    = 0.0;
                    s5FirstSupport       = 0.0;
                    s5ResistanceBreakout = 0.0;
                    s5SecondSupport      = 0.0;
                }
            }

            supportLines = supportLines + 1;
            ObjectCreate(0, "Support Line: " + supportLines, OBJ_HLINE, 0, 0, supportPrice);
        }
    } else if(closePrice <= openPrice && (iClose(Symbol(), PERIOD_M5, 2) > iOpen(Symbol(), PERIOD_M5, 2) || openPrice == closePrice)) {
        resistancePrice = iClose(Symbol(), PERIOD_M5, 2);

        if(resistancePrice > 0) {
            s5PreviousResistance         = resistancePrice;
            double _S5SecondSupport      = s5SecondSupport;
            double _S5FirstSupport       = s5FirstSupport;
            double _S5ResistanceBreakout = s5ResistanceBreakout;
            double _ResistancePrice      = resistancePrice;
            double _S5FirstResistance    = s5FirstResistance;
            if((s5ResistanceBreakout > 0 && resistancePrice > s5ResistanceBreakout) || (s5ResistanceBreakout > 0 && s5FirstSupport == 0) || (s5FirstResistance > 0 && resistancePrice > s5FirstResistance) || (s5ResistanceBreakout > 0 && s5FirstSupport > s5ResistanceBreakout) || (resistancePrice < s5FirstSupport) || (s5FirstSupport > 0 && s5FirstResistance - s5FirstSupport < LTAMinimumDistance) || (s5ResistanceBreakout > 0 && resistancePrice < s5ResistanceBreakout)) {
                s5FirstResistance    = 0;
                s5FirstSupport       = 0;
                s5SecondSupport      = 0;
                s5ResistanceBreakout = 0;
            }
            if(resistanceLines >= 3) {
                ObjectDelete(0, "Resistance Line: 1");
                ObjectDelete(0, "Resistance Line: 2");
                ObjectDelete(0, "Resistance Line: 3");
                resistanceLines = 0;
            }

            resistanceLines = resistanceLines + 1;

            // Second resistance after going down which is the breakout zone
            if(s5FirstSupport > 0 && resistancePrice > s5FirstSupport && s5FirstResistance - resistancePrice > LTAMinimumDistance) {
                s5ResistanceBreakout = resistancePrice;
            }

            ObjectCreate(0, "Resistance Line: " + resistanceLines, OBJ_HLINE, 0, 0, resistancePrice);
            ObjectSetInteger(0, "Resistance Line: " + resistanceLines, OBJPROP_COLOR, clrAliceBlue);
        }
    }
}

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void HandlePartialClosing(ulong ticket, double openPrice, double posVolume) {
// If setting for 1:1 RR is enabled than close 75% and move to BE

    double lotsToClose = posVolume * 0.75;
    lotsToClose        = NormalizeDouble(lotsToClose, 1);

    if(trade.PositionClosePartial(ticket, lotsToClose)) {
        Log("Pos :" + ticket + " was closed 75% with " + lotsToClose);
        trade.PositionModify(ticket, openPrice, 0.0);
    }
}

void HandleTrailStop(double askPrice, double bidPrice, double atrValue, double riskAmount, double lowPrice, double highPrice) {
    
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket)) {
            double             openPrice      = PositionGetDouble(POSITION_PRICE_OPEN);
            double             stopLoss       = PositionGetDouble(POSITION_SL);
            double             tp             = PositionGetDouble(POSITION_TP);
            double             startTrailing  = atrValue * Trail_Entry_Multiplication;
            double             offsetTrailing = atrValue * Trail_Offset_Multiplication;
            ENUM_POSITION_TYPE positionType   = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            double             posVolume      = PositionGetDouble(POSITION_VOLUME);
            datetime           openTime       = (datetime)PositionGetInteger(POSITION_TIME);
            datetime           currentTime    = TimeCurrent();
            int                magic          = PositionGetInteger(POSITION_MAGIC);
            string             symbol         = PositionGetString(POSITION_SYMBOL);

            // Check if candle is still open
            if((currentTime < (openTime + PeriodSeconds(PERIOD_CURRENT)) && Start_Trailing_After_Candle_Closed) || magic != MagicNumber || symbol != _Symbol) {
                return;
            }

            double newStopLoss = 0.0;
            if(positionType == POSITION_TYPE_BUY) {
  
                if (Trail_Along_Candle_Low) {
                    if (lowPrice > stopLoss) {
                        newStopLoss = lowPrice;
                        Log("Modify: " + ticket + ", SL: " + stopLoss + " to: " + newStopLoss);
                        trade.PositionModify(ticket, newStopLoss, 0.0);
                    }
                } else {
                    newStopLoss = MathMax(stopLoss, NormalizeDouble(bidPrice - offsetTrailing, _Digits));
                }

                double difference = bidPrice - openPrice;

                // The initial entry doesn't have a stop loss and therfore it will be set to new stop loss with adding 0.1 so that it is higher
                if(stopLoss == 0.0 && difference > 0) {
                    newStopLoss = NormalizeDouble(bidPrice - offsetTrailing, _Digits);
                    stopLoss    = newStopLoss - 0.1;
                }

                // If it goes in the other direction and risk reached than just close
                // if (difference < 0 && stopLoss == 0.0) {
                //    double slPoints = MathAbs(bidPrice - openPrice);
                //    if ((slPoints * posVolume) >= riskAmount) {
                //       Log("Close because reached risk: " + ticket);
                //       trade.PositionClose(ticket);
                //    }
                // }

                // Activate trail stop only if price is greater than defined start trailing
                if(difference >= startTrailing && IsGreater(newStopLoss, stopLoss) && Trail_Along_Candle_Low == false) {
                    Log("Modify: " + ticket + ", SL: " + stopLoss + " to: " + newStopLoss + ", startTrailing: " + (startTrailing * _Point));
                    trade.PositionModify(ticket, newStopLoss, 0.0);
                }

                // If setting for 1:1 RR is enabled than close 75% and move to BE
                stopLoss = PositionGetDouble(POSITION_SL);
                if(Is1To1(openPrice, bidPrice, openPrice - atrValue) && stopLoss < openPrice && bidPrice > openPrice) {
                    HandlePartialClosing(ticket, openPrice, posVolume);
                }
            } else if(positionType == POSITION_TYPE_SELL) {
                
                if (Trail_Along_Candle_Low) {
                    if (highPrice < stopLoss) {
                        newStopLoss = highPrice;
                        Log("Modify: " + ticket + ", SL: " + stopLoss + " to: " + newStopLoss);
                        trade.PositionModify(ticket, newStopLoss, 0.0);
                    }
                } else {
                    newStopLoss = MathMin(stopLoss, NormalizeDouble(askPrice + offsetTrailing, _Digits));
                }

                // Price difference from openprice to current price
                double difference = openPrice - askPrice;

                if(stopLoss == 0.0 && difference > 0) {
                    newStopLoss = NormalizeDouble(askPrice + offsetTrailing, _Digits);
                    stopLoss    = newStopLoss + 0.1;
                }

                // If it goes in the other direction and risk reached than just close
                // if (difference < 0 && stopLoss == 0.0) {
                //    double slPoints = MathAbs(Ask - openPrice);
                //    if ((slPoints * posVolume) >= risk_amount) {
                //       Log("Close because reached risk: " + ticket);
                //       trade.PositionClose(ticket);
                //    }
                // }

                if(difference >= startTrailing && IsLess(newStopLoss, stopLoss)) {
                    Log("Modify: " + ticket + ", SL: " + stopLoss + " to: " + newStopLoss + ", startTrailing: " + (startTrailing * _Point));
                    trade.PositionModify(ticket, newStopLoss, 0.0);
                }

                // If setting for 1:1 RR is enabled than close 75% and move to BE
                stopLoss = PositionGetDouble(POSITION_SL);
                if(Is1To1(openPrice, askPrice, openPrice + atrValue) && stopLoss > openPrice && askPrice < openPrice) {
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
    SymbolInfoTick(_Symbol, tick);
    double askPrice = tick.ask;
    double bidPrice = tick.bid;
    
    double    openPrice  = iOpen(Symbol(), PERIOD_M5, 1);
    double    closePrice = iClose(Symbol(), PERIOD_M5, 1);
    double    highPrice  = iHigh(Symbol(), PERIOD_M5, 1);
    double    lowPrice   = iLow(Symbol(), PERIOD_M5, 1);
    double    spread     = askPrice - bidPrice + Add_Points_To_Spread;

// Check for new bar (compatible with both MQL4 and MQL5).
    static datetime dtBarCurrent  = WRONG_VALUE;
    datetime        dtBarPrevious = dtBarCurrent;
    dtBarCurrent                  = iTime(_Symbol, _Period, 0);
    bool bNewBarEvent             = (dtBarCurrent != dtBarPrevious);

// React to a new bar event and handle it.
    if(bNewBarEvent && InTradingHours()) {
        // Detect if this is the first tick received and handle it.
        /* For example, when it is first attached to a chart and
           the bar is somewhere in the middle of its progress and
           it's not actually the start of a new bar. */
        if(dtBarPrevious == WRONG_VALUE) {
            // Do something on first tick or middle of bar ...
        } else {
            double    atrValue   = CalculateATR();
            lastAtrValue = atrValue;
            MA_Return ma         = CalculateMA();
          
            CheckAndClosePendingOrders();

            // Do something when a normal bar starts ...

            HandleS2Setups(tick.time, tick.time_msc, openPrice, closePrice, highPrice, lowPrice, riskAmount, spread, atrValue, ma);
            HandleS5Setups(openPrice, closePrice, highPrice, lowPrice, riskAmount, spread, atrValue, ma);
        }
    } else {
        // Do something else ...
    };
    HandleTrailStop(askPrice, bidPrice, lastAtrValue, riskAmount, lowPrice, highPrice);

    //Check trade positions for wick creation
    double open = iOpen(Symbol(), PERIOD_CURRENT, 0);
    double low = iLow(Symbol(), PERIOD_CURRENT, 0);
    double high = iHigh(Symbol(), PERIOD_CURRENT, 0);
    long time_ms = tick.time_msc;

    for(int i=0; i<tradePositions.Size(); i++) {
        TradePosition *position = tradePositions.At(i);
        position.CheckEntry(time_ms, open, low, high);
    }

}

// Check if the current price is on 1:1 with given stop loss and entry price
bool Is1To1(double entryPrice, double currentPrice, double stopLoss) {
    return MathAbs(currentPrice - entryPrice) >= MathAbs(stopLoss - entryPrice) && Target1To1;
}

// Checks open pending orders and closes them if certain amount of new candles closed either below or above the open price
void CheckAndClosePendingOrders() {
    int totalOrders = OrdersTotal();
    for(int i = 0; i < totalOrders; i++) {
        if(OrderSelect(OrderGetTicket(i))) {
            int type = OrderGetInteger(ORDER_TYPE);
            int magic = OrderGetInteger(ORDER_MAGIC);
            string symbol = OrderGetString(ORDER_SYMBOL);
            if((type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP) && magic == MagicNumber && symbol == _Symbol) {
                double   priceOpen = OrderGetDouble(ORDER_PRICE_OPEN);
                datetime time      = (datetime)OrderGetInteger(ORDER_TIME_SETUP);

                MqlRates m_rates_m5[];
                int      copied        = CopyRates(Symbol(), PERIOD_M5, time, TimeCurrent(), m_rates_m5);
                int      size          = fmin(copied, 10);
                int      closedCandles = 0;
                for(int i = 0; i < size; i++) {
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

                // Delete pending order when candles closed below or above open price
                if(closedCandles >= NumberOfCandlesClosedForPendingOrders) {
                    CTrade *Trade;
                    Trade = new CTrade;
                    if(Trade.OrderDelete(OrderGetTicket(i))) {
                        Log("Order: " + OrderGetTicket(i) + " deleted!");
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void CheckLoosingPositionsAndClose(double askPrice, double bidPrice, double closePrice) {
    int    handleFast = iMA(Symbol(), PERIOD_CURRENT, Fast_MA, 0, MODE_SMA, PRICE_CLOSE);
    int    handleSlow = iMA(Symbol(), PERIOD_CURRENT, Slow_MA, 0, MODE_SMA, PRICE_CLOSE);
    double maSlow[];
    double maFast[];
    CopyBuffer(handleFast, 0, 0, 1, maFast);
    CopyBuffer(handleSlow, 0, 0, 1, maSlow);
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket)) {
            double             openPrice    = PositionGetDouble(POSITION_PRICE_OPEN);
            double             stopLoss     = PositionGetDouble(POSITION_SL);
            double             tp           = PositionGetDouble(POSITION_TP);
            ENUM_POSITION_TYPE positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            double             posVolume    = PositionGetDouble(POSITION_VOLUME);
            datetime           openTime     = (datetime)PositionGetInteger(POSITION_TIME);
            datetime           currentTime  = TimeCurrent();

            double margin_level = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
            Print("Margin level: " + margin_level);
            if(margin_level < 100) {
                // Logic to handle margin call, e.g., close positions
            }

            double newStopLoss = 0.0;
            if(positionType == POSITION_TYPE_BUY) {
                double difference = bidPrice - openPrice;

                // If it goes in the other direction and risk reached than just close
                if(difference < 0 && stopLoss == 0.0) {
                    // double slPoints = MathAbs(Bid - openPrice);
                    // if ((slPoints * posVolume) >= risk_amount) {
                    // if (closePrice < maFast[0]) {
                    //     Log("Close because went under slo ma: " + ticket);
                    //     trade.PositionClose(ticket);
                    // }

                    // If ma changes the direction than close
                    if(maFast[0] < maSlow[0]) {
                        // trade.PositionClose(ticket);
                    }
                }
            } else if(positionType == POSITION_TYPE_SELL) {
                double difference = openPrice - askPrice;

                // If it goes in the other direction and risk reached than just close
                if(difference < 0 && stopLoss == 0.0) {
                    // double slPoints = MathAbs(Bid - openPrice);
                    // if ((slPoints * posVolume) >= risk_amount) {
                    if(closePrice < maSlow[0]) {
                        Log("Close because went under slo ma: " + ticket);
                        // trade.PositionClose(ticket);
                    }
                }
            }
        }
    }
}
//+------------------------------------------------------------------+