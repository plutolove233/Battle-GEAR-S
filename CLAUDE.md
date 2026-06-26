# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**机斗战甲** (Battle-GEAR-S) is a Godot 4.6 turn-based tactical mech combat game based on tabletop rules. The project is in the vertical slice phase: a minimal playable loop from menu → loadout → battle → result.

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
rule/*.xlsx → tools/export_rule_data → data/*.json → DataRegistry → CardDatabase → game systems
```

**DataRegistry** (`scripts/data/data_registry.gd`) loads raw JSON and provides lookup APIs. **CardDatabase** (`scripts/generated_database/CardDatabase.gd`) converts raw JSON into typed `CardDef` instances and binds `CardEffect` definitions, serving as the unified access point for all card and effect data.

### Module Responsibilities

| Module | Purpose |
|--------|---------|
| `scripts/app/` | Application entry point, scene routing, UI orchestration |
| `scripts/data/` | DataRegistry loads JSON, provides lookup APIs |
| `scripts/battle/` | BattleState (bridge to services), BattleMath (damage/range), RangeCalculator (BFS pathfinding), HexGrid (axial coords) |
| `scripts/card_defs/` | Static card type definitions: CardDef, EquipmentCardDef, ActionCardDef, EventCardDef, PilotCardDef, MechFrameDef, MechSlotDef |
| `scripts/effect_core/` | Data-driven effect/hook system: EffectEngine, EffectRegistry, CardEffect, ConditionChecker, TargetChecker, CostChecker, AtomicActionResolver, GameActions |
| `scripts/runtime/` | Mutable runtime state objects: GameState, GameContext (DI container), PlayerState, MechState, MechSlotState, CardInstance, DeckState, ShopState, MapState, MapCellState, MapMarkerState |
| `scripts/services/` | 18 game service classes: turn/round/attack/card-play/equipment/deck/shop/map/marker/victory/damage-token/equipment-break/event-timer/game-setup/game-flow/player-action/attack-rule-checker/deck-build |
| `scripts/generated_database/` | CardDatabase (unified access), CardDatabaseLoader (JSON→CardDef), GeneratedEffects (hand-written effect definitions) |
| `scripts/config/` | GameConfig — centralized rule constants (gold, draw counts, attack limits, shop prices, map dimensions, victory conditions, sell prices) |
| `scripts/campaign/` | CampaignState manages faction, pilot, equipment selection |
| `scripts/ui/` | BattleBoard (hex grid), HandPanel (action/equipment hand), EquipmentPanel (slot layout), SkillBar (active effects), ResponsePanel (counter-attack), BattleMessageLog (event log), EnemyInfoPopup |
| `scenes/app/` | AppRoot scene, the main entry scene defined in project.godot |

### Effect System (Hook-Driven Architecture)

The core design principle: **never write per-character/per-card functions**. All abilities are unified as `CardEffect` data, resolved through a consistent pipeline:

```
Service → fire_hook(hook, payload) → EffectEngine → EffectRegistry (lookup bindings)
  → ConditionChecker → TargetChecker → CostChecker → AtomicActionResolver → GameActions → GameState
```

**Hook types** (defined in `EffectConst`):
- **Flow hooks**: `ON_TURN_START`, `ON_ATTACK_DECLARED`, `ON_MAIN_PHASE_START`, etc. — trigger passive/static effects
- **Result hooks**: `ON_CARD_DRAWN`, `ON_DAMAGE_DEALT`, `ON_MECH_MOVED`, etc. — can chain further effects via queue

**Effect modes**: `MODE_ACTIVE` (player-initiated, shown in SkillBar), `MODE_PASSIVE` (auto-trigger on hook), `MODE_STATIC` (always-on modifier)

**EffectBinding**: Bridges a static `CardEffect` definition to a runtime `CardInstance`, allowing the system to trace back to the owning player/mech/card.

**EffectRegistry**: Maintains two dictionaries — `effects_by_hook` (passive/static effects grouped by hook) and `active_effects_by_source` (active effects by source card). Cards are registered when entering active zones (equipment slots, weapon slots, hand) and unregistered when leaving.

### Battle System

- **HexGrid**: Axial coordinates (`q`, `r`), distance/neighbors utilities, map generation
- **RangeCalculator**: BFS-based range calculation for weapon attacks and movement (terrain-aware: GREEN costs 2 power, RED blocks), hex-distance circle for skills
- **BattleState**: Bridge between `app_root` and the service layer via `GameContext`. Manages compat fields for legacy UI. Handles attack response window (interception/counter-attack)
- **BattleMath**: Attack calculation (`damage = max(0, attack - armor)`, markers = floor(attack/5)), range checks (delegates to RangeCalculator), movement validation

Key battle concepts:
- **Power**: Movement resource; each hex costs 1 power (GREEN terrain costs 2, RED is impassable)
- **Weapons**: Have range (might) and damage; attacks are resolved vs armor in two phases (declare → response window → resolve)
- **Equipment**: Parts add armor/power to slots; weapons add to weapon list. Equipment has durability — damage tokens exceeding durability trigger break
- **Damage tokens**: Placed on mech slots with priority (equipped parts > equipped weapons > empty parts > empty weapons > other)
- **Turn flow**: Start turn (gain power/gold, draw 2 action + 1 equipment) → MAIN phase (actions) → end turn (tick event timers, discard excess cards, clean THIS_TURN effects) → enemy turn
- **Attack flow**: Declare attack (validate, consume attack card, fire hooks) → response window (counter-attack cards) → resolve (range recheck, damage calculation, token placement, HP reduction)
- **Map markers**: GOLD (roll D6, gain gold), EVENT (draw event card), TRAP (blast damage in range)

### Service Layer

All services hold a `context` (GameContext) reference and implement domain-specific logic. They communicate through `context` rather than global singletons.

| Service | Responsibility |
|---------|---------------|
| `TurnService` | Turn lifecycle: start (draw, gain gold, restore power), end (tick timers, discard excess, clean effects) |
| `RoundService` | Round-robin turn order for 1v1 |
| `AttackService` | Two-phase attack: declare → response → resolve |
| `AttackRuleChecker` | Pre-attack validation (attacker alive, phase correct, attack count, weapon valid, range check) |
| `CardPlayService` | Action card play validation and execution |
| `CardSetService` | Equipment setting (slot validation, replacement) and selling (rarity-based pricing) |
| `DeckService` | Drawing (auto-reshuffle), discarding, deck construction from config |
| `DeckBuildService` | Deck construction from CardDatabase (SR/SSR equipment → advanced deck) |
| `MapService` | Mech movement (BFS pathfinding, terrain cost, marker triggers) |
| `MarkerService` | Map marker effects: GOLD, EVENT, TRAP |
| `ShopService` | Shop management: 3 normal + 1 advanced + 1 hidden slots, buy/refresh/reveal |
| `DamageTokenService` | Damage token placement with slot priority, equipment breakage checks |
| `EquipmentBreakService` | Equipment break flow (durability exceeded → hook → unregister → discard) and replacement |
| `EventTimerService` | Event card timer countdown at turn end |
| `GameSetupService` | Initial game state creation for tutorial battle |
| `GameFlowService` | Top-level game flow orchestration, command routing |
| `PlayerActionService` | Alternative command dispatcher with phase validation |
| `VictoryService` | Win/loss conditions: mech destroyed, HP zero, turn limit (attacker-disadvantage rule) |

### Runtime State Objects

| Class | Purpose |
|-------|---------|
| `GameContext` | Dependency injection container — holds all services, GameState, EffectEngine, EffectRegistry, CardDatabase |
| `GameState` | Top-level mutable state: players, mechs, cards, attacks, map, deck, shop, log, phase/turn tracking |
| `PlayerState` | Per-player: gold, action/equipment hand, card limits, once-per-turn tracking, statuses |
| `MechState` | Per-mech: HP, power, position, slots, statuses, attack count. Provides aggregate queries (armor, power, weapon IDs) |
| `MechSlotState` | Per-slot: equipped card, base armor/power/durability, damage tokens, modifiers. Computes effective armor/power |
| `CardInstance` | Runtime card instance: references CardDef, tracks zone, slot, damage tokens, timer, counters, disabled state |
| `DeckState` | All deck arrays: action, equipment, advanced equipment, pilot, event, discard |
| `ShopState` | Shop slots: 3 normal, 1 advanced, 1 hidden advanced |
| `MapState` | Hex grid cells (keyed by "q,r") and markers |
| `MapCellState` | Single hex: terrain (NORMAL/GREEN/RED), move cost, passability |
| `MapMarkerState` | Map marker: type (GOLD/EVENT/TRAP), revealed state |

### Card Definitions

Card type definitions are in `scripts/card_defs/`. Due to Godot 4 cross-file `extends` resolution issues, subclasses manually duplicate base `CardDef` fields rather than inheriting.

| Class | Key Fields |
|-------|-----------|
| `CardDef` | card_id, display_name, card_kind, rarity, tags, effects, effect_text, count |
| `EquipmentCardDef` | equipment_kind (PART/WEAPON), slot, set_name, armor, power, might, range_value, weapon_kind, durability, cost |
| `ActionCardDef` | action_type: "攻击" (attack), "迎击" (counter), "辅助" (support) |
| `EventCardDef` | delay (0=instant, >0=countdown), tone, timing, discard_when_timer_zero |
| `PilotCardDef` | attack_limit, action_card_limit, faction, cost |
| `MechFrameDef` | faction, life, base_slots (6 body parts), base_weapons, reserve_slots |
| `MechSlotDef` | slot_id, slot_kind (PART/WEAPON/RESERVE/EVENT/PILOT), base_armor, base_power, base_durability |

### UI Panels

| Panel | Purpose |
|-------|---------|
| `BattleBoard` | Hex grid renderer (flat-top, 24×8), input handler, unit/marker display, attack/move range highlighting |
| `HandPanel` | Action/equipment hand as clickable buttons, color-coded by type, slide-in animation for new cards |
| `EquipmentPanel` | Mech slot layout (6 parts, 2 weapons, 2 reserves, 1 event, 1 pilot), damage/durability color coding |
| `SkillBar` | Active-mode effect buttons from equipped cards, queries EffectRegistry |
| `ResponsePanel` | Counter-attack response window when attacked, lists "迎击" cards |
| `BattleMessageLog` | Real-time event log, receives EffectEngine.hook_fired, BBCode-formatted Chinese messages |
| `EnemyInfoPopup` | Modal popup showing enemy mech stats and equipment |

### Test Structure

Tests are GDScript files in `tests/` following a simple pattern: methods prefixed with `test_` return `true` on success or an error string on failure. `run_tests.gd` enumerates and runs all test files.

## Data Structure

Runtime JSON in `data/`:
- `cards/action_cards.json`, `event_cards.json`, `equipment_parts.json`, `equipment_weapons.json`, `pilot_cards.json`
- `mechs/mech_frames.json`
- `lore/history_nodes.json`
- `campaign/tutorial_campaign.json`

Records have `id`, `name`, `rarity`, and type-specific fields. DataRegistry indexes arrays by `id` for O(1) lookups.

## Game Configuration

`GameConfig` (`scripts/config/GameConfig.gd`) centralizes all rule constants:
- **Initial resources**: 15 gold, 2 gold/turn
- **Drawing**: 2 action + 1 equipment per turn, hand limit 5, paid draw cost 2
- **Attack**: 1 attack/turn default, 1 damage token per 5 attack power
- **Shop**: 3 normal slots, refresh cost 2, reveal hidden cost 2, buy hidden cost 10
- **Map**: 24×8 grid, gold marker D6, trap blast range 1 / damage 3 / tokens 1
- **Victory**: 30 turn limit
- **Sell prices**: N=1, R=2, SR=3, SSR=5

## Scope

The vertical slice intentionally excludes: reward progression, collection unlocks, networking, and advanced AI.

The following systems are now **implemented**: data-driven effect/hook system, full service layer, card database with typed definitions, shop system, event timer system, damage token system, equipment break/replace, map markers, and counter-attack response flow.
