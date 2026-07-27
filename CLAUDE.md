# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**机斗战甲** (Battle-GEAR-S) is a Godot 4.6 turn-based tactical mech combat game based on tabletop rules. The project has moved past the initial vertical slice and is mid-refactor toward a unified, timing-point-driven **Action Engine**. The old hook/effect system (`scripts/effect_core/`) is retained as a compatibility layer pending removal.

Main scene: `res://scenes/app/app_root.tscn`. Window 1536×768, Forward Plus renderer (D3D12 on Windows).

> **Platform note:** This checkout lives on **Windows**. Godot is installed at `F:/Godot_4.6/Godot_v4.6-stable_win64.exe` (see `.vscode/settings.json`). The historical macOS path `/Applications/Godot.app/...` still appears in `README.md` but does not apply here.

## Commands

### Run the Game (Windows)
```bash
# Preferred — uses the editor binary on this machine
"F:/Godot_4.6/Godot_v4.6-stable_win64.exe" --path .

# Or, if `godot` is on PATH
godot --path .
```

### Run Tests (Windows)
```bash
# Godot unit tests (GDScript), headless
"F:/Godot_4.6/Godot_v4.6-stable_win64.exe" --headless --path . -s res://tests/run_tests.gd

# Python tests for the data export tool
python3 -m unittest tools/export_rule_data/test_export_rule_data.py
```

### Regenerate Data from Source Spreadsheets
```bash
python3 tools/export_rule_data/export_rule_data.py --rule-dir rule --output-dir data
```

The `rule/` directory contains source `.xlsx` and `.docx` files. The game reads generated JSON from `data/` at runtime, not the source files.

### In-Game Developer Mode
Toggle with **F3** at runtime (`app_root.gd` → `_toggle_dev_mode`). Opens `DevModePanel` — modify any player's hand/equipment/stats, adjust damage tokens, add cards by ID. Backed by `DevModeService`. See `docs/developer_mode_plan.md`.

## Architecture

### Core Data Flow
```
rule/*.xlsx → tools/export_rule_data → data/*.json → DataRegistry → CardDatabase → game systems
```

**DataRegistry** (`scripts/data/data_registry.gd`) loads raw JSON and provides lookup APIs (indexed by `id`). **CardDatabase** (`scripts/generated_database/CardDatabase.gd`) converts raw JSON into typed `CardDef` instances and binds effect definitions, serving as the unified access point for card/effect data.

### Two Effect Systems (migration in progress)

The codebase currently runs **two** effect-resolution systems in parallel. New code must use the Action system; the hook system is legacy.

| System | Location | Status | Role |
|--------|----------|--------|------|
| **Action Engine** (new) | `scripts/action_core/`, `scripts/action_defs/` | **Primary entry point** | Step-based action execution with timing points, sub-actions, and UI input waits |
| **Hook/Effect Engine** (old) | `scripts/effect_core/` | Compatibility layer ("待重写后删除" per `GameContext`) | Legacy passive/static effects — being migrated |

**Rule of thumb:** All player/game actions go through `context.action_service.execute(action_type, params)`. Do not add new logic to `EffectEngine`/`EffectRegistry`.

### Action Engine (primary system)

The Action Engine drives gameplay as a sequence of **Actions**, each composed of ordered **steps**. Steps can fire **timing points** (pausing for response windows) or request **player input** (pausing for target selection etc.), and one action may spawn **sub-actions** that the parent waits on.

```
ActionService.execute(type, params)
  → factory creates Action (steps[], record) → ActionRegistry.register
  → ActionEngine.execute_action
      for each step:
        1. fire timing point (TimingEngine) — may pause (waiting_timing) for listeners/response window
        2. call step handler (reads/writes action.record, may return need_input → waiting_input)
        3. handler may create sub-action → parent pauses (waiting_sub_action)
      → action_completed (notify parent via call_deferred, cleanup)
  → continue_action(input_data) resumes a paused action
  → cancel_action cancels (recursively cancels sub-tree)
```

**Key classes** (`scripts/action_core/`):

| Class | Responsibility |
|-------|----------------|
| `Action` | Runtime action instance: steps, record (params/results), state, parent/child links. States: `running`, `waiting_input`, `waiting_timing`, `waiting_sub_action`, `completed`, `cancelled` |
| `ActionEngine` | Drives step execution; handles pause/resume (`execute_action`, `continue_action`, `cancel_action`), parent-child wait coordination |
| `ActionService` | **Unified entry point** (`execute` / `continue_action` / `cancel_action`); registers action-type factories; resolves atomic vs. full actions; runs sub-actions |
| `ActionRegistry` | Holds active actions by id; cleanup of actions and their temporary timing listeners |
| `TimingEngine` | Fires timing points; manages **listeners** — permanent, temporary (per-action), and AVAILABILITY listeners (hand cards that become playable in response windows) |
| `TimingConst` | All timing-point constants (`ATTACK_BEFORE/PRE/AT/AFTER/SETTLE`, `USE_ACTION_*`, `TURN_*`, `BASIC_MOVE_*`, etc.) and effect modes (`DIRECT`, `LISTEN`, `AVAILABILITY`) |
| `ActionEffect` | Static effect definition bound to a card; modes DIRECT (play card → execute), LISTEN (watch a timing point), AVAILABILITY (appear as a playable option in a response window) |
| `EffectBinding` | Bridges a static `ActionEffect` to a runtime `CardInstance` |
| `ConditionChecker` / `TargetChecker` / `CostChecker` | Validate effect conditions, targets, and costs (moved here from `effect_core/`) |
| `ActionUIBridge` | Bridges ActionEngine signals ↔ UI panels (drives response windows, target selection, etc.) |
| `GeneratedActionEffects` | Hand-written `ActionEffect` definitions keyed by card id (the new-logic effect registry) |

**Action types** (`scripts/action_defs/`, registered as factories in `ActionService.init_factories`):

`attack`, `use_action_card`, `stat_modify`, `basic_move`, `single_move`, `set_equipment`, `gain_card`, `discard_card`, `steal_action_card`, `effect_fire`, `hp_change`, `damage_change`, `show_card`.

Step handlers call into `GameActions` (atomic state mutations) and the retained services.

**Designated reference docs** (in `new_logic/`): `各动作的生命周期与时点.txt`, `行动牌的效果与逻辑.txt` — the authoritative spec for action lifecycles, timing points, and per-card effect logic.

### Legacy Hook/Effect System (`scripts/effect_core/`)

Being phased out. Currently holds `EffectEngine`, `EffectRegistry`, `EffectConst`, `CardEffect`, `AtomicActionResolver`, `GameActions`. `GameContext` instantiates `effect_engine`/`effect_registry` for compatibility only. When migrating an effect, port its definition to `GeneratedActionEffects` and its trigger to a timing-point listener rather than touching this module.

### Module Responsibilities

| Module | Purpose |
|--------|---------|
| `scripts/app/` | `app_root.gd` — entry point, scene routing, UI orchestration, dev-mode toggle, input dispatch |
| `scripts/action_core/` | **Primary**: Action engine, timing system, effect definitions, condition/target/cost checkers, UI bridge |
| `scripts/action_defs/` | The 13 concrete Action types (attack, move, equip, card-play, stat/hp/damage change, …) |
| `scripts/data/` | DataRegistry loads JSON, provides O(1) lookup by id |
| `scripts/battle/` | `battle_state.gd` (bridge to services via GameContext, legacy UI compat, response window), `battle_math.gd` (damage/range), `RangeCalculator.gd` (BFS pathfinding), `hex_grid.gd` (axial coords) |
| `scripts/card_defs/` | Static card type definitions: CardDef, EquipmentCardDef, ActionCardDef, EventCardDef, PilotCardDef, MechFrameDef, MechSlotDef |
| `scripts/effect_core/` | **Legacy** hook/effect engine (compatibility layer, pending removal) |
| `scripts/runtime/` | Mutable runtime state: GameContext (DI container), GameState, PlayerState, MechState, MechSlotState, CardInstance, DeckState, ShopState, MapState, MapCellState, MapMarkerState |
| `scripts/services/` | 16 retained service classes + 2 logging singletons (see Service Layer) |
| `scripts/generated_database/` | CardDatabase (unified access), CardDatabaseLoader (JSON→CardDef), GeneratedEffects (legacy), GeneratedActionEffects / GeneratedPilotEffects (new-logic effect defs), `_pilot_effects_kj.gd` |
| `scripts/config/` | GameConfig — centralized rule constants |
| `scripts/campaign/` | CampaignState manages faction, pilot, equipment selection |
| `scripts/ui/` | Battle board, hand/equipment/shop/sell panels, skill bar, response panel, message log, dev-mode panel, popups, flow controller (see UI Panels) |
| `scenes/app/` | AppRoot scene — main entry defined in project.godot |

### Service Layer

All services hold a `context` (GameContext) reference and implement domain-specific logic, communicating through `context` rather than global singletons. **16 retained services** (the action system is the preferred entry point; services are internal helpers called by action step handlers):

| Service | Responsibility |
|---------|---------------|
| `TurnService` | Turn lifecycle: start (draw, gain gold, restore power), end (tick timers, discard excess, clean effects) |
| `RoundService` | Round-robin turn order for 1v1 |
| `CardSetService` | Equipment setting (slot validation, replacement) and **selling** (rarity-based pricing, 2/turn limit) |
| `DeckService` | Drawing (auto-reshuffle), discarding, deck construction from config |
| `DeckBuildService` | Deck construction from CardDatabase (SR/SSR equipment → advanced deck) |
| `MapService` | Mech movement (BFS pathfinding, terrain cost, marker triggers) |
| `MarkerService` | Map marker effects: GOLD, EVENT, TRAP |
| `ShopService` | Shop management: 3 normal + 1 advanced + 1 hidden slots, buy/refresh/reveal |
| `DamageTokenService` | Damage token placement with slot priority, equipment breakage checks |
| `EquipmentBreakService` | Equipment break flow (durability exceeded → hook → unregister → discard) and replacement |
| `EventTimerService` | Event card timer countdown at turn end |
| `GameSetupService` | Initial game state creation for tutorial battle |
| `VictoryService` | Win/loss conditions: mech destroyed, HP zero, turn limit (attacker-disadvantage rule) |
| `DevModeService` | Developer-mode card/stat/damage editing (backs the F3 panel) |
| `session_logger.gd` | **Autoload singleton** (`SessionLogger`) — one log file per game session, captures game messages + service call results |
| `slog.gd` | `SLog` preload proxy — every script that logs uses `preload(slog.gd)` instead of the bare autoload identifier (the bare id is unresolvable in `-s` test mode). Forwards to `SessionLogger` at runtime |

> Note: `AttackService`, `AttackRuleChecker`, `CardPlayService`, `GameFlowService`, `PlayerActionService` listed in older docs **no longer exist** — attack flow and card play now live in `action_defs/` (attack / use_action_card actions) driven by the Action Engine.

### Runtime State Objects

| Class | Purpose |
|-------|---------|
| `GameContext` | DI container — holds GameState, CardDatabase, ActionEngine/Registry/TimingEngine/ActionService/ActionUIBridge, all retained services, and the legacy effect_engine/registry |
| `GameState` | Top-level mutable state: players, mechs, cards, attacks, map, deck, shop, log, phase/turn tracking |
| `PlayerState` | Per-player: gold, action/equipment hand, card limits, once-per-turn tracking, statuses |
| `MechState` | Per-mech: HP, power, position, slots, statuses, attack count. Aggregate queries (armor, power, weapon IDs) |
| `MechSlotState` | Per-slot: equipped card, base armor/power/durability, damage tokens, modifiers. Computes effective armor/power |
| `CardInstance` | Runtime card instance: references CardDef, tracks zone, slot, damage tokens, timer, counters, disabled state, owner_player_id, mech_id |
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

### Battle System

- **HexGrid**: Axial coordinates (`q`, `r`), distance/neighbors utilities, map generation
- **RangeCalculator**: BFS-based range calculation for weapon attacks and movement (terrain-aware: GREEN costs 2 power, RED blocks), hex-distance circle for skills
- **BattleState**: Bridge between `app_root` and the service/action layer via `GameContext`. Manages compat fields for legacy UI. Handles the attack response window (interception/counter-attack)
- **BattleMath**: Attack calculation (`damage = max(0, attack - armor)`, markers = floor(attack/5)), range checks (delegates to RangeCalculator), movement validation

Key battle concepts:
- **Power**: Movement resource; each hex costs 1 power (GREEN terrain costs 2, RED is impassable)
- **Weapons**: Have range (might) and damage; attacks resolve vs armor across timing points — declare (`ATTACK_AT`, response window) → resolve (`ATTACK_AFTER`, damage/tokens/HP) → settle (`ATTACK_SETTLE`)
- **Equipment**: Parts add armor/power to slots; weapons add to weapon list. Equipment has durability — damage tokens exceeding durability trigger break
- **Damage tokens**: Placed on mech slots with priority (equipped parts > equipped weapons > empty parts > empty weapons > other)
- **Turn flow**: `TURN_BEFORE_START` → `TURN_START` (gain power/gold, draw 2 action + 1 equipment) → `TURN_AFTER_START` → MAIN phase (actions) → `TURN_BEFORE_END` → `TURN_END` (tick event timers, discard excess, clean THIS_TURN effects, cancel stray actions) → `TURN_AFTER_END` → enemy turn
- **Response window**: At `ATTACK_AT`, AVAILABILITY-listener hand cards ("迎击") become playable; `ActionUIBridge` opens the response panel. The attack action pauses (`waiting_timing`) until the window closes, then continues
- **Map markers**: GOLD (roll D6, gain gold), EVENT (draw event card), TRAP (blast damage in range)

### UI Panels

| Panel | Purpose |
|-------|---------|
| `battle_board` | Hex grid renderer (flat-top, 24×8), input handler, unit/marker display, attack/move range highlighting |
| `hand_panel` | Action/equipment hand as clickable buttons, color-coded by type, slide-in animation for new cards |
| `equipment_panel` | Mech slot layout (6 parts, 2 weapons, 2 reserves, 1 event, 1 pilot), damage/durability color coding |
| `weapon_picker_panel` | Pick which weapon to attack with |
| `skill_bar` | Active-mode effect buttons from equipped cards, queries effect registry |
| `response_panel` | Counter-attack response window when attacked, lists "迎击" cards |
| `shop_panel` | Buy equipment from shop slots, refresh/reveal (added with shop system) |
| `sell_equipment_panel` | Sell equipped/inventory equipment for rarity-based gold |
| `dev_mode_panel` | F3 developer tools — edit hands/equipment/stats/damage tokens |
| `attack_flow_controller` | Orchestrates the multi-step attack UI flow |
| `damage_placement_panel` | Choose where damage tokens are placed |
| `choice_panel` / `discard_select_panel` / `deck_info_popup` / `enemy_info_popup` | Generic choice, discard selection, deck info modal, enemy mech stats modal |
| `battle_message_log` | Real-time event log, BBCode Chinese messages; writes to `SessionLogger` rather than directly to file |

### Session Logging

`SessionLogger` (autoload) writes **one file per game session** to `battle_logs/session_log_<timestamp>.txt`, containing both game-facing messages and service call results (params/returns) for post-mortem debugging. **Always log through `SLog`** (`preload("res://scripts/services/slog.gd")`) — never reference the bare `SessionLogger` autoload identifier, which fails to resolve in headless `-s` test mode.

### Test Structure

Tests are GDScript files in `tests/` (~21 files). The pattern: methods prefixed with `test_` return `true` on success or an error string on failure. `run_tests.gd` enumerates a fixed list of test files (in a `TestDriver` Node) and drives them with one `process_frame` between methods so `call_deferred` action-resume calls flush. Because `-s` (SceneTree) mode does not autoload singletons, `run_tests.gd` manually instantiates `SessionLogger` — hence the `SLog` preload-proxy rule above.

Test files cover: smoke, data registry, battle math/state, campaign, effect primitives, action card effects, timing listeners, action execution, target selection, param extraction, response-window registration, respond-attack flow, evade response, evade enemy-turn resume, expose-response steal, counter-attack effect2.

## Data Structure

Runtime JSON in `data/`:
- `cards/action_cards.json`, `event_cards.json`, `equipment_parts.json`, `equipment_weapons.json`, `pilot_cards.json`
- `mechs/mech_frames.json`
- `lore/history_nodes.json`
- `campaign/tutorial_campaign.json`

Records have `id`, `name`, `rarity`, and type-specific fields. DataRegistry indexes arrays by `id` for O(1) lookups.

### Reference material (not read at runtime)

- `rule/` — source `.xlsx` / `.docx` (规则书, 行动+事件牌, 装备牌+机甲框架, 机师牌, Effect全牌表)
- `new_logic/` — design specs: `各动作的生命周期与时点.txt/.docx`, `行动牌的效果与逻辑.txt/.docx`, `机斗战甲规则书.txt`, `UI联动计划.md`
- `docs/` — `developer_mode_plan.md`, `效果系统完整参考.xlsx`, `effect_system_reference.xlsx`

## Game Configuration

`GameConfig` (`scripts/config/GameConfig.gd`) centralizes all rule constants:
- **Initial resources**: 15 gold, 2 gold/turn
- **Drawing**: 2 action + 1 equipment per turn, action hand limit 5, paid draw cost 2 (draws 1)
- **Attack**: 1 attack/turn default, 1 damage token per 5 attack power
- **Shop**: 3 normal slots, refresh cost 2, reveal hidden cost 2, buy hidden cost 10
- **Map**: 24×8 grid, gold marker D6, trap blast range 1 / damage 3 / tokens 1
- **Victory**: 30 turn limit (then HP-judged, attacker-disadvantage)
- **Sell prices**: N=1, R=2, SR=3, SSR=5; max 2 sells/turn

## Scope

Intentionally excluded: reward progression, collection unlocks, networking, and advanced AI.

**Implemented:** timing-point-driven Action Engine (primary), legacy hook/effect compat layer, data-driven effect definitions, full retained service layer, card database with typed definitions, shop system, sell-equipment, event timer system, damage token system, equipment break/replace, map markers, counter-attack response window, in-game developer mode (F3), and session logging.
