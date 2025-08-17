"""
Stop-Grid Trader  – version 3.1
------------------------------------------------------------
Mini-GUI bot for MetaTrader 5 that trades a symmetric
stop-grid around the current mid-price.

Key workflow (unchanged trading logic, polished GUI):
  1.  Select a running MT5 terminal.
  2.  Enter parameters, then press **Start**:
        • Symbol name (incl. suffix)
        • Price-digits to round to
        • Base lot (even, ≥ 0.02)
        • Orders per side
        • Grid multiplier  (= spread × factor)
        • Loop count (#restarts after a full close)
  3.  The bot places alternating BUY_STOP / SELL_STOP orders
      at ±multiplier·spread intervals, outermost stops include
      a TP one grid-step farther out.
  4.  Every 0.02-lot fill is partially closed at +1 grid step
      (0.01 lot).  The remainder:
          – SL is moved to break-even (both grid & BE-REV).
          – A 0.02-lot reverse STOP is placed at the BE price.
          – If the reverse position’s 0.01 lot remainder finds
            price already beyond the initial mid-price, it is
            closed instantly; otherwise TP = initial mid-price.
  5.  Once the current mid-price touches the outer TP level,
      all pending orders are removed, every position is closed,
      and (optionally) the grid restarts up to *loop count*.
"""

import tkinter as tk
from tkinter import ttk, messagebox
import threading, time, sys
import MetaTrader5 as mt5
try:
    import psutil
except ImportError:
    psutil = None

# ── default GUI values ──────────────────────────────────────────
DEF_SYMBOL        = "XAUUSD"
DEF_DIGITS        = 2
DEF_LOT           = 0.02
DEF_ORDERS_SIDE   = 10
DEF_MULTIPLIER    = 2.0
DEF_LOOP          = 0              # 0 ⇒ run once
# ── constants (rarely changed) ─────────────────────────────────
DEVIATION         = 100
MAGIC_NUMBER      = 0
GRID_TAG          = "basic grid"
CHECK_INTERVAL    = 1.0
# ───────────────────────────────────────────────────────────────


# ═════════════════════════ GUI HELPERS ═════════════════════════
def _discover_terminals() -> list[str]:
    paths = []
    if psutil:
        for p in psutil.process_iter(attrs=["name", "exe"]):
            if "terminal64.exe" in (p.info.get("name") or "").lower():
                exe = p.info.get("exe") or ""
                if exe and exe not in paths:
                    paths.append(exe)
    return paths


def choose_terminal() -> str | None:
    """Modal: pick an MT5 terminal."""
    root = tk.Tk(); root.withdraw()
    win = tk.Toplevel(root); win.title("Select MT5 terminal"); win.grab_set()

    cols = ("exe", "login", "server", "balance", "currency", "name")
    tree = ttk.Treeview(win, columns=cols, show="headings", height=8)
    for c, w in zip(cols, (340, 80, 170, 100, 70, 150)):
        tree.heading(c, text=c); tree.column(c, width=w, anchor="w")

    for exe in _discover_terminals():
        mt5.initialize(path=exe)
        acc, _ = mt5.account_info(), mt5.terminal_info()
        if acc:
            tree.insert(
                "", tk.END,
                values=(
                    exe, acc.login, acc.server,
                    f"{acc.balance:.2f}", acc.currency, acc.name
                )
            )
        mt5.shutdown()

    tree.grid(row=0, column=0, columnspan=2, padx=6, pady=6)

    sel: dict[str, str | None] = {"path": None}

    def _use() -> None:
        if tree.selection():
            sel["path"] = tree.item(tree.selection()[0], "values")[0]
            win.destroy()

    ttk.Button(win, text="Use", command=_use)\
        .grid(row=1, column=1, pady=(0, 6), padx=6, sticky="e")

    if tree.get_children():
        tree.selection_set(tree.get_children()[0])

    win.wait_window(); root.destroy()
    return sel["path"]


class ParamDialog(tk.Toplevel):
    """Gather user parameters; returns None if canceled."""

    def __init__(self, parent: tk.Tk):
        super().__init__(parent)
        self.title("Grid parameters"); self.grab_set()
        self.res: tuple | None = None

        rows = (
            ("Symbol",          DEF_SYMBOL),
            ("Price digits",    str(DEF_DIGITS)),
            ("Base lot",        f"{DEF_LOT:.2f}"),
            ("Orders / side",   str(DEF_ORDERS_SIDE)),
            ("Grid multiplier", str(DEF_MULTIPLIER)),
            ("Loop count",      str(DEF_LOOP)),
        )
        self.vars: list[tk.StringVar] = []
        for r, (label, default) in enumerate(rows):
            ttk.Label(self, text=label).grid(row=r, column=0, sticky="w", padx=6, pady=4)
            var = tk.StringVar(value=default); self.vars.append(var)
            ttk.Entry(self, textvariable=var, width=15)\
                .grid(row=r, column=1, sticky="w", padx=6, pady=4)

        ttk.Button(self, text="Start", command=self._ok)\
            .grid(row=len(rows), column=1, pady=8, sticky="e")

    def _ok(self) -> None:
        try:
            sym   = self.vars[0].get().strip()
            digs  = int(self.vars[1].get())
            lot   = float(self.vars[2].get())
            nside = int(self.vars[3].get())
            mult  = float(self.vars[4].get())
            loops = int(self.vars[5].get())

            if digs < 0:               raise ValueError("digits ≥ 0")
            if lot < 0.02 or int(round(lot * 100)) % 2:
                raise ValueError("lot must be even ×0.01 and ≥0.02")
            if nside < 1:              raise ValueError("orders / side ≥ 1")
            if mult <= 0:              raise ValueError("multiplier > 0")
            if loops < 0:              raise ValueError("loop count ≥ 0")
        except Exception as err:
            messagebox.showerror("Invalid input", str(err), parent=self)
            return

        self.res = (sym, digs, lot, nside, mult, loops)
        self.destroy()


# ═════════════════════════ TRADER CLASS ════════════════════════
class StopGridTrader:

    def __init__(
        self,
        terminal_path: str,
        symbol: str,
        digits: int,
        base_lot: float,
        orders_side: int,
        multiplier: float,
        loop_count: int
    ):
        self.path   = terminal_path
        self.symbol = symbol
        self.digits = digits
        self.lot    = base_lot
        self.side   = orders_side
        self.mult   = multiplier
        self.loopN  = loop_count
        self.done   = 0  # loops completed

        # runtime
        self.mid: float | None = None
        self.step_pts: int | None = None
        self.tp_high = self.tp_low = None
        self.running = False

        # status window
        self.root = tk.Tk(); self.root.title("Stop-Grid Trader")
        self.status = tk.StringVar(value="Initializing…")
        ttk.Label(self.root, textvariable=self.status)\
            .grid(padx=12, pady=10)
        ttk.Button(self.root, text="Abort", command=self._abort)\
            .grid(pady=(0, 10))

    # ── MetaTrader 5 init ────────────────────────────────────
    def _mt5_init(self) -> None:
        if not mt5.initialize(path=self.path):
            c, m = mt5.last_error(); raise RuntimeError(f"MT5 init: {c} {m}")
        if not mt5.symbol_select(self.symbol, True):
            raise RuntimeError(f"Cannot select symbol {self.symbol}")

    # ── helpers ──────────────────────────────────────────────
    def _norm_vol(self, vol: float) -> float:
        info = mt5.symbol_info(self.symbol); step = info.volume_step or 0.01
        return round(max(info.volume_min, min(vol, info.volume_max)) / step) * step

    # place pending order
    def _pend(
        self, ord_type: int, price: float,
        sl: float, tp: float = 0.0,
        vol: float | None = None,
        tag: str = GRID_TAG
    ) -> None:
        if vol is None: vol = self.lot
        mt5.order_send({
            "action": mt5.TRADE_ACTION_PENDING,
            "symbol": self.symbol,
            "volume": self._norm_vol(vol),
            "type":   ord_type,
            "price":  price,
            "sl":     sl,
            "tp":     tp,
            "deviation": DEVIATION,
            "magic":  MAGIC_NUMBER,
            "comment": tag,
            "type_time": mt5.ORDER_TIME_GTC,
        })

    # ── grid creation ────────────────────────────────────────
    def _build_grid(self) -> None:
        tick = mt5.symbol_info_tick(self.symbol); info = mt5.symbol_info(self.symbol)
        self.mid      = round((tick.bid + tick.ask) / 2, self.digits)
        raw_spd_pts   = int(round((tick.ask - tick.bid) / info.point))
        self.step_pts = int(raw_spd_pts * self.mult)
        pt            = info.point

        self.tp_high = self.tp_low = None
        for i in range(1, self.side + 1):
            buy  = self.mid + i * self.step_pts * pt
            sell = self.mid - i * self.step_pts * pt
            if i == self.side:                       # outer layer
                self.tp_high = buy  + self.step_pts * pt
                self.tp_low  = sell - self.step_pts * pt
                tp_b, tp_s   = self.tp_high, self.tp_low
            else:
                tp_b = tp_s = 0.0
            self._pend(mt5.ORDER_TYPE_BUY_STOP , buy , self.mid, tp=tp_b)
            self._pend(mt5.ORDER_TYPE_SELL_STOP, sell, self.mid, tp=tp_s)

        self.status.set(f"Grid ready   (loop {self.done}/{self.loopN})")

    # place reverse stop at break-even
    def _place_be_rev(self, pos) -> None:
        info = mt5.symbol_info(self.symbol); pt = info.point
        be   = round(pos.price_open, self.digits)
        if pos.type == mt5.POSITION_TYPE_BUY:
            otype, sl = mt5.ORDER_TYPE_SELL_STOP, be + self.step_pts * pt
        else:
            otype, sl = mt5.ORDER_TYPE_BUY_STOP,  be - self.step_pts * pt
        self._pend(otype, be, round(sl, self.digits), vol=self.lot, tag="BE-REV")

    # after partial TP
    def _handle_partial(self, pos) -> None:
        tick = mt5.symbol_info_tick(self.symbol); bid, ask = tick.bid, tick.ask
        half = self.lot / 2
        be_price = round(pos.price_open, self.digits)

        if pos.comment.startswith("BE-REV"):
            beyond = (
                pos.type == mt5.POSITION_TYPE_BUY  and bid >= self.mid or
                pos.type == mt5.POSITION_TYPE_SELL and ask <= self.mid
            )
            if beyond:
                mt5.order_send({
                    "action": mt5.TRADE_ACTION_DEAL, "symbol": self.symbol,
                    "position": pos.ticket, "volume": half,
                    "type": mt5.ORDER_TYPE_SELL if pos.type == mt5.POSITION_TYPE_BUY
                           else mt5.ORDER_TYPE_BUY,
                    "price": bid if pos.type == mt5.POSITION_TYPE_BUY else ask,
                    "deviation": DEVIATION, "magic": MAGIC_NUMBER,
                    "comment": "mid-instant TP"
                })
                return
            mt5.order_send({
                "action":  mt5.TRADE_ACTION_SLTP, "symbol": self.symbol,
                "position": pos.ticket,
                "sl": be_price,                           # BE SL
                "tp": round(self.mid, self.digits),
                "deviation": DEVIATION
            })
        else:
            mt5.order_send({
                "action":  mt5.TRADE_ACTION_SLTP, "symbol": self.symbol,
                "position": pos.ticket,
                "sl": be_price,
                "tp": 0.0,
                "deviation": DEVIATION
            })
            self._place_be_rev(pos)

    # ── monitoring loop ──────────────────────────────────────
    def _monitor(self) -> None:
        info = mt5.symbol_info(self.symbol); pt = info.point
        half = self.lot / 2

        while self.running:
            time.sleep(CHECK_INTERVAL)
            tick = mt5.symbol_info_tick(self.symbol)
            mid_now = (tick.bid + tick.ask) / 2

            # global exit condition
            if (self.tp_high and mid_now >= self.tp_high) or \
               (self.tp_low  and mid_now <= self.tp_low):
                self._full_close()
                continue

            # partial-TP check
            for pos in mt5.positions_get(symbol=self.symbol) or []:
                trg = (
                    pos.price_open + self.step_pts * pt
                    if pos.type == mt5.POSITION_TYPE_BUY
                    else pos.price_open - self.step_pts * pt
                )
                hit = (
                    pos.type == mt5.POSITION_TYPE_BUY  and tick.bid >= trg or
                    pos.type == mt5.POSITION_TYPE_SELL and tick.ask <= trg
                )
                if hit and abs(pos.volume - self.lot) < 1e-6:
                    mt5.order_send({
                        "action": mt5.TRADE_ACTION_DEAL, "symbol": self.symbol,
                        "position": pos.ticket, "volume": half,
                        "type": mt5.ORDER_TYPE_SELL if pos.type == mt5.POSITION_TYPE_BUY
                               else mt5.ORDER_TYPE_BUY,
                        "price": tick.bid if pos.type == mt5.POSITION_TYPE_BUY else tick.ask,
                        "deviation": DEVIATION, "magic": MAGIC_NUMBER,
                        "comment": "partial TP"
                    })
                    time.sleep(0.3)
                    self._handle_partial(pos)

    # ── cancel orders & close positions ──────────────────────
    def _full_close(self) -> None:
        # cancel pending
        for o in mt5.orders_get(symbol=self.symbol) or []:
            if hasattr(mt5, "order_delete"):
                mt5.order_delete(o.ticket)
            else:
                mt5.order_send({
                    "action": mt5.TRADE_ACTION_REMOVE,
                    "order":  o.ticket,
                    "symbol": o.symbol
                })

        # close all positions
        tick = mt5.symbol_info_tick(self.symbol)
        for p in mt5.positions_get(symbol=self.symbol) or []:
            mt5.order_send({
                "action": mt5.TRADE_ACTION_DEAL, "symbol": self.symbol,
                "position": p.ticket, "volume": p.volume,
                "type": mt5.ORDER_TYPE_SELL if p.type == mt5.POSITION_TYPE_BUY
                       else mt5.ORDER_TYPE_BUY,
                "price": tick.bid if p.type == mt5.POSITION_TYPE_BUY else tick.ask,
                "deviation": DEVIATION, "magic": MAGIC_NUMBER,
                "comment": "grid exit"
            })

        self.done += 1
        if self.done <= self.loopN:
            self.status.set(f"Loop {self.done} finished – restarting…")
            time.sleep(2)
            self._build_grid()
        else:
            self.status.set("All loops done – exit")
            self.running = False
            self.root.after(800, self.root.quit)

    # ── GUI: abort button ────────────────────────────────────
    def _abort(self) -> None:
        if messagebox.askyesno("Abort", "Stop trading and exit?", parent=self.root):
            self.running = False
            self._full_close()

    # ── run bot ──────────────────────────────────────────────
    def run(self) -> None:
        self._mt5_init()
        self._build_grid()
        self.running = True
        threading.Thread(target=self._monitor, daemon=True).start()
        self.root.mainloop()
        mt5.shutdown()


# ══════════════════════════ MAIN ══════════════════════════════
def main() -> None:
    term = choose_terminal()
    if not term:
        sys.exit("No MT5 terminal selected – exiting.")

    root = tk.Tk(); root.withdraw()
    pd = ParamDialog(root); pd.wait_window(); root.destroy()
    if pd.res is None:
        sys.exit("Parameters dialog canceled – exiting.")

    sym, digs, lot, nside, mult, loops = pd.res
    StopGridTrader(
        terminal_path = term,
        symbol        = sym,
        digits        = digs,
        base_lot      = lot,
        orders_side   = nside,
        multiplier    = mult,
        loop_count    = loops
    ).run()


if __name__ == "__main__":
    main()