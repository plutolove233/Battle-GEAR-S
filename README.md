# mech-battle-suit

Godot 4.6 prototype for **机斗战甲**.

## Run

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path .
```

## Test

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . -s res://tests/run_tests.gd
python3 -m unittest tools/export_rule_data/test_export_rule_data.py
```

## Data

Runtime data lives under `data/` as JSON. The local `rule/` directory is source
material and is not read by the game at runtime.

To regenerate JSON from local rule spreadsheets:

```bash
python3 tools/export_rule_data/export_rule_data.py --rule-dir rule --output-dir data
```

The first playable slice intentionally excludes reward progression, unlock
progression, full collection state, networking, full card effects, and advanced
shop/event systems.
