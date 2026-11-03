"""Tests for the transform step. They run locally and in CI, without AWS."""
import subprocess
import sys
from pathlib import Path

import pandas as pd
import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lambda"))
from transform import parse_timestamp, transform  # noqa: E402

COLUMNS = ["reading_id", "machine_id", "plant", "timestamp", "energy", "energy_unit",
           "voltage_v", "temperature_c", "status"]


def frame(*rows):
    return pd.DataFrame([dict(zip(COLUMNS, r)) for r in rows], dtype=str)


def good(reading_id="R1", **overrides):
    row = dict(zip(COLUMNS, [reading_id, "m-001", " augsburg ", "2026-06-01 08:00:00",
                             "40.5", "kWh", "400", "55", " RUNNING "]))
    row.update(overrides)
    return [row[c] for c in COLUMNS]


def test_all_three_timestamp_formats_are_parsed():
    for text in ("2026-06-01 08:00:00", "01/06/2026 08:00", "2026-06-01T08:00:00"):
        assert parse_timestamp(text).hour == 8
    assert pd.isna(parse_timestamp("yesterday"))


def test_wh_readings_are_converted_to_kwh():
    out, q = transform(frame(good(energy="40500", energy_unit="Wh")))
    assert out["energy_kwh"].iloc[0] == 40.5
    assert q["rows_converted_from_wh"] == 1


def test_duplicate_batch_is_counted_once():
    out, q = transform(frame(good("R1"), good("R1"), good("R2")))
    assert len(out) == 2 and q["duplicates_removed"] == 1


def test_impossible_values_are_rejected_and_counted():
    out, q = transform(frame(good("R1", energy="-3"), good("R2", temperature_c="999"), good("R3")))
    assert list(out["reading_id"]) == ["R3"]
    assert q["impossible_values_rejected"] == 2


def test_missing_energy_drops_row_but_missing_voltage_does_not():
    out, q = transform(frame(good("R1", energy=""), good("R2", voltage_v="")))
    assert list(out["reading_id"]) == ["R2"]
    assert q["rows_dropped_missing_critical"] == 1 and q["null_voltage"] == 1


def test_text_is_normalised():
    out, _ = transform(frame(good()))
    row = out.iloc[0]
    assert (row["plant"], row["machine_id"], row["status"]) == ("Augsburg", "M-001", "running")


def test_unknown_status_is_reported():
    _, q = transform(frame(good(status="exploded")))
    assert q["unknown_status_values"] == ["exploded"]


def test_full_generated_dataset(tmp_path):
    """The numbers quoted in the README come from this run."""
    subprocess.run([sys.executable, str(ROOT / "data" / "generate_raw_data.py")], cwd=tmp_path, check=True,
                   capture_output=True)
    df = pd.read_csv(tmp_path / "raw_energy_readings.csv", dtype=str)
    out, q = transform(df)
    assert q["rows_in"] == 7416
    assert q["rows_out"] == len(out) == 6840
    assert q["pass_rate_pct"] == pytest.approx(92.23)
    assert out["energy_kwh"].between(0, 500).all()


def test_missing_text_stays_missing_instead_of_becoming_nan():
    out, q = transform(frame(good("R1", status=None), good("R2")))
    assert q["null_status"] == 1
    assert q["unknown_status_values"] == []          # not ["nan"]
    assert out["status"].isna().sum() == 1


def test_missing_or_unknown_unit_is_rejected_not_assumed_kwh():
    out, q = transform(frame(good("R1", energy_unit=None), good("R2", energy_unit="MWh"), good("R3")))
    assert list(out["reading_id"]) == ["R3"]
    assert q["unknown_unit_rejected"] == 2


def test_handler_processes_every_file_in_the_event(monkeypatch):
    import types
    written, reports = [], []
    wr = types.SimpleNamespace(s3=types.SimpleNamespace(
        read_csv=lambda path, dtype: frame(good("R1"), good("R2")),
        to_parquet=lambda **kw: written.append(len(kw["df"]))))
    client = types.SimpleNamespace(put_object=lambda **kw: reports.append(kw["Key"]))
    boto3 = types.SimpleNamespace(client=lambda name: client)
    monkeypatch.setitem(sys.modules, "awswrangler", wr)
    monkeypatch.setitem(sys.modules, "boto3", boto3)
    monkeypatch.setenv("CURATED_BUCKET", "curated")
    from transform import handler

    event = {"Records": [{"s3": {"bucket": {"name": "raw"}, "object": {"key": f"raw/day{i}.csv"}}} for i in (1, 2)]}
    result = handler(event, None)
    assert result["files"] == 2 and written == [2, 2]
    assert len(set(reports)) == 2 and all(k.endswith(("_day1.json", "_day2.json")) for k in reports)
