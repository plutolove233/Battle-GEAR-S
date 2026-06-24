# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**机斗战甲** (Mech Battle Suit) is a Godot 4.6 turn-based tactical mech combat game based on tabletop rules. The project is in the vertical slice phase: a minimal playable loop from menu → loadout → battle → result.

## Commands

### Run the Game
```bash
/Applications/Godot.app/Contents/MacOS/Godot --path .
```

### Run Tests
```bash
# Godot unit tests (GDScript)
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . -s res://tests/run_tests.gd

# Python tests for the data export tool
python3 -m unittest tools/export_rule_data/test_export_rule_data.py
```

### Regenerate Data from Source Spreadsheets
```bash
python3 tools/export_rule_data/export_rule_data.py --rule-dir rule --output-dir data
```

The `rule/` directory contains source `.xlsx` and `.docx` files. The game reads generated JSON from `data/` at runtime, not the source files.

## Architecture

### Core Data Flow
```
rule/*.xlsx → tools/export_rule_data → data/*.json → DataRegistry → game systems
```

**DataRegistry** (`scripts/data/data_registry.gd`) is the single entry point for loading game data. All game systems query it instead of hardcoding JSON paths.

### Module Responsibilities

| Module | Purpose |
|--------|---------|
| `scripts/app/` | Application entry point, scene routing, UI orchestration |
| `scripts/data/` | DataRegistry loads JSON, provides lookup APIs |
| `scripts/battle/` | BattleState owns battle logic, HexGrid/BattleMath are utilities |
| `scripts/campaign/` | CampaignState manages faction, pilot, equipment selection |
| `scripts/ui/` | BattleBoard renders the hex grid and handles input |
| `scenes/app/` | AppRoot scene, the main entry scene defined in project.godot |

### Battle System

- **HexGrid**: Axial coordinates (`q`, `r`), distance/neighbors utilities, map generation
- **BattleState**: Turn flow, movement (power-cost), attacks (weapon range, damage, armor), equipment setting/selling, enemy AI
- **BattleMath**: Attack calculation, range checks, pathfinding for movement validation

Key battle concepts:
- **Power**: Movement resource; each hex costs 1 power
- **Weapons**: Have range and damage; attacks are resolved vs armor
- **Equipment**: Parts add armor/power; weapons add to weapon list
- **Turn flow**: Start turn (gain power/gold) → actions → end turn → enemy turn

### Test Structure

Tests are GDScript files in `tests/` following a simple pattern: methods prefixed with `test_` return `true` on success or an error string on failure. `run_tests.gd` enumerates and runs all test files.

## Data Structure

Runtime JSON in `data/`:
- `cards/action_cards.json`, `event_cards.json`, `equipment_parts.json`, `equipment_weapons.json`
- `mechs/mech_frames.json`
- `lore/history_nodes.json`
- `campaign/tutorial_campaign.json`

Records have `id`, `name`, `rarity`, and type-specific fields. DataRegistry indexes arrays by `id` for O(1) lookups.

## Scope

The vertical slice intentionally excludes: reward progression, collection unlocks, networking, full card effects, shop/event systems, and advanced AI. These are documented in `docs/superpowers/specs/2026-06-22-mech-battle-suit-initialization-design.md` for future phases.
