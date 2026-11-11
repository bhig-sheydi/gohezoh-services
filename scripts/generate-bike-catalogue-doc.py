"""Generate the reviewable bike catalogue from the migration seed."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
source = root / "supabase/migrations/20261111123000_bike_item_catalogue_and_space_pricing.sql"
target = root / "docs/BIKE_ITEM_CATALOGUE_FULL_LIST.md"
row = re.compile(r"^\('([^']+)','([^']+)','([^']+)',([0-9.]+),([0-9.]+),([0-9.]+),([0-9.]+),'(unit|pages)'\)[,;]$")
items = [match.groups() for line in source.read_text(encoding="utf-8").splitlines()
         if (match := row.match(line.strip()))]
if len(items) != 80:
    raise SystemExit(f"Expected 80 seeded items; found {len(items)}")
lines = ["# Full bike item catalogue", "",
         "Estimates include normal protective packaging. Loose document thickness and weight change with the selected page count; their catalogue values are placeholders. See [pricing rules](BIKE_ITEM_CATALOGUE_AND_PRICING.md).", "",
         "| Category | Item | Packed size (cm) | Average weight (kg) | Measurement |",
         "| --- | --- | ---: | ---: | --- |"]
for _, category, label, length, width, height, weight, measure in items:
    size = f"{length} × {width} × {height}" if measure == 'unit' else f"{length} × {width} × varies"
    mass = weight if measure == 'unit' else "Varies"
    lines.append(f"| {category} | {label} | {size} | {mass} | {'Pages per envelope' if measure == 'pages' else 'Per unit'} |")
target.write_text("\n".join(lines) + "\n", encoding="utf-8")
