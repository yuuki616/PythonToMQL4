#property strict

input string  SymbolName      = "XAUUSD";   // Symbol name
input int     PriceDigits     = 2;           // Price digits
input double  BaseLot         = 0.02;        // Base lot size
input int     OrdersPerSide   = 10;          // Number of orders per side
input double  GridMultiplier  = 2.0;         // Multiplier of spread for grid step
input int     LoopCount       = 0;           // Number of grid restarts (0 = once)

int    MAGIC_NUMBER = 0;
int    DEVIATION    = 100;
double StepPts = 0.0;
double MidPrice = 0.0;
double TPHigh = 0.0;
double TPLow = 0.0;
int    DoneLoops = 0;

//---- build grid of pending orders
void BuildGrid()
{
   double ask   = MarketInfo(SymbolName, MODE_ASK);
   double bid   = MarketInfo(SymbolName, MODE_BID);
   double point = MarketInfo(SymbolName, MODE_POINT);
   int    digits = (int)MarketInfo(SymbolName, MODE_DIGITS);
   MidPrice     = NormalizeDouble((ask + bid) / 2.0, PriceDigits);
   // stop-loss for all pending orders is the rounded mid-price
   double midSL = NormalizeDouble(MidPrice, PriceDigits);
   int rawPts   = (int)MathRound((ask - bid) / point);
   int stepInt  = (int)(rawPts * GridMultiplier);
   StepPts      = stepInt * point;
   TPHigh = 0; TPLow = 0;

   for (int i = 1; i <= OrdersPerSide; i++)
   {
      double buyPrice  = NormalizeDouble(MidPrice + StepPts * i, digits);
      double sellPrice = NormalizeDouble(MidPrice - StepPts * i, digits);
      int buyTicket  = OrderSend(SymbolName, OP_BUYSTOP, BaseLot, buyPrice, DEVIATION, midSL, 0, "basic grid", MAGIC_NUMBER, 0, clrBlue);
      int sellTicket = OrderSend(SymbolName, OP_SELLSTOP, BaseLot, sellPrice, DEVIATION, midSL, 0, "basic grid", MAGIC_NUMBER, 0, clrRed);
      if (i == OrdersPerSide)
      {
         double tpBuy  = NormalizeDouble(buyPrice + StepPts, digits);
         double tpSell = NormalizeDouble(sellPrice - StepPts, digits);
         if (buyTicket > 0)
         {
            if (!OrderModify(buyTicket, buyPrice, midSL, tpBuy, 0, clrBlue))
               Print("OrderModify failed for buyTicket", buyTicket, " error:", GetLastError());
         }
         if (sellTicket > 0)
         {
            if (!OrderModify(sellTicket, sellPrice, midSL, tpSell, 0, clrRed))
               Print("OrderModify failed for sellTicket", sellTicket, " error:", GetLastError());
         }
         TPHigh = tpBuy; TPLow = tpSell;
      }
   }
}

//---- close all positions and orders
void FullClose(bool restart = true)
{
   double ask = MarketInfo(SymbolName, MODE_ASK);
   double bid = MarketInfo(SymbolName, MODE_BID);
   for (int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderSymbol() != SymbolName || OrderMagicNumber() != MAGIC_NUMBER) continue;
      if (OrderType() <= OP_SELL)
      {
         double price = (OrderType() == OP_BUY) ? bid : ask;
         if (!OrderClose(OrderTicket(), OrderLots(), price, DEVIATION, clrGreen))
            Print("OrderClose failed: ", GetLastError());
      }
      else
      {
         if (!OrderDelete(OrderTicket()))
            Print("OrderDelete failed: ", GetLastError());
      }
   }
   DoneLoops++;
   if (restart && DoneLoops <= LoopCount) BuildGrid();
}

//---- handle partial profit and reversal
void HandlePartial(int ticket, int type, double openPrice)
{
   double ask = MarketInfo(SymbolName, MODE_ASK);
   double bid = MarketInfo(SymbolName, MODE_BID);
   if (!OrderSelect(ticket, SELECT_BY_TICKET)) return;

   // break-even price rounded to user-specified digits
   double bePrice = NormalizeDouble(openPrice, PriceDigits);

   string comment = OrderComment();

   if (StringFind(comment, "BE-REV", 0) == 0)
   {
      bool beyond = (type == OP_BUY && bid >= MidPrice) || (type == OP_SELL && ask <= MidPrice);
      if (beyond)
      {
         double price = (type == OP_BUY) ? bid : ask;
         if (!OrderClose(ticket, OrderLots(), price, DEVIATION, clrGreen))
            Print("OrderClose failed: ", GetLastError());
         return;
      }
      double midTP = NormalizeDouble(MidPrice, PriceDigits);
      if (!OrderModify(ticket, bePrice, bePrice, midTP, 0, clrYellow))
         Print("OrderModify failed: ", GetLastError());
   }
   else
   {
      // move SL to break-even and remove TP
      if (!OrderModify(ticket, bePrice, bePrice, 0, 0, clrYellow))
         Print("OrderModify failed: ", GetLastError());

      // place reverse stop at break-even
      int    revType = (type == OP_BUY) ? OP_SELLSTOP : OP_BUYSTOP;
      double sl      = NormalizeDouble((type == OP_BUY) ? bePrice + StepPts : bePrice - StepPts, PriceDigits);
      int revTicket = OrderSend(SymbolName, revType, BaseLot, bePrice, DEVIATION, sl, 0, "BE-REV", MAGIC_NUMBER, 0, clrMagenta);
      if (revTicket < 0)
         Print("OrderSend failed: ", GetLastError());
   }
}

//---- check open positions for partial TP
void CheckPartial()
{
   double ask = MarketInfo(SymbolName, MODE_ASK);
   double bid = MarketInfo(SymbolName, MODE_BID);
   // iterate backwards so closing a position doesn't skip the next one
   for (int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderSymbol() != SymbolName || OrderMagicNumber() != MAGIC_NUMBER) continue;
      if (OrderType() > OP_SELL) continue;
      double trg = (OrderType() == OP_BUY) ? OrderOpenPrice() + StepPts : OrderOpenPrice() - StepPts;
      bool hit = (OrderType() == OP_BUY && bid >= trg) || (OrderType() == OP_SELL && ask <= trg);
      if (hit && MathAbs(OrderLots() - BaseLot) < 0.000001)
      {
         int ticket = OrderTicket();
         double openPrice = OrderOpenPrice();
         int type = OrderType();
         double price = (type == OP_BUY) ? bid : ask;
         double half = BaseLot / 2.0;
         if (OrderClose(ticket, half, price, DEVIATION, clrGreen))
            HandlePartial(ticket, type, openPrice);
      }
   }
}

//---- expert initialization
int OnInit()
{
   int lot100 = (int)MathRound(BaseLot * 100);
   if (PriceDigits < 0 || lot100 < 2 || lot100 % 2 != 0 ||
      OrdersPerSide < 1 || GridMultiplier <= 0 || LoopCount < 0)
   {
      Print("Invalid input parameters");
      return(INIT_PARAMETERS_INCORRECT);
   }
   BuildGrid();
   return(INIT_SUCCEEDED);
}

//---- expert tick function
void OnTick()
{
   double ask = MarketInfo(SymbolName, MODE_ASK);
   double bid = MarketInfo(SymbolName, MODE_BID);
   double mid = (ask + bid) / 2.0;
   if ((TPHigh > 0 && mid >= TPHigh) || (TPLow > 0 && mid <= TPLow))
   {
      FullClose();
      return;
   }
   CheckPartial();
}

//---- expert deinitialization
void OnDeinit(const int reason)
{
   FullClose(false);
}
