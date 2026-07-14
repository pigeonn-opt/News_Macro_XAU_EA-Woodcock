"""
Gold Macro Auto EA Backend v18

Production-oriented lightweight macro/news signal bridge for MT5 EA.
- Jin10 authorized API adapter with variable endpoint/field mapping.
- MT5 calendar and market snapshot ingestion.
- Deterministic macro scorer that can later be replaced by LLM/FinGPT/OpenAI.
- Auto execution gate; no client approval required.
- Long-priority conflict rule: if any valid macro long exists, suppress shorts.
- SQLite audit trail for events, market snapshots, signals, and MT5 ACKs.

This backend does not guarantee profitability or correctness of geopolitical judgments.
It enforces small-position, auditable, risk-gated automation.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sqlite3
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone, timedelta
from enum import Enum
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

import requests
from dotenv import load_dotenv
from fastapi import FastAPI, Header, HTTPException, Query
from pydantic import BaseModel, Field

load_dotenv()

# =============================================================================
# Config helpers
# =============================================================================


def env_str(name: str, default: str = "") -> str:
    return os.getenv(name, default)


def env_int(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, str(default)))
    except ValueError:
        return default


def env_float(name: str, default: float) -> float:
    try:
        return float(os.getenv(name, str(default)))
    except ValueError:
        return default


def env_bool(name: str, default: bool = False) -> bool:
    v = os.getenv(name)
    if v is None:
        return default
    return v.strip().lower() in {"1", "true", "yes", "y", "on"}


API_KEY = env_str("BACKEND_API_KEY", "change-me")
DB_PATH = Path(env_str("SQLITE_PATH", "./runtime/gold_macro_auto_ea.sqlite3"))
DB_PATH.parent.mkdir(parents=True, exist_ok=True)

DEFAULT_SYMBOL = env_str("DEFAULT_SYMBOL", "XAUUSD")
ENABLE_AUTO_EXECUTION = env_bool("ENABLE_AUTO_EXECUTION", False)
LIVE_STAGE = env_str("LIVE_STAGE", "shadow").lower()  # shadow, demo, micro, live

DAILY_WINDOWS_UTC = [x.strip() for x in env_str("DAILY_WINDOWS_UTC", "00:30,04:30,08:30,12:30,16:30").split(",") if x.strip()]
WINDOW_TOLERANCE_MINUTES = env_int("WINDOW_TOLERANCE_MINUTES", 20)
ALLOW_SEVERE_EVENT_OVERRIDE = env_bool("ALLOW_SEVERE_EVENT_OVERRIDE", True)
SIGNAL_TTL_SECONDS = env_int("SIGNAL_TTL_SECONDS", 900)
MAX_AUTO_SIGNALS_PER_DAY = env_int("MAX_AUTO_SIGNALS_PER_DAY", 5)
SIGNAL_COOLDOWN_SECONDS = env_int("SIGNAL_COOLDOWN_SECONDS", 1800)

SL_PIPS = env_int("SL_PIPS", 50)
TP_PIPS = env_int("TP_PIPS", 200)

# Position sizing for 100 lots full position assumption.
FULL_POSITION_LOTS = env_float("FULL_POSITION_LOTS", 100.0)
GEO_SCOUT_LOTS = env_float("GEO_SCOUT_LOTS", 1.0)
GEO_CONFIRMED_LOTS = env_float("GEO_CONFIRMED_LOTS", 3.0)
GEO_STRONG_LOTS = env_float("GEO_STRONG_LOTS", 5.0)
GEO_MAX_LOTS = env_float("GEO_MAX_LOTS", 8.0)
RATES_SCOUT_LOTS = env_float("RATES_SCOUT_LOTS", 1.0)
RATES_CONFIRMED_LOTS = env_float("RATES_CONFIRMED_LOTS", 3.0)
RATES_STRONG_LOTS = env_float("RATES_STRONG_LOTS", 5.0)
MAX_LIVE_LOTS = env_float("MAX_LIVE_LOTS", 5.0)
MAX_MICRO_LIVE_LOTS = env_float("MAX_MICRO_LIVE_LOTS", 1.0)
MAX_DEMO_LOTS = env_float("MAX_DEMO_LOTS", 0.10)

# Macro thresholds
LONG_THRESHOLD = env_float("LONG_THRESHOLD", 65.0)
SHORT_THRESHOLD = env_float("SHORT_THRESHOLD", -65.0)
MIN_CONFIDENCE = env_float("MIN_CONFIDENCE", 0.55)
SEVERE_GEO_THRESHOLD = env_float("SEVERE_GEO_THRESHOLD", 70.0)

# Market confirmation thresholds. These are conservative defaults; broker symbols differ.
XAU_MOVE_CONFIRM_PCT = env_float("XAU_MOVE_CONFIRM_PCT", 0.0010)  # 0.10% move
OIL_MOVE_CONFIRM_PCT = env_float("OIL_MOVE_CONFIRM_PCT", 0.0060)  # 0.60% move
DXY_MOVE_CONFIRM_PCT = env_float("DXY_MOVE_CONFIRM_PCT", 0.0020)  # 0.20% move
YIELD_MOVE_CONFIRM = env_float("YIELD_MOVE_CONFIRM", 0.03)  # symbol dependent, e.g. 3bp if quote in %
MARKET_LOOKBACK_SECONDS = env_int("MARKET_LOOKBACK_SECONDS", 1800)

# Jin10 authorization variables. Do not hard-code unknown endpoints.
JIN10_ENABLED = env_bool("JIN10_ENABLED", False)
JIN10_NEWS_URL = env_str("JIN10_NEWS_URL", "")
JIN10_CALENDAR_URL = env_str("JIN10_CALENDAR_URL", "")
JIN10_AUTH_HEADER_NAME = env_str("JIN10_AUTH_HEADER_NAME", "Authorization")
JIN10_AUTH_HEADER_VALUE = env_str("JIN10_AUTH_HEADER_VALUE", "")
JIN10_TIMEOUT_SECONDS = env_int("JIN10_TIMEOUT_SECONDS", 10)
JIN10_LIST_PATH = env_str("JIN10_LIST_PATH", "")

# Field mapping for Jin10 payloads; these must be aligned with contract/API docs.
JIN10_FIELD_ID = env_str("JIN10_FIELD_ID", "id")
JIN10_FIELD_TIMESTAMP = env_str("JIN10_FIELD_TIMESTAMP", "timestamp")
JIN10_FIELD_TITLE = env_str("JIN10_FIELD_TITLE", "title")
JIN10_FIELD_CONTENT = env_str("JIN10_FIELD_CONTENT", "content")
JIN10_FIELD_CATEGORY = env_str("JIN10_FIELD_CATEGORY", "category")
JIN10_FIELD_IMPORTANCE = env_str("JIN10_FIELD_IMPORTANCE", "importance")
JIN10_FIELD_CURRENCY = env_str("JIN10_FIELD_CURRENCY", "currency")
JIN10_FIELD_ACTUAL = env_str("JIN10_FIELD_ACTUAL", "actual")
JIN10_FIELD_FORECAST = env_str("JIN10_FIELD_FORECAST", "forecast")
JIN10_FIELD_PREVIOUS = env_str("JIN10_FIELD_PREVIOUS", "previous")


# =============================================================================
# Pydantic models
# =============================================================================

class Source(str, Enum):
    JIN10 = "JIN10"
    MT5_CALENDAR = "MT5_CALENDAR"
    MANUAL = "MANUAL"
    SYSTEM = "SYSTEM"


class Action(str, Enum):
    BUY = "BUY"
    SELL = "SELL"
    NO_TRADE = "NO_TRADE"


class Permission(str, Enum):
    AUTO_ALLOWED = "AUTO_ALLOWED"
    AUTO_BLOCKED = "AUTO_BLOCKED"
    NO_EXECUTION = "NO_EXECUTION"


class SignalState(str, Enum):
    DETECTED = "DETECTED"
    SCORED = "SCORED"
    MARKET_CONFIRMED = "MARKET_CONFIRMED"
    AUTO_ALLOWED = "AUTO_ALLOWED"
    MT5_PENDING = "MT5_PENDING"
    EXECUTED = "EXECUTED"
    EXPIRED = "EXPIRED"
    BLOCKED = "BLOCKED"
    ACKED = "ACKED"


class MacroEvent(BaseModel):
    event_id: str
    source: Source
    timestamp_utc: int
    title: str
    content: str = ""
    category: str = "UNKNOWN"
    importance: str = "UNKNOWN"
    currency: str = ""
    actual: Optional[str] = None
    forecast: Optional[str] = None
    previous: Optional[str] = None
    raw: Dict[str, Any] = Field(default_factory=dict)


class MT5CalendarBatch(BaseModel):
    symbol: str = DEFAULT_SYMBOL
    events: List[MacroEvent]


class MarketTick(BaseModel):
    symbol: str
    bid: Optional[float] = None
    ask: Optional[float] = None
    last: Optional[float] = None
    spread_points: Optional[float] = None
    point: Optional[float] = None
    digits: Optional[int] = None
    timestamp_utc: int


class MarketSnapshotBatch(BaseModel):
    source: str = "MT5"
    account_login: Optional[int] = None
    account_server: Optional[str] = None
    ticks: List[MarketTick]


class MacroDecision(BaseModel):
    mode: str
    action: Action
    score: float
    severity: float
    confidence: float
    horizon: str
    source_event_ids: List[str]
    transmission: List[str]
    risk_flags: List[str]
    reason: str


class MarketConfirmation(BaseModel):
    confirmed: bool
    score: float
    xau_confirmed: bool = False
    oil_confirmed: bool = False
    dxy_confirmed: bool = False
    yields_confirmed: bool = False
    risk_flags: List[str] = Field(default_factory=list)
    explanation: str = ""


class Signal(BaseModel):
    signal_id: str
    symbol: str
    action: Action
    permission: Permission
    state: SignalState
    lots: float
    sl_pips: int
    tp_pips: int
    macro_mode: str
    macro_score: float
    severity: float
    confidence: float
    market_confirmation_score: float
    valid_until_utc: int
    created_at_utc: int
    source_event_ids: List[str]
    reason: str
    risk_flags: List[str]


class AckPayload(BaseModel):
    signal_id: str
    symbol: str
    action: str
    requested_lots: float
    filled_lots: float = 0.0
    price: float = 0.0
    retcode: str = ""
    comment: str = ""
    time_utc: int = 0


# =============================================================================
# SQLite store
# =============================================================================

class Store:
    def __init__(self, path: Path):
        self.path = path
        self._init()

    def connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(str(self.path))
        conn.row_factory = sqlite3.Row
        return conn

    def _init(self) -> None:
        with self.connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS events (
                    event_id TEXT PRIMARY KEY,
                    source TEXT NOT NULL,
                    timestamp_utc INTEGER NOT NULL,
                    title TEXT NOT NULL,
                    content TEXT,
                    category TEXT,
                    importance TEXT,
                    currency TEXT,
                    actual TEXT,
                    forecast TEXT,
                    previous TEXT,
                    raw_json TEXT NOT NULL,
                    created_at_utc INTEGER NOT NULL
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS market_ticks (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    symbol TEXT NOT NULL,
                    bid REAL,
                    ask REAL,
                    last REAL,
                    spread_points REAL,
                    point REAL,
                    digits INTEGER,
                    timestamp_utc INTEGER NOT NULL,
                    created_at_utc INTEGER NOT NULL
                )
                """
            )
            conn.execute("CREATE INDEX IF NOT EXISTS idx_ticks_symbol_time ON market_ticks(symbol, timestamp_utc)")
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS signals (
                    signal_id TEXT PRIMARY KEY,
                    symbol TEXT NOT NULL,
                    action TEXT NOT NULL,
                    permission TEXT NOT NULL,
                    state TEXT NOT NULL,
                    lots REAL NOT NULL,
                    sl_pips INTEGER NOT NULL,
                    tp_pips INTEGER NOT NULL,
                    macro_mode TEXT,
                    macro_score REAL,
                    severity REAL,
                    confidence REAL,
                    market_confirmation_score REAL,
                    valid_until_utc INTEGER NOT NULL,
                    created_at_utc INTEGER NOT NULL,
                    source_event_ids_json TEXT NOT NULL,
                    reason TEXT,
                    risk_flags_json TEXT NOT NULL
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS acks (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    signal_id TEXT,
                    symbol TEXT,
                    action TEXT,
                    requested_lots REAL,
                    filled_lots REAL,
                    price REAL,
                    retcode TEXT,
                    comment TEXT,
                    time_utc INTEGER,
                    created_at_utc INTEGER NOT NULL,
                    raw_json TEXT NOT NULL
                )
                """
            )

    def upsert_event(self, event: MacroEvent) -> None:
        with self.connect() as conn:
            conn.execute(
                """
                INSERT OR REPLACE INTO events
                (event_id, source, timestamp_utc, title, content, category, importance, currency,
                 actual, forecast, previous, raw_json, created_at_utc)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    event.event_id,
                    event.source.value,
                    event.timestamp_utc,
                    event.title,
                    event.content,
                    event.category,
                    event.importance,
                    event.currency,
                    event.actual,
                    event.forecast,
                    event.previous,
                    json.dumps(event.raw, ensure_ascii=False),
                    now_utc(),
                ),
            )

    def recent_events(self, lookback_hours: int = 12) -> List[MacroEvent]:
        cutoff = now_utc() - lookback_hours * 3600
        with self.connect() as conn:
            rows = conn.execute(
                "SELECT * FROM events WHERE timestamp_utc >= ? ORDER BY timestamp_utc DESC LIMIT 200",
                (cutoff,),
            ).fetchall()
        return [row_to_event(r) for r in rows]

    def insert_tick(self, tick: MarketTick) -> None:
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO market_ticks
                (symbol, bid, ask, last, spread_points, point, digits, timestamp_utc, created_at_utc)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    tick.symbol,
                    tick.bid,
                    tick.ask,
                    tick.last,
                    tick.spread_points,
                    tick.point,
                    tick.digits,
                    tick.timestamp_utc,
                    now_utc(),
                ),
            )

    def latest_tick(self, symbol: str) -> Optional[MarketTick]:
        with self.connect() as conn:
            row = conn.execute(
                "SELECT * FROM market_ticks WHERE symbol=? ORDER BY timestamp_utc DESC LIMIT 1",
                (symbol,),
            ).fetchone()
        return row_to_tick(row) if row else None

    def tick_change(self, symbol: str, lookback_seconds: int) -> Optional[Tuple[float, float, float]]:
        """Return (current_mid, previous_mid, pct_change_or_abs_for_yields)."""
        latest = self.latest_tick(symbol)
        if not latest:
            return None
        cutoff = latest.timestamp_utc - lookback_seconds
        with self.connect() as conn:
            row = conn.execute(
                "SELECT * FROM market_ticks WHERE symbol=? AND timestamp_utc <= ? ORDER BY timestamp_utc DESC LIMIT 1",
                (symbol, cutoff),
            ).fetchone()
        if not row:
            return None
        old = row_to_tick(row)
        now_mid = tick_mid(latest)
        old_mid = tick_mid(old)
        if now_mid is None or old_mid is None or old_mid == 0:
            return None
        pct = (now_mid - old_mid) / abs(old_mid)
        abs_change = now_mid - old_mid
        # Return both in tuple's third element? Use pct by default; caller can use abs_change by subtract.
        return now_mid, old_mid, pct

    def tick_abs_change(self, symbol: str, lookback_seconds: int) -> Optional[float]:
        latest = self.latest_tick(symbol)
        if not latest:
            return None
        cutoff = latest.timestamp_utc - lookback_seconds
        with self.connect() as conn:
            row = conn.execute(
                "SELECT * FROM market_ticks WHERE symbol=? AND timestamp_utc <= ? ORDER BY timestamp_utc DESC LIMIT 1",
                (symbol, cutoff),
            ).fetchone()
        if not row:
            return None
        old = row_to_tick(row)
        now_mid = tick_mid(latest)
        old_mid = tick_mid(old)
        if now_mid is None or old_mid is None:
            return None
        return now_mid - old_mid

    def insert_signal(self, signal: Signal) -> None:
        with self.connect() as conn:
            conn.execute(
                """
                INSERT OR REPLACE INTO signals
                (signal_id, symbol, action, permission, state, lots, sl_pips, tp_pips,
                 macro_mode, macro_score, severity, confidence, market_confirmation_score,
                 valid_until_utc, created_at_utc, source_event_ids_json, reason, risk_flags_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    signal.signal_id,
                    signal.symbol,
                    signal.action.value,
                    signal.permission.value,
                    signal.state.value,
                    signal.lots,
                    signal.sl_pips,
                    signal.tp_pips,
                    signal.macro_mode,
                    signal.macro_score,
                    signal.severity,
                    signal.confidence,
                    signal.market_confirmation_score,
                    signal.valid_until_utc,
                    signal.created_at_utc,
                    json.dumps(signal.source_event_ids, ensure_ascii=False),
                    signal.reason,
                    json.dumps(signal.risk_flags, ensure_ascii=False),
                ),
            )

    def update_signal_state(self, signal_id: str, state: SignalState, permission: Optional[Permission] = None) -> None:
        with self.connect() as conn:
            if permission:
                conn.execute(
                    "UPDATE signals SET state=?, permission=? WHERE signal_id=?",
                    (state.value, permission.value, signal_id),
                )
            else:
                conn.execute("UPDATE signals SET state=? WHERE signal_id=?", (state.value, signal_id))

    def due_signal_for_mt5(self, symbol: str) -> Optional[Signal]:
        with self.connect() as conn:
            rows = conn.execute(
                """
                SELECT * FROM signals
                WHERE symbol=? AND action IN ('BUY','SELL') AND permission='AUTO_ALLOWED'
                  AND state='AUTO_ALLOWED' AND valid_until_utc >= ?
                ORDER BY created_at_utc ASC LIMIT 20
                """,
                (symbol, now_utc()),
            ).fetchall()
        if not rows:
            return None
        # Long priority at delivery as final guard.
        signals = [row_to_signal(r) for r in rows]
        longs = [s for s in signals if s.action == Action.BUY]
        if longs:
            longs.sort(key=lambda s: (s.severity, s.macro_score, s.confidence), reverse=True)
            return longs[0]
        signals.sort(key=lambda s: (abs(s.macro_score), s.confidence), reverse=True)
        return signals[0]

    def recent_signal_exists(self, event_ids: Iterable[str], action: Action, cooldown_seconds: int) -> bool:
        if not event_ids:
            return False
        cutoff = now_utc() - cooldown_seconds
        id_set = set(event_ids)
        with self.connect() as conn:
            rows = conn.execute(
                "SELECT * FROM signals WHERE action=? AND created_at_utc >= ? ORDER BY created_at_utc DESC LIMIT 100",
                (action.value, cutoff),
            ).fetchall()
        for r in rows:
            try:
                ids = set(json.loads(r["source_event_ids_json"]))
            except Exception:
                ids = set()
            if ids & id_set:
                return True
        return False

    def daily_action_count(self) -> int:
        day_start = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
        start = int(day_start.timestamp())
        with self.connect() as conn:
            row = conn.execute(
                "SELECT COUNT(*) AS n FROM signals WHERE created_at_utc >= ? AND action IN ('BUY','SELL')",
                (start,),
            ).fetchone()
        return int(row["n"] if row else 0)

    def insert_ack(self, ack: AckPayload) -> None:
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO acks
                (signal_id, symbol, action, requested_lots, filled_lots, price, retcode, comment, time_utc, created_at_utc, raw_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    ack.signal_id,
                    ack.symbol,
                    ack.action,
                    ack.requested_lots,
                    ack.filled_lots,
                    ack.price,
                    ack.retcode,
                    ack.comment,
                    ack.time_utc,
                    now_utc(),
                    json.dumps(ack.model_dump(), ensure_ascii=False),
                ),
            )


STORE = Store(DB_PATH)


def row_to_event(row: sqlite3.Row) -> MacroEvent:
    return MacroEvent(
        event_id=row["event_id"],
        source=Source(row["source"]),
        timestamp_utc=int(row["timestamp_utc"]),
        title=row["title"],
        content=row["content"] or "",
        category=row["category"] or "UNKNOWN",
        importance=row["importance"] or "UNKNOWN",
        currency=row["currency"] or "",
        actual=row["actual"],
        forecast=row["forecast"],
        previous=row["previous"],
        raw=json.loads(row["raw_json"] or "{}"),
    )


def row_to_tick(row: sqlite3.Row) -> MarketTick:
    return MarketTick(
        symbol=row["symbol"],
        bid=row["bid"],
        ask=row["ask"],
        last=row["last"],
        spread_points=row["spread_points"],
        point=row["point"],
        digits=row["digits"],
        timestamp_utc=int(row["timestamp_utc"]),
    )


def row_to_signal(row: sqlite3.Row) -> Signal:
    return Signal(
        signal_id=row["signal_id"],
        symbol=row["symbol"],
        action=Action(row["action"]),
        permission=Permission(row["permission"]),
        state=SignalState(row["state"]),
        lots=float(row["lots"]),
        sl_pips=int(row["sl_pips"]),
        tp_pips=int(row["tp_pips"]),
        macro_mode=row["macro_mode"] or "UNKNOWN",
        macro_score=float(row["macro_score"] or 0.0),
        severity=float(row["severity"] or 0.0),
        confidence=float(row["confidence"] or 0.0),
        market_confirmation_score=float(row["market_confirmation_score"] or 0.0),
        valid_until_utc=int(row["valid_until_utc"]),
        created_at_utc=int(row["created_at_utc"]),
        source_event_ids=json.loads(row["source_event_ids_json"] or "[]"),
        reason=row["reason"] or "",
        risk_flags=json.loads(row["risk_flags_json"] or "[]"),
    )


def tick_mid(t: MarketTick) -> Optional[float]:
    if t.bid is not None and t.ask is not None and t.bid > 0 and t.ask > 0:
        return (t.bid + t.ask) / 2.0
    if t.last is not None and t.last > 0:
        return t.last
    if t.bid is not None and t.bid > 0:
        return t.bid
    if t.ask is not None and t.ask > 0:
        return t.ask
    return None


# =============================================================================
# Auth + common utilities
# =============================================================================


def require_key(x_api_key: Optional[str]) -> None:
    if x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="invalid api key")


def now_utc() -> int:
    return int(time.time())


def normalize_text(text: str) -> str:
    return re.sub(r"\s+", " ", (text or "").strip())


def parse_timestamp(value: Any) -> int:
    if value is None:
        return now_utc()
    if isinstance(value, (int, float)):
        v = int(value)
        return int(v / 1000) if v > 10_000_000_000 else v
    if isinstance(value, str):
        txt = value.strip().replace("Z", "+00:00")
        try:
            return int(datetime.fromisoformat(txt).timestamp())
        except ValueError:
            return now_utc()
    return now_utc()


def event_hash(source: str, title: str, content: str, timestamp_utc: int) -> str:
    base = f"{source}|{normalize_text(title).lower()}|{normalize_text(content).lower()}|{timestamp_utc // 300}"
    return hashlib.sha256(base.encode("utf-8")).hexdigest()[:16]


def is_in_daily_window(ts: Optional[int] = None) -> bool:
    dt = datetime.fromtimestamp(ts or now_utc(), tz=timezone.utc)
    tolerance = timedelta(minutes=WINDOW_TOLERANCE_MINUTES)
    for hhmm in DAILY_WINDOWS_UTC:
        try:
            hour, minute = [int(x) for x in hhmm.split(":")]
        except Exception:
            continue
        target = dt.replace(hour=hour, minute=minute, second=0, microsecond=0)
        if abs(dt - target) <= tolerance:
            return True
    return False


def max_lots_by_stage() -> float:
    if not ENABLE_AUTO_EXECUTION:
        return 0.0
    if LIVE_STAGE == "shadow":
        return 0.0
    if LIVE_STAGE == "demo":
        return MAX_DEMO_LOTS
    if LIVE_STAGE == "micro":
        return MAX_MICRO_LIVE_LOTS
    if LIVE_STAGE == "live":
        return MAX_LIVE_LOTS
    return 0.0


# =============================================================================
# Jin10 adapter
# =============================================================================

class Jin10Client:
    def headers(self) -> Dict[str, str]:
        h = {"User-Agent": "gold-macro-auto-ea/0.1"}
        if JIN10_AUTH_HEADER_VALUE:
            h[JIN10_AUTH_HEADER_NAME] = JIN10_AUTH_HEADER_VALUE
        return h

    def pull(self) -> List[MacroEvent]:
        if not JIN10_ENABLED:
            return []
        raw: List[Dict[str, Any]] = []
        for url in [JIN10_NEWS_URL, JIN10_CALENDAR_URL]:
            raw.extend(self._fetch(url))
        events: List[MacroEvent] = []
        for item in raw:
            event = self._map_item(item)
            if event:
                events.append(event)
        return events

    def _fetch(self, url: str) -> List[Dict[str, Any]]:
        if not url:
            return []
        r = requests.get(url, headers=self.headers(), timeout=JIN10_TIMEOUT_SECONDS)
        r.raise_for_status()
        data = r.json()
        obj: Any = data
        if JIN10_LIST_PATH:
            for part in JIN10_LIST_PATH.split("."):
                if isinstance(obj, dict):
                    obj = obj.get(part, [])
                else:
                    obj = []
                    break
        if isinstance(obj, list):
            return [x for x in obj if isinstance(x, dict)]
        if isinstance(obj, dict):
            for k in ("data", "items", "list", "news", "events"):
                if isinstance(obj.get(k), list):
                    return [x for x in obj[k] if isinstance(x, dict)]
            return [obj]
        return []

    def _map_item(self, item: Dict[str, Any]) -> Optional[MacroEvent]:
        title = str(item.get(JIN10_FIELD_TITLE) or item.get("name") or item.get("event") or "")
        content = str(item.get(JIN10_FIELD_CONTENT) or item.get("summary") or item.get("desc") or "")
        if not title and not content:
            return None
        ts = parse_timestamp(item.get(JIN10_FIELD_TIMESTAMP) or item.get("time") or item.get("pub_time"))
        eid = str(item.get(JIN10_FIELD_ID) or f"JIN10_{event_hash('JIN10', title, content, ts)}")
        return MacroEvent(
            event_id=eid,
            source=Source.JIN10,
            timestamp_utc=ts,
            title=title,
            content=content,
            category=str(item.get(JIN10_FIELD_CATEGORY) or item.get("type") or "UNKNOWN"),
            importance=str(item.get(JIN10_FIELD_IMPORTANCE) or item.get("star") or "UNKNOWN"),
            currency=str(item.get(JIN10_FIELD_CURRENCY) or item.get("asset") or ""),
            actual=to_optional_str(item.get(JIN10_FIELD_ACTUAL)),
            forecast=to_optional_str(item.get(JIN10_FIELD_FORECAST)),
            previous=to_optional_str(item.get(JIN10_FIELD_PREVIOUS)),
            raw=item,
        )


def to_optional_str(x: Any) -> Optional[str]:
    if x is None:
        return None
    return str(x)


# =============================================================================
# Macro engine: event classifier/scorer + market confirmation + sizing
# =============================================================================

@dataclass
class Candidate:
    mode: str
    action: Action
    score: float
    severity: float
    confidence: float
    source_event_ids: List[str]
    transmission: List[str]
    risk_flags: List[str]
    reason: str


class MacroEngine:
    """Auditable rule-based macro engine, intentionally LLM-replaceable."""

    geo_long_patterns = [
        ("trump", 8, "Trump headline"),
        ("特朗普", 8, "Trump headline"),
        ("iran", 14, "Iran risk"),
        ("伊朗", 14, "Iran risk"),
        ("airstrike", 24, "airstrike"),
        ("空袭", 24, "airstrike"),
        ("bomb", 22, "bombing"),
        ("轰炸", 22, "bombing"),
        ("missile", 18, "missile strike"),
        ("导弹", 18, "missile strike"),
        ("war", 24, "war escalation"),
        ("战争", 24, "war escalation"),
        ("military action", 18, "military action"),
        ("军事行动", 18, "military action"),
        ("middle east", 12, "Middle East"),
        ("中东", 12, "Middle East"),
        ("hormuz", 18, "Hormuz risk"),
        ("霍尔木兹", 18, "Hormuz risk"),
        ("sanction", 14, "sanction risk"),
        ("制裁", 14, "sanction risk"),
        ("geopolitical escalation", 18, "geopolitical escalation"),
        ("地缘升级", 18, "geopolitical escalation"),
    ]

    geo_fade_patterns = [
        ("ceasefire", -24, "ceasefire"),
        ("停火", -24, "ceasefire"),
        ("denies", -40, "official denial"),
        ("否认", -40, "official denial"),
        ("no further escalation", -22, "no further escalation"),
        ("不扩大冲突", -22, "no further escalation"),
        ("no ground troops", -8, "no ground troops"),
        ("没有地面部队", -8, "no ground troops"),
        ("limited strike", -5, "limited strike"),
        ("有限打击", -5, "limited strike"),
    ]

    rates_short_patterns = [
        ("ust 2y", -10, "UST 2Y"),
        ("ust 10y", -10, "UST 10Y"),
        ("2-year yield", -18, "2Y yield spike"),
        ("10-year yield", -18, "10Y yield spike"),
        ("美债收益率飙升", -28, "UST yield surge"),
        ("长端美债收益率", -14, "long-end yields"),
        ("短端美债收益率", -14, "front-end yields"),
        ("real yield", -22, "real yield"),
        ("实际利率上行", -24, "real yield up"),
        ("dxy", -12, "DXY"),
        ("美元指数飙升", -26, "DXY surge"),
        ("美元走强", -22, "strong USD"),
        ("higher for longer", -24, "higher-for-longer"),
        ("鹰派", -22, "hawkish repricing"),
        ("hawkish", -22, "hawkish repricing"),
        ("通胀超预期", -24, "hot inflation"),
        ("hot inflation", -24, "hot inflation"),
        ("非农强劲", -20, "strong NFP"),
        ("strong payrolls", -20, "strong payrolls"),
    ]

    long_macro_patterns = [
        ("降息", 16, "rate cut"),
        ("dovish", 16, "dovish Fed"),
        ("鸽派", 16, "dovish Fed"),
        ("央行购金", 22, "central bank gold demand"),
        ("central bank gold", 22, "central bank gold demand"),
        ("去美元化", 18, "reserve diversification"),
        ("de-dollar", 18, "reserve diversification"),
        ("财政赤字", 12, "fiscal credibility risk"),
        ("debt ceiling", 12, "sovereign risk"),
        ("债务上限", 12, "sovereign risk"),
    ]

    def build_candidates(self, events: List[MacroEvent]) -> List[Candidate]:
        if not events:
            return []
        recent = sorted(events, key=lambda e: e.timestamp_utc, reverse=True)[:50]
        text = " ".join([f"{e.title} {e.content} {e.category} {e.currency}" for e in recent])
        text_low = text.lower()
        ids = [e.event_id for e in recent[:20]]
        candidates: List[Candidate] = []

        geo_score, geo_drivers = self._score_patterns(text_low, self.geo_long_patterns)
        fade_score, fade_drivers = self._score_patterns(text_low, self.geo_fade_patterns)
        extra_long, extra_long_drivers = self._score_patterns(text_low, self.long_macro_patterns)
        rates_score, rates_drivers = self._score_patterns(text_low, self.rates_short_patterns)

        official_bonus = self._official_bonus(recent)
        importance_bonus = self._importance_bonus(recent)

        geo_total = geo_score + fade_score + extra_long + official_bonus + importance_bonus
        if geo_total >= 45:
            severity = min(max(geo_total, 0), 100)
            confidence = min(0.40 + len(geo_drivers) * 0.06 + official_bonus / 100, 0.88)
            risk_flags = []
            if fade_score < 0:
                risk_flags.append("geopolitical_fade_risk")
            if official_bonus == 0:
                risk_flags.append("no_official_confirmation")
            candidates.append(
                Candidate(
                    mode="GEO_WAR_LONG_MODE",
                    action=Action.BUY,
                    score=min(geo_total, 100),
                    severity=severity,
                    confidence=confidence,
                    source_event_ids=ids,
                    transmission=list(dict.fromkeys(geo_drivers + extra_long_drivers)),
                    risk_flags=risk_flags,
                    reason="Geopolitical/war-risk macro long candidate for gold.",
                )
            )

        if rates_score <= -45:
            severity = min(abs(rates_score), 100)
            confidence = min(0.40 + len(rates_drivers) * 0.07, 0.86)
            candidates.append(
                Candidate(
                    mode="RATES_SPIKE_SHORT_MODE",
                    action=Action.SELL,
                    score=max(rates_score, -100),
                    severity=severity,
                    confidence=confidence,
                    source_event_ids=ids,
                    transmission=list(dict.fromkeys(rates_drivers)),
                    risk_flags=[],
                    reason="Rates/USD spike macro short candidate for gold.",
                )
            )

        # Numeric macro surprises: CPI/NFP actual vs forecast.
        surprise_candidate = self._numeric_surprise_candidate(recent)
        if surprise_candidate:
            candidates.append(surprise_candidate)

        return candidates

    def _numeric_surprise_candidate(self, events: List[MacroEvent]) -> Optional[Candidate]:
        score = 0.0
        drivers: List[str] = []
        ids: List[str] = []
        for e in events[:20]:
            delta = actual_minus_forecast(e)
            if delta is None:
                continue
            title = f"{e.title} {e.category}".lower()
            if any(k in title for k in ["cpi", "pce", "通胀"]):
                ids.append(e.event_id)
                if delta > 0:
                    score -= 28
                    drivers.append("hot inflation surprise")
                elif delta < 0:
                    score += 22
                    drivers.append("cooler inflation surprise")
            if any(k in title for k in ["nfp", "payroll", "非农", "就业"]):
                ids.append(e.event_id)
                if delta > 0:
                    score -= 22
                    drivers.append("strong labor surprise")
                elif delta < 0:
                    score += 18
                    drivers.append("weak labor surprise")
        if score <= -45:
            return Candidate(
                mode="RATES_SPIKE_SHORT_MODE",
                action=Action.SELL,
                score=max(score, -100),
                severity=min(abs(score), 100),
                confidence=0.65,
                source_event_ids=ids,
                transmission=drivers,
                risk_flags=[],
                reason="Hot macro data implies hawkish repricing / higher yields.",
            )
        if score >= 60:
            return Candidate(
                mode="DOVISH_MACRO_LONG_MODE",
                action=Action.BUY,
                score=min(score, 100),
                severity=min(abs(score), 100),
                confidence=0.62,
                source_event_ids=ids,
                transmission=drivers,
                risk_flags=[],
                reason="Cooler macro data implies lower real-rate pressure for gold.",
            )
        return None

    @staticmethod
    def _score_patterns(text_low: str, patterns: List[Tuple[str, float, str]]) -> Tuple[float, List[str]]:
        score = 0.0
        drivers: List[str] = []
        for pat, weight, reason in patterns:
            if pat.lower() in text_low:
                score += weight
                drivers.append(reason)
        return score, drivers

    @staticmethod
    def _official_bonus(events: List[MacroEvent]) -> float:
        text = " ".join([f"{e.source.value} {e.title} {e.content}" for e in events[:20]]).lower()
        official_terms = ["white house", "pentagon", "treasury", "federal reserve", "fed", "白宫", "五角大楼", "财政部", "美联储", "official", "官方"]
        return 12.0 if any(t in text for t in official_terms) else 0.0

    @staticmethod
    def _importance_bonus(events: List[MacroEvent]) -> float:
        high_terms = {"high", "3", "重要", "高"}
        return 8.0 if any(str(e.importance).lower() in high_terms for e in events[:20]) else 0.0


class MarketConfirmer:
    def confirm(self, candidate: Candidate) -> MarketConfirmation:
        flags: List[str] = []
        score = 0.0
        xau_confirmed = False
        oil_confirmed = False
        dxy_confirmed = False
        yields_confirmed = False

        # Symbol names can be configured at EA side. Backend uses canonical labels if uploaded.
        xau_chg = STORE.tick_change(DEFAULT_SYMBOL, MARKET_LOOKBACK_SECONDS)
        oil_chg = first_available_pct(["WTI", "USOIL", "OIL", "BRENT", "UKOIL"], MARKET_LOOKBACK_SECONDS)
        dxy_chg = first_available_pct(["DXY", "USDX", "USDOLLAR"], MARKET_LOOKBACK_SECONDS)
        y2_abs = first_available_abs(["US02Y", "UST2Y", "US2Y"], MARKET_LOOKBACK_SECONDS)
        y10_abs = first_available_abs(["US10Y", "UST10Y", "US10YR"], MARKET_LOOKBACK_SECONDS)

        if candidate.action == Action.BUY:
            if xau_chg and xau_chg[2] >= XAU_MOVE_CONFIRM_PCT:
                xau_confirmed = True
                score += 35
            if oil_chg is not None and oil_chg >= OIL_MOVE_CONFIRM_PCT:
                oil_confirmed = True
                score += 20
            if dxy_chg is not None and dxy_chg <= -DXY_MOVE_CONFIRM_PCT:
                dxy_confirmed = True
                score += 15
            elif dxy_chg is not None and dxy_chg > DXY_MOVE_CONFIRM_PCT:
                flags.append("dxy_conflicts_with_gold_long")
                score -= 10

            # Severe geopolitical event can allow scout long even if market data incomplete.
            confirmed = xau_confirmed or (candidate.mode == "GEO_WAR_LONG_MODE" and candidate.severity >= SEVERE_GEO_THRESHOLD)

        elif candidate.action == Action.SELL:
            if xau_chg and xau_chg[2] <= -XAU_MOVE_CONFIRM_PCT:
                xau_confirmed = True
                score += 30
            if dxy_chg is not None and dxy_chg >= DXY_MOVE_CONFIRM_PCT:
                dxy_confirmed = True
                score += 30
            if y2_abs is not None and y2_abs >= YIELD_MOVE_CONFIRM:
                yields_confirmed = True
                score += 20
            if y10_abs is not None and y10_abs >= YIELD_MOVE_CONFIRM:
                yields_confirmed = True
                score += 20
            confirmed = xau_confirmed or dxy_confirmed or yields_confirmed
        else:
            confirmed = False

        if not xau_chg:
            flags.append("xau_market_history_missing")
        return MarketConfirmation(
            confirmed=confirmed,
            score=max(min(score, 100), -100),
            xau_confirmed=xau_confirmed,
            oil_confirmed=oil_confirmed,
            dxy_confirmed=dxy_confirmed,
            yields_confirmed=yields_confirmed,
            risk_flags=flags,
            explanation=f"Market confirmation score={score:.1f}",
        )


class SizingEngine:
    def size(self, candidate: Candidate, confirmation: MarketConfirmation) -> float:
        max_lots = max_lots_by_stage()
        if max_lots <= 0:
            return 0.0

        if candidate.action == Action.BUY:
            if candidate.mode == "GEO_WAR_LONG_MODE":
                if confirmation.score >= 60:
                    lots = GEO_STRONG_LOTS
                elif confirmation.confirmed:
                    lots = GEO_CONFIRMED_LOTS
                else:
                    lots = GEO_SCOUT_LOTS
                lots = min(lots, GEO_MAX_LOTS)
            else:
                lots = GEO_CONFIRMED_LOTS if confirmation.confirmed else GEO_SCOUT_LOTS
        elif candidate.action == Action.SELL:
            if confirmation.score >= 60:
                lots = RATES_STRONG_LOTS
            elif confirmation.confirmed:
                lots = RATES_CONFIRMED_LOTS
            else:
                lots = RATES_SCOUT_LOTS
        else:
            lots = 0.0

        return round(min(lots, max_lots), 2)


class AutoExecutionGate:
    def allow(self, candidate: Candidate, confirmation: MarketConfirmation, lots: float) -> Tuple[bool, List[str]]:
        flags: List[str] = []
        if not ENABLE_AUTO_EXECUTION:
            flags.append("auto_execution_disabled")
        if LIVE_STAGE not in {"demo", "micro", "live"}:
            flags.append(f"stage_not_tradable:{LIVE_STAGE}")
        if lots <= 0:
            flags.append("lot_size_zero_after_stage_cap")
        if candidate.confidence < MIN_CONFIDENCE:
            flags.append("confidence_below_threshold")
        if candidate.action == Action.BUY and candidate.score < LONG_THRESHOLD:
            flags.append("long_score_below_threshold")
        if candidate.action == Action.SELL and candidate.score > SHORT_THRESHOLD:
            flags.append("short_score_below_threshold")
        if STORE.daily_action_count() >= MAX_AUTO_SIGNALS_PER_DAY:
            flags.append("max_daily_auto_signals_reached")

        in_window = is_in_daily_window()
        severe_override = ALLOW_SEVERE_EVENT_OVERRIDE and candidate.mode == "GEO_WAR_LONG_MODE" and candidate.severity >= SEVERE_GEO_THRESHOLD
        if not in_window and not severe_override:
            flags.append("outside_daily_windows")

        if candidate.action == Action.SELL and not confirmation.confirmed:
            # Shorts on yield/USD spikes need confirmation; otherwise too easy to overfit headline language.
            flags.append("short_requires_market_confirmation")

        if STORE.recent_signal_exists(candidate.source_event_ids, candidate.action, SIGNAL_COOLDOWN_SECONDS):
            flags.append("duplicate_recent_signal_for_same_event")

        # Official denial or ceasefire should block longs/shorts from the same news cluster.
        bad_flags = {"geopolitical_fade_risk"}
        if candidate.mode == "GEO_WAR_LONG_MODE" and bad_flags & set(candidate.risk_flags) and candidate.severity < 75:
            flags.append("geo_fade_risk_blocks_nonsevere_long")

        return len(flags) == 0, flags


# =============================================================================
# Helper functions for market changes and surprises
# =============================================================================


def first_available_pct(symbols: List[str], lookback: int) -> Optional[float]:
    for s in symbols:
        chg = STORE.tick_change(s, lookback)
        if chg:
            return chg[2]
    return None


def first_available_abs(symbols: List[str], lookback: int) -> Optional[float]:
    for s in symbols:
        chg = STORE.tick_abs_change(s, lookback)
        if chg is not None:
            return chg
    return None


def actual_minus_forecast(event: MacroEvent) -> Optional[float]:
    if event.actual is None or event.forecast is None:
        return None
    try:
        actual = float(re.sub(r"[,%]", "", str(event.actual)))
        forecast = float(re.sub(r"[,%]", "", str(event.forecast)))
        return actual - forecast
    except ValueError:
        return None


# =============================================================================
# Signal generation
# =============================================================================


def no_trade_signal(symbol: str, reason: str, flags: Optional[List[str]] = None) -> Signal:
    t = now_utc()
    return Signal(
        signal_id=f"NO_TRADE_{symbol}_{t}",
        symbol=symbol,
        action=Action.NO_TRADE,
        permission=Permission.NO_EXECUTION,
        state=SignalState.BLOCKED,
        lots=0.0,
        sl_pips=SL_PIPS,
        tp_pips=TP_PIPS,
        macro_mode="NONE",
        macro_score=0.0,
        severity=0.0,
        confidence=0.0,
        market_confirmation_score=0.0,
        valid_until_utc=t + 30,
        created_at_utc=t,
        source_event_ids=[],
        reason=reason,
        risk_flags=flags or [],
    )


def generate_signal(lookback_hours: int = 12) -> Signal:
    events = STORE.recent_events(lookback_hours=lookback_hours)
    candidates = MacroEngine().build_candidates(events)
    if not candidates:
        sig = no_trade_signal(DEFAULT_SYMBOL, "No macro candidate.", ["no_macro_candidate"])
        STORE.insert_signal(sig)
        return sig

    # Long priority: if any long candidate exists, suppress all shorts.
    longs = [c for c in candidates if c.action == Action.BUY]
    active_candidates = longs if longs else [c for c in candidates if c.action == Action.SELL]

    confirmer = MarketConfirmer()
    sizer = SizingEngine()
    gate = AutoExecutionGate()
    generated: List[Signal] = []

    for c in active_candidates:
        confirmation = confirmer.confirm(c)
        lots = sizer.size(c, confirmation)
        allowed, gate_flags = gate.allow(c, confirmation, lots)
        all_flags = list(dict.fromkeys(c.risk_flags + confirmation.risk_flags + gate_flags))
        t = now_utc()
        signal_id = f"{c.mode}_{DEFAULT_SYMBOL}_{t}_{uuid.uuid4().hex[:8]}"
        sig = Signal(
            signal_id=signal_id,
            symbol=DEFAULT_SYMBOL,
            action=c.action if allowed else Action.NO_TRADE,
            permission=Permission.AUTO_ALLOWED if allowed else Permission.AUTO_BLOCKED,
            state=SignalState.AUTO_ALLOWED if allowed else SignalState.BLOCKED,
            lots=lots if allowed else 0.0,
            sl_pips=SL_PIPS,
            tp_pips=TP_PIPS,
            macro_mode=c.mode,
            macro_score=c.score,
            severity=c.severity,
            confidence=c.confidence,
            market_confirmation_score=confirmation.score,
            valid_until_utc=t + SIGNAL_TTL_SECONDS,
            created_at_utc=t,
            source_event_ids=c.source_event_ids,
            reason=f"{c.reason} {confirmation.explanation}",
            risk_flags=all_flags,
        )
        STORE.insert_signal(sig)
        generated.append(sig)

    # Choose best generated signal by long priority, score, confidence.
    tradable = [s for s in generated if s.action in (Action.BUY, Action.SELL) and s.permission == Permission.AUTO_ALLOWED]
    if tradable:
        longs2 = [s for s in tradable if s.action == Action.BUY]
        pool = longs2 if longs2 else tradable
        pool.sort(key=lambda s: (s.severity, abs(s.macro_score), s.confidence), reverse=True)
        return pool[0]
    generated.sort(key=lambda s: (s.severity, abs(s.macro_score), s.confidence), reverse=True)
    return generated[0]


# =============================================================================
# API routes
# =============================================================================

app = FastAPI(title="Gold Macro Auto EA Backend v18", version="0.18.0")


@app.get("/health")
def health():
    return {
        "status": "ok",
        "db": str(DB_PATH),
        "symbol": DEFAULT_SYMBOL,
        "enable_auto_execution": ENABLE_AUTO_EXECUTION,
        "live_stage": LIVE_STAGE,
        "max_lots_by_stage": max_lots_by_stage(),
        "daily_windows_utc": DAILY_WINDOWS_UTC,
        "jin10_enabled": JIN10_ENABLED,
    }


@app.post("/api/v1/jin10/pull")
def pull_jin10(x_api_key: Optional[str] = Header(None)):
    require_key(x_api_key)
    events = Jin10Client().pull()
    for e in events:
        STORE.upsert_event(e)
    return {"ok": True, "pulled": len(events), "stored_total_recent": len(STORE.recent_events(168))}


@app.post("/api/v1/events/manual")
def ingest_manual(event: MacroEvent, x_api_key: Optional[str] = Header(None)):
    require_key(x_api_key)
    STORE.upsert_event(event)
    return {"ok": True, "event_id": event.event_id}


@app.post("/api/v1/mt5/calendar")
def ingest_mt5_calendar(batch: MT5CalendarBatch, x_api_key: Optional[str] = Header(None)):
    require_key(x_api_key)
    n = 0
    for e in batch.events:
        STORE.upsert_event(e)
        n += 1
    return {"ok": True, "stored": n}


@app.post("/api/v1/mt5/market")
def ingest_market(batch: MarketSnapshotBatch, x_api_key: Optional[str] = Header(None)):
    require_key(x_api_key)
    for t in batch.ticks:
        STORE.insert_tick(t)
    return {"ok": True, "stored": len(batch.ticks)}


@app.post("/api/v1/macro/evaluate", response_model=Signal)
def evaluate_macro(lookback_hours: int = Query(default=12, ge=1, le=168), x_api_key: Optional[str] = Header(None)):
    require_key(x_api_key)
    return generate_signal(lookback_hours=lookback_hours)


@app.get("/api/v1/mt5/next", response_model=Signal)
def mt5_next(symbol: str = DEFAULT_SYMBOL, evaluate_if_due: bool = True, x_api_key: Optional[str] = Header(None)):
    require_key(x_api_key)
    # Opportunistically evaluate on EA polling; this avoids a separate scheduler in the MVP.
    if evaluate_if_due:
        # Evaluate only if window or severe recent event can override; generate_signal itself enforces gates.
        if is_in_daily_window() or ALLOW_SEVERE_EVENT_OVERRIDE:
            try:
                generate_signal(lookback_hours=12)
            except Exception as exc:
                # Never crash EA poll because of backend evaluation error.
                return no_trade_signal(symbol, f"evaluation_error: {exc}", ["evaluation_error"])

    sig = STORE.due_signal_for_mt5(symbol)
    if not sig:
        return no_trade_signal(symbol, "No auto-allowed signal.", ["no_auto_allowed_signal"])
    STORE.update_signal_state(sig.signal_id, SignalState.MT5_PENDING)
    sig.state = SignalState.MT5_PENDING
    return sig


@app.post("/api/v1/mt5/ack")
def ack(payload: AckPayload, x_api_key: Optional[str] = Header(None)):
    require_key(x_api_key)
    STORE.insert_ack(payload)
    if payload.retcode in {"10009", "10008", "TRADE_RETCODE_DONE", "TRADE_RETCODE_PLACED"}:
        STORE.update_signal_state(payload.signal_id, SignalState.ACKED, Permission.NO_EXECUTION)
    else:
        STORE.update_signal_state(payload.signal_id, SignalState.BLOCKED, Permission.NO_EXECUTION)
    return {"ok": True}


@app.get("/api/v1/signals")
def list_signals(limit: int = Query(default=20, ge=1, le=200), x_api_key: Optional[str] = Header(None)):
    require_key(x_api_key)
    with STORE.connect() as conn:
        rows = conn.execute("SELECT * FROM signals ORDER BY created_at_utc DESC LIMIT ?", (limit,)).fetchall()
    return {"signals": [row_to_signal(r).model_dump() for r in rows]}


@app.get("/api/v1/events")
def list_events(limit: int = Query(default=20, ge=1, le=200), x_api_key: Optional[str] = Header(None)):
    require_key(x_api_key)
    with STORE.connect() as conn:
        rows = conn.execute("SELECT * FROM events ORDER BY timestamp_utc DESC LIMIT ?", (limit,)).fetchall()
    return {"events": [row_to_event(r).model_dump() for r in rows]}
