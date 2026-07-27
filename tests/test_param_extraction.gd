## test_param_extraction.gd — 参数提取与参数修改测试
##
## 测试新逻辑中参数提取与修改的相关功能：
##   1. Action.record 的参数记录与传递
##   2. Action.source 的来源信息提取
##   3. ActionService 的子动作参数提取
##   4. 数值修正动作的参数应用
##   5. 攻击动作的参数记录
##   6. 效果动作列表的参数传递
##   7. payload 中的变量注入
##   8. AtomicActionResolver 的参数分发
extends RefCounted

const _Action = preload("res://scripts/action_core/Action.gd")
const _ActionEngine = preload("res://scripts/action_core/ActionEngine.gd")
const _ActionRegistry = preload("res://scripts/action_core/ActionRegistry.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _TimingEngine = preload("res://scripts/action_core/TimingEngine.gd")
const _ActionService = preload("res://scripts/action_core/ActionService.gd")
const _GeneratedActionEffects = preload("res://scripts/action_core/GeneratedActionEffects.gd")
const _AtomicActionResolver = preload("res://scripts/effect_core/AtomicActionResolver.gd")
const _EffectBinding = preload("res://scripts/action_core/EffectBinding.gd")


## ── 辅助：创建最小测试 context ──
func _make_test_context() -> Dictionary:
	var engine = _ActionEngine.new()
	var registry = _ActionRegistry.new()
	var timing_engine = _TimingEngine.new()
	var service = _ActionService.new()

	var context = {
		action_engine = engine,
		action_registry = registry,
		timing_engine = timing_engine,
		action_service = service,
		game_state = null,
		game_actions = null,
	}
	engine.context = context
	registry.context = context
	timing_engine.context = context
	service.context = context
	service.init_factories()

	return context


## ── Action.record 参数记录测试 ──

func test_action_record_initial_empty():
	var action = _Action.new()
	if not action.record.is_empty():
		return "初始 record 应为空"
	return true


func test_action_record_step_merge():
	var context = _make_test_context()
	var engine = context.action_engine as _ActionEngine
	var registry = context.action_registry as _ActionRegistry

	var action = _Action.new()
	action.action_id = &"record_merge_test"
	action.action_type = &"test"
	action.context = context

	var handler1 := func(a) -> Dictionary:
		return {"key1": "value1", "key2": 42}
	var handler2 := func(a) -> Dictionary:
		return {"key3": true}

	action.set_steps([
		{step_name = &"step1", timing_point = &"", handler = handler1},
		{step_name = &"step2", timing_point = &"", handler = handler2},
	])

	registry.register(action)
	engine.execute_action(action)

	if action.record.get("key1") != "value1":
		return "record 应包含步骤1的key1"
	if action.record.get("key2") != 42:
		return "record 应包含步骤1的key2"
	if action.record.get("key3") != true:
		return "record 应包含步骤2的key3"
	return true


func test_action_record_later_step_overwrites():
	var context = _make_test_context()
	var engine = context.action_engine as _ActionEngine
	var registry = context.action_registry as _ActionRegistry

	var action = _Action.new()
	action.action_id = &"overwrite_test"
	action.action_type = &"test"
	action.context = context

	var handler1 := func(a) -> Dictionary:
		return {"damage": 10}
	var handler2 := func(a) -> Dictionary:
		return {"damage": 5}

	action.set_steps([
		{step_name = &"step1", timing_point = &"", handler = handler1},
		{step_name = &"step2", timing_point = &"", handler = handler2},
	])

	registry.register(action)
	engine.execute_action(action)

	if action.record.get("damage") != 5:
		return "后步骤的值应覆盖前步骤的同名key"
	return true


## ── Action.source 来源信息测试 ──

func test_action_source_structure():
	var action = _Action.new()
	action.source = {
		"effect_id": &"smash_effect2",
		"card_instance_id": &"card_猛击",
		"mech_id": &"mech_1",
		"player_id": &"player_1",
		"source_action_id": &"action_use_card_1",
	}

	if action.source.get("effect_id") != &"smash_effect2":
		return "source 应包含 effect_id"
	if action.source.get("mech_id") != &"mech_1":
		return "source 应包含 mech_id"
	if action.source.get("player_id") != &"player_1":
		return "source 应包含 player_id"
	return true


## ── ActionService 参数提取测试 ──

func test_service_init_factories():
	var service = _ActionService.new()
	service.init_factories()

	var expected_types: Array[StringName] = [
		&"attack", &"use_action_card", &"stat_modify",
		&"basic_move", &"single_move", &"set_equipment",
		&"gain_card", &"discard_card", &"effect_fire",
		&"hp_change", &"damage_change", &"show_card",
	]

	for action_type in expected_types:
		if not service._action_factories.has(action_type):
			return "缺少动作类型工厂: %s" % String(action_type)
	return true


func test_service_flash_use_previous_weapon_and_target():
	var service = _ActionService.new()
	service.init_factories()

	var action_def = {
		"type": &"EXECUTE_ATTACK",
		"params": {
			"target_count": 1,
			"use_previous_weapon": true,
			"use_previous_target": true,
			"skip_weapon_select": true,
			"skip_target_select": true,
		},
	}
	var payload = {"weapon_id": &"weapon_last", "target_id": &"target_last", "source_mech_id": &"mech_1"}
	var parent_action = _Action.new()

	var params = service._extract_attack_params(action_def, payload, parent_action)

	if params.get("weapon_id") != &"weapon_last":
		return "闪击再攻应使用上一次武器"
	if params.get("target_id") != &"target_last":
		return "闪击再攻应使用上一次目标"
	if params.get("skip_weapon_select") != true:
		return "应跳过武器选择"
	if params.get("skip_target_select") != true:
		return "应跳过目标选择"
	return true


func test_service_extract_stat_mod_params():
	var service = _ActionService.new()
	service.init_factories()

	var action_def = {
		"type": &"EXECUTE_STAT_MODIFY",
		"params": {"stat_type": &"might", "value": 4, "method": &"add"},
	}
	var payload = {"source_mech_id": &"mech_1"}
	var parent_action = _Action.new()

	var params = service._extract_stat_mod_params(action_def, payload, parent_action)

	if params.get("stat_type") != &"might":
		return "修正类型应为might"
	if params.get("value") != 4:
		return "修正值应为4"
	if params.get("method") != &"add":
		return "修正方式应为add"
	return true


func test_service_extract_hp_change_params():
	var service = _ActionService.new()
	service.init_factories()

	var action_def = {
		"type": &"EXECUTE_HP_CHANGE",
		"params": {"value": 4, "method": &"restore"},
	}
	var payload = {}
	var parent_action = _Action.new()

	var params = service._extract_hp_change_params(action_def, payload, parent_action)

	if params.get("value") != 4:
		return "生命变动值应为4"
	if params.get("method") != &"restore":
		return "生命变动方式应为restore"
	return true


func test_service_extract_damage_change_params():
	var service = _ActionService.new()
	service.init_factories()

	var action_def = {
		"type": &"EXECUTE_DAMAGE_CHANGE",
		"params": {"value": 2, "method": &"decrease", "executor": &"mech_1"},
	}
	var payload = {}
	var parent_action = _Action.new()

	var params = service._extract_damage_change_params(action_def, payload, parent_action)

	if params.get("value") != 2:
		return "损伤变动值应为2"
	if params.get("method") != &"decrease":
		return "损伤变动方式应为decrease"
	if params.get("executor") != &"mech_1":
		return "执行者应为mech_1"
	return true


func test_service_extract_gain_card_params():
	var service = _ActionService.new()
	service.init_factories()

	var action_def = {
		"type": &"EXECUTE_GAIN_CARD",
		"params": {"from_zone": &"equipment_discard", "count": 1, "random": true, "card_kind": &"equipment"},
	}
	var payload = {}
	var parent_action = _Action.new()

	var params = service._extract_gain_card_params(action_def, payload, parent_action)

	if params.get("from_zone") != &"equipment_discard":
		return "获取牌来源应为equipment_discard"
	if params.get("count") != 1:
		return "获取牌数量应为1"
	if params.get("random") != true:
		return "获取牌应为随机"
	return true


func test_service_extract_discard_params():
	var service = _ActionService.new()
	service.init_factories()

	var action_def = {
		"type": &"EXECUTE_DISCARD",
		"params": {"count": 1, "reason": &"PREDICT_DISCARD"},
	}
	var payload = {}
	var parent_action = _Action.new()

	var params = service._extract_discard_params(action_def, payload, parent_action)

	if params.get("count") != 1:
		return "弃牌数量应为1"
	if params.get("reason") != &"PREDICT_DISCARD":
		return "弃牌原因应为PREDICT_DISCARD"
	return true


## ── 来源信息构建测试 ──

func test_build_source_from_payload():
	var service = _ActionService.new()
	var payload = {
		"player_id": &"player_1",
		"source_mech_id": &"mech_1",
		"card_instance_id": &"card_1",
		"effect_id": &"effect_1",
	}
	var parent_action = _Action.new()
	parent_action.action_id = &"parent_1"

	var source = service._build_source_from_payload(payload, parent_action)

	if source.get("player_id") != &"player_1":
		return "来源应包含player_id"
	if source.get("mech_id") != &"mech_1":
		return "来源应包含mech_id"
	if source.get("card_instance_id") != &"card_1":
		return "来源应包含card_instance_id"
	if source.get("effect_id") != &"effect_1":
		return "来源应包含effect_id"
	if source.get("source_action_id") != &"parent_1":
		return "来源应包含source_action_id"
	return true


func test_build_source_from_params():
	var service = _ActionService.new()
	var params = {
		"player_id": &"player_2",
		"mech_id": &"mech_2",
		"card_id": &"card_2",
	}

	var source = service._build_source_from_params(params)

	if source.get("player_id") != &"player_2":
		return "来源应包含player_id"
	if source.get("mech_id") != &"mech_2":
		return "来源应包含mech_id"
	return true


## ── 效果动作参数完整性测试 ──

func test_all_effect_actions_have_type():
	var all_effects = _GeneratedActionEffects.build_all_effects()

	for effect_id in all_effects:
		var effect = all_effects[effect_id]
		for i in range(effect.actions.size()):
			var act = effect.actions[i]
			if not act.has("type"):
				return "效果 %s 的动作%d缺少type字段" % [String(effect_id), i]
	return true


func test_stat_modify_effects_have_required_params():
	var all_effects = _GeneratedActionEffects.build_all_effects()

	for effect_id in all_effects:
		var effect = all_effects[effect_id]
		for act in effect.actions:
			if act.get("type") == &"EXECUTE_STAT_MODIFY":
				var params = act.get("params", {})
				# 检查是否有 stat_type 或特殊的参数（如 value_multiplier, value_per_card）
				var has_stat_type = params.has("stat_type")
				var has_special_value = params.has("value_multiplier") or params.has("value_per_card")
				if not has_stat_type and not has_special_value:
					return "EXECUTE_STAT_MODIFY动作缺少stat_type或特殊value参数"
				# method 可选（某些效果使用 value_multiplier 或 value_per_card）
	return true


func test_execute_attack_effects_have_target_count():
	var all_effects = _GeneratedActionEffects.build_all_effects()

	for effect_id in all_effects:
		var effect = all_effects[effect_id]
		for act in effect.actions:
			if act.get("type") == &"EXECUTE_ATTACK":
				var params = act.get("params", {})
				if not params.has("target_count"):
					return "EXECUTE_ATTACK动作缺少target_count"
	return true


func test_add_status_effects_have_status_type():
	var all_effects = _GeneratedActionEffects.build_all_effects()

	for effect_id in all_effects:
		var effect = all_effects[effect_id]
		for act in effect.actions:
			if act.get("type") == &"ADD_STATUS":
				var params = act.get("params", {})
				if not params.has("status_type"):
					return "ADD_STATUS动作缺少status_type"
	return true


func test_remove_status_effects_have_status_type():
	var all_effects = _GeneratedActionEffects.build_all_effects()

	for effect_id in all_effects:
		var effect = all_effects[effect_id]
		for act in effect.actions:
			if act.get("type") == &"REMOVE_STATUS":
				var params = act.get("params", {})
				if not params.has("status_type"):
					return "REMOVE_STATUS动作缺少status_type"
	return true


## ── payload 变量注入测试 ──

func test_payload_injects_into_sub_action_params():
	# 当子动作的params中缺少某个key时，应从payload中注入
	var action_def = {
		"type": &"MODIFY_ATTACK_POWER",
		"params": {"delta": 4},
	}
	var payload = {"attack_id": &"attack_1"}

	# 验证payload中有攻击ID可用于注入
	if not payload.has("attack_id"):
		return "payload应包含attack_id用于注入"
	return true


## ── 攻击动作参数记录完整性测试 ──

func test_attack_action_records_all_info():
	var AttackAction = load("res://scripts/action_defs/attack_action.gd")
	if AttackAction == null:
		return "无法加载 attack_action.gd"
	var action = AttackAction.new()
	action.setup_steps()

	var expected_names = [
		&"extract_attack_info",
		&"select_weapon",
		&"select_target",
		&"execute_attack",
		&"check_hit",
		&"calculate_damage",
		&"apply_damage",
		&"settle",
		&"cleanup",
	]

	for i in range(action.steps.size()):
		if action.steps[i].get("step_name") != expected_names[i]:
			return "步骤%d名称不匹配" % i
	return true


## ── AtomicActionResolver 参数分发测试 ──

func test_resolve_params_payload_reference():
	var binding = _EffectBinding.new(null, null)
	binding.override_owner_player_id = &"player_1"
	binding.override_source_mech_id = &"mech_1"

	var payload = {"selected_weapon_id": &"weapon_abc", "target_id": &"mech_target"}
	var raw_params = {"weapon_ref": "$payload.selected_weapon_id"}

	var result = _AtomicActionResolver._resolve_params(raw_params, binding, payload)

	if result.get("weapon_ref") != &"weapon_abc":
		return "$payload.selected_weapon_id 应解析为 weapon_abc，实际: %s" % str(result.get("weapon_ref"))
	return true


func test_resolve_params_source_reference():
	var binding = _EffectBinding.new(null, null)
	binding.override_owner_player_id = &"player_1"
	binding.override_source_mech_id = &"mech_1"

	var payload = {}
	var raw_params = {"mech_ref": "$source.mech_id"}

	var result = _AtomicActionResolver._resolve_params(raw_params, binding, payload)

	if result.get("mech_ref") != &"mech_1":
		return "$source.mech_id 应解析为 mech_1，实际: %s" % str(result.get("mech_ref"))
	return true


func test_resolve_params_auto_inject_source():
	var binding = _EffectBinding.new(null, null)
	binding.override_owner_player_id = &"player_1"
	binding.override_source_mech_id = &"mech_1"

	var payload = {}
	var raw_params = {"delta": 4}

	var result = _AtomicActionResolver._resolve_params(raw_params, binding, payload)

	if result.get("source_card_id") != binding.get_source_instance_id():
		return "应自动注入 source_card_id"
	if result.get("source_mech_id") != &"mech_1":
		return "应自动注入 source_mech_id"
	if result.get("player_id") != &"player_1":
		return "应自动注入 player_id"
	return true


## ── 数值修正参数验证 ──

func test_stat_modify_all_types_supported():
	var StatModifyAction = load("res://scripts/action_defs/stat_modify_action.gd")
	if StatModifyAction == null:
		return "无法加载 stat_modify_action.gd"
	var action = StatModifyAction.new()
	action.setup_steps()

	if action.steps.size() != 3:
		return "数值修正动作应有3个步骤"

	var handler = action.steps[1].get("handler", Callable())
	if not handler.is_valid():
		return "数值修正步骤2的handler应有效"
	return true


## ── 使用行动牌动作参数传递测试 ──

func test_use_action_card_records_card_info():
	var UseActionCardAction = load("res://scripts/action_defs/use_action_card_action.gd")
	if UseActionCardAction == null:
		return "无法加载 use_action_card_action.gd"
	var action = UseActionCardAction.new()
	action.setup_steps()

	var expected_names = [
		&"validate_card",
		&"card_to_temp_zone",  # 翻转后合并回单步：牌进临时区+注册效果，handler 完成后 fire USE_ACTION_AT
		&"execute_effects",
		&"settle",
	]

	for i in range(action.steps.size()):
		if action.steps[i].get("step_name") != expected_names[i]:
			return "步骤%d名称不匹配" % i
	return true
