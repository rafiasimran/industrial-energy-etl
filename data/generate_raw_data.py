"""
Generates a messy industrial energy dataset on purpose.

A pipeline that only ever sees clean data hasn't really been tested, so the
generator adds the kind of problems real plant exports have.
"""
import csv
import random
from datetime import datetime, timedelta

random.seed(42)

PLANTS = ["Augsburg", "Regensburg", "Dresden"]
MACHINES = [f"M-{i:03d}" for i in range(1, 13)]
STATUSES = ["running", "idle", "maintenance", "RUNNING", " running ", "Idle"]

START = datetime(2026, 6, 1)
DAYS = 30
ROWS_PER_DAY = 240


def base_load(hour: int) -> float:
    """Factories draw more power during shifts."""
    if 6 <= hour < 14:
        return 42.0
    if 14 <= hour < 22:
        return 38.0
    return 12.0


def main(path: str = "raw_energy_readings.csv") -> None:
    rows = []
    reading_id = 1

    for day in range(DAYS):
        for _ in range(ROWS_PER_DAY):
            ts = START + timedelta(
                days=day,
                hours=random.randint(0, 23),
                minutes=random.randint(0, 59),
            )
            energy = round(random.gauss(base_load(ts.hour), 6.0), 3)

            # DEFECT: three different timestamp formats in one column
            fmt = random.random()
            if fmt < 0.70:
                ts_str = ts.strftime("%Y-%m-%d %H:%M:%S")
            elif fmt < 0.90:
                ts_str = ts.strftime("%d/%m/%Y %H:%M")
            else:
                ts_str = ts.isoformat()

            # DEFECT: some readings recorded in Wh instead of kWh
            unit = "kWh"
            energy_value = energy
            if random.random() < 0.08:
                unit = "Wh"
                energy_value = round(energy * 1000, 1)

            # DEFECT: missing values
            voltage = round(random.gauss(400, 8), 1)
            temperature = round(random.gauss(58, 9), 1)
            if random.random() < 0.04:
                voltage = ""
            if random.random() < 0.03:
                temperature = ""
            if random.random() < 0.02:
                energy_value = ""

            # DEFECT: physically impossible values (sensor faults)
            if random.random() < 0.015:
                energy_value = round(-abs(energy), 3)
            if random.random() < 0.01:
                temperature = 999.0

            rows.append({
                "reading_id": f"R{reading_id:07d}",
                "machine_id": random.choice(MACHINES),
                "plant": random.choice(PLANTS),
                "timestamp": ts_str,
                "energy": energy_value,
                "energy_unit": unit,
                "voltage_v": voltage,
                "temperature_c": temperature,
                # DEFECT: inconsistent casing and stray whitespace
                "status": random.choice(STATUSES),
            })
            reading_id += 1

    # DEFECT: duplicate rows (a batch got ingested twice)
    duplicates = random.sample(rows, k=int(len(rows) * 0.03))
    rows.extend(duplicates)
    random.shuffle(rows)

    with open(path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

    print(f"Wrote {len(rows):,} rows to {path} ({len(duplicates):,} of them duplicates)")


if __name__ == "__main__":
    main()
