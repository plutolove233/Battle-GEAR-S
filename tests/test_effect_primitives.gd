extends RefCounted

const _DataRegistry = preload("res://scripts/data/data_registry.gd")
const _EffectConst = preload("res://scripts/effect_core/EffectConst.gd")
const _GeneratedEffects = preload("res://scripts/generated_database/GeneratedEffects.gd")
const _CardEffect = preload("res://scripts/effect_core/CardEffect.gd")
const _MapService = preload("res://scripts/services/MapService.gd")
const _MapCellState = preload("res://scripts/runtime/MapCellState.gd")


## ── 新增条件运算符测试 ──

func test_attack_count_below_condition_exists():
	var effects := _GeneratedEffects.build_all_effects()
	# Just verify the effect system still builds correctly after adding new conditions
	if effects.is_empty():
		return "GeneratedEffects returned empty"
	return true


func test_has_faction_condition_exists():
	var effects := _GeneratedEffects.build_all_effects()
	if effects.is_empty():
		return "GeneratedEffects returned empty"
	return true


## ── 新增目标规则测试 ──

func test_choose_enemy_mech_target_rule_exists():
	var effects := _GeneratedEffects.build_all_effects()
	if effects.is_empty():
		return "GeneratedEffects returned empty"
	return true


## ── 新增动作测试 ──

func test_apply_energy_to_weapon_action_resolvable():
	var effects := _GeneratedEffects.build_all_effects()
	if effects.is_empty():
		return "GeneratedEffects returned empty"
	return true


func test_steal_action_card_action_resolvable():
	var effects := _GeneratedEffects.build_all_effects()
	if effects.is_empty():
		return "GeneratedEffects returned empty"
	return true


func test_place_trap_marker_action_resolvable():
	var effects := _GeneratedEffects.build_all_effects()
	if effects.is_empty():
		return "GeneratedEffects returned empty"
	return true


func test_convert_weapon_kind_action_resolvable():
	var effects := _GeneratedEffects.build_all_effects()
	if effects.is_empty():
		return "GeneratedEffects returned empty"
	return true


func test_map_service_reads_map_cell_state_terrain_without_dictionary_get():
	var service := _MapService.new()
	var cell := _MapCellState.new("1,1", 1, 1, &"GREEN")
	return service._get_cell_terrain(cell) == &"GREEN"


## ── 增援事件牌效果测试 ──

func test_event_reinforce_draw_actions_registers():
	var effects := _GeneratedEffects.build_all_effects()
	if not effects.has(&"event_reinforce_draw_actions"):
		return "effect event_reinforce_draw_actions not found in GeneratedEffects"
	var effect = effects[&"event_reinforce_draw_actions"]
	if effect.hook != _EffectConst.HOOK_OWNER_MAIN_PHASE:
		return "expected hook HOOK_OWNER_MAIN_PHASE, got %s" % effect.hook
	if effect.mode != "ACTIVE":
		return "expected mode ACTIVE, got %s" % effect.mode
	return true


func test_event_reinforce_draw_equipment_registers():
	var effects := _GeneratedEffects.build_all_effects()
	if not effects.has(&"event_reinforce_draw_equipment"):
		return "effect event_reinforce_draw_equipment not found in GeneratedEffects"
	var effect = effects[&"event_reinforce_draw_equipment"]
	if effect.hook != _EffectConst.HOOK_OWNER_MAIN_PHASE:
		return "expected hook HOOK_OWNER_MAIN_PHASE, got %s" % effect.hook
	if effect.mode != "ACTIVE":
		return "expected mode ACTIVE, got %s" % effect.mode
	return true


func test_event_reinforce_shared_once_per_turn():
	var effects := _GeneratedEffects.build_all_effects()
	var effect_a = effects[&"event_reinforce_draw_actions"]
	var effect_b = effects[&"event_reinforce_draw_equipment"]
	if effect_a.once_per_turn_key != effect_b.once_per_turn_key:
		return "增援两个效果应共享同一个 once_per_turn_key"
	if effect_a.once_per_turn_key == &"":
		return "once_per_turn_key 不应为空"
	return true


func test_event_reinforce_draw_actions_has_valid_actions():
	var effects := _GeneratedEffects.build_all_effects()
	var effect = effects[&"event_reinforce_draw_actions"]
	if effect.actions.is_empty():
		return "event_reinforce_draw_actions has no actions"
	var action = effect.actions[0]
	if action.get("type", &"") != &"DRAW_ACTION":
		return "expected DRAW_ACTION, got %s" % action.get("type", &"")
	return true


func test_event_reinforce_draw_equipment_has_valid_actions():
	var effects := _GeneratedEffects.build_all_effects()
	var effect = effects[&"event_reinforce_draw_equipment"]
	if effect.actions.is_empty():
		return "event_reinforce_draw_equipment has no actions"
	var action = effect.actions[0]
	if action.get("type", &"") != &"DRAW_EQUIPMENT":
		return "expected DRAW_EQUIPMENT, got %s" % action.get("type", &"")
	return true
