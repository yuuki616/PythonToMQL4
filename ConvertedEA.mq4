#property strict

extern int    InpMagic=12112;
extern double InpBaseLot=0.02;
extern int    InpSlippagePoints=10;
extern double InpMaxSpreadPips=2.0;
extern bool   InpVerboseLog=true;
extern bool   InpNettingEmulation=false;
extern int    InpTimerSec=1;
extern string InpSymbol="XAUUSD";
extern int    InpOrdersSide=10;
extern double InpGridMultiplier=2.0;
extern int    InpLoopCount=0;

string GRID_TAG="basic grid";
double mid=0;
int    stepPts=0;
double tpHigh=0;
double tpLow=0;
int    loopsDone=0;

double PipsToPoints(double p){ return p*((Digits==3||Digits==5)?10:1); }
double SpreadPips(){ return MarketInfo(Symbol(), MODE_SPREAD)/((Digits==3||Digits==5)?10.0:1.0); }

double NormalizeLots(double lot){
   double minLot=MarketInfo(Symbol(),MODE_MINLOT);
   double maxLot=MarketInfo(Symbol(),MODE_MAXLOT);
   double step=MarketInfo(Symbol(),MODE_LOTSTEP);
   if(lot<minLot) lot=minLot;
   if(lot>maxLot) lot=maxLot;
   if(step>0) lot=minLot+MathFloor((lot-minLot)/step)*step;
   return NormalizeDouble(lot,2);
}

void Pend(int type,double price,double sl,double tp,string tag){
   double lot=NormalizeLots(InpBaseLot);
   if(InpVerboseLog)
      Print("[PEND] type=",type," price=",DoubleToString(price,Digits)," tp=",DoubleToString(tp,Digits)," lot=",lot," tag=",tag);
   int ticket=OrderSend(Symbol(),type,lot,price,InpSlippagePoints,sl,tp,tag,InpMagic,0,clrNONE);
   if(ticket<=0 && InpVerboseLog)
      Print("OrderSend failed err=",GetLastError());
}

void PlaceBERev(int type,double be){
   int otype= type==OP_BUY ? OP_SELLSTOP : OP_BUYSTOP;
   double sl = type==OP_BUY ? be+stepPts*Point : be-stepPts*Point;
   Pend(otype,be,NormalizeDouble(sl,Digits),0,"BE-REV");
}

void HandlePartial(int ticket,int type){
   if(!OrderSelect(ticket,SELECT_BY_TICKET)) return;
   double bePrice=NormalizeDouble(OrderOpenPrice(),Digits);
   if(StringFind(OrderComment(),"BE-REV")==0){
      bool beyond = (type==OP_BUY && Bid>=mid) || (type==OP_SELL && Ask<=mid);
      if(beyond){
         bool ok=OrderClose(ticket,OrderLots(), (type==OP_BUY?Bid:Ask), InpSlippagePoints);
         if(!ok && InpVerboseLog) Print("mid-instant TP failed err=",GetLastError());
         return;
      }
      OrderModify(ticket,OrderOpenPrice(),bePrice,NormalizeDouble(mid,Digits),0,clrNONE);
   }else{
      OrderModify(ticket,OrderOpenPrice(),bePrice,0,0,clrNONE);
      PlaceBERev(type,bePrice);
   }
}

void BuildGrid(){
   RefreshRates();
   double pt=Point;
   mid=NormalizeDouble((Bid+Ask)/2,Digits);
   stepPts=int(MarketInfo(Symbol(),MODE_SPREAD)*InpGridMultiplier);
   tpHigh=0; tpLow=0;
   for(int i=1;i<=InpOrdersSide;i++){
      double buy=NormalizeDouble(mid+i*stepPts*pt,Digits);
      double sell=NormalizeDouble(mid-i*stepPts*pt,Digits);
      double tpB=0,tpS=0;
      if(i==InpOrdersSide){
         tpHigh=NormalizeDouble(buy+stepPts*pt,Digits);
         tpLow =NormalizeDouble(sell-stepPts*pt,Digits);
         tpB=tpHigh; tpS=tpLow;
      }
      Pend(OP_BUYSTOP,buy,mid,tpB,GRID_TAG);
      Pend(OP_SELLSTOP,sell,mid,tpS,GRID_TAG);
   }
   if(InpVerboseLog)
      Print("Grid ready loop=",loopsDone,"/",InpLoopCount);
}

void FullClose(){
   for(int i=OrdersTotal()-1;i>=0;i--){
      if(OrderSelect(i,SELECT_BY_POS,MODE_TRADES)){
         if(OrderMagicNumber()!=InpMagic || OrderSymbol()!=Symbol()) continue;
         if(OrderType()>OP_SELL){
            bool ok=OrderDelete(OrderTicket());
            if(!ok && InpVerboseLog) Print("OrderDelete failed err=",GetLastError());
         }else{
            bool ok=OrderClose(OrderTicket(),OrderLots(),(OrderType()==OP_BUY?Bid:Ask),InpSlippagePoints);
            if(!ok && InpVerboseLog) Print("OrderClose failed err=",GetLastError());
         }
      }
   }
   loopsDone++;
   if(loopsDone<=InpLoopCount){
      BuildGrid();
   }else{
      if(InpVerboseLog) Print("All loops done – exit");
      if(InpTimerSec>0) EventKillTimer();
   }
}

void Monitor(){
   if(SpreadPips()>InpMaxSpreadPips) return;
   RefreshRates();
   double midNow=(Bid+Ask)/2;
   if((tpHigh>0 && midNow>=tpHigh) || (tpLow>0 && midNow<=tpLow)){
      FullClose();
      return;
   }
   double half=NormalizeLots(InpBaseLot/2.0);
   for(int i=OrdersTotal()-1;i>=0;i--){
      if(OrderSelect(i,SELECT_BY_POS,MODE_TRADES)){
         if(OrderMagicNumber()!=InpMagic || OrderSymbol()!=Symbol()) continue;
         if(OrderType()==OP_BUY || OrderType()==OP_SELL){
            double trg = (OrderType()==OP_BUY) ? OrderOpenPrice()+stepPts*Point : OrderOpenPrice()-stepPts*Point;
            bool hit = (OrderType()==OP_BUY && Bid>=trg) || (OrderType()==OP_SELL && Ask<=trg);
            if(hit && MathAbs(OrderLots()-InpBaseLot)<0.0000001){
               bool ok=OrderClose(OrderTicket(),half,(OrderType()==OP_BUY?Bid:Ask),InpSlippagePoints);
               if(ok){
                  HandlePartial(OrderTicket(),OrderType());
               }else if(InpVerboseLog){
                  Print("partial TP failed err=",GetLastError());
               }
            }
         }
      }
   }
}

int OnInit(){
   if(InpTimerSec>0) EventSetTimer(InpTimerSec);
   BuildGrid();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason){
   if(InpTimerSec>0) EventKillTimer();
}

void OnTick(){
   // grid logic handled in OnTimer
}

void OnTimer(){
   Monitor();
}

