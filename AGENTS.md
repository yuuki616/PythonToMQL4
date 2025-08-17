# AGENTS.md — Codex 変換仕様（MT5用 Python EA ▶ MT4用 MQL4 EA）

この文書は、**MetaTrader 5 の Python EA / 自動売買スクリプト**を、**MetaTrader 4 の MQL4 EA**に変換させるための Codex 指示書（エージェント仕様）です。Codex は本仕様に厳密に従い、ソースの取扱い、API 対応表、コード生成規約、検証基準を満たした **.mq4** を出力します。

---

## 0. スコープと前提

- 入力：MetaTrader5 Python API（`MetaTrader5` パッケージ）を用いた取引ロジック／監視ループ／指標計算コード。
- 出力：MT4 Build 1350+ 互換の **単一 EA**（必要に応じて補助 `.mqh` を併設しても良いが、**同一リポジトリに生成**）。
- 口座モード：MT4 は **ヘッジ口座**前提。Python 側がネットティング相当の設計でも、必要なら **自前でネットティング模倣（反対ポジ全決済→新規）** を実装すること。
- イベントモデル：Python の `while True` ループは **MQL4 の **``** / **`` に置換。``** を OnTick 内で使わない。**
- 計測／ログ：**Verbose ログ ON/OFF** を外部パラメータ化し、トレード根拠・ロット算出根拠・失敗理由を必ず `Print()` 出力可能にする。

---

## 1. 生成物（成果物）

- `ConvertedEA.mq4`（デフォルト名。ユーザーが別名を指定した場合は従う）
- 任意：`/include/ConvertedEA_Utils.mqh`（ユーティリティ分離時）
- **コンパイル警告 0 / エラー 0**。ビルド直後にストラテジーテスターで起動可能であること。

---

## 2. 外部入力パラメータ（デフォルト）

```mql
extern int      InpMagic            = 12112;
extern double   InpBaseLot          = 0.10;          // 既定ロット
extern int      InpSlippagePoints   = 10;            // スリッページ（ポイント）
extern double   InpMaxSpreadPips    = 2.0;           // 許容最大スプレッド（pips）
extern bool     InpVerboseLog       = true;          // 詳細ログ
extern bool     InpNettingEmulation = false;         // 反対側全決済→新規
extern int      InpTimerSec         = 0;             // >0 なら OnTimer を使用
```

> 変換時に Python 側の設定値が存在する場合は、**上記へマッピング**し、初期値も引き継ぐ。

---

## 3. API 対応表（Python ➜ MQL4）

### 3.1 初期化・終了

| Python (MetaTrader5)                  | MQL4 対応                                           |
| ------------------------------------- | ------------------------------------------------- |
| `mt5.initialize()` / `mt5.shutdown()` | 不要（MT4 ではプラットフォームが管理）。`OnInit()`/`OnDeinit()` を実装 |

### 3.2 シンボル・ティック情報

| Python                            | MQL4 対応                                                    |
| --------------------------------- | ---------------------------------------------------------- |
| `mt5.symbol_info(symbol)`         | `MarketInfo(symbol, MODE_*)` / `Digits` / `Point`          |
| `mt5.symbol_select(symbol, True)` | 不要（チャートの `Symbol()` を使用。必要なら `RefreshRates()`）             |
| `mt5.symbol_info_tick(symbol)`    | `MarketInfo(symbol, MODE_BID/ASK)`（必要に応じ `RefreshRates()`） |

### 3.3 レート／ヒストリ

| Python                             | MQL4 対応                                                                 |
| ---------------------------------- | ----------------------------------------------------------------------- |
| `mt5.copy_rates_from(_pos/_range)` | `iTime/iOpen/iHigh/iLow/iClose/iVolume`（必要本数を `ArraySetAsSeries` で後方基準） |

### 3.4 ポジション／注文取得

| Python                          | MQL4 対応                                                                                                                     |
| ------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `mt5.positions_get(symbol=...)` | `OrdersTotal()`→`OrderSelect(i, SELECT_BY_POS, MODE_TRADES)`→`OrderSymbol/OrderMagicNumber/OrderType/OrderLots/OrderTicket` |
| `mt5.orders_get(symbol=...)`    | 同上。ただし `OrderType` が保留型（`OP_BUYLIMIT` など）を抽出                                                                                |

### 3.5 新規発注

| Python Request              | MQL4 `OrderSend` 引数                                |
| --------------------------- | -------------------------------------------------- |
| `type=ORDER_TYPE_BUY`       | `OP_BUY`                                           |
| `type=ORDER_TYPE_SELL`      | `OP_SELL`                                          |
| `type=BUY_LIMIT/SELL_LIMIT` | `OP_BUYLIMIT` / `OP_SELLLIMIT`                     |
| `type=BUY_STOP/SELL_STOP`   | `OP_BUYSTOP` / `OP_SELLSTOP`                       |
| `volume` (lots)             | `lots`（`NormalizeLots()` で丸め）                      |
| `price`                     | `price`（小数桁に合わせて `NormalizeDouble(price, Digits)`） |
| `sl`, `tp`                  | `sl`, `tp`（**StopLevel/FreezeLevel** を順守）          |
| `type_filling`（FOK/IOC）     | **未対応**（MT4 は `slippage` のみ）                       |
| `comment`                   | `comment`                                          |
| `magic`                     | `magic`                                            |

> 失敗時は `GetLastError()` をログ。戻り値 `ticket <= 0` は**必ず**ハンドリング。

### 3.6 クローズ／変更

| Python                        | MQL4 対応                                                                 |
| ----------------------------- | ----------------------------------------------------------------------- |
| `order_close(...)`（または再リクエスト） | 成行：`OrderClose(ticket, lots, price, slippage)`／保留：`OrderDelete(ticket)` |
| `order_modify(sl,tp,...)`     | `OrderModify(ticket, price, sl, tp, expiration)`                        |

---

## 4. シグナル・インディケータ対応

- Python の **pandas/NumPy** による移動平均や ATR 等は、MQL4 の組込 ``** / **``** / **``** / **``** / **`` に置換。
- カスタム計算が必要な場合：
  1. 直接 MQL4 で実装（配列は `ArraySetAsSeries`）。
  2. もしくは **カスタムインジケータ（.mq4）** を別途生成し、EA は `iCustom` で参照。
- オフセットは ``** を基準（確定足）**。確定足以外を使用していた場合は、**明示的に仕様へ記述**。

---

## 5. 取引ルール実装ガイド

### 5.1 スプレッド・小数桁・pips 換算

```mql
int    _Digits = Digits;
double _Point  = Point;
double PipsToPoints(double p){ return p * ((_Digits==3 || _Digits==5)?10:1); }
double SpreadPips(){ return (MarketInfo(Symbol(), MODE_SPREAD)) / ((_Digits==3||_Digits==5)?10.0:1.0); }
```

- **許容スプレッド**：`if(SpreadPips() > InpMaxSpreadPips) return;`
- 価格・SL/TP は ``。ロットは `` で口座最小・ステップに丸め。

### 5.2 StopLevel / FreezeLevel

```mql
int stopLevelPoints  = MarketInfo(Symbol(), MODE_STOPLEVEL);
int freezeLevelPoints= MarketInfo(Symbol(), MODE_FREEZELEVEL);
```

- `sl/tp` は ``** 以上の距離**を厳守。違反時は**安全側に再配置**。

### 5.3 発注ユーティリティ（例）

```mql
bool SendMarket(int type,double lots,double sl,double tp,string cmt){
    RefreshRates();
    double price = (type==OP_BUY)? Ask : Bid;
    int    tk = OrderSend(Symbol(), type, lots, NormalizeDouble(price,Digits), InpSlippagePoints,
                          (sl>0?NormalizeDouble(sl,Digits):0), (tp>0?NormalizeDouble(tp,Digits):0),
                          cmt, InpMagic, 0, clrNONE);
    if(tk<=0){ if(InpVerboseLog) Print("OrderSend failed ",GetLastError()); return false; }
    return true;
}
```

### 5.4 ネッティング模倣（任意）

- `InpNettingEmulation==true` の場合：**新規エントリー前に反対方向のポジションを全決済**。

### 5.5 ポジション列挙（自分の注文のみ）

```mql
int MyPositionsCount(int type){
    int n=0;
    for(int i=OrdersTotal()-1;i>=0;i--) if(OrderSelect(i,SELECT_BY_POS,MODE_TRADES)){
        if(OrderSymbol()==Symbol() && OrderMagicNumber()==InpMagic && OrderType()==type) n++;
    }
    return n;
}
```

---

## 6. Python の制御フロー → MQL4 への写像

- `while True: ... time.sleep(x)`
  - **OnTick ベース**に置換。`sleep` 等の待機は `` に移し、`InpTimerSec>0` 時のみ `EventSetTimer(InpTimerSec)` を使用。
- **状態管理**：Python のグローバル／クラス変数は MQL4 の `static`／グローバル変数へ移す。
- **例外処理**：Python の try/except は、MQL4 では戻り値チェック＋ `GetLastError()` ログで代替。

---

## 7. ロット計算・資金管理

- Python 側のロット算出（例：残高比率、固定ロット、独自列・モンテカルロ等）は **専用関数**に切出し：

```mql
double CalcLots(){
    // 例）固定ロット
    double lot = InpBaseLot;
    return NormalizeLots(lot);
}

double NormalizeLots(double lot){
    double minLot = MarketInfo(Symbol(), MODE_MINLOT);
    double step   = MarketInfo(Symbol(), MODE_LOTSTEP);
    double maxLot = MarketInfo(Symbol(), MODE_MAXLOT);
    lot = MathMax(minLot, MathMin(maxLot, lot));
    if(step>0) lot = minLot + MathFloor((lot-minLot)/step)*step;
    return NormalizeDouble(lot, 2);
}
```

- **（任意）列ベース管理**：Python の「数列」「勝敗列」を使用している場合は、**ログ出力に列のスナップショット**（例：`[0,1,1,0,...]`）と最終ロットを Print。テスター解析性を担保。

---

## 8. 取引時間・フィルタ

- Python の時間帯制御・曜日フィルタは ``** / **``** / **`` で再現。
- 祝日カレンダー等の外部依存は、**最初は非対応**（スコープ外）。必要時に `.csv` 読込で拡張可能に設計。

---

## 9. ログ規約

- `InpVerboseLog==true` のとき：
  - シグナル根拠（指標値、閾値、足インデックス）
  - エントリー方向・価格・SL/TP・ロット
  - **ロット算出根拠（必要なら数列）**
  - エラーコードと対処
- ログは一行に過剰情報を詰め込まず、**キー=値**形式で可読化：

```
[ENTRY] dir=BUY price=1.23456 sl=1.23300 tp=1.23700 lot=0.10 reason=RSI_cross seq=[1,0,0,1]
```

---

## 10. コーディング規約（要遵守）

- **イベント関数**：`OnInit()`, `OnDeinit()`, `OnTick()`, （必要時）`OnTimer()` を実装。二重定義禁止。
- **マジック番号**で自己ポジのみを管理。`OrderSelect` 時は `Symbol()` と `InpMagic` を必ず照合。
- **確定足ベース**でシグナル判定（ルールが未確定足を使用していない限り）。
- 価格参照前は `RefreshRates()`。
- 数値は `Digits/Point` に順応（3/5 桁対応）。
- グローバル状態の初期化は `OnInit()`、破棄は `OnDeinit()`。
- **Sleep 禁止**（`OnTimer` を用いる）。

---

## 11. 受入基準（Acceptance Criteria）

1. **コンパイル無警告**。テスターで即実行可。
2. スプレッド・StopLevel 違反が無い（違反時は回避ロジックが働く）。
3. Python 版と **シグナル一致**（同一ヒストリ・同一パラメータで、方向・タイミングの差異が出ない）。
4. 主要操作のログが出力され、**ロット根拠**が追跡可能。
5. ネッティング模倣有効時、反対ポジ全決済→新規が正しく機能。

---

## 12. よくある落とし穴（回避指示）

- ``（FOK/IOC）は MT4 に無い ⇒ スリッページで代替、約定拒否時はリトライしない（仕様に従う）。
- ``** の取得本数**：MQL4 では足の順序・インデックスが逆（`ArraySetAsSeries` を忘れない）。
- **StopLevel/FreezeLevel** を無視すると `OrderSend` 失敗が頻発。
- **未確定足を参照**してシグナルがチラつく ⇒ 確定足基準へ。
- **口座ロット最小・ステップ**に合わないロット ⇒ `NormalizeLots()` 必須。

---

## 13. 変換テンプレート（最小骨子）

```mql
#property strict
extern int    InpMagic=12112;
extern double InpBaseLot=0.10;
extern int    InpSlippagePoints=10;
extern double InpMaxSpreadPips=2.0;
extern bool   InpVerboseLog=true;
extern bool   InpNettingEmulation=false;
extern int    InpTimerSec=0;

int OnInit(){ if(InpTimerSec>0) EventSetTimer(InpTimerSec); return(INIT_SUCCEEDED); }
void OnDeinit(const int reason){ if(InpTimerSec>0) EventKillTimer(); }
void OnTimer(){ /* 必要なら周期処理 */ }

void OnTick(){
    if(SpreadPips()>InpMaxSpreadPips) return;
    // 1) 指標更新
    // 2) シグナル判定（確定足）
    // 3) ネッティング模倣（任意）
    // 4) 発注（SendMarket/SendPending）
}
```

---

## 14. 追加要件（任意統合ポイント）

- **資金管理モジュール差替**：`CalcLots()` をインターフェースにし、固定／残高比率／独自数列（例：分解モンテカルロ）を切替。
- **ログの数列表示**：`Print("seq=", SeqToString(seqArr), " lot=", lot);`
- **テスター検証**：`OnTester()` を実装してカスタム評価値を返すことも可能。

---

## 15. 実装完了後の自己チェックリスト（Codex 用）

-

---

## 付録 A：型・定数マップ（抜粋）

- 市場注文：`OP_BUY`, `OP_SELL`
- 保留注文：`OP_BUYLIMIT`, `OP_SELLLIMIT`, `OP_BUYSTOP`, `OP_SELLSTOP`
- 価格：`Bid`, `Ask`（`RefreshRates()` 後）
- 情報：`MarketInfo(symbol, MODE_SPREAD|MODE_STOPLEVEL|MODE_FREEZELEVEL|MODE_MINLOT|MODE_LOTSTEP|MODE_MAXLOT)`

## 付録 B：よく使うラッパ

```mql
double SpreadPips(){ return (MarketInfo(Symbol(), MODE_SPREAD))/((Digits==3||Digits==5)?10.0:1.0); }
string F(double x,int d=Digits){ return DoubleToString(NormalizeDouble(x,d), d); }
```

---

**以上を満たす **``** を生成してください。Python 版の意図・ロジックを変更せず、イベント駆動・注文規約・丸め規則・ログ規約を遵守して移植すること。**

