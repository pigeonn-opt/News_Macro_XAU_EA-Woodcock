"""Offline XAUUSD macro-news CSV reader.

This file deliberately has no HTTP server, API client, database, or MT5
endpoint. The former FastAPI/Jin10/MT5 interface is disabled. Instead, this
program exports a local CSV signal file that the EA reads from ``MQL5/Files``.

# Previous external interfaces intentionally disabled:
# from fastapi import FastAPI
# import requests
# @app.post("/api/v1/...")
"""
from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CSV_PATH = PROJECT_ROOT / "data" / "XAUUSD_Macro_News_Clean.csv"
DEFAULT_MT5_FILES_DIR = PROJECT_ROOT.parent.parent.parent / "Files"
DEFAULT_SIGNAL_PATH = DEFAULT_MT5_FILES_DIR / "GoldMacroSignal.csv"


@dataclass(frozen=True)
class DailyMacroRecord:
    """The selected daily features used by the initial offline rule set."""

    date: str
    gold_close: float
    dxy: Optional[float]
    us10y: Optional[float]
    real_yield_10y: Optional[float]
    vix: Optional[float]
    geo_risk_score: float
    fed_hawkish_score: float
    news_count: float
    long_candidate: bool
    short_candidate: bool
    gold_return_1d: Optional[float]
    dxy_change: Optional[float]
    us10y_change: Optional[float]
    news_bias: Optional[float]


@dataclass(frozen=True)
class OfflineSignal:
    date: str
    action: str
    score: float
    reason: str


def export_signals(records: list[DailyMacroRecord], output_path: Path) -> int:
    """Write one local signal per CSV date for the MT5 EA.

    This is the offline replacement for the former HTTP ``/mt5/next`` route.
    No request is sent and no order is placed.  The output contains every day
    so a Strategy Tester can select the row matching its simulated date.
    """
    if not records:
        raise ValueError("Cannot export signals from an empty CSV")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(("date", "action", "score", "gold_close", "geo_risk", "fed_hawkish", "news_count", "reason"))
        for record in records:
            signal = evaluate_record(record)
            writer.writerow((
                signal.date,
                signal.action,
                f"{signal.score:.2f}",
                f"{record.gold_close:.2f}",
                f"{record.geo_risk_score:.2f}",
                f"{record.fed_hawkish_score:.2f}",
                f"{record.news_count:.0f}",
                signal.reason,
            ))
    return len(records)


def optional_float(value: Optional[str]) -> Optional[float]:
    """Convert a CSV cell to float; blank cells remain missing rather than 0."""
    if value is None or not value.strip():
        return None
    return float(value)


def required_float(row: dict[str, str], name: str) -> float:
    value = optional_float(row.get(name))
    if value is None:
        raise ValueError(f"{name} is empty for {row.get('date', '<unknown>')}")
    return value


def read_records(csv_path: Path) -> list[DailyMacroRecord]:
    """Read the supplied daily dataset. No remote data is fetched."""
    if not csv_path.is_file():
        raise FileNotFoundError(f"CSV not found: {csv_path}")

    records: list[DailyMacroRecord] = []
    with csv_path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        required_columns = {"date", "gold_close", "GeoRisk_Score", "Fed_Hawkish_Score",
                            "News_Count", "LONG_GOLD_Candidate", "SHORT_GOLD_Candidate"}
        missing = required_columns - set(reader.fieldnames or [])
        if missing:
            raise ValueError(f"CSV is missing required columns: {', '.join(sorted(missing))}")
        for row in reader:
            records.append(DailyMacroRecord(
                date=(row.get("date") or "").strip(),
                gold_close=required_float(row, "gold_close"),
                dxy=optional_float(row.get("DXY")),
                us10y=optional_float(row.get("US10Y")),
                real_yield_10y=optional_float(row.get("RealYield10Y")),
                vix=optional_float(row.get("VIX")),
                geo_risk_score=required_float(row, "GeoRisk_Score"),
                fed_hawkish_score=required_float(row, "Fed_Hawkish_Score"),
                news_count=required_float(row, "News_Count"),
                long_candidate=required_float(row, "LONG_GOLD_Candidate") >= 1,
                short_candidate=required_float(row, "SHORT_GOLD_Candidate") >= 1,
                gold_return_1d=optional_float(row.get("gold_return_1d")),
                dxy_change=optional_float(row.get("DXY_change")),
                us10y_change=optional_float(row.get("US10Y_change")),
                news_bias=optional_float(row.get("News_Bias")),
            ))
    return sorted(records, key=lambda item: item.date)


def evaluate_record(record: DailyMacroRecord) -> OfflineSignal:
    """A transparent, non-executing baseline for reviewing CSV labels.

    Positive score favours gold; negative score indicates macro pressure on
    gold.  It is a research label only and must not submit orders.
    """
    score = 0.0
    reasons: list[str] = []
    if record.long_candidate:
        score += 35.0
        reasons.append("CSV long candidate")
    if record.short_candidate:
        score -= 35.0
        reasons.append("CSV short candidate")
    if record.geo_risk_score >= 50:
        score += min(30.0, record.geo_risk_score * 0.30)
        reasons.append(f"geopolitical risk {record.geo_risk_score:.1f}")
    if record.fed_hawkish_score >= 50:
        score -= min(30.0, record.fed_hawkish_score * 0.30)
        reasons.append(f"Fed hawkishness {record.fed_hawkish_score:.1f}")
    if record.dxy_change is not None:
        score -= max(-15.0, min(15.0, record.dxy_change * 1000.0))
    if record.us10y_change is not None:
        score -= max(-15.0, min(15.0, record.us10y_change * 100.0))

    action = "LONG_RESEARCH" if score >= 25 else "SHORT_RESEARCH" if score <= -25 else "NEUTRAL"
    reason = "; ".join(reasons) or "No CSV candidate or threshold trigger"
    return OfflineSignal(record.date, action, round(score, 2), reason)


def select_record(records: list[DailyMacroRecord], date: Optional[str]) -> DailyMacroRecord:
    if not records:
        raise ValueError("CSV contains no data rows")
    if date is None:
        return records[-1]
    for record in records:
        if record.date == date:
            return record
    raise ValueError(f"No row found for date {date}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Evaluate the local XAUUSD macro-news CSV.")
    parser.add_argument("--csv", type=Path, default=DEFAULT_CSV_PATH, help="Path to XAUUSD CSV")
    parser.add_argument("--date", help="Daily row to evaluate (YYYY-MM-DD); defaults to the final row")
    parser.add_argument("--summary", action="store_true", help="Print dataset coverage and exit")
    parser.add_argument(
        "--export-mt5-signals", nargs="?", type=Path, const=DEFAULT_SIGNAL_PATH,
        help="Export all daily research signals to GoldMacroSignal.csv for the EA",
    )
    args = parser.parse_args()

    records = read_records(args.csv)
    if args.export_mt5_signals is not None:
        count = export_signals(records, args.export_mt5_signals)
        print(f"exported={count} signal rows path={args.export_mt5_signals}")
        return 0
    if args.summary:
        print(f"rows={len(records)} first_date={records[0].date} last_date={records[-1].date}")
        return 0
    record = select_record(records, args.date)
    signal = evaluate_record(record)
    print(f"date={signal.date} close={record.gold_close:.2f} action={signal.action} score={signal.score:.2f}")
    print(f"reason={signal.reason}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
