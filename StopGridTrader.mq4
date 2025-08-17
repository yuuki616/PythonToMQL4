#property strict
#property indicator_chart_window

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
   MidPrice     = NormalizeDouble((ask + bid) / 2.0, PriceDigits);
   int rawPts   = (int)MathRound((ask - bid) / point);
   int stepInt  = (int)(rawPts * GridMultiplier);
   StepPts      = NormalizeDouble(stepInt * point, PriceDigits);
   TPHigh = 0; TPLow = 0;

   for(int i=1;i<=OrdersPerSide;i++)
   {
      double buyPrice  = NormalizeDouble(MidPrice + StepPts*i, PriceDigits);
      double sellPrice = NormalizeDouble(MidPrice - StepPts*i, PriceDigits);
      int buyTicket  = OrderSend(SymbolName, OP_BUYSTOP, BaseLot, buyPrice, DEVIATION, MidPrice, 0, "basic grid", MAGIC_NUMBER, 0, clrBlue);
      int sellTicket = OrderSend(SymbolName, OP_SELLSTOP, BaseLot, sellPrice, DEVIATION, MidPrice, 0, "basic grid", MAGIC_NUMBER, 0, clrRed);
      if(i == OrdersPerSide)
      {
         double tpBuy  = NormalizeDouble(buyPrice + StepPts, PriceDigits);
         double tpSell = NormalizeDouble(sellPrice - StepPts, PriceDigits);
         if(buyTicket > 0)  OrderModify(buyTicket, buyPrice, MidPrice, tpBuy, 0, clrBlue);
         if(sellTicket > 0) OrderModify(sellTicket, sellPrice, MidPrice, tpSell, 0, clrRed);
         TPHigh = tpBuy; TPLow = tpSell;
      }
   }
}

//---- close all positions and orders
void FullClose(bool restart=true)
{
   double ask = MarketInfo(SymbolName, MODE_ASK);
   double bid = MarketInfo(SymbolName, MODE_BID);
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol()!=SymbolName || OrderMagicNumber()!=MAGIC_NUMBER) continue;
      if(OrderType()<=OP_SELL)
      {
         double price = (OrderType()==OP_BUY)?bid:ask;
         OrderClose(OrderTicket(), OrderLots(), price, DEVIATION, clrGreen);
      }
      else
      {
         OrderDelete(OrderTicket());
      }
   }
   DoneLoops++;
   if(restart && DoneLoops <= LoopCount) BuildGrid();
}

//---- handle partial profit and reversal
void HandlePartial(int ticket, int type, double openPrice)
{
   double ask = MarketInfo(SymbolName, MODE_ASK);
   double bid = MarketInfo(SymbolName, MODE_BID);
   if(!OrderSelect(ticket, SELECT_BY_TICKET)) return;

   string comment = OrderComment();

   if(StringFind(comment, "BE-REV", 0) == 0)
   {
      bool beyond = (type==OP_BUY && bid >= MidPrice) || (type==OP_SELL && ask <= MidPrice);
      if(beyond)
      {
         double price = (type==OP_BUY)?bid:ask;
         OrderClose(ticket, OrderLots(), price, DEVIATION, clrGreen);
         return;
      }
      OrderModify(ticket, openPrice, openPrice, MidPrice, 0, clrYellow);
   }
   else
   {
      // move SL to break-even and remove TP
      OrderModify(ticket, openPrice, openPrice, 0, 0, clrYellow);

      // place reverse stop at break-even
      int    revType = (type==OP_BUY)?OP_SELLSTOP:OP_BUYSTOP;
      double sl      = NormalizeDouble((type==OP_BUY)?openPrice + StepPts:openPrice - StepPts, PriceDigits);
      OrderSend(SymbolName, revType, BaseLot, openPrice, DEVIATION, sl, 0, "BE-REV", MAGIC_NUMBER, 0, clrMagenta);
   }
}

//---- check open positions for partial TP
void CheckPartial()
{
   double ask = MarketInfo(SymbolName, MODE_ASK);
   double bid = MarketInfo(SymbolName, MODE_BID);
   for(int i=0;i<OrdersTotal();i++)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol()!=SymbolName || OrderMagicNumber()!=MAGIC_NUMBER) continue;
      if(OrderType()>OP_SELL) continue;
      double trg = (OrderType()==OP_BUY) ? OrderOpenPrice()+StepPts : OrderOpenPrice()-StepPts;
      bool hit = (OrderType()==OP_BUY && bid >= trg) || (OrderType()==OP_SELL && ask <= trg);
      if(hit && MathAbs(OrderLots()-BaseLot) < 0.000001)
      {
         int ticket = OrderTicket();
         double openPrice = OrderOpenPrice();
         int type = OrderType();
         double price = (type==OP_BUY)?bid:ask;
         double half = BaseLot/2.0;
         if(OrderClose(ticket, half, price, DEVIATION, clrGreen))
            HandlePartial(ticket, type, openPrice);
      }
   }
}

//---- expert initialization
int OnInit()
{
   BuildGrid();
   return(INIT_SUCCEEDED);
}

//---- expert tick function
void OnTick()
{
   double ask = MarketInfo(SymbolName, MODE_ASK);
   double bid = MarketInfo(SymbolName, MODE_BID);
   double mid = (ask + bid) / 2.0;
   if((TPHigh>0 && mid >= TPHigh) || (TPLow>0 && mid <= TPLow))
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
