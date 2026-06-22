# Mech Battle Suit Initialization Design

Date: 2026-06-22

## Goal

Initialize the Godot project as a minimal playable vertical slice for "机斗战甲".
The first version should prove the game loop can run from menu to loadout, battle,
result, and return flow. It should not attempt to complete every tabletop rule,
campaign reward, collection, or lore system.

## Source Context

The local `rule/` directory contains the current design source material:

- `机斗战甲规则书.docx`: tabletop battle rules, turn flow, equipment zones,
  attack resolution, map markers, and shop rules.
- `游戏设定.docx`: campaign, collection, character, gear, currency, interaction,
  and tutorial concepts.
- `用语设定.docx`: world terminology, factions, places, events, and technology.
- `行动+事件牌.xlsx`: action and event card definitions.
- `装备牌+机甲框架.xlsx`: equipment cards, weapons, body parts, and mech frames.
- `太空纪元历史线.xlsx`: Space Era history nodes.

`rule/` remains a local source directory and is not a runtime asset. Project code
should consume generated JSON data checked into the repository.

## Chosen Approach

Use a vertical slice approach:

1. Build the full app skeleton at a shallow level.
2. Implement one local single-player tutorial battle.
3. Use real rule data where practical, but only implement a small executable
   subset of effects.
4. Leave campaign rewards, unlocks, full collection progress, networking, and
   advanced card effects for later phases.

Rejected alternatives:

- Rule engine first: stronger battle correctness, but delays visible game flow.
- Content browser first: uses more lore data early, but does not prove gameplay.
- Full feature skeleton with every subsystem active: too broad for initialization.

## Platform And Language

- Engine: Godot 4.6.
- Language: GDScript.
- Battle view: 2D hex board.
- Data format: generated JSON.

GDScript is preferred for this initialization because it keeps the Godot edit/run
cycle simple and avoids extra build-chain complexity.

## Proposed Directory Structure

```text
data/
  cards/
  mechs/
  campaign/
  lore/
scenes/
  app/
  menu/
  campaign/
  battle/
  collection/
scripts/
  core/
  data/
  battle/
  campaign/
  ui/
tools/
  export_rule_data/
docs/
  superpowers/specs/
```

Responsibilities:

- `tools/export_rule_data/`: export and validate `rule/*.xlsx` into JSON. It is
  not used at runtime.
- `scripts/data/`: load generated JSON and expose lookup APIs through a registry.
- `scripts/battle/`: own battle state, turn flow, hex movement, attack
  resolution, damage, equipment, hand/deck operations, and simple enemy AI.
- `scripts/campaign/`: own outer campaign state, selected faction, selected
  pilot, selected equipment, and tutorial battle entry.
- `scenes/*`: present UI and forward player intents to services/rules. Scenes
  should not own complex rule logic.
- `collection/`: reserve a place for card, mech, pilot, and history browsing.
  Collection progress is not required for the first vertical slice.

## Data Flow

Static content follows one direction:

```text
rule/*.xlsx -> tools/export_rule_data -> data/*.json -> DataRegistry -> game systems
```

Initial JSON groups:

```text
data/cards/action_cards.json
data/cards/event_cards.json
data/cards/equipment_parts.json
data/cards/equipment_weapons.json
data/mechs/mech_frames.json
data/lore/history_nodes.json
data/campaign/tutorial_campaign.json
```

Runtime scripts should use `DataRegistry` or a similar loader facade instead of
hardcoding JSON paths throughout UI and battle code.

Card and equipment records should preserve source fields such as:

- `id`
- `name`
- `type`
- `rarity`
- `count`
- `effect_text`
- `effect_id`
- combat/stat fields such as `armor`, `power`, `damage`, `range`,
  `durability`, and `cost`

Only a small number of effects need executable `effect_id` handlers in the first
slice. Unimplemented effects should remain visible as text and produce clear
logs when encountered.

## Minimal Playable Flow

The initialization vertical slice is:

```text
Launch game
-> Main menu
-> New campaign
-> Faction / protagonist selection
-> Initial equipment selection
-> Tutorial battle
-> Victory / defeat result
-> Return to campaign hub or main menu
```

Reward calculation, currency grants, collection unlocks, and history-node
unlocking are not part of the minimal implementation. They may have UI entry
points or placeholder data, but battle completion does not need to mutate those
systems.

## Scenes

- `AppRoot`: application entry, data loading, save service, and scene routing.
- `MainMenu`: new campaign, continue if a save exists, collection entry, quit.
- `CampaignHub`: current selected protagonist/loadout and tutorial battle entry.
- `LoadoutScreen`: faction, pilot, and initial equipment selection. The first
  slice can expose only a small curated set.
- `BattleScreen`: 2D hex board, player and enemy units, hand, equipment zones,
  action buttons, and battle log.
- `ResultScreen`: win/loss, turn count, reason, retry, return to campaign hub,
  and return to main menu.
- `CollectionScreen`: optional placeholder or static browser. Collection
  progress is not required.

## Battle Scope

Implement the foundational battle loop:

- Hex map with basic tiles and optional blocked tiles.
- Unit state: life, armor, power, gold, equipment zones, hand, and decks.
- Turn start: draw action cards, draw equipment cards, gain gold, restore power.
- Turn actions: move, play an attack card, set equipment, sell unset equipment,
  and end turn.
- Attack resolution: choose weapon and target, check range, hit if target is
  still in range, calculate damage, place damage markers, reduce life.
- Basic executable action effects, such as `进攻`, `回避`, `防御`, `维修`, and
  `推进`.
- Simple enemy AI: attack if possible, otherwise move toward the player, then
  end turn.
- Battle result: player mech destroyed, enemy mech destroyed, or turn limit
  reached.

The first slice should not implement:

- Full response/interrupt chains.
- Every action card and event card effect.
- Advanced shop operations.
- Map marker reset cycles.
- Network play.
- Full campaign rewards and collection unlocks.
- Character interaction, gifts, bonds, or core-slot systems.

## Error Handling

- Data export should report missing required fields, duplicate IDs, invalid
  rarity values, and invalid numeric fields.
- Runtime data loading should fail with clear logs and use a small fallback
  sample only when it keeps the app inspectable.
- UI should disable invalid operations where possible.
- Rule-layer methods should still reject invalid operations, because UI checks
  are not a substitute for state validation.
- Unimplemented card effects should not crash the battle. They should display
  the source effect text and add an "effect not implemented" battle log entry.

## Testing And Verification

Use three verification layers:

1. Export verification: generated JSON has required fields, unique IDs, legal
   enum values, and parseable numeric fields.
2. Rule tests: movement cost, range checks, damage and damage markers, equipment
   replacement, draw/discard behavior, and battle result conditions.
3. Manual acceptance: start from the main menu, create a campaign, choose a
   loadout, enter the tutorial battle, move, attack, end turns, let the enemy
   act, reach win or loss, and return to the outer flow.

## Acceptance Criteria

The initialization is complete when:

- The project opens and runs in Godot.
- The main menu can start a new local campaign.
- The player can choose a minimal faction/protagonist/loadout.
- A 2D hex tutorial battle starts from that loadout.
- The player can move, attack, set equipment, sell unset equipment, and end turn.
- The enemy AI can take basic turns.
- The battle can end in victory or defeat and show a result screen.
- The result screen can return to the campaign hub or main menu.
- Rule data used by the slice is loaded from generated JSON, not directly from
  `rule/`.
- Reward, unlock, and collection progression are not required for the first
  slice.

## Open Extension Points

Future phases can add:

- Full executable card effect system.
- Event cards and map markers.
- Shop system.
- Reward and unlock progression.
- Collection and history-node progression.
- Character interaction, bonds, and core-slot systems.
- Additional campaign mission types.
- Local multiplayer and later network play.
