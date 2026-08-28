## ActionService.gd — 统一动作调度入口
##
## ActionService 是新系统的对外统一接口：
##   execute —— 创建并执行动作
##   continue_action —— 继续等待输入的动作
##   cancel_action —— 取消动作
##
## 它负责：
##   1. 根据动作类型创建对应的 Action 子类实例
##   2. 注册到 ActionRegistry
##   3. 通过 ActionEngine 执行
##   4. 将效果动作（效果产生的动作）也通过同一流程执行
extends RefCounted
class_name ActionService
const SLog = preload("res://scripts/services/slog.gd")
const _GenEquipEffects = preload("res://scripts/generated_database/GeneratedEquipmentEffects.gd")
const _GeneratedActionEffects = preload("res://scripts/action_core/GeneratedActionEffects.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _RangeCalculator = preload("res://scripts/battle/RangeCalculator.gd")
const _TC = preload("res://scripts/action_core/TimingConst.gd")
const _ActionEffect = preload("res://scripts/action_core/ActionEffect.gd")
# 新增动作类用 preload 引用，避免 headless -s 模式下新 class_name 尚未注册到全局缓存
const _AwakenAction = preload("res://scripts/action_defs/awaken_action.gd")
const _TrapExplosionAction = preload("res://scripts/action_defs/trap_explosion_action.gd")
const _ImmediateUseAction = preload("res://scripts/action_defs/immediate_use_action.gd")
const _SetEventCardAction = preload("res://scripts/action_defs/set_event_card_action.gd")

## 动作类型到创建函数的映射
var _action_factories: Dictionary = {}

## 依赖注入：GameContext 容器
var context = null

## pilot_003 effect_02 串行队列：多张正面牌同时离堆时按离开顺序串行处理（先来后到），
## force_use 挂起（人类选目标）时等该 use_action_card 完成后再处理下一张。
var _p003_e02_queue: Array[Dictionary] = []
var _p003_e02_active: bool = false
var _p003_e02_force_action_id: StringName = &""
var _p003_e02_signal_connected: bool = false
## 当前正在处理的即时队列条目（已 pop_front、force_use 可能挂起）。
## 供 get_p003_judging_card_entries 暴露给 UI（美杜莎操控列表将其标记为不可选）。
var _p003_e02_active_entry: Dictionary = {}

## pilot_003 effect_02 串行化（问题2）：正面牌因 gain_card/discard_card 动作离堆时，
## 判定延迟到该动作 SETTLE 时点作为其子动作串行执行，使父级动作（如攻击中抽牌）等待判定完成。
## key = cause_action_id, value = Array[{card_id, owner_pid, owner_mech_id}]。
var _p003_deferred_e02_map: Dictionary = {}
var _p003_deferred_effect = null  ## 惰性构建的 pilot_003_e02_deferred ActionEffect

## 通用「动作完成钩子」：action_id -> Callable。某动作完成后执行回调（call_deferred，
## 避免在完成栈中递归执行新动作）。铠威等「攻击结算完成后弹窗」效果用。
var _after_complete_hooks: Dictionary = {}
var _after_complete_signal_connected: bool = false


## 初始化：注册所有动作类型的工厂函数
func init_factories() -> void:
	_action_factories[&"attack"] = _create_attack_action
	_action_factories[&"use_action_card"] = _create_use_action_card_action
	_action_factories[&"stat_modify"] = _create_stat_modify_action
	_action_factories[&"basic_move"] = _create_basic_move_action
	_action_factories[&"single_move"] = _create_single_move_action
	_action_factories[&"set_equipment"] = _create_set_equipment_action
	_action_factories[&"gain_card"] = _create_gain_card_action
	_action_factories[&"discard_card"] = _create_discard_card_action
	_action_factories[&"steal_action_card"] = _create_steal_action_card_action
	_action_factories[&"awaken"] = _create_awaken_action
	_action_factories[&"effect_fire"] = _create_effect_fire_action
	_action_factories[&"hp_change"] = _create_hp_change_action
	_action_factories[&"damage_change"] = _create_damage_change_action
	_action_factories[&"show_card"] = _create_show_card_action
	_action_factories[&"trap_explosion"] = _create_trap_explosion_action
	_action_factories[&"immediate_use"] = _create_immediate_use_action
	_action_factories[&"set_event_card"] = _create_set_event_card_action


## 统一入口：创建并执行动作
func execute(action_type: StringName, params: Dictionary) -> Dictionary:
	# 记录动作创建
	SLog.log_call("ActionService", "execute", {"action_type": String(action_type), "params": params}, {})

	var action = _create_action(action_type, params)
	if action == null:
		var err_result = {"state": &"error", "message": "无法创建动作: %s" % String(action_type)}
		SLog.log_call("ActionService", "execute", {}, err_result)
		return err_result

	if context == null or context.action_registry == null:
		var err_result = {"state": &"error", "message": "context 或 action_registry 未初始化"}
		SLog.log_call("ActionService", "execute", {}, err_result)
		return err_result

	context.action_registry.register(action)
	var result = context.action_engine.execute_action(action)

	# 记录动作执行结果
	SLog.log_call("ActionService", "execute", {"action_id": String(action.action_id)}, result)

	return result


## 继续等待输入的动作
func continue_action(action_id: StringName, input_data: Dictionary) -> Dictionary:
	if context == null or context.action_engine == null:
		return {"state": &"error", "message": "context 或 action_engine 未初始化"}
	return context.action_engine.continue_action(action_id, input_data)


## 取消动作
func cancel_action(action_id: StringName) -> void:
	if context != null and context.action_engine != null:
		context.action_engine.cancel_action(action_id)


## 执行效果动作（由 TimingEngine 或效果的 actions 列表调用）
## parent_action 为触发此效果动作的动作（如破甲 DIRECT 效果产生的 attack A 的父动作是 use_action_card；
## 而 effect2 的 MODIFY_ATTACK_MARKERS 的 parent_action 是 attack A 本身）。
## 非原子效果动作在此显式登记父子关系（child.parent_action_id / parent.pending_effect_action_ids），
## 不再依赖 ActionRegistry size 前后差或 source_action_id 字符串匹配。
func execute_sub_action(action_def: Dictionary, payload: Dictionary, parent_action) -> Dictionary:
	var act_type: StringName = action_def.get("type", &"")

	# 原子操作：不需要创建动作实例，直接调用 GameActions / 特判 parent_action
	# （MODIFY_ATTACK_MARKERS 写 parent_action.record["extra_markers"]）
	if _is_atomic_action(act_type):
		return _execute_atomic_action(act_type, action_def, payload, parent_action)

	# 非原子效果动作：创建动作实例并显式登记父子关系
	var child_params: Dictionary = _extract_sub_action_params(act_type, action_def, payload, parent_action)
	var child: Action = _create_action(_map_sub_action_type(act_type), child_params)
	if child == null:
		push_warning("ActionService: 无法创建效果动作: %s" % String(act_type))
		return {"state": &"error", "message": "无法创建效果动作: %s" % String(act_type)}

	if context == null or context.action_registry == null:
		return {"state": &"error", "message": "context 或 action_registry 未初始化"}

	context.action_registry.register(child)

	# 显式登记父子关系
	if parent_action != null:
		child.parent_action_id = parent_action.action_id
		parent_action.pending_effect_action_ids.append(child.action_id)
		# 在效果动作 record 里记 parent_action_id，便于日志/调试
		child.record["parent_action_id"] = parent_action.action_id

	# 修复 bind_to_sub 监听器注册时机：若父动作是 use_action_card 且挂起了 bind_to_sub
	# LISTEN 效果（如猛击 effect2 监听 ATTACK_BEFORE、破甲 effect2 监听 ATTACK_AFTER），
	# 必须在 attack 子动作 run 之前注册到该子动作。否则 weapon/target 预填时 attack A 不在
	# select_weapon 暂停，会一路同步跑过 ATTACK_BEFORE 才注册，监听器漏掉已 fire 的时点
	# （猛击 extra_might 永不写入 = AI 打猛击不加威力的根因）。
	if parent_action != null and child.action_type == &"attack" and parent_action.has_method(&"_register_pending_listeners_on_sub"):
		parent_action._register_pending_listeners_on_sub(child.action_id)

	SLog.log_call("ActionService", "execute_sub_action", {
		"action_type": String(child.action_type),
		"action_id": String(child.action_id),
		"parent_action_id": String(parent_action.action_id) if parent_action != null else &"",
	}, {})

	var result = context.action_engine.execute_action(child)

	SLog.log_call("ActionService", "execute_sub_action", {"action_id": String(child.action_id)}, result)
	return result


## 效果动作类型 EXECUTE_* 到动作系统类型的映射
func _map_sub_action_type(act_type: StringName) -> StringName:
	match act_type:
		&"EXECUTE_ATTACK":
			return &"attack"
		&"EXECUTE_STAT_MODIFY":
			return &"stat_modify"
		&"EXECUTE_BASIC_MOVE":
			return &"basic_move"
		&"EXECUTE_SINGLE_MOVE":
			return &"single_move"
		&"EXECUTE_SET_EQUIP":
			return &"set_equipment"
		&"EXECUTE_GAIN_CARD":
			return &"gain_card"
		&"EXECUTE_DISCARD":
			return &"discard_card"
		&"EXECUTE_STEAL":
			return &"steal_action_card"
		&"AWAKEN_DRAW":
			return &"awaken"
		&"EXECUTE_HP_CHANGE":
			return &"hp_change"
		&"EXECUTE_DAMAGE_CHANGE":
			return &"damage_change"
		&"EXECUTE_SHOW_CARD":
			return &"show_card"
		&"EXECUTE_EFFECT_FIRE":
			return &"effect_fire"
		&"EXECUTE_USE_ACTION_CARD":
			return &"use_action_card"
		&"PILOT_002_USE_BATCH_AS_NAMED":
			return &"use_action_card"
		&"PLAY_AS_NAMED":
			# 通用转化：把临时区燃料牌当作具名行动牌 virtual_transform 打出
			# （诺拉全牌当进攻/防御、伏特2张当强袭/猛击/破甲）。替换旧 PILOT_015_USE_ALL_AS_NAMED。
			return &"use_action_card"
		&"EXECUTE_SET_EVENT_CARD":
			return &"set_event_card"
		&"EXECUTE_TRAP_EXPLOSION":
			return &"trap_explosion"
		_:
			return act_type


## 判断是否为原子操作（不创建动作实例，直接调用 GameActions）
func _is_atomic_action(act_type: StringName) -> bool:
	match act_type:
		&"MODIFY_ATTACK_MARKERS", \
		&"MODIFY_ATTACK_MIGHT", \
		&"MODIFY_ATTACK_POWER", &"MODIFY_ATTACK_RANGE", &"MODIFY_ARMOR", &"MODIFY_MECH_POWER", \
		&"RESPOND_ATTACK", &"MODIFY_ATTACK_TEMP_ARMOR", &"ADD_MECH_TEMP_ARMOR", \
		&"SPEND_POWER", &"RESTORE_POWER", &"GAIN_GOLD", &"SPEND_GOLD", \
		&"ADD_STATUS", &"REMOVE_STATUS", &"SET_ATTACK_UNNEGATABLE", \
		&"NEGATE_ATTACK", &"APPLY_CANNOT_RESPOND", &"APPLY_OR_CHECK_LOCKED", \
		&"MOVE_MECH", &"CONSUME_NEXT_ATTACK_POWER_BUFF", \
		&"APPLY_ENERGY_TO_WEAPON", &"STEAL_ACTION_CARD", \
		&"GAIN_SPECIFIC_CARD", \
		&"RANDOM_DRAW_FROM_DISCARD_OR_DECK", &"TRANSFER_ACTION_CARDS", \
		&"PLACE_DAMAGE_TOKENS", &"MODIFY_DAMAGE_TOKENS", &"REMOVE_DAMAGE_TOKENS", \
		&"HEAL_HP", &"DEAL_DAMAGE", &"DISCARD_CARD", &"DISCARD_ACTION_CARD", \
		&"DESTROY_CARD", &"SET_CARD_TO_SLOT", &"PLACE_OR_TRIGGER_TRAP", &"MOVE_MAP_MARKER", \
		&"REDUCE_EVENT_TIMER", &"SET_EVENT_TIMER", &"TRACK_EVENT_PROGRESS", \
		&"REVEAL_OR_PEEK_CARD", &"ROLL_D6", &"TOGGLE_AURA_TARGET", \
		&"CUSTOM_EFFECT_CHECK_TEXT", &"CHOOSE_ONE", &"MODIFY_ATTACK_COUNT", \
		&"APPLY_NEXT_OWNER_TURN_ATTACK_BONUS", \
		&"APPLY_NEXT_OWNER_TURN_ACTION_HAND_BONUS", \
		&"MARK_EFFECT_ONCE_PER_TURN_USED", \
		&"SET_CARD_COUNTER", \
		&"SET_TURN_START_DRAW_BONUS", \
		&"MODIFY_ACTION_HAND_LIMIT", &"INCREMENT_VARIABLE", &"ADD_WEAPON_TAG", \
		&"CONVERT_WEAPON_KIND", &"NEGATE_EQUIPMENT_EFFECT", &"MODIFY_WEAPON_POWER", \
		&"SET_WEAPON_STATS", &"SHOP_BUY_MODIFIER", &"SWAP_HAND_LIMIT_AND_ATTACK_COUNT", &"REPLACE_USED_ACTION_EFFECT_BY_SEQUENCE", &"CLEAR_SOURCE_STAT_MODIFIERS", &"SET_ATTACK_DEFENSE_STAT_SOURCE", &"PILOT_005_DISCARD_OPPOSING", &"PILOT_008_RECOVER_REPAIR", &"PILOT_008_BUILD_HEAL_REDIRECT_PROMPT", &"PILOT_008_BUILD_REMOVE_REDIRECT_PROMPT", &"SET_ROUND_MARKED_TARGET", &"DRAW_ACTION_AND_TAG_IF_ATTACK", &"CLAIM_RESOLVED_ATTACK_SOURCE_CARD", &"GRANT_TEMP_CARD_CONTROL", &"PILOT_009_DISCARD_ALL_CONTROLLED_TYPE", &"PILOT_007_COMPUTE_X", &"PILOT_044_COMPUTE_DAMAGE", &"GRANT_TRANSFER_BATCH_AS_NAMED_TYPE", &"INSERT_ACTION_CARDS_FACE_UP_RANDOM", &"TOGGLE_PILOT_003_SKIP", &"SET_PILOT_003_SKIP_PLAYERS", &"REPEAT_USED_ACTION_EFFECT_CHAIN", \
		&"OPEN_OR_USE_RESPONSE", &"REDIRECT_DAMAGE_TOKENS", \
		&"REDIRECT_HEAL_TO_DAMAGE", &"REDIRECT_REMOVE_TO_PLACE_TOKENS", \
		&"REDIRECT_ATTACK_TARGET_TO_SELF", &"RESTORE_REDIRECTED_ATTACK_TARGET", \
		&"REDIRECT_HP_CHANGE_TARGET", &"MODIFY_HP_CHANGE_VALUE_BY_VARIABLE", \
		&"MODIFY_NEXT_DAMAGE_DEALT", &"DECLARE_CARD_TYPE", \
		&"DRAW_ADVANCED_EQUIPMENT", &"PLACE_CARD_IN_DECK_FACE_UP", \
		&"DECREMENT_STATUS_DURATION", &"CANCEL_PARENT_ACTION", \
		&"SET_ATTACK_EFFECTIVE_WEAPON_KIND", &"REMOVE_DAMAGE_TOKENS_FROM_DISCARD_ORIGIN_SLOT", \
		&"OFFER_DAMAGE_REDIRECT", \
		&"DISCARD_SELF_AND_REDUCE_ATTACK_MARKERS", &"DISCARD_SELF_FROM_SLOT", &"REMOVE_DAMAGE_TOKENS_OTHER_SLOTS", \
		&"RANDOM_DISCARD_ACTION_CARD", &"SET_WEAPON_MODE", &"SET_WEAPON_COOLDOWN", \
		&"SET_ATTACK_MIGHT_FROM_PRINTED_WEAPON", &"DISCARD_ALL_FACE_UP_PARTS", \
		&"SET_WEAPON_LOCK", &"SET_WEAPON_CONVERSION", \
		&"IMMEDIATELY_USE_DECK_CARD_OR_FALLBACK", \
		&"SET_ACTION_RECORD_FLAG", &"MODIFY_ATTACK_DAMAGE", \
		&"PILOT_015_FORCE_PURE_ASSAULT", &"PILOT_015_REPLACE_COUNTER_AS_DEFEND", \
		&"DISCARD_TEMP_ZONE_CARDS", &"MOVE_ACTION_CARDS_TO_TEMP_ZONE", \
		&"RECORD_WEAPON_ATTACK_COUNT", &"DECAY_WEAPON_BY_RECORDED_COUNT", \
		&"PILOT_018_RESPOND_DISCARD", \
		&"PILOT_022_APPLY_POWER_BONUS", &"PILOT_022_MULTIPLY_ATTACK_MIGHT", &"PILOT_022_MARK_USED", \
		&"PILOT_024_RE_MARK_USED", \
		&"PILOT_081_RE_MARK_USED", \
		&"PILOT_083_RE_MARK_USED", \
		&"PILOT_034_RECORD_DAMAGE_SOURCE", \
		&"PILOT_035_SET_MARK", &"PILOT_035_CLEAR_MARK", \
		&"SET_ATTACK_NO_RESPONSE", \
		&"ACCUMULATE_NEXT_ATTACK_BONUS", &"APPLY_NEXT_ATTACK_BONUS", \
		&"ACCUMULATE_MELEE_MIGHT", &"APPLY_MELEE_MIGHT", &"CLEAR_MELEE_MIGHT", \
		&"GRANT_MELEE_MIGHT", &"EXPIRE_MELEE_MIGHT":
			return true
		_:
			return false


## 从 EXECUTE_* 动作定义提取效果动作参数
func _extract_sub_action_params(act_type: StringName, action_def: Dictionary, payload: Dictionary, parent_action) -> Dictionary:
	match act_type:
		&"EXECUTE_ATTACK":
			return _extract_attack_params(action_def, payload, parent_action)
		&"EXECUTE_STAT_MODIFY":
			return _extract_stat_mod_params(action_def, payload, parent_action)
		&"EXECUTE_BASIC_MOVE":
			return _extract_move_params(action_def, payload, parent_action)
		&"EXECUTE_SINGLE_MOVE":
			return _extract_single_move_params(action_def, payload, parent_action)
		&"EXECUTE_SET_EQUIP":
			return _extract_set_equip_params(action_def, payload, parent_action)
		&"EXECUTE_GAIN_CARD":
			return _extract_gain_card_params(action_def, payload, parent_action)
		&"EXECUTE_DISCARD":
			return _extract_discard_params(action_def, payload, parent_action)
		&"EXECUTE_STEAL":
			return _extract_steal_params(action_def, payload, parent_action)
		&"AWAKEN_DRAW":
			return _extract_awaken_params(action_def, payload, parent_action)
		&"EXECUTE_HP_CHANGE":
			return _extract_hp_change_params(action_def, payload, parent_action)
		&"EXECUTE_DAMAGE_CHANGE":
			return _extract_damage_change_params(action_def, payload, parent_action)
		&"EXECUTE_SHOW_CARD":
			return _extract_show_card_params(action_def, payload, parent_action)
		&"EXECUTE_EFFECT_FIRE":
			return _extract_effect_fire_params(action_def, payload, parent_action)
		&"EXECUTE_USE_ACTION_CARD":
			return _extract_use_action_card_params(action_def, payload, parent_action)
		&"PILOT_002_USE_BATCH_AS_NAMED":
			return _extract_pilot_002_batch_use_params(action_def, payload, parent_action)
		&"PLAY_AS_NAMED":
			return _extract_play_as_named_params(action_def, payload, parent_action)
		&"EXECUTE_SET_EVENT_CARD":
			return _extract_set_event_card_params(action_def, payload, parent_action)
		&"EXECUTE_TRAP_EXPLOSION":
			return _extract_trap_explosion_params(action_def, payload, parent_action)
		_:
			return action_def.get("params", {})


## ── 内部方法 ──


## 创建动作实例
func _create_action(action_type: StringName, params: Dictionary) -> Action:
	var factory: Callable = _action_factories.get(action_type, Callable())
	if not factory.is_valid():
		push_error("ActionService: 未注册的动作类型: %s" % String(action_type))
		return null
	var action: Action = factory.call(params)
	if action != null:
		action.context = context
		# 注入来源信息
		if params.has("source"):
			action.source = params["source"]
		else:
			action.source = _build_source_from_params(params)
		# 注入初始记录
		if params.has("record"):
			action.record = params["record"].duplicate(true)
		else:
			# 将通用参数注入record（排除source和特殊参数）
			var record_keys: Array = [&"attacker_id", &"target_id", &"weapon_id", &"attack_card_id",
				&"target_count", &"card_instance_id", &"card_id", &"mech_id", &"player_id",
				&"stat_type", &"value", &"method", &"target_cell", &"available_power",
				&"slot_id", &"card_ids", &"mech_ids", &"from_zone", &"reason",
				&"count", &"executor", &"effect_id", &"targets", &"is_virtual",
				&"power_fraction", &"loop_until_cancel", &"card_kind", &"random",
				&"duration", &"tag", &"status_type", &"stacks", &"attack_action_id",
				&"from_target", &"from_attacker", &"from_player_id", &"to_player_id",
				&"choose", &"face_up", &"no_cancel", &"determined_card_ids", &"selected_action_card_ids", &"phase",
				&"max_cells", &"free_move", &"adjacent_only",
				&"target_slot_id", &"target_mech_id", &"fixed_slot", &"exclude_slot_id", &"direct_remove",
				&"allow_cancel", &"max_mode", &"source_label",
				&"cardless_weapon_attack", &"consume_turn_attack_count", &"skip_weapon_select", &"weapon_instance_id",
				&"as_card_def_id", &"consume_original_card", &"virtual_transform", &"consume_attack_count",
				&"trigger_q", &"trigger_r", &"trigger_mech_id",
				&"stat_changes", &"duration_owner_id", &"source_effect_id",
				&"source_key", &"source_target_id", &"source_card_id",
				&"mode", &"runtime_tag", &"stat_types",
				&"from_target_id", &"to_target_id", &"chooser_id", &"card_kind", &"optional",
				&"from_opposing", &"source_mech", &"discard_all_action_hand",
				&"auto_discard_all_if_covered", &"event_card_id"]
			for key: String in params:
				if key in record_keys or String(key).begins_with("_"):
					action.record[key] = params[key]
		# 来源同步进 record（仅注入有效来源）：ConditionChecker 的
		# HP_CHANGE_SOURCE_MECH_IS_BINDING 等经 _live_action_record 读 action.record["source"]
		# （fire 时 payload.source 来自 action.source，但条件读的是 record 而非 payload）。
		# 此前 record 白名单显式排除 source，导致 record.source 恒空 → 来源永远判"非绑定"：
		# 杰狞 effect_01 自己攻击时误弹转移确认窗阻塞攻击、effect_02 加伤永不触发。
		# 仅注入有效来源（含 source_action_id/mech_id/card_instance_id 之一，与 fire_timing
		# 的注入条件对齐）——空 source（顶层动作 _build_source_from_params 无链接字段）不注入，
		# 避免 record.source 空值键使 fire payload 带 source，短路"source.mech_id 空则回退
		# payload.mech_id"的来源解析（琳 RE 维修窗口关闭判断依赖顶层 mech_id 回退）。
		if action.source is Dictionary and not action.source.is_empty() \
				and (String(action.source.get("source_action_id", &"")) != "" \
					or String(action.source.get("mech_id", &"")) != "" \
					or String(action.source.get("card_instance_id", &"")) != ""):
			action.record["source"] = action.source
	return action


## 从参数构建来源信息
func _build_source_from_params(params: Dictionary) -> Dictionary:
	var source: Dictionary = {}
	source["player_id"] = params.get("player_id", &"")
	source["mech_id"] = params.get("mech_id", params.get("source_mech_id", &""))
	source["card_instance_id"] = params.get("card_instance_id", params.get("card_id", &""))
	source["effect_id"] = params.get("effect_id", &"")
	source["source_action_id"] = params.get("source_action_id", &"")
	return source


## 执行原效果动作（直接调用 GameActions）
func _execute_atomic_action(act_type: StringName, action_def: Dictionary, payload: Dictionary, parent_action) -> Dictionary:
	if context == null or context.game_actions == null:
		return {"state": &"error", "message": "context 或 game_actions 未初始化"}

	# pilot_010 effect_02：按序号替换 effect 链为强袭/闪击/预判 + 计数。需 parent_action 设 record。
	if act_type == &"REPLACE_USED_ACTION_EFFECT_BY_SEQUENCE":
		context.game_actions.replace_used_action_effect_by_sequence(action_def.get("params", {}), payload, parent_action)
		return {"state": &"completed"}

	# pilot_004 effect_02：改 attack record 防御值来源（动力代护甲）。需 parent_action 设 record。
	if act_type == &"SET_ATTACK_DEFENSE_STAT_SOURCE":
		context.game_actions.set_attack_defense_stat_source(action_def.get("params", {}), payload, parent_action)
		return {"state": &"completed"}

	# pilot_005 effect_01 授予能力：弃对侧2张行动牌。需 payload（attacker/target）+ binding_context.mech_id。
	if act_type == &"PILOT_005_DISCARD_OPPOSING":
		context.game_actions.pilot_005_discard_opposing(action_def.get("params", {}), payload, parent_action)
		return {"state": &"completed"}

	# pilot_008 effect_01a/01b：回收弃牌堆维修 + X+1。需 payload.binding_context。
	if act_type == &"PILOT_008_RECOVER_REPAIR":
		context.game_actions.pilot_008_recover_repair(action_def.get("params", {}), payload)
		return {"state": &"completed"}

	# pilot_008 effect_02/03：逆转 + 弹窗描述。需 payload + parent_action（被监听的 hp_change/damage_change）。
	# 修改被监听动作 record，让其后续步骤按修改后信息执行（回复->伤害 / 移除->设置）。
	if act_type == &"REDIRECT_HEAL_TO_DAMAGE":
		context.game_actions.redirect_heal_to_damage(action_def.get("params", {}), payload, parent_action)
		return {"state": &"completed"}
	if act_type == &"REDIRECT_REMOVE_TO_PLACE_TOKENS":
		context.game_actions.redirect_remove_to_place_tokens(action_def.get("params", {}), payload, parent_action)
		return {"state": &"completed"}
	# pilot_049 effect_01：将其他机甲即将受到的HP伤害转移由我方承受（改被监听 hp_change 的 mech_ids）。
	if act_type == &"REDIRECT_HP_CHANGE_TARGET":
		context.game_actions.redirect_hp_change_target(action_def.get("params", {}), payload, parent_action)
		return {"state": &"completed"}
	# pilot_049 effect_02：我方造成伤害时按受伤计数 X 加伤 +4*X 并清零（改被监听 hp_change 的 value）。
	if act_type == &"MODIFY_HP_CHANGE_VALUE_BY_VARIABLE":
		context.game_actions.modify_hp_change_value_by_variable(action_def.get("params", {}), payload, parent_action)
		return {"state": &"completed"}
	if act_type == &"PILOT_008_BUILD_HEAL_REDIRECT_PROMPT":
		context.game_actions.pilot_008_build_heal_redirect_prompt(action_def.get("params", {}), payload, parent_action)
		return {"state": &"completed"}
	if act_type == &"PILOT_008_BUILD_REMOVE_REDIRECT_PROMPT":
		context.game_actions.pilot_008_build_remove_redirect_prompt(action_def.get("params", {}), payload, parent_action)
		return {"state": &"completed"}

	# pilot_006 effect_01：设置本轮悬赏目标。需 payload.binding_context + target_id。
	if act_type == &"SET_ROUND_MARKED_TARGET":
		context.game_actions.set_round_marked_target(action_def.get("params", {}), payload)
		return {"state": &"completed"}

	# pilot_006 effect_02：攻击方抽1，若攻击牌挂标记。需 payload.attacker_id + binding_context。
	if act_type == &"DRAW_ACTION_AND_TAG_IF_ATTACK":
		context.game_actions.draw_action_and_tag_if_attack(action_def.get("params", {}), payload)
		return {"state": &"completed"}

	# pilot_007 effect_01：夺取攻击来源牌。需 payload.attack_card_id + binding_context.player_id。
	if act_type == &"CLAIM_RESOLVED_ATTACK_SOURCE_CARD":
		context.game_actions.claim_resolved_attack_source_card(action_def.get("params", {}), payload)
		return {"state": &"completed"}

	# pilot_009 effect_01：授予临时卡牌控制。需 payload.target_id + binding_context + params.card_type。
	if act_type == &"GRANT_TEMP_CARD_CONTROL":
		context.game_actions.grant_temp_card_control(action_def.get("params", {}), payload)
		return {"state": &"completed"}

	# pilot_009 effect_01：立即弃置目标当前全部该类型受控牌（全弃，持续光环保留）。
	if act_type == &"PILOT_009_DISCARD_ALL_CONTROLLED_TYPE":
		context.game_actions.pilot_009_discard_all_controlled_type(action_def.get("params", {}), payload)
		return {"state": &"completed"}

	# pilot_007 effect_02 类型破绽：算 X+1 写入 payload.pilot_007_flaw_count（供后续 EXECUTE_DISCARD/GAIN_CARD 取 count）。
	if act_type == &"PILOT_007_COMPUTE_X":
		context.game_actions.pilot_007_compute_x(action_def.get("params", {}), payload)
		return {"state": &"completed"}

	# pilot_044 索伦：记录绑定机甲所有区域损伤总数 X（写 payload[store_key]=X，可选写 X+1）。
	# params 含 $binding_context 等表达式，先 _resolve_atomic_params 解析再交 GameActions。
	if act_type == &"PILOT_044_COMPUTE_DAMAGE":
		var p044_params: Dictionary = _resolve_atomic_params(action_def.get("params", {}), payload, parent_action)
		context.game_actions.pilot_044_compute_damage(p044_params, payload)
		return {"state": &"completed"}

	# pilot_034 effect_02：记录对我方造成过伤害的其他机甲（来源解析见 GameActions）。
	if act_type == &"PILOT_034_RECORD_DAMAGE_SOURCE":
		context.game_actions.pilot_034_record_damage_source(action_def.get("params", {}), payload)
		return {"state": &"completed"}

	# pilot_035 库马斯 effect_02：设置本轮标记机甲（选其他机甲）。需 payload.binding_context + target_id。
	if act_type == &"PILOT_035_SET_MARK":
		var p035_bind: Dictionary = payload.get("binding_context", {})
		var p035_source: StringName = p035_bind.get("card_instance_id", &"")
		var p035_target: StringName = payload.get("target_id", payload.get("target_mech_id", &""))
		if p035_source != &"" and p035_target != &"":
			_ActionPilotEffects.set_pilot_035_mark(p035_source, p035_target)
		return {"state": &"completed"}

	# pilot_035 库马斯 effect_01：轮始清除本轮标记（上轮选择不延续 / 取消选择则本轮不监听）。
	if act_type == &"PILOT_035_CLEAR_MARK":
		var p035cb: Dictionary = payload.get("binding_context", {})
		var p035_csrc: StringName = p035cb.get("card_instance_id", &"")
		if p035_csrc != &"":
			_ActionPilotEffects.clear_pilot_035_mark(p035_csrc)
		return {"state": &"completed"}

	# 通用：在来源牌实例 counters 上设键值（开关型效果：银雪 pilot_066 拦截开关等）。
	# params 含 $binding_context 等表达式时先解析；card_instance_id 缺省回退 binding_context。
	if act_type == &"SET_CARD_COUNTER":
		var scc_params: Dictionary = _resolve_atomic_params(action_def.get("params", {}), payload, parent_action)
		context.game_actions.set_card_counter(scc_params, payload)
		return {"state": &"completed"}

	# 通用：累积「下次攻击加成」（影刹 pilot_069 等）。TURN_END 时读机甲本回合攻击/移动状态，
	# 条件满足则累加来源牌实例 counters 上的加成计数（威力/范围）。跨回合可叠加。
	# 不在此时清空——清空由 APPLY 之后的 ATTACK_SETTLE 用 SET_CARD_COUNTER 置 0（取消攻击时保留）。
	# 参数化可复制：mech_id/card_instance_id（$binding_context）、might_key/might_delta（未攻击累加）、
	#   range_key/range_delta + range_when_moved_at_most（移动不超过阈值累加）由 params 指定，复用改参即可。
	if act_type == &"ACCUMULATE_NEXT_ATTACK_BONUS":
		var nab_params: Dictionary = _resolve_atomic_params(action_def.get("params", {}), payload, parent_action)
		var nab_mid: StringName = StringName(nab_params.get("mech_id", &""))
		var nab_cid: StringName = StringName(nab_params.get("card_instance_id", &""))
		if nab_cid == &"":
			nab_cid = StringName(payload.get("binding_context", {}).get("card_instance_id", &""))
		var nab_mech: Variant = null
		var nab_card: Variant = null
		if context != null and context.game_state != null:
			nab_mech = context.game_state.mechs.get(nab_mid) if nab_mid != &"" else null
			nab_card = context.game_state.cards.get(nab_cid) if nab_cid != &"" else null
		if nab_mech != null and nab_card != null:
			if not "counters" in nab_card:
				nab_card.counters = {}
			var nab_mkey: String = String(nab_params.get("might_key", &""))
			if nab_mkey != "" and not nab_mech.has_attacked_this_turn:
				var nab_md: int = int(nab_params.get("might_delta", 0))
				if nab_md != 0:
					nab_card.counters[nab_mkey] = int(nab_card.counters.get(nab_mkey, 0)) + nab_md
					SLog.log_raw("[ACTION] ACCUMULATE_NEXT_ATTACK_BONUS 威力+%d（本回合未攻击）mech=%s" % [nab_md, String(nab_mid)])
			var nab_rkey: String = String(nab_params.get("range_key", &""))
			# 注册"下次攻击范围加成"计数器键：攻击前置检查（app_root._get_weapon_range）需把
			# 待用加成计入武器射程，否则范围+1 只在实际攻击时生效、攻击牌预检仍按基础射程判
			# "无可用目标"（影刹 pilot_069 等）。任何带 range_key 的该 act_type 效果自动生效。
			if nab_rkey != "":
				_ActionPilotEffects.register_next_attack_range_key(nab_rkey)
			var nab_rlimit: int = int(nab_params.get("range_when_moved_at_most", -1))
			if nab_rkey != "" and nab_rlimit >= 0 and nab_mech.cells_moved_this_turn <= nab_rlimit:
				var nab_rd: int = int(nab_params.get("range_delta", 0))
				if nab_rd != 0:
					nab_card.counters[nab_rkey] = int(nab_card.counters.get(nab_rkey, 0)) + nab_rd
					SLog.log_raw("[ACTION] ACCUMULATE_NEXT_ATTACK_BONUS 范围+%d（移动%d≤%d）mech=%s" % [nab_rd, nab_mech.cells_moved_this_turn, nab_rlimit, String(nab_mid)])
		return {"state": &"completed"}

	# 通用：应用「下次攻击加成」（影刹 pilot_069 等）。ATTACK_BEFORE 时读来源牌计数器，
	# 累加进目标 attack record 的 extra_might/extra_range（选目标前生效，双连 fork 深拷贝继承）。
	# 不清空——取消攻击时加成保留；攻击完全结算（ATTACK_SETTLE）后由 SET_CARD_COUNTER 置 0。
	if act_type == &"APPLY_NEXT_ATTACK_BONUS":
		var ap_target = parent_action
		if ap_target == null or ap_target.action_type != &"attack":
			var ap_attack_id: StringName = payload.get("attack_action_id", &"")
			if String(ap_attack_id) == "" and parent_action != null:
				ap_attack_id = parent_action.record.get("attack_action_id", &"")
			if String(ap_attack_id) != "" and context != null and context.action_registry != null:
				ap_target = context.action_registry.get_action(ap_attack_id)
		if ap_target != null:
			var ap_params: Dictionary = _resolve_atomic_params(action_def.get("params", {}), payload, parent_action)
			var ap_cid: StringName = StringName(ap_params.get("card_instance_id", &""))
			if ap_cid == &"":
				ap_cid = StringName(payload.get("binding_context", {}).get("card_instance_id", &""))
			if context != null and context.game_state != null and ap_cid != &"":
				var ap_card = context.game_state.cards.get(ap_cid)
				if ap_card != null:
					if not "counters" in ap_card:
						ap_card.counters = {}
					var ap_mkey: String = String(ap_params.get("might_key", &""))
					var ap_mn: int = int(ap_card.counters.get(ap_mkey, 0)) if ap_mkey != "" else 0
					if ap_mn != 0:
						ap_target.record["extra_might"] = int(ap_target.record.get("extra_might", 0)) + ap_mn
						SLog.log_raw("[ACTION] APPLY_NEXT_ATTACK_BONUS 威力+%d（应用计数器）" % ap_mn)
					var ap_rkey: String = String(ap_params.get("range_key", &""))
					var ap_rn: int = int(ap_card.counters.get(ap_rkey, 0)) if ap_rkey != "" else 0
					if ap_rn != 0:
						ap_target.record["extra_range"] = int(ap_target.record.get("extra_range", 0)) + ap_rn
						SLog.log_raw("[ACTION] APPLY_NEXT_ATTACK_BONUS 范围+%d（应用计数器）" % ap_rn)
		return {"state": &"completed"}

	# 通用：累积「近战弃牌威力加成」（泰特 pilot_073 等）。来源牌实例 × 机甲分离存储
	# _melee_buff[source_cid][mech_id] 计数（泰特自己与他机各自独立）。与效果绑定不绑机师。
	if act_type == &"ACCUMULATE_MELEE_MIGHT":
		var am_params: Dictionary = _resolve_atomic_params(action_def.get("params", {}), payload, parent_action)
		_ActionPilotEffects.add_melee_buff(
			StringName(am_params.get("source_cid", &"")),
			StringName(am_params.get("mech_id", &"")),
			int(am_params.get("delta", 0))
		)
		return {"state": &"completed"}

	# 通用：应用「近战弃牌威力加成」（泰特 pilot_073 等）。ATTACK_BEFORE 读 _melee_buff 计数
	# 累加进目标 attack record 的 extra_might（选目标前生效，双连 fork 深拷贝继承）。
	# 不清空——近战攻击结算（ATTACK_SETTLE）由 CLEAR_MELEE_MIGHT 消耗（取消攻击保留）。
	if act_type == &"APPLY_MELEE_MIGHT":
		var apm_target = parent_action
		if apm_target == null or apm_target.action_type != &"attack":
			var apm_attack_id: StringName = payload.get("attack_action_id", &"")
			if String(apm_attack_id) == "" and parent_action != null:
				apm_attack_id = parent_action.record.get("attack_action_id", &"")
			if String(apm_attack_id) != "" and context != null and context.action_registry != null:
				apm_target = context.action_registry.get_action(apm_attack_id)
		if apm_target != null:
			var apm_params: Dictionary = _resolve_atomic_params(action_def.get("params", {}), payload, parent_action)
			var apm_n: int = _ActionPilotEffects.get_melee_buff(
				StringName(apm_params.get("source_cid", &"")),
				StringName(apm_params.get("mech_id", &""))
			)
			if apm_n != 0:
				apm_target.record["extra_might"] = int(apm_target.record.get("extra_might", 0)) + apm_n
				SLog.log_raw("[ACTION] APPLY_MELEE_MIGHT 威力+%d（近战弃牌加成）mech=%s" % [apm_n, String(apm_params.get("mech_id", &""))])
		return {"state": &"completed"}

	# 通用：清空「近战弃牌威力加成」（泰特 pilot_073 等）。近战攻击结算（ATTACK_SETTLE）后
	# 消耗一次（取消攻击保留）；自己回合结束后（TURN_AFTER_END）清空"本回合"待发。
	if act_type == &"CLEAR_MELEE_MIGHT":
		var clm_params: Dictionary = _resolve_atomic_params(action_def.get("params", {}), payload, parent_action)
		_ActionPilotEffects.clear_melee_buff(
			StringName(clm_params.get("source_cid", &"")),
			StringName(clm_params.get("mech_id", &""))
		)
		return {"state": &"completed"}

	# 通用：授予目标机甲「近战弃牌威力加成」效果（泰特 pilot_073 等）。
	# 向目标机甲注册 DIRECT 按钮（虚拟时点）+ 隐藏 LISTEN（ATTACK_BEFORE 应用/ATTACK_SETTLE 消耗/
	# TURN_AFTER_END 清空），binding 打 granted=true 标记（equipment_panel EX 按钮通用检测）。
	# 记录到 _melee_grant_mechs 供到期注销。
	if act_type == &"GRANT_MELEE_MIGHT":
		var gm_params: Dictionary = _resolve_atomic_params(action_def.get("params", {}), payload, parent_action)
		_ActionPilotEffects.grant_melee_might_to_mech(context,
			StringName(gm_params.get("source_cid", &"")),
			StringName(gm_params.get("target_mech_id", &""))
		)
		return {"state": &"completed"}

	# 通用：到期注销「近战弃牌威力加成」授予（泰特 pilot_073 等）。
	# 来源下个回合开始后（TURN_AFTER_START）注销目标机甲 DIRECT+隐藏 LISTEN，清待发威力（EX 消失）。
	if act_type == &"EXPIRE_MELEE_MIGHT":
		var em_params: Dictionary = _resolve_atomic_params(action_def.get("params", {}), payload, parent_action)
		_ActionPilotEffects.expire_melee_might_grants(context,
			StringName(em_params.get("source_cid", &""))
		)
		return {"state": &"completed"}

	# 通用：累加玩家"回合开始抽取行动牌数加成"（艾希 pilot_061 等"回合开始抽牌+X"效果）。
	# 参数走 _resolve_atomic_params 支持 $binding_context 表达式；player_id 缺省回退 binding_context。
	if act_type == &"SET_TURN_START_DRAW_BONUS":
		var tdb_params: Dictionary = _resolve_atomic_params(action_def.get("params", {}), payload, parent_action)
		context.game_actions.set_turn_start_draw_bonus(tdb_params, payload)
		return {"state": &"completed"}

	# pilot_002 effect_01：登记批次转化权限（接收者获一次性"当作具名牌使用"权限）。
	if act_type == &"GRANT_TRANSFER_BATCH_AS_NAMED_TYPE":
		var p002_grant_params: Dictionary = _resolve_atomic_params(action_def.get("params", {}), payload, parent_action)
		context.game_actions.pilot_002_grant_transfer_batch(p002_grant_params, payload)
		return {"state": &"completed"}

	# pilot_002 effect_01：转移行动牌到目标手牌（card_ids/target_mech_id 可能是 $runtime/$payload，需解析）。
	if act_type == &"TRANSFER_ACTION_CARDS":
		var p002_xfer_params: Dictionary = _resolve_atomic_params(action_def.get("params", {}), payload, parent_action)
		# target_mech_id -> to_player_id 转换（transfer_action_cards 按 player 转移手牌）
		if not p002_xfer_params.has("to_player_id") and p002_xfer_params.has("target_mech_id"):
			var p002_to_mid: StringName = p002_xfer_params["target_mech_id"]
			if p002_to_mid != &"" and context.game_state != null:
				var p002_to_player = context.game_state.get_player_for_mech(p002_to_mid)
				if p002_to_player != null:
					p002_xfer_params["to_player_id"] = p002_to_player.player_id
		# batch_tag：标记转移的牌（pilot_002 批次不可拆分）
		var p002_batch_tag: StringName = p002_xfer_params.get("batch_tag", &"")
		if p002_batch_tag != &"":
			var p002_card_ids: Array = p002_xfer_params.get("card_ids", [])
			for p002_cid in p002_card_ids:
				var p002_c = context.game_state.get_card(p002_cid) if context.game_state != null else null
				if p002_c != null:
					if not "counters" in p002_c:
						p002_c.counters = {}
					p002_c.counters["pilot_002_batch_tag"] = p002_batch_tag
		context.game_actions.transfer_action_cards(p002_xfer_params)
		return {"state": &"completed"}

	# pilot_003 effect_01：将手牌正面朝上随机插入行动牌堆。
	if act_type == &"INSERT_ACTION_CARDS_FACE_UP_RANDOM":
		var p003_ins_params: Dictionary = _resolve_atomic_params(action_def.get("params", {}), payload, parent_action)
		context.game_actions.pilot_003_insert_face_up_random(p003_ins_params, payload)
		return {"state": &"completed"}

	# pilot_003 effect_03：切换跳过正面牌设置。
	if act_type == &"TOGGLE_PILOT_003_SKIP":
		context.game_actions.toggle_pilot_003_skip(action_def.get("params", {}), payload)
		return {"state": &"completed"}

	# pilot_003 effect_03 复选框提交：整组覆盖跳过玩家集合（need_input resume 后执行）。
	if act_type == &"SET_PILOT_003_SKIP_PLAYERS":
		context.game_actions.set_pilot_003_skip_players(action_def.get("params", {}), payload)
		return {"state": &"completed"}

	# pilot_003 effect_02：IMMEDIATELY_USE_DECK_CARD_OR_FALLBACK —— 由瑟尔基尔拥有者立即完整使用；
	# 无法合法使用（迎击牌/攻击牌无合法武器目标/机甲不可用）则公开弃置该牌 + 拥有者抽1。
	if act_type == &"IMMEDIATELY_USE_DECK_CARD_OR_FALLBACK":
		var iu_params: Dictionary = _resolve_atomic_params(action_def.get("params", {}), payload, parent_action)
		_handle_pilot_003_immediately_use(iu_params)
		return {"state": &"completed"}

	# pilot_012/013 effect_01：SET_ACTION_RECORD_FLAG
	# 真写入 attack 动作 record["_effect_flags"][flag] = {value, data}。
	# effect_02(AFTER) 读此 flag 判断 effect_01 是否发动；fork 深拷贝 record（attack_action.gd _create_fork_sub_action
	# 用 record.duplicate(true)）故 flag 继承到各复制攻击，使双连多目标的每个 fork AFTER 都能触发命中奖励。
	# （requires_effect 查同 action_id，fork 子动作 id 不同 -> 在 fork 上失效，故 e02 改靠 flag 而非 requires_effect。）
	if act_type == &"SET_ACTION_RECORD_FLAG":
		var sarf_params: Dictionary = _resolve_atomic_params(action_def.get("params", {}), payload, parent_action)
		var sarf_flag: StringName = sarf_params.get("flag", &"")
		if sarf_flag == &"":
			return {"state": &"completed"}
		var sarf_value = sarf_params.get("value", true)
		var sarf_data: Dictionary = sarf_params.get("data", {})
		# 定位 attack 动作：e01 在 ATTACK_PRE 触发，parent_action 即 attack；兜底 action_id/attack_action_id。
		var sarf_atk = parent_action
		if sarf_atk == null or sarf_atk.action_type != &"attack":
			var sarf_aid: StringName = sarf_params.get("action_id", payload.get("attack_action_id", payload.get("action_id", &"")))
			if String(sarf_aid) != "" and context.action_registry != null:
				sarf_atk = context.action_registry.get_action(sarf_aid)
		if sarf_atk == null:
			push_warning("SET_ACTION_RECORD_FLAG: 无攻击动作，无法写入 flag=%s" % String(sarf_flag))
			return {"state": &"completed"}
		if not sarf_atk.record.has("_effect_flags"):
			sarf_atk.record["_effect_flags"] = {}
		sarf_atk.record["_effect_flags"][sarf_flag] = {"value": sarf_value, "data": sarf_data}
		SLog.log_raw("[ACTION] SET_ACTION_RECORD_FLAG flag=%s value=%s on %s" % [String(sarf_flag), str(sarf_value), String(sarf_atk.action_id)])
		return {"state": &"completed"}

	# pilot_013 effect_02b：MODIFY_ATTACK_DAMAGE 改本次攻击对当前命中目标的 damage 记录 +3。
	# 不另开 DEAL_DAMAGE -> 仍属攻击产生伤害（不被 effect_01 非攻击伤害免疫拦截）。
	# 仿 MODIFY_ATTACK_MARKERS：定位 attack 动作（parent 或 payload.attack_action_id），写 record["damage"]。
	# 单目标直接改 record["damage"]（_step_apply_damage 读此值）；双连另写 damage_by_target[target]。
	if act_type == &"MODIFY_ATTACK_DAMAGE":
		var mad_params: Dictionary = _resolve_atomic_params(action_def.get("params", {}), payload, parent_action)
		var mad_target: StringName = mad_params.get("target_id", &"")
		var mad_delta: int = int(mad_params.get("delta", 0))
		var mad_min: int = int(mad_params.get("min_value", 0))
		var mad_atk = parent_action
		if mad_atk == null or mad_atk.action_type != &"attack":
			var mad_aid: StringName = payload.get("attack_action_id", payload.get("action_id", &""))
			if String(mad_aid) != "" and context.action_registry != null:
				mad_atk = context.action_registry.get_action(mad_aid)
		if mad_atk == null:
			push_warning("MODIFY_ATTACK_DAMAGE: 无攻击动作，无法写入 damage")
			return {"state": &"completed"}
		# 单目标：改 record["damage"]（_step_apply_damage 读取并入 HP 变动）
		var mad_prev: int = int(mad_atk.record.get("damage", 0))
		mad_atk.record["damage"] = max(mad_min, mad_prev + mad_delta)
		# 双连 per-target map（双连闭环后 _step_calculate_damage 写入 damage_by_target）
		if not mad_atk.record.has("damage_by_target"):
			mad_atk.record["damage_by_target"] = {}
		if mad_target != &"":
			var mad_pt_prev: int = int(mad_atk.record["damage_by_target"].get(mad_target, mad_prev))
			mad_atk.record["damage_by_target"][mad_target] = max(mad_min, mad_pt_prev + mad_delta)
		SLog.log_raw("[ACTION] %s damage %+d (累计=%d, target=%s)" % [String(mad_atk.action_id), mad_delta, int(mad_atk.record.get("damage", 0)), String(mad_target)])
		return {"state": &"completed"}

	# 提比里安 pilot_021 effect_01（弃甲铸威）：PILOT_022_APPLY_POWER_BONUS
	# 我方回合1次，弃置1张武器装备牌 -> 该武器牌面威力每5点 → 本回合下次攻击威力+3。
	# 威力加成存 PILOT_022_POWER_BONUS 状态（stacks=X，duration=1），由状态监听器在下次
	# ATTACK_PRE 注入 extra_might 后移除；回合结束经 DECREMENT_STATUS_DURATION 兜底清除。
	# 弃置走 EXECUTE_DISCARD（效果2 弃置原因），本动作只算 X 并施加/累加状态。
	if act_type == &"PILOT_022_APPLY_POWER_BONUS":
		var p022a_params: Dictionary = _resolve_atomic_params(action_def.get("params", {}), payload, parent_action)
		var p022a_weapon_ids: Array = p022a_params.get("card_ids", payload.get("pilot_021_weapon", []))
		var p022a_mech: StringName = p022a_params.get("mech_id", payload.get("source_mech_id", payload.get("mech_id", &"")))
		if p022a_mech == &"":
			push_warning("PILOT_022_APPLY_POWER_BONUS: 缺少来源机甲")
			return {"state": &"completed"}
		# 取被弃武器装备牌（CHOOSE_MANY_CARDS 已把选中牌存 payload["pilot_021_weapon"]）
		var p022a_might: int = 0
		if p022a_weapon_ids is Array and not p022a_weapon_ids.is_empty():
			var p022a_card = context.game_state.get_card(p022a_weapon_ids[0]) if context.game_state != null else null
			if p022a_card != null and p022a_card.def != null:
				p022a_might = int(p022a_card.def.might) if "might" in p022a_card.def else 0
		var p022a_bonus: int = (p022a_might / 5) * 3
		if p022a_bonus <= 0:
			SLog.log_raw("[ACTION] PILOT_022 弃甲铸威 威力不足5，无加成 might=%d" % p022a_might)
			return {"state": &"completed"}
		# 施加/累加状态：同类型已有则累加 stacks（同回合重复使用），否则新建（走状态监听器注册）。
		var p022a_mech_state = context.game_state.mechs.get(p022a_mech)
		var p022a_existing: Dictionary = {}
		if p022a_mech_state != null:
			for p022a_s: Dictionary in p022a_mech_state.statuses:
				if p022a_s.get("type", &"") == &"PILOT_022_POWER_BONUS":
					p022a_existing = p022a_s
					break
		if not p022a_existing.is_empty():
			p022a_existing["stacks"] = int(p022a_existing.get("stacks", 0)) + p022a_bonus
			context.game_state.write_log(&"status_added", {
				"target_id": String(p022a_mech),
				"status_type": "PILOT_022_POWER_BONUS",
				"delta": p022a_bonus,
				"source_card_id": String(p022a_params.get("source_card_id", &"")),
			})
		else:
			_dispatch_add_status({
				"status_type": &"PILOT_022_POWER_BONUS",
				"duration": 1,
				"stacks": p022a_bonus,
				"target_id": p022a_mech,
				"source_card_id": p022a_params.get("source_card_id", &""),
			}, payload)
		SLog.log_raw("[ACTION] PILOT_022 弃甲铸威 might=%d bonus=%d on %s" % [p022a_might, p022a_bonus, String(p022a_mech)])
		return {"state": &"completed"}

	# 提比里安 pilot_021 effect_02（火力爆发）：PILOT_022_MULTIPLY_ATTACK_MIGHT
	# 本局1次，发动攻击时，初始威力 = 攻击武器原本威力×1.5（向下取整）。
	# 实现为 delta 累加：delta = floor(原威力/2)，extra_might += delta，保留猛击/聚能等其他修正。
	# 原本威力 = 攻击武器牌面威力（不含增减衰减）；范围+3 与锁定由效果定义内 MODIFY_ATTACK_RANGE /
	# FOR_EACH_TARGET+ADD_STATUS 处理。
	if act_type == &"PILOT_022_MULTIPLY_ATTACK_MIGHT":
		var p022m_atk = parent_action
		if p022m_atk == null or p022m_atk.action_type != &"attack":
			var p022m_aid: StringName = payload.get("attack_action_id", payload.get("action_id", &""))
			if String(p022m_aid) != "" and context.action_registry != null:
				p022m_atk = context.action_registry.get_action(p022m_aid)
		if p022m_atk == null:
			push_warning("PILOT_022_MULTIPLY_ATTACK_MIGHT: 无攻击动作")
			return {"state": &"completed"}
		var p022m_weapon_id: StringName = p022m_atk.record.get("weapon_id", &"")
		var p022m_attacker_id: StringName = p022m_atk.record.get("attacker_id", &"")
		var p022m_attacker = context.game_state.mechs.get(p022m_attacker_id) if context.game_state != null else null
		var p022m_printed: int = _pilot_021_printed_weapon_might(p022m_attacker, p022m_weapon_id)
		var p022m_delta: int = p022m_printed / 2  # 向下取整（1.5倍→原威力+原威力/2）
		var p022m_prev: int = int(p022m_atk.record.get("extra_might", 0))
		p022m_atk.record["extra_might"] = p022m_prev + p022m_delta
		SLog.log_raw("[ACTION] %s PILOT_022 火力爆发 原威力=%d delta=%d (extra_might=%d)" % [String(p022m_atk.action_id), p022m_printed, p022m_delta, p022m_prev + p022m_delta])
		return {"state": &"completed"}

	# 提比里安 pilot_021 effect_02 本局1次标记：PILOT_022_MARK_USED
	# 在机师牌实例 counters 写 pilot_021_effect_02_used=true，供 PILOT_022_NOT_USED_THIS_GAME
	# 条件在后续攻击中拦截（本局仅一次）。
	if act_type == &"PILOT_022_MARK_USED":
		var p022u_params: Dictionary = _resolve_atomic_params(action_def.get("params", {}), payload, parent_action)
		var p022u_card_id: StringName = p022u_params.get("card_instance_id", &"")
		if p022u_card_id == &"":
			p022u_card_id = payload.get("card_instance_id", payload.get("card_id", &""))
		# LISTEN 触发时 payload 是攻击 record（无 card_instance_id），来源机师牌实例在 binding_context
		if p022u_card_id == &"" and payload != null and payload.get("binding_context", {}).get("card_instance_id", &"") != &"":
			p022u_card_id = payload.get("binding_context", {}).get("card_instance_id", &"")
		if p022u_card_id != &"" and context.game_state != null:
			var p022u_card = context.game_state.get_card(p022u_card_id)
			if p022u_card != null:
				if not "counters" in p022u_card:
					p022u_card.counters = {}
				p022u_card.counters["pilot_021_effect_02_used"] = true
				SLog.log_raw("[ACTION] PILOT_022 本局1次已标记 on %s" % String(p022u_card_id))
		return {"state": &"completed"}

	# 琳 pilot_024 RE 使用标记：PILOT_024_RE_MARK_USED
	# 请求方点击 RE 即消耗本回合次数（即使琳拒绝也不刷新）。次数存琳 pilot 牌实例
	# counters["pilot_024_re_<requester>_<turn_number>"]，turn_number 每轮递增自动重置。
	if act_type == &"PILOT_024_RE_MARK_USED":
		var p024u_bind: Dictionary = payload.get("binding_context", {}) if payload != null else {}
		var p024u_req: StringName = StringName(p024u_bind.get("mech_id", payload.get("mech_id", payload.get("source_mech_id", &""))))
		if p024u_req != &"" and context.game_state != null:
			_ActionPilotEffects.pilot_024_re_mark_used(context.game_state, p024u_req)
			SLog.log_raw("[ACTION] PILOT_024 RE 已标记使用 requester=%s turn=%d" % [String(p024u_req), int(context.game_state.turn_number)])
		return {"state": &"completed"}

	# 汀兰 pilot_081 RE 使用标记：PILOT_081_RE_MARK_USED
	# 请求方点击 RE 即消耗本回合次数（持有者拒绝也不刷新）。次数存请求方所属玩家
	# once_per_turn_used["pilot_081_re_<mech>"]，TURN_START 清零 -> 每「请求方回合」1 次；
	# 存于请求方而非持有者 -> 多持有者时拒绝 H1 后 H2 本回合亦不可用。
	if act_type == &"PILOT_081_RE_MARK_USED":
		var p081u_bind: Dictionary = payload.get("binding_context", {}) if payload != null else {}
		var p081u_req: StringName = StringName(p081u_bind.get("mech_id", payload.get("mech_id", payload.get("source_mech_id", &""))))
		if p081u_req != &"" and context.game_state != null:
			_ActionPilotEffects.pilot_081_re_mark_used(context.game_state, p081u_req)
			SLog.log_raw("[ACTION] PILOT_081 RE 已标记使用 requester=%s turn=%d" % [String(p081u_req), int(context.game_state.turn_number)])
		return {"state": &"completed"}

	# 瓦恩 pilot_083 RE 使用标记：PILOT_083_RE_MARK_USED
	# 请求方点击 RE 即消耗本回合次数（持有者拒绝也不刷新）。次数存请求方所属玩家
	# once_per_turn_used["pilot_083_re_<mech>"]，TURN_START 清零 -> 每「请求方回合」1 次；
	# 存于请求方而非持有者 -> 多持有者时拒绝 H1 后 H2 本回合亦不可用。接受请求不消耗瓦恩效果1额度。
	if act_type == &"PILOT_083_RE_MARK_USED":
		var p083u_bind: Dictionary = payload.get("binding_context", {}) if payload != null else {}
		var p083u_req: StringName = StringName(p083u_bind.get("mech_id", payload.get("mech_id", payload.get("source_mech_id", &""))))
		if p083u_req != &"" and context.game_state != null:
			_ActionPilotEffects.pilot_083_re_mark_used(context.game_state, p083u_req)
			SLog.log_raw("[ACTION] PILOT_083 RE 已标记使用 requester=%s turn=%d" % [String(p083u_req), int(context.game_state.turn_number)])
		return {"state": &"completed"}

	# pilot_015 effect_01b：PILOT_015_FORCE_PURE_ASSAULT
	# 设 pilot_015_force_pure_assault flag 到当前 attack（parent_action）+ 根 attack（fork 场景同时标根）。
	# trigger B 在 ATTACK_AT 补跑阶段触发，parent_action 可能是 fork；遍历 parent_action_id 链到根 attack，
	# 全部置 flag。这样当前 fork 的 ATTACK_AFTER/SETTLE 额外效果被剥离 + 还原威力，
	# 且根 attack 的 _create_next_fork 读 flag 清空后续 fork 队列（双连仅完成当前 fork）。
	if act_type == &"PILOT_015_FORCE_PURE_ASSAULT":
		var p015_atk = parent_action
		if p015_atk == null or p015_atk.action_type != &"attack":
			var p015_aid: StringName = payload.get("attack_action_id", payload.get("action_id", &""))
			if String(p015_aid) != "" and context.action_registry != null:
				p015_atk = context.action_registry.get_action(p015_aid)
		if p015_atk == null:
			push_warning("PILOT_015_FORCE_PURE_ASSAULT: 无攻击动作")
			return {"state": &"completed"}
		var p015_flagged: Array = []
		var p015_cur = p015_atk
		# 沿 parent_action_id 链向上，所有 attack 动作置 flag（当前 fork + 根 attack）
		while p015_cur != null:
			if not p015_cur.record.has("_effect_flags"):
				p015_cur.record["_effect_flags"] = {}
			p015_cur.record["_effect_flags"][&"pilot_015_force_pure_assault"] = {"value": true, "data": {}}
			p015_flagged.append(String(p015_cur.action_id))
			var p015_pid: StringName = p015_cur.parent_action_id
			if String(p015_pid) == "" or context.action_registry == null:
				break
			var p015_parent = context.action_registry.get_action(p015_pid)
			if p015_parent == null or p015_parent.action_type != &"attack":
				break
			p015_cur = p015_parent
		SLog.log_raw("[ACTION] PILOT_015_FORCE_PURE_ASSAULT on %s" % str(p015_flagged))
		return {"state": &"completed"}

	# pilot_015 effect_01c：PILOT_015_REPLACE_COUNTER_AS_DEFEND
	# 视为机制（同刻托 REPLACE_USED_ACTION_EFFECT_BY_SEQUENCE / 莱比尔 as_card_def_id）：
	# 设 use_action_card record["as_card_def_id"]=action_009_防御，使 step②/③ 按防御效果链执行。
	# parent_action 即 use_action_card 动作（USE_ACTION_BEFORE 的 parent 是 use_action_card 本身）。
	if act_type == &"PILOT_015_REPLACE_COUNTER_AS_DEFEND":
		var p015r_params: Dictionary = _resolve_atomic_params(action_def.get("params", {}), payload, parent_action)
		var p015r_as_id: StringName = p015r_params.get("as_card_def_id", &"action_009_防御")
		var p015r_use = parent_action
		if p015r_use == null or p015r_use.action_type != &"use_action_card":
			var p015r_aid: StringName = payload.get("action_id", &"")
			if String(p015r_aid) != "" and context.action_registry != null:
				p015r_use = context.action_registry.get_action(p015r_aid)
		if p015r_use == null:
			push_warning("PILOT_015_REPLACE_COUNTER_AS_DEFEND: 无 use_action_card 动作")
			return {"state": &"completed"}
		p015r_use.record["as_card_def_id"] = p015r_as_id
		SLog.log_raw("[ACTION] PILOT_015_REPLACE_COUNTER_AS_DEFEND 视为 %s on %s" % [String(p015r_as_id), String(p015r_use.action_id)])
		return {"state": &"completed"}

	# pilot_001 effect_01：重复执行行动牌效果链（克隆 DIRECT effect，不重发 USE_ACTION_*，attack 不计攻击数）。
	# 裁定：迎击牌不可重复（条件拦截）；第2次重新选目标；失败不返还次数；repeat_depth 防递归。
	if act_type == &"REPEAT_USED_ACTION_EFFECT_CHAIN":
		var rp_payload: Dictionary = payload.duplicate()
		rp_payload["repeat_depth"] = int(payload.get("repeat_depth", 0)) + 1
		var rp_card_id: StringName = payload.get("card_instance_id", &"")
		var rp_action_id: StringName = payload.get("action_id", &"")
		if rp_card_id != &"" and rp_action_id != &"" and context.action_registry != null:
			var rp_source_action = context.action_registry.get_action(rp_action_id)
			var rp_card = context.game_state.get_card(rp_card_id)
			if rp_source_action != null and rp_card != null and rp_card.def != null:
				# 重新收集 bind_to_sub LISTEN 效果，使第二次 DIRECT 产生的新 attack 也能注册并触发 effect2
				# （阿克罗姆完整重跑 effect1+effect2：闪击再攻/破甲命中破甲/猛击威力+4 在第二次均生效）。
				# 第一次 _register_pending_listeners_on_sub 注册后已 erase _pending_listen_effects，此处重填。
				if rp_source_action.has_method(&"refill_bind_to_sub_pending_effects"):
					rp_source_action.refill_bind_to_sub_pending_effects(rp_card_id)
				var rp_mappings: Array = _GeneratedActionEffects.get_effects_for_card(rp_card.def.card_id)
				var rp_all_effects: Dictionary = _GeneratedActionEffects.build_all_effects()
				for mapping in rp_mappings:
					var eid: StringName = mapping.get("effect_id", &"") if mapping is Dictionary else &""
					var eff = rp_all_effects.get(eid)
					if eff != null and eff.mode == &"DIRECT":
						context.timing_engine._execute_effect(eff, rp_payload, rp_source_action)
		return {"state": &"completed"}

	# 特殊处理 MODIFY_ATTACK_MARKERS：把 delta 累加到攻击动作（attack A）的 record["extra_markers"]。
	# LISTEN 效果（破甲 effect2 / 联邦左腿）在 attack A 时点触发，parent_action 即 attack A，直接写。
	# DIRECT 效果（防御 effect1）在 use_action_card 里执行，parent_action 是 use_action_card，
	# 需经 payload.attack_action_id 定位原 attack A--否则 -1 写到 use_action_card record，
	# 攻击动作 _step_apply_damage 读自己的 extra_markers(=0) 读不到（旧 bug：防御 -1 损伤失效）。
	# 时点翻转后 ATTACK_AFTER fire 在 _step_calculate_damage handler 之后，extra_markers 由
	# _step_apply_damage（step7，fire 之后）读取并入 markers，统一一次损伤放置。
	if act_type == &"MODIFY_ATTACK_MARKERS":
		var target_action = parent_action
		if target_action == null or target_action.action_type != &"attack":
			var mk_attack_id: StringName = payload.get("attack_action_id", &"")
			if mk_attack_id != &"" and context.action_registry != null:
				target_action = context.action_registry.get_action(mk_attack_id)
		if target_action == null:
			push_warning("MODIFY_ATTACK_MARKERS: 无攻击动作，无法写入 extra_markers")
			return {"state": &"completed"}
		var params_mk: Dictionary = action_def.get("params", {})
		var delta: int = int(params_mk.get("delta", payload.get("delta", 0)))
		# fork_persist=true（洛尔恩 pilot_063 效果2「掩护后损伤-1」）：写入 fork_extra_markers 而非
		# extra_markers。多目标 fork 深拷贝主攻击 record 时会清除 extra_markers（独立结算各目标），
		# 但保留 fork_extra_markers，使「本次掩护对双连的每个复制攻击都生效」。
		# attack_action._step_apply_damage 读取 extra_markers + fork_extra_markers 合并应用。
		if bool(params_mk.get("fork_persist", false)):
			var prev_fork: int = int(target_action.record.get("fork_extra_markers", 0))
			target_action.record["fork_extra_markers"] = prev_fork + delta
			SLog.log_raw("[ACTION] %s fork_extra_markers %+d (累计=%d)" % [String(target_action.action_id), delta, prev_fork + delta])
			return {"state": &"completed"}
		var prev: int = int(target_action.record.get("extra_markers", 0))
		target_action.record["extra_markers"] = prev + delta
		SLog.log_raw("[ACTION] %s extra_markers +%d (累计=%d)" % [String(target_action.action_id), delta, prev + delta])
		return {"state": &"completed"}

	# 特殊处理 SET_ATTACK_NO_RESPONSE：把攻击动作（attack A）的 record["no_response"]=true。
	# 洛尔恩 pilot_063 效果2「掩护后该攻击不能被响应」：掩护经 use_action_card 打出，
	# 在 USE_ACTION_AFTER 触发，parent_action 是 use_action_card，需经 payload.attack_action_id
	# 定位原 attack A（仿 MODIFY_ATTACK_MARKERS）。写入后 fire_timing(ATTACK_AT) 检查
	# action.record.no_response 抑制响应窗口（迎击/识破都不弹）。多目标 fork 深拷贝 record
	# 快照时保留 no_response，双连的每个复制攻击都继承不可响应。
	if act_type == &"SET_ATTACK_NO_RESPONSE":
		var nr_target_action = parent_action
		if nr_target_action == null or nr_target_action.action_type != &"attack":
			var nr_attack_id: StringName = payload.get("attack_action_id", &"")
			if String(nr_attack_id) == "" and parent_action != null:
				nr_attack_id = parent_action.record.get("attack_action_id", &"")
			if String(nr_attack_id) != "" and context != null and context.action_registry != null:
				nr_target_action = context.action_registry.get_action(nr_attack_id)
		if nr_target_action == null:
			push_warning("SET_ATTACK_NO_RESPONSE: 无攻击动作，无法写入 no_response")
			return {"state": &"completed"}
		nr_target_action.record["no_response"] = true
		SLog.log_raw("[ACTION] %s no_response=true（本次攻击不可被响应）" % String(nr_target_action.action_id))
		return {"state": &"completed"}

	# 特殊处理 MODIFY_ATTACK_MIGHT：把 delta 累加到父动作（attack A）的 record["extra_might"]。
	# 猛击 effect2（+4）/掩护 effect1（-5）在 attack A 的 ATTACK_BEFORE/ATTACK_AT 时点触发，
	# 此时 parent_action 就是 attack A。_step_calculate_damage 读取 weapon_might + extra_might
	# 算进攻击威力。仿 MODIFY_ATTACK_MARKERS 范式，绕过 modify_attack_power 的旧字典写入
	# （新攻击流程不设 current_attack_id、不写 game_state.attacks，modify_attack_power 会空返）。
	if act_type == &"MODIFY_ATTACK_MIGHT":
		# 定位目标 attack：优先 parent_action（ATTACK_BEFORE/PRE 等时点 parent 即 attack A）；
		# parent 非 attack（如 effect_035 在 use_action_card.USE_ACTION_AT 执行，parent 是
		# use_action_card）时，经 payload.attack_action_id 定位原 attack（迎击响应路径注入），
		# 仿 MODIFY_ATTACK_MARKERS。否则 -4 写到 use_action_card record，attack 读不到。
		var might_target = parent_action
		if might_target == null or might_target.action_type != &"attack":
			var might_attack_id: StringName = payload.get("attack_action_id", &"")
			if String(might_attack_id) == "" and parent_action != null:
				might_attack_id = parent_action.record.get("attack_action_id", &"")
			if String(might_attack_id) != "" and context != null and context.action_registry != null:
				might_target = context.action_registry.get_action(might_attack_id)
		if might_target == null:
			push_warning("MODIFY_ATTACK_MIGHT: 无攻击动作，无法写入 extra_might")
			return {"state": &"completed"}
		var params_might: Dictionary = action_def.get("params", {})
		var might_delta: int = int(params_might.get("delta", payload.get("delta", 0)))
		var might_prev: int = int(might_target.record.get("extra_might", 0))
		might_target.record["extra_might"] = might_prev + might_delta
		SLog.log_raw("[ACTION] %s extra_might %+d (累计=%d)" % [String(might_target.action_id), might_delta, might_prev + might_delta])
		return {"state": &"completed"}

	# 特殊处理 MODIFY_ATTACK_RANGE：把 delta 累加到目标 attack 动作的 record["extra_range"]。
	# 狙击头部（+1）/近战头部（-2）在 ATTACK_BEFORE 时点触发，parent_action 即 attack A；
	# 冰魄 pilot_060 e01 在 use_action_card.USE_ACTION_AT（迎击响应）触发，parent_action 是
	# use_action_card，此时经 payload.attack_action_id 定位原 attack（仿 MODIFY_ATTACK_MIGHT）。
	# _step_select_target/_step_check_hit 读取 weapon_range + extra_range 做范围/命中判断。
	# 支持 min_value 钳制（近战头部/冰魄范围最低1）。
	if act_type == &"MODIFY_ATTACK_RANGE":
		var range_target = parent_action
		if range_target == null or range_target.action_type != &"attack":
			var range_attack_id: StringName = payload.get("attack_action_id", &"")
			if String(range_attack_id) == "" and parent_action != null:
				range_attack_id = parent_action.record.get("attack_action_id", &"")
			if String(range_attack_id) != "" and context != null and context.action_registry != null:
				range_target = context.action_registry.get_action(range_attack_id)
		if range_target == null:
			push_warning("MODIFY_ATTACK_RANGE: 无攻击动作，无法写入 extra_range")
			return {"state": &"completed"}
		var params_range: Dictionary = action_def.get("params", {})
		var range_delta: int = int(params_range.get("delta", payload.get("delta", 0)))
		var range_prev: int = int(range_target.record.get("extra_range", 0))
		var new_extra: int = range_prev + range_delta
		# min_value 钳制：最终有效范围 = weapon_range + extra_range 不低于 min_value
		var min_value: int = int(params_range.get("min_value", 0))
		if min_value > 0:
			var base_range: int = int(range_target.record.get("weapon_range", 1))
			var effective: int = base_range + new_extra
			if effective < min_value:
				new_extra = min_value - base_range  # 钳制到 min_value
		range_target.record["extra_range"] = new_extra
		SLog.log_raw("[ACTION] %s extra_range %+d (累计=%d)" % [String(range_target.action_id), range_delta, new_extra])
		return {"state": &"completed"}

	# 特殊处理 SET_ATTACK_EFFECTIVE_WEAPON_KIND：改写父动作（attack A）的 effective_weapon_type。
	# 近战装·头部效果（ATTACK_BEFORE priority 20）把非近战武器转为近战，供后续近战威力+2效果识别。
	if act_type == &"SET_ATTACK_EFFECTIVE_WEAPON_KIND":
		if parent_action == null:
			push_warning("SET_ATTACK_EFFECTIVE_WEAPON_KIND: 无父动作")
			return {"state": &"completed"}
		var params_wk: Dictionary = action_def.get("params", {})
		var new_kind: StringName = params_wk.get("weapon_kind", &"")
		if new_kind != &"":
			parent_action.record["effective_weapon_type"] = new_kind
			SLog.log_raw("[ACTION] %s effective_weapon_type → %s" % [String(parent_action.action_id), String(new_kind)])
		return {"state": &"completed"}

	# ── 装备牌效果专用原效果动作特判（C-H 阶段）──

	# DISCARD_SELF_AND_REDUCE_ATTACK_MARKERS：弃置本牌 + 减少本次攻击 markers
	# 联邦左腿（effect_007）被命中时弃自身减最多2损伤。减值写 parent_action record["extra_markers"] 负值。
	if act_type == &"DISCARD_SELF_AND_REDUCE_ATTACK_MARKERS":
		if parent_action == null:
			push_warning("DISCARD_SELF_AND_REDUCE_ATTACK_MARKERS: 无父动作")
			return {"state": &"completed"}
		var dsr_params: Dictionary = action_def.get("params", {})
		var dsr_max_reduce: int = int(dsr_params.get("max_reduce", 1))
		# 减值直接取 max_reduce（玩家"最多"减，此处自动减满；未来可扩为弹窗选1..max_reduce）
		var dsr_prev: int = int(parent_action.record.get("extra_markers", 0))
		parent_action.record["extra_markers"] = dsr_prev - dsr_max_reduce
		SLog.log_raw("[ACTION] %s extra_markers -%d" % [String(parent_action.action_id), dsr_max_reduce])
		# 弃置本牌（走 discard_card 动作发时点，reason=effect_self_discard）
		var dsr_bind_ctx: Dictionary = payload.get("binding_context", {})
		var dsr_card_id: StringName = dsr_bind_ctx.get("card_instance_id", payload.get("card_instance_id", &""))
		if dsr_card_id != &"" and context.deck_service != null:
			_clear_equipped_card_from_slot(dsr_card_id)
			context.deck_service.discard_card(dsr_card_id, &"effect_self_discard")
		return {"state": &"completed"}

	# DRAW_EQUIPMENT_AND_IMMEDIATELY_SET：抽1张装备牌顶 → 立即设置到本牌原区域（区域空时）
	# 联邦左臂/近战左腿（effect_005）离场诱发。简化版：抽装备牌到装备手牌，若原区域空则自动 set_equipment。
	if act_type == &"DISCARD_SELF_FROM_SLOT":
		var dsf_bind_ctx: Dictionary = payload.get("binding_context", {})
		var dsf_card_id: StringName = dsf_bind_ctx.get("card_instance_id", payload.get("card_instance_id", &""))
		if dsf_card_id != &"" and context.deck_service != null:
			_clear_equipped_card_from_slot(dsf_card_id)
			context.deck_service.discard_card(dsf_card_id, &"effect_self_discard")
			SLog.log_raw("[ACTION] DISCARD_SELF_FROM_SLOT 弃置 %s" % String(dsf_card_id))
		else:
			push_warning("DISCARD_SELF_FROM_SLOT: 缺 card_instance_id 或 deck_service")
		return {"state": &"completed"}

	# DRAW_EQUIPMENT_AND_IMMEDIATELY_SET 已移至 TimingEngine._execute_actions 拦截
	# （抽装备->玩家选合法区域设置；取消/无合法区域则弃置抽到的牌 reason=effect_unset_discard）

	# OFFER_DAMAGE_REDIRECT：损伤转移汇总弹窗（A6）
	# 不在此特判——由 TimingEngine._execute_actions 拦截并挂起弹窗（同 CHOOSE_ONE 范式），
	# 因为它需要玩家输入（选转移点数），原效果动作无法暂停。提交后写 parent_action.record["redirect_plan"]。
	# _is_atomic_action 仍保留 true 以阻止创建效果动作实例。
	if act_type == &"OFFER_DAMAGE_REDIRECT":
		return {"state": &"completed"}  # 占位：实际由 TimingEngine 拦截，不会走到这

	# 特殊处理 RESPOND_ATTACK：把"被响应"信息写回原 attack 动作的 record。
	# 迎击牌 effect1 在 use_action_card 的 _step_execute_effects 里执行，parent_action 是 use_action_card，
	# 故需从 payload.attack_action_id 定位原 attack 动作（handle_response_selection 发起 use_action_card 时注入）。
	if act_type == &"RESPOND_ATTACK":
		var attack_id_ra: StringName = payload.get("attack_action_id", &"")
		if attack_id_ra == &"" or context.action_registry == null:
			push_warning("RESPOND_ATTACK: 缺少 attack_action_id")
			return {"state": &"completed"}
		var attack_action = context.action_registry.get_action(attack_id_ra)
		if attack_action == null:
			push_warning("RESPOND_ATTACK: 找不到攻击动作 %s" % String(attack_id_ra))
			return {"state": &"completed"}
		attack_action.record["responded"] = true
		# counter_attacked 仅迎击牌(is_counter_card=true/缺省)置真；装备响应(如一角兽右腿 effect_084
		# is_counter_card=false)不算迎击，损伤仍由攻击方放置（assault-noncounter-response 双参数语义）。
		var ra_is_counter: bool = bool(action_def.get("params", {}).get("is_counter_card", true))
		if ra_is_counter:
			attack_action.record["counter_attacked"] = true
		var ra_card_id: StringName = payload.get("card_instance_id", payload.get("source_card_id", &""))
		attack_action.record["response_card_id"] = ra_card_id
		attack_action.record["response_source"] = {
			"player_id": payload.get("player_id", &""),
			"mech_id": payload.get("source_mech_id", payload.get("mech_id", &"")),
			"card_instance_id": ra_card_id,
		}
		SLog.log_raw("[ACTION] %s 被 %s 响应(迎击)" % [String(attack_id_ra), String(ra_card_id)])
		return {"state": &"completed"}

	# 特殊处理 REDIRECT_ATTACK_TARGET_TO_SELF：pilot_011 effect_02 挡攻转移。
	# 将本次攻击的目标改为迪恩自身（保护被攻击的相邻友军）。写回原 attack 动作 record：
	# target_id（单目标）/ target_ids（多目标中匹配项）。旧目标存入 _redirect_from 供回滚。
	# parent_action 通常是 attack（响应窗口 _execute_actions 直传）；否则用 payload.attack_action_id 定位。
	if act_type == &"REDIRECT_ATTACK_TARGET_TO_SELF":
		var rdt_attack = parent_action
		if rdt_attack == null or rdt_attack.action_type != &"attack":
			var rdt_aid: StringName = payload.get("attack_action_id", &"")
			if rdt_aid != &"" and context.action_registry != null:
				rdt_attack = context.action_registry.get_action(rdt_aid)
		if rdt_attack == null:
			push_warning("REDIRECT_ATTACK_TARGET_TO_SELF: 找不到攻击动作")
			return {"state": &"completed"}
		var rdt_bind: Dictionary = payload.get("binding_context", {})
		var rdt_protector: StringName = rdt_bind.get("mech_id", payload.get("source_mech_id", payload.get("mech_id", &"")))
		if rdt_protector == &"":
			push_warning("REDIRECT_ATTACK_TARGET_TO_SELF: 缺少 protector mech_id")
			return {"state": &"completed"}
		# 被保护目标：优先 params.protect_target_id（可为 $payload.target_id 表达式，需解析），
		# 否则 payload.target_id，否则 attack.record.target_id
		var rdt_params_a: Dictionary = action_def.get("params", {})
		var rdt_protected_raw = rdt_params_a.get("protect_target_id", payload.get("target_id", rdt_attack.record.get("target_id", &"")))
		var rdt_protected: StringName = _resolve_atomic_value(rdt_protected_raw, payload, parent_action)
		if String(rdt_protected) == "":
			rdt_protected = rdt_protector  # 兜底：无明确被保护目标时视为自身（无操作）
		# 记录原目标供 RESTORE 回滚（仅单目标路径）
		if not rdt_attack.record.has("_redirect_from"):
			rdt_attack.record["_redirect_from"] = String(rdt_protected)
		# 单目标：替换 target_id
		if StringName(rdt_attack.record.get("target_id", &"")) == StringName(rdt_protected):
			rdt_attack.record["target_id"] = rdt_protector
		# 多目标：替换 target_ids 中匹配项
		if rdt_attack.record.has("target_ids"):
			var rdt_tids: Array = rdt_attack.record["target_ids"]
			for rdt_i in range(rdt_tids.size()):
				if StringName(rdt_tids[rdt_i]) == StringName(rdt_protected):
					rdt_tids[rdt_i] = rdt_protector
			rdt_attack.record["target_ids"] = rdt_tids
		SLog.log_raw("[ACTION] %s 目标转移: %s -> %s(迪恩)" % [String(rdt_attack.action_id), String(rdt_protected), String(rdt_protector)])
		# 标记需要回退 ATTACK_PRE 重 fire：转移目标=迪恩后，让迪恩的 PRE 装备被动（如「被攻击时」）
		# 重新触发（原 PRE 对友军 fire，迪恩 PRE 监听器检查 self==target 未触发）。
		# 回退由 ActionEngine._execute_step 阶段4 检测标志执行（回退到 PRE 步，phase=timing_firing 跳过
		# select_target handler 重 fire PRE；推进 ATTACK_AT 时 _execute_attack_ran 幂等 + responded=true 不弹窗）。
		rdt_attack.record["_redirect_rewind"] = true
		return {"state": &"completed"}

	# 特殊处理 RESTORE_REDIRECTED_ATTACK_TARGET：pilot_011 effect_02 回滚（虚拟具名链提交失败时还原目标）。
	# 最小闭环下挡攻转移一旦提交不回滚；此动作为占位 no-op，保留 actions 链兼容拆解文档。
	if act_type == &"RESTORE_REDIRECTED_ATTACK_TARGET":
		if parent_action != null and parent_action.action_type == &"attack":
			var rra_from = parent_action.record.get("_redirect_from", &"")
			if rra_from != &"":
				parent_action.record["target_id"] = StringName(rra_from)
				parent_action.record.erase("_redirect_from")
		return {"state": &"completed"}

	# 特殊处理 MODIFY_ATTACK_TEMP_ARMOR：防御牌护甲+5，写原 attack 动作的 temporary_armor_bonus。
	# _step_calculate_damage 读 action.record["temporary_armor_bonus"]，故必须写到 attack record（非 use_action_card）。
	if act_type == &"MODIFY_ATTACK_TEMP_ARMOR":
		var attack_id_ta: StringName = payload.get("attack_action_id", &"")
		if attack_id_ta == &"" or context.action_registry == null:
			push_warning("MODIFY_ATTACK_TEMP_ARMOR: 缺少 attack_action_id")
			return {"state": &"completed"}
		var ta_action = context.action_registry.get_action(attack_id_ta)
		if ta_action == null:
			push_warning("MODIFY_ATTACK_TEMP_ARMOR: 找不到攻击动作 %s" % String(attack_id_ta))
			return {"state": &"completed"}
		var ta_params: Dictionary = action_def.get("params", {})
		var ta_delta: int = int(ta_params.get("delta", payload.get("delta", 0)))
		var ta_prev: int = int(ta_action.record.get("temporary_armor_bonus", 0))
		ta_action.record["temporary_armor_bonus"] = ta_prev + ta_delta
		SLog.log_raw("[ACTION] %s temporary_armor_bonus %+d (累计=%d)" % [String(attack_id_ta), ta_delta, ta_prev + ta_delta])
		return {"state": &"completed"}

	# 特殊处理 ADD_MECH_TEMP_ARMOR：防御牌护甲+5，写到机甲 temp_armor_bonus（get_armor 计入，
	# 装备面板可见）。同时在攻击动作 record["temp_armor_grants"] 登记，供 attack_action._step_cleanup
	# 在 ATTACK_SETTLE 后恢复（防御结算后恢复护甲数值）。替代旧 MODIFY_ATTACK_TEMP_ARMOR：
	# 旧法把 +5 藏在 attack record.temporary_armor_bonus，面板不可见、效果不明显。
	if act_type == &"ADD_MECH_TEMP_ARMOR":
		var amt_params: Dictionary = action_def.get("params", {})
		# mech_id 优先取 params.mech_id（可为 $binding_context.mech_id 表达式，pilot_002 防御分支
		# 经响应窗口触发时 payload.mech_id 是莱比尔自身机甲，须显式指定被授予机甲 A）。
		var amt_mech_id: StringName = &""
		if amt_params.has("mech_id"):
			amt_mech_id = _resolve_atomic_value(amt_params.get("mech_id", &""), payload, parent_action)
		if String(amt_mech_id) == "":
			amt_mech_id = payload.get("source_mech_id", payload.get("mech_id", &""))
		if amt_mech_id == &"" or context.game_state == null:
			push_warning("ADD_MECH_TEMP_ARMOR: 缺少 mech_id")
			return {"state": &"completed"}
		var amt_mech = context.game_state.mechs.get(amt_mech_id)
		if amt_mech == null:
			push_warning("ADD_MECH_TEMP_ARMOR: 找不到机甲 %s" % String(amt_mech_id))
			return {"state": &"completed"}
		var amt_delta: int = int(amt_params.get("delta", payload.get("delta", 0)))
		amt_mech.temp_armor_bonus += amt_delta
		# 登记到攻击动作，供 _step_cleanup 结算后恢复
		var amt_attack_id: StringName = payload.get("attack_action_id", &"")
		if amt_attack_id != &"" and context.action_registry != null:
			var amt_attack = context.action_registry.get_action(amt_attack_id)
			if amt_attack != null:
				if not amt_attack.record.has("temp_armor_grants"):
					amt_attack.record["temp_armor_grants"] = []
				amt_attack.record["temp_armor_grants"].append({"mech_id": amt_mech_id, "delta": amt_delta})
		SLog.log_raw("[ACTION] %s 机甲 %s temp_armor_bonus %+d (累计=%d)" % [String(amt_attack_id), String(amt_mech_id), amt_delta, amt_mech.temp_armor_bonus])
		return {"state": &"completed"}

	# ── 武器装备牌效果专用特判（effect_093+）──

	# APPLY_ENERGY_TO_WEAPON：把聚能目标武器写回父 effect_fire 动作 record，
	# 供 EFFECT_FIRE_AFTER 时点的武器聚能联动效果（effect_093/095/114/126）经
	# ENERGY_TARGET_IS_SELF 条件读取。parent_action 即 effect_fire 动作。
	# selected_weapon_id 由 CHOOSE_OWN_WEAPON 目标选择注入 payload。
	if act_type == &"APPLY_ENERGY_TO_WEAPON":
		var aetw_weapon: StringName = payload.get("selected_weapon_id", payload.get("weapon_id", &""))
		if aetw_weapon == &"":
			var aetw_p: Dictionary = action_def.get("params", {})
			aetw_weapon = aetw_p.get("weapon_id", aetw_p.get("target_card_instance_id", &""))
			if String(aetw_weapon).begins_with("$"):
				aetw_weapon = _resolve_atomic_value(aetw_weapon, payload, parent_action)
		if aetw_weapon != &"" and parent_action != null and parent_action.record is Dictionary:
			parent_action.record["energy_target_weapon_instance_id"] = aetw_weapon
			# fire EFFECT_FIRE_AFTER 触发武器聚能联动效果（effect_093/095/114/126 监听此点）。
			# 聚能经 use_action_card 执行（不发 EFFECT_FIRE_AFTER），故在此补 fire。
			# payload=parent_action.record.duplicate() 含 energy_target_weapon_instance_id。
			if context != null and context.timing_engine != null:
				# fire_timing 在 action.state=waiting_timing 时跳过；resume 重跑 _execute_effect 时
				# use_action_card 仍处 waiting_timing，需临时设 running 让 fire 生效，再恢复。
				var _saved_state: StringName = parent_action.state
				parent_action.state = &"running"
				context.timing_engine.fire_timing(&"EFFECT_FIRE_AFTER", parent_action)
				parent_action.state = _saved_state

	# INCREMENT_VARIABLE scope=attack：写父动作 record["variables"][name]，
	# 供同动作后续时点经 VARIABLE_ABOVE(scope=attack) 读取（effect_106/108/117 及武器「之后」自损
	# effect_102b/130b/131b/134b/135b/137b 等）。parent 可为 attack 或 effect_fire 等（不限定 action_type，
	# payload = record.duplicate() 故 payload.variables 可读）。
	if act_type == &"INCREMENT_VARIABLE":
		var iv_params: Dictionary = action_def.get("params", {})
		var iv_scope: StringName = iv_params.get("scope", &"")
		if iv_scope == &"attack" and parent_action != null:
			var iv_name: StringName = iv_params.get("variable_name", &"")
			var iv_delta: int = int(iv_params.get("delta", 1))
			if iv_name != &"":
				if not parent_action.record.has("variables"):
					parent_action.record["variables"] = {}
				var iv_prev: int = int(parent_action.record["variables"].get(iv_name, 0))
				parent_action.record["variables"][iv_name] = iv_prev + iv_delta
				return {"state": &"completed"}
		# pilot_008 X 绑 card_instance_id + max_value：传 payload 让 increment_variable 从 binding_context 取
		if iv_params.has("source_card_instance_id") or iv_params.has("max_value"):
			context.game_actions.increment_variable(iv_params, payload)
			return {"state": &"completed"}

	# SET_ATTACK_MIGHT_FROM_PRINTED_WEAPON：本次攻击威力覆盖为 牌面威力+bonus，
	# 忽略本牌损伤惩罚（effect_121 大型光束炮回复全值+2）。仅改本次 attack.record["weapon_might"]。
	if act_type == &"SET_ATTACK_MIGHT_FROM_PRINTED_WEAPON":
		var sam_params: Dictionary = action_def.get("params", {})
		var sam_wid: StringName = sam_params.get("weapon_instance_id", sam_params.get("target_card_instance_id", &""))
		if String(sam_wid).begins_with("$"):
			sam_wid = _resolve_atomic_value(sam_wid, payload, parent_action)
		var sam_bonus: int = int(sam_params.get("bonus", 0))
		var sam_target = parent_action
		if sam_target == null or sam_target.action_type != &"attack":
			var sam_atk_id: StringName = payload.get("attack_action_id", &"")
			if sam_atk_id != &"" and context.action_registry != null:
				sam_target = context.action_registry.get_action(sam_atk_id)
		if sam_target != null and sam_wid != &"" and context.game_state != null:
			var sam_card = context.game_state.get_card(sam_wid)
			if sam_card != null and sam_card.def != null:
				var printed: int = int(sam_card.def.might) if "might" in sam_card.def else 0
				sam_target.record["weapon_might"] = printed + sam_bonus
				SLog.log_raw("[ACTION] %s weapon_might 覆盖为 牌面%d+bonus%d=%d" % [String(sam_target.action_id), printed, sam_bonus, printed + sam_bonus])
		return {"state": &"completed"}

	# SET_WEAPON_MODE：设置武器形态（流星钢锤 effect_098/099）。refresh_parent_attack=true 时
	# 同步刷新当前 attack 的基础 weapon_might/weapon_range（只替换 base，不重叠 extra）。
	if act_type == &"SET_WEAPON_MODE":
		var swm_params: Dictionary = action_def.get("params", {})
		var swm_wid: StringName = swm_params.get("target_card_instance_id", swm_params.get("weapon_id", &""))
		if String(swm_wid).begins_with("$"):
			swm_wid = _resolve_atomic_value(swm_wid, payload, parent_action)
		var swm_mode: StringName = swm_params.get("mode", &"normal")
		if swm_wid != &"" and context.game_state != null:
			var swm_card = context.game_state.get_card(swm_wid)
			if swm_card != null:
				swm_card.weapon_mode = swm_mode
				SLog.log_raw("[ACTION] SET_WEAPON_MODE %s -> %s" % [String(swm_wid), String(swm_mode)])
				if bool(swm_params.get("refresh_parent_attack", false)) and parent_action != null and parent_action.action_type == &"attack":
					var swm_attacker_id: StringName = parent_action.record.get("attacker_id", &"")
					var swm_attacker = context.game_state.mechs.get(swm_attacker_id) if swm_attacker_id != &"" else null
					if swm_attacker != null:
						var swm_stats: Dictionary = _GenEquipEffects.get_effective_weapon_stats(swm_card)
						parent_action.record["weapon_might"] = int(swm_stats.get("might", 0))
						parent_action.record["weapon_range"] = int(swm_stats.get("range_value", 1)) + _GenEquipEffects.get_passive_weapon_range_bonus(swm_attacker, swm_stats.get("weapon_kind", &""))
		return {"state": &"completed"}

	# PLACE_DAMAGE_TOKENS 强制落点（effect_082/102/105/121/122/129/134/137 等自损/额外损伤强制落本武器槽）：
	# 指定 target_slot(+target_card_instance_id) 时走 place_damage_tokens_on_slot（逐点放、region+card 双计、
	# 不开转移窗、不弹逐点 UI），避免自损误触盾牌转移。无 target_slot 时回退原 place_damage_tokens（弹 UI）。
	if act_type == &"PLACE_DAMAGE_TOKENS":
		var pdt_params: Dictionary = action_def.get("params", {})
		var pdt_slot: StringName = pdt_params.get("target_slot", &"")
		var pdt_card_id: StringName = pdt_params.get("target_card_instance_id", &"")
		if String(pdt_slot).begins_with("$"):
			pdt_slot = _resolve_atomic_value(pdt_slot, payload, parent_action)
		if String(pdt_card_id).begins_with("$"):
			pdt_card_id = _resolve_atomic_value(pdt_card_id, payload, parent_action)
		# 仅有 target_card_instance_id 无 target_slot：从卡实例反查 slot_id
		if pdt_slot == &"" and pdt_card_id != &"" and context.game_state != null:
			var pdt_card = context.game_state.get_card(pdt_card_id)
			if pdt_card != null:
				pdt_slot = pdt_card.slot_id if "slot_id" in pdt_card else &""
		if pdt_slot != &"" and pdt_slot != &"choose_by_executor":
			var pdt_mech: StringName = pdt_params.get("target_mech_id", &"")
			if String(pdt_mech).begins_with("$"):
				pdt_mech = _resolve_atomic_value(pdt_mech, payload, parent_action)
			if pdt_mech == &"":
				pdt_mech = payload.get("source_mech_id", payload.get("mech_id", &""))
			var pdt_count: int = int(pdt_params.get("count", pdt_params.get("amount", 0)))
			if pdt_mech != &"" and pdt_count > 0 and context.game_actions != null:
				context.game_actions.place_damage_tokens_on_slot({"mech_id": pdt_mech, "slot_id": pdt_slot, "amount": pdt_count, "source_card_id": pdt_card_id})
			return {"state": &"completed"}

	# SET_WEAPON_LOCK：拘束钩爪 effect_104 施加/解除锁定。apply 时设 card.lock_target_mech_id=target，
	# 期间 WEAPON_IS_LOCKED_OUT 拦截本牌攻击。目标下一次被任意攻击命中时由 attack_action 清除。
	if act_type == &"SET_WEAPON_LOCK":
		var swl_params: Dictionary = action_def.get("params", {})
		var swl_wid: StringName = swl_params.get("weapon_id", swl_params.get("target_card_instance_id", &""))
		if String(swl_wid).begins_with("$"):
			swl_wid = _resolve_atomic_value(swl_wid, payload, parent_action)
		var swl_target: StringName = swl_params.get("target_id", &"")
		if String(swl_target).begins_with("$"):
			swl_target = _resolve_atomic_value(swl_target, payload, parent_action)
		var swl_mode: StringName = swl_params.get("mode", &"apply")
		if swl_wid != &"" and context.game_state != null:
			var swl_card = context.game_state.get_card(swl_wid)
			if swl_card != null:
				if swl_mode == &"apply":
					swl_card.lock_target_mech_id = swl_target
				else:
					swl_card.lock_target_mech_id = &""
				SLog.log_raw("[ACTION] SET_WEAPON_LOCK %s mode=%s target=%s" % [String(swl_wid), String(swl_mode), String(swl_target)])
		return {"state": &"completed"}

	var params: Dictionary = action_def.get("params", {})
	# 将 payload 中的变量注入 params
	for key in payload:
		if not params.has(key):
			params[key] = payload[key]

	# 特殊处理NEGATE_ATTACK：设置攻击动作的negated标志
	# 识破 effect2 在 use_action_card 里执行，parent 是 use_action_card，需用 attack_action_id 定位原 attack；
	# 其它路径（破甲等）parent_action 即 attack，退回用 parent_action。
	if act_type == &"NEGATE_ATTACK":
		var attack_id_neg: StringName = payload.get("attack_action_id", &"")
		var neg_target = null
		if attack_id_neg != &"" and context.action_registry != null:
			neg_target = context.action_registry.get_action(attack_id_neg)
		if neg_target == null:
			neg_target = parent_action
		if neg_target != null and not neg_target.unnegatable:
			neg_target.negated = true
			SLog.log_raw("[ACTION] %s 被识破，攻击无效" % String(neg_target.action_id))
		return {"state": &"completed"}

	# 特殊处理SET_ATTACK_UNNEGATABLE
	if act_type == &"SET_ATTACK_UNNEGATABLE":
		if parent_action != null:
			parent_action.unnegatable = true
		return {"state": &"completed"}

	# 特殊处理CANCEL_PARENT_ACTION：沿parent链向上找指定类型祖先并取消（递归清理子树）
	# 联合effect2选"弃牌抽1张"后中断父use_action_card动作（不算真正使用）
	# scope=CURRENT_ACTION（pilot_013 effect_01）：仅取消当前生命变动动作（hp_change）本身，
	# 不沿链找祖先、不取消来源效果中的其他动作/损伤/后续步骤（preserve_source_parent_action）。
	if act_type == &"CANCEL_PARENT_ACTION":
		var cancel_params: Dictionary = action_def.get("params", {})
		var cancel_scope: StringName = cancel_params.get("scope", &"")
		if cancel_scope == &"CURRENT_ACTION":
			if parent_action != null and context.action_engine != null:
				context.action_engine.cancel_action(parent_action.action_id)
			return {"state": &"completed"}
		var target_type: StringName = cancel_params.get("target", &"use_action_card")
		var ancestor = parent_action
		while ancestor != null:
			if ancestor.action_type == target_type:
				if context.action_engine != null:
					context.action_engine.cancel_action(ancestor.action_id)
				break
			ancestor = context.action_registry.get_action(ancestor.parent_action_id) if ancestor.parent_action_id != &"" and context.action_registry != null else null
		return {"state": &"completed"}

	# 原子操作内联分发：直接调用 context.game_actions.xxx
	# （原由 effect_core/AtomicActionResolver.resolve 静态分发，现内联以切断对 effect_core 的反向依赖）
	var source_info := _build_source_info_from_parent(parent_action)
	var resolved_params: Dictionary = _resolve_atomic_params(params, payload, parent_action)

	SLog.log_action_step(
		payload.get("action_id", &"") if payload else &"",
		act_type, &"resolve", 0,
		resolved_params, source_info
	)

	_dispatch_atomic_action(act_type, resolved_params, payload, source_info)
	return {"state": &"completed"}


## ── pilot_003 effect_02 离堆强制使用 helper（事后语义）──
## IMMEDIATELY_USE_DECK_CARD_OR_FALLBACK：face_up_bury 牌 zone 从 action_deck 变走时
## （CardInstance.zone setter emit left_action_deck -> _fire_pilot_003_card_leave_deck
##  fire CARD_LEAVE_ACTION_DECK_BEFORE -> effect_02 监听器执行本原子）事后处理。
## 牌此时已进入抽牌者手牌（被抽走，zone=action_hand，owner=抽牌者）或弃牌堆（从牌堆弃置）。
## 流程：移除 face_up_bury 标签 + disconnect 离堆信号 -> 判断对瑟尔基尔是否可用 ->
##   可用：从抽牌者手牌移除 + 重指向 owner=瑟尔基尔 + 进临时区 + use_action_card；
##   不可用：discard_card（已在弃牌堆则跳过）+ 瑟尔基尔抽1。
## 抽牌者不补抽（瑟尔基尔核心玩法）。
func _handle_pilot_003_immediately_use(params: Dictionary) -> void:
	if context == null or context.game_state == null or context.game_actions == null:
		return
	var card_id: StringName = params.get("card_instance_id", &"")
	if card_id == &"":
		return
	var card = context.game_state.get_card(card_id)
	if card == null:
		return
	# 使用者 = 埋牌者（移标签前从 face_up_bury 标签读 owner_pid/mech_id）
	var face_tag: Dictionary = card.get_tag(&"face_up_bury")
	var owner_pid: StringName = StringName(face_tag.get("owner_pid", &""))
	var owner_mech_id: StringName = StringName(face_tag.get("mech_id", &""))
	# 移除标签（防后续 zone 变化再触发）+ disconnect 离堆信号（_p003_mark_face_up 时 connect 的）
	card.remove_tag(&"face_up_bury")
	if context.deck_service != null and card.left_action_deck.is_connected(Callable(context.deck_service, &"_fire_pilot_003_card_leave_deck")):
		card.left_action_deck.disconnect(Callable(context.deck_service, &"_fire_pilot_003_card_leave_deck"))
	# 问题2串行化：若此离堆由 gain_card/discard_card 动作引起，判定延迟到该动作 SETTLE 时点，
	# 作为其子动作串行执行（使父级动作如攻击中抽牌等待判定完成再继续）。非 gain/discard 起因走原即时队列。
	var _p003_cause = _p003_find_cause_action_for_card(card)
	if _p003_cause != null:
		var _p003_cause_id: StringName = _p003_cause.action_id
		if not _p003_deferred_e02_map.has(_p003_cause_id):
			_p003_deferred_e02_map[_p003_cause_id] = []
			# 首次为该 cause 动作注册 SETTLE 临时监听器（effect=pilot_003_e02_deferred）
			var _p003_settle_t: StringName = _p003_settle_timing_for(_p003_cause.action_type)
			if _p003_settle_t != &"" and context.timing_engine != null:
				context.timing_engine.register_temporary_listener(
					_p003_settle_t, _p003_cause_id, _p003_cause.action_type,
					_p003_get_deferred_effect(), &"", &"", {})
		_p003_deferred_e02_map[_p003_cause_id].append({
			"card_id": card_id, "owner_pid": owner_pid, "owner_mech_id": owner_mech_id,
		})
		return  # 不立即处理，等 cause 动作 SETTLE 触发 _run_p003_deferred_judgment
	# 入队串行处理：多张正面牌同时离堆时按离开牌堆顺序先来先执行（先来后到）。
	# force_use 的 use_action_card 若挂起（人类选目标），等其完成后再处理下一张；
	# unusable/同步完成则立即续跑下一张。owner 信息在移标签前已读取，此处保留。
	_p003_e02_queue.append({"card_id": card_id, "owner_pid": owner_pid, "owner_mech_id": owner_mech_id})
	_ensure_p003_e02_signal()
	if not _p003_e02_active:
		_p003_process_next_e02()


## 查找引起本牌离堆的 gain_card/discard_card 动作（当前 running 状态者）。
## 命中 player_id 与卡牌当前持有者一致的优先；否则取首个 running 的 gain/discard 动作。
## 未找到返回 null（非 gain/discard 起因，走原即时队列）。
func _p003_find_cause_action_for_card(card):
	if context == null or context.action_registry == null or card == null:
		return null
	var _fallback = null
	for _fc_aid in context.action_registry.active_actions:
		var _fc_a = context.action_registry.active_actions[_fc_aid]
		if _fc_a == null:
			continue
		if _fc_a.action_type != &"gain_card" and _fc_a.action_type != &"discard_card":
			continue
		if _fc_a.state == &"completed" or _fc_a.state == &"cancelled":
			continue
		var _fc_pid: StringName = _fc_a.record.get("player_id", &"") if _fc_a.record != null else &""
		if _fc_pid != &"" and _fc_pid == card.owner_player_id:
			return _fc_a
		if _fallback == null:
			_fallback = _fc_a
	return _fallback


## cause 动作类型 -> 其 SETTLE 时点。gain_card/discard_card 各自的结算时点。
func _p003_settle_timing_for(action_type: StringName) -> StringName:
	match action_type:
		&"gain_card":
			return _TC.GAIN_CARD_SETTLE
		&"discard_card":
			return _TC.DISCARD_SETTLE
		_:
			return &""


## 惰性构建 pilot_003_e02_deferred 效果（监听 cause 动作 SETTLE，动作=PILOT_003_RUN_DEFERRED_JUDGE）。
## 空条件/目标/费用 -> _execute_effect 直通 _execute_actions -> TimingEngine 的 PILOT_003_RUN_DEFERRED_JUDGE 分支。
func _p003_get_deferred_effect():
	if _p003_deferred_effect != null:
		return _p003_deferred_effect
	var eff := _ActionEffect.new()
	eff.effect_id = &"pilot_003_e02_deferred"
	eff.display_name = "离堆判定串行化"
	eff.description = "正面牌因获取/弃置动作离堆时，延迟到该动作结算时点串行判定。"
	eff.mode = _TC.MODE_LISTEN
	eff.priority = 0
	eff.set_conditions([])
	eff.set_target_rules([{"rule": &"NO_TARGET"}])
	eff.set_costs([])
	eff.set_actions([{"type": &"PILOT_003_RUN_DEFERRED_JUDGE", "params": {}}])
	_p003_deferred_effect = eff
	return eff


## 问题2：在 cause 动作 SETTLE 触发，串行执行延迟的正面牌判定。
## 逐张构建子动作 def（_seq 串行，挂为 cause 动作子动作使其等待）：
##   可用 -> prep（移手牌+改 owner）+ EXECUTE_USE_ACTION_CARD（迎击牌带 attack_action_id 即时响应）；
##   不可用 -> 同步弃置 + EXECUTE_GAIN_CARD（补偿抽，作为子动作串行；其再抽到正面牌自然递归延迟到自身 SETTLE）。
func _run_p003_deferred_judgment(cause_action, payload: Dictionary) -> void:
	if context == null or context.game_state == null or context.timing_engine == null:
		return
	if cause_action == null:
		return
	var cause_id: StringName = cause_action.action_id
	if not _p003_deferred_e02_map.has(cause_id):
		return
	var deferred: Array = _p003_deferred_e02_map[cause_id]
	_p003_deferred_e02_map.erase(cause_id)
	if deferred.is_empty():
		return
	var seq_remaining: Array = []
	for entry in deferred:
		var d_card_id: StringName = entry.get("card_id", &"")
		var d_owner_pid: StringName = entry.get("owner_pid", &"")
		var d_owner_mech_id: StringName = entry.get("owner_mech_id", &"")
		var d_card = context.game_state.get_card(d_card_id)
		if d_card == null:
			continue
		var d_owner_mech = context.game_state.mechs.get(d_owner_mech_id)
		# 即时生效优先：迎击/掩护牌若能响应当前进行中攻击，带 attack_action_id 强制使用。
		var d_imm_aid: StringName = _p003_find_immediate_attack_for_card(d_card, d_owner_mech)
		if d_imm_aid != &"" or _pilot_003_can_use_card(d_card, d_owner_mech):
			_p003_prep_force_use(d_card_id, d_owner_pid)
			var ua_params: Dictionary = {
				"card_instance_id": d_card_id,
				"player_id": d_owner_pid,
				"mech_id": d_owner_mech_id,
				"source_action_id": &"pilot_003_force_use",
				"reason": &"pilot_003_force_use",
				"executor": &"pilot_003_force_use",
			}
			if d_imm_aid != &"":
				ua_params["attack_action_id"] = d_imm_aid
			seq_remaining.append({"type": &"EXECUTE_USE_ACTION_CARD", "params": ua_params})
		else:
			# 不可用：公开弃置（同步）+ 补偿抽（EXECUTE_GAIN_CARD 进 _seq 串行）
			var d_already: bool = d_card.zone == &"discard"
			context.game_state.write_log(&"pilot_003_unusable", {"card_id": String(d_card_id), "player_id": String(d_owner_pid)})
			if not d_already and context.deck_service != null:
				context.deck_service.discard_card(d_card_id, &"pilot_003_unusable_face_up_card")
			seq_remaining.append({
				"type": &"EXECUTE_GAIN_CARD",
				"params": {
					"from_zone": &"action_deck", "card_kind": &"action", "count": 1,
					"player_id": d_owner_pid, "reason": &"pilot_003_unusable_compensation",
				},
			})
	if seq_remaining.is_empty():
		return
	# 设 _seq 并启动首个子动作；子动作挂起则 cause 动作被 fire_timing 置 waiting_effect_action。
	cause_action.record["_seq_effect_actions"] = {"payload": payload, "remaining": seq_remaining}
	context.timing_engine._continue_seq_effect_actions(cause_action)


## force_use 的同步准备部分：从抽牌者手牌移除 + 改 owner=瑟尔基尔（不进手牌，由 use_action_card 移入临时区）。
## 从 _pilot_003_force_use 拆出，供延迟判定路径在 SETTLE 时为每张可用牌预先准备。
func _p003_prep_force_use(card_id: StringName, owner_pid: StringName) -> void:
	if context == null or context.game_state == null:
		return
	var card = context.game_state.get_card(card_id)
	if card == null:
		return
	var drawer_pid: StringName = card.owner_player_id
	if drawer_pid != &"" and drawer_pid != owner_pid:
		var drawer = context.game_state.players.get(drawer_pid)
		if drawer != null:
			drawer.action_hand.erase(card_id)
	card.owner_player_id = owner_pid
	context.game_state.write_log(&"pilot_003_force_use", {"card_id": String(card_id), "player_id": String(owner_pid)})


## 串行处理 effect_02 队列队首：force_use / unusable_discard。
## force_use 的 use_action_card 若挂起（人类选目标/武器），保持 active 等其 action_completed 回调；
## 否则（同步完成 / unusable 弃置+补偿抽）立即递归处理下一张，保证先来后到、全部完成。
## 注：unusable_discard 的补偿抽牌可能再触发本 _handle（入队），此时 active=true 故只入队不处理，
## 待当前 unusable 返回后递归处理新入队的牌。
func _p003_process_next_e02() -> void:
	if _p003_e02_active:
		return  # 上一张 force_use 仍挂起，等 action_completed 回调
	if _p003_e02_queue.is_empty():
		return
	if context == null or context.game_state == null:
		_p003_e02_queue.clear()
		return
	_p003_e02_active = true
	var entry: Dictionary = _p003_e02_queue.pop_front()
	_p003_e02_active_entry = entry
	var card_id: StringName = entry.get("card_id", &"")
	var owner_pid: StringName = entry.get("owner_pid", &"")
	var owner_mech_id: StringName = entry.get("owner_mech_id", &"")
	if owner_pid == &"" or owner_mech_id == &"":
		_pilot_003_unusable_discard(card_id, &"", &"")
		_p003_e02_active = false
		_p003_e02_active_entry = {}
		_p003_process_next_e02()
		return
	var card = context.game_state.get_card(card_id)
	var owner_mech = context.game_state.mechs.get(owner_mech_id)
	# 即时生效：若此牌监听当前进行中攻击（未到判断命中 idx<4）的时点且基本条件满足，
	# 瑟尔基尔强制使用（不弹是否使用窗）。迎击牌带 attack_action_id 让 use_action_card 通过 validate +
	# RESPOND_ATTACK 定位 attack 标记已响应；掩护带 attack_action_id 让 MODIFY_ATTACK_MIGHT 定位 attack -5。
	var _p003_imm_aid: StringName = _p003_find_immediate_attack_for_card(card, owner_mech)
	if _p003_imm_aid != &"":
		_pilot_003_force_use(card_id, owner_pid, owner_mech_id, _p003_imm_aid)
		if _p003_e02_force_action_id != &"" and context.action_registry != null:
			var _p003_imm_ua = context.action_registry.get_action(_p003_e02_force_action_id)
			if _p003_imm_ua != null and (_p003_imm_ua.state == &"waiting_input" or _p003_imm_ua.state == &"waiting_timing" or _p003_imm_ua.state == &"waiting_effect_action"):
				return  # 挂起，等回调
		_p003_e02_force_action_id = &""
		_p003_e02_active = false
		_p003_e02_active_entry = {}
		_p003_process_next_e02()
		return
	if _pilot_003_can_use_card(card, owner_mech):
		_pilot_003_force_use(card_id, owner_pid, owner_mech_id)
		# force_use 创建的 use_action_card 若挂起 -> 等 action_completed 回调（保持 active=true）
		if _p003_e02_force_action_id != &"" and context.action_registry != null:
			var ua = context.action_registry.get_action(_p003_e02_force_action_id)
			if ua != null and (ua.state == &"waiting_input" or ua.state == &"waiting_timing" or ua.state == &"waiting_effect_action"):
				return  # 挂起，等回调
		# 未挂起（同步完成，如无 target 的辅助牌 force_use 直接跑完）-> 续跑下一张
		_p003_e02_force_action_id = &""
		_p003_e02_active = false
		_p003_e02_active_entry = {}
		_p003_process_next_e02()
	else:
		_pilot_003_unusable_discard(card_id, owner_pid, owner_mech_id)
		_p003_e02_active = false
		_p003_e02_active_entry = {}
		_p003_process_next_e02()


## 惰性连接 action_engine.action_completed，监听 force_use 的 use_action_card 完成以续跑队列。
func _ensure_p003_e02_signal() -> void:
	if _p003_e02_signal_connected or context == null or context.action_engine == null:
		return
	var cb := Callable(self, "_on_p003_e02_action_completed")
	if not context.action_engine.action_completed.is_connected(cb):
		context.action_engine.action_completed.connect(cb)
	_p003_e02_signal_connected = true


## force_use 的 use_action_card 完成回调：续跑队列下一张（延迟一帧避免在完成栈中递归 execute）。
func _on_p003_e02_action_completed(action_id: StringName, _action_type: StringName, _record: Dictionary) -> void:
	if action_id == _p003_e02_force_action_id:
		_p003_e02_force_action_id = &""
		_p003_e02_active = false
		_p003_e02_active_entry = {}
		call_deferred("_p003_process_next_e02")


## ── 通用「动作完成钩子」（铠威等「攻击结算后」延迟流程）──

## 惰性连接 action_engine.action_completed，派发 _after_complete_hooks。
func _ensure_after_complete_signal() -> void:
	if _after_complete_signal_connected or context == null or context.action_engine == null:
		return
	var cb := Callable(self, "_on_action_completed_for_hooks")
	if not context.action_engine.action_completed.is_connected(cb):
		context.action_engine.action_completed.connect(cb)
	_after_complete_signal_connected = true


## 登记一个回调，在某动作完成后执行（call_deferred 防止在完成栈中递归 execute 新动作）。
## 回调应携带需要的参数（闭包捕获）。同一 action_id 重复登记：后登记的覆盖先登记的（后者生效）。
func run_after_action_completed(action_id: StringName, cb: Callable) -> void:
	if action_id == &"" or context == null or context.action_engine == null:
		return
	_ensure_after_complete_signal()
	_after_complete_hooks[action_id] = cb


## action_completed 信号回调：匹配钩子并派发。
func _on_action_completed_for_hooks(action_id: StringName, _action_type: StringName, _record: Dictionary) -> void:
	if not _after_complete_hooks.has(action_id):
		return
	var cb: Callable = _after_complete_hooks[action_id]
	_after_complete_hooks.erase(action_id)
	cb.call_deferred()


## 返回当前登记的完成钩子数量（供测试断言钩子已登记/已派发）。
func get_after_complete_hook_count() -> int:
	return _after_complete_hooks.size()


## 返回当前是否登记了指定 action_id 的完成钩子。
func has_after_complete_hook(action_id: StringName) -> bool:
	return _after_complete_hooks.has(action_id)


## 返回当前处于瑟尔基尔 effect_02 判定管线中的全部卡牌条目：
## pending 即时队列 + 当前正在处理的即时牌（已 pop、force_use 可能挂起）+ 延迟 map（待 cause 动作 SETTLE）。
## 每条 {card_id, owner_pid, owner_mech_id}。供 UI（美杜莎操控列表）将这些牌标记为"出现但不可选"。
func get_p003_judging_card_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in _p003_e02_queue:
		out.append(e)
	if not _p003_e02_active_entry.is_empty():
		out.append(_p003_e02_active_entry)
	for cause_id in _p003_deferred_e02_map:
		for e in _p003_deferred_e02_map[cause_id]:
			out.append(e)
	return out


## 预检：离堆正面牌是否可由 owner_mech 立即合法使用。
## 裁定：迎击牌（含 AVAILABILITY 效果）不能凭空开无攻击来源的响应窗口 → 不可用；
## 攻击牌 passive 仍需武器 + 合法范围；机甲 destroyed 不可用。
func _pilot_003_can_use_card(card, owner_mech) -> bool:
	if card == null or card.def == null or card.def.card_kind != &"action":
		return false
	if owner_mech == null or owner_mech.destroyed:
		return false
	var card_mappings: Array = _GeneratedActionEffects.get_effects_for_card(card.def.card_id)
	var all_effects: Dictionary = _GeneratedActionEffects.build_all_effects()
	var has_direct_or_listen := false
	var has_availability := false
	for mapping in card_mappings:
		var eid: StringName = mapping.get("effect_id", &"") if mapping is Dictionary else &""
		var eff = all_effects.get(eid)
		if eff == null:
			continue
		if eff.mode == &"DIRECT" or eff.mode == &"LISTEN":
			has_direct_or_listen = true
		if eff.mode == &"AVAILABILITY":
			has_availability = true
	# 带 AVAILABILITY 的牌只能在其合法响应窗口打出（use_action_card 校验同此）
	if has_availability:
		return false
	if not has_direct_or_listen:
		return false
	# 攻击牌：需至少一把武器能命中至少一个存活敌方（passive 攻击仍占武器/范围）
	if String(card.def.action_type) == "攻击":
		var weapon_ids: Array[StringName] = owner_mech.get_weapon_ids()
		if weapon_ids.is_empty():
			return false
		var map_cells: Dictionary = context.game_state.map_state.cells if context.game_state.map_state else {}
		var _attack_aura: Dictionary = context.map_service.get_attack_aura_cells()
		# 与 attack_action._step_select_target 口径一致：机甲格为路径障碍 + 陷落不可被指定
		var _attack_blocked: Dictionary = context.map_service.get_attack_blocked_keys(owner_mech.mech_id)
		for wid: StringName in weapon_ids:
			var ws: Dictionary = _pilot_003_weapon_stats(owner_mech, wid)
			var w_kind: StringName = ws.get("weapon_kind", &"")
			var w_range: int = int(ws.get("range_value", 1)) + _GenEquipEffects.get_passive_weapon_range_bonus(owner_mech, w_kind)
			w_range = max(1, w_range)
			for mid: StringName in context.game_state.mechs:
				if mid == owner_mech.mech_id:
					continue
				var m = context.game_state.mechs[mid]
				if m == null or m.destroyed:
					continue
				if m.has_status(&"cannot_be_targeted"):
					continue
				if _RangeCalculator.is_in_weapon_range(owner_mech.position, m.position, w_range, map_cells, _attack_aura, _attack_blocked):
					return true
		return false
	# 非攻击辅助牌预检：effect_02 离堆事后处理在自动抽牌中触发（无攻击上下文，但可弹窗让人类选目标）。
	# 裁定（用户）：除以下外都 force_use 可用--锁定/联合（CHOOSE_OTHER_MECH）由人类玩家选目标后使用。
	# 不可用：掩护（MODIFY_ATTACK 依赖攻击上下文）、维修（TARGET_IS_ADJACENT_OR_SELF 选目标+二选一）、
	#   聚能（CHOOSE_OWN_WEAPON 选武器）、弃牌堆空时的回忆/回收（EXECUTE_GAIN_CARD from discard）、
	#   弃牌堆空时的觉醒（AWAKEN_DRAW）。
	for _p003_map in card_mappings:
		var _p003_eid: StringName = _p003_map.get("effect_id", &"") if _p003_map is Dictionary else &""
		var _p003_eff = all_effects.get(_p003_eid)
		if _p003_eff == null or _p003_eff.mode != &"DIRECT":
			continue
		# 维修/聚能等需选目标+后续条件 -> 不可用（锁定/联合 CHOOSE_OTHER_MECH 可由人类选，故放行）
		for _p003_tr in _p003_eff.target_rules:
			var _p003_rule: StringName = _p003_tr.get("rule", &"") if _p003_tr is Dictionary else &""
			if _p003_rule == &"TARGET_IS_ADJACENT_OR_SELF" or _p003_rule == &"CHOOSE_OWN_WEAPON":
				return false
		for _p003_act in _p003_eff.actions:
			var _p003_atype: StringName = _p003_act.get("type", &"") if _p003_act is Dictionary else &""
			# 依赖攻击上下文 -> 不可用（掩护 MODIFY_ATTACK -5）
			if String(_p003_atype).begins_with("MODIFY_ATTACK"):
				return false
			# 回忆/回收：从弃牌堆获取，弃牌堆空 -> 不可用
			if _p003_atype == &"EXECUTE_GAIN_CARD":
				var _p003_gp: Dictionary = _p003_act.get("params", {}) if _p003_act is Dictionary else {}
				var _p003_fz: StringName = _p003_gp.get("from_zone", &"")
				if _p003_fz == &"action_discard" and context.game_state.deck_state.action_discard_pile.is_empty():
					return false
				if _p003_fz == &"equipment_discard" and context.game_state.deck_state.equipment_discard_pile.is_empty():
					return false
			# 觉醒：核心从行动弃牌堆获取，弃牌堆空 -> 不可用
			if _p003_atype == &"AWAKEN_DRAW":
				if context.game_state.deck_state.action_discard_pile.is_empty():
					return false
	return true


## 武器数据（供预检范围判断）：基础武器虚拟 ID 或实体/虚拟武器卡，仅取 range_value/weapon_kind。
func _pilot_003_weapon_stats(attacker, weapon_id: StringName) -> Dictionary:
	var wid_str := String(weapon_id)
	if wid_str.begins_with("frame_base_weapon"):
		var slot_index: int = 0
		if wid_str.begins_with("frame_base_weapon_"):
			slot_index = wid_str.trim_prefix("frame_base_weapon_").to_int() - 1
		var base_weapon: Dictionary = attacker.get_base_weapon(slot_index)
		if not base_weapon.is_empty():
			return {
				"range_value": int(base_weapon.get("range_value", 1)),
				"weapon_kind": base_weapon.get("weapon_kind", &""),
			}
	var weapon_card = context.game_state.get_card(weapon_id)
	if weapon_card and weapon_card.def:
		var eff_stats: Dictionary = _GenEquipEffects.get_effective_weapon_stats(weapon_card)
		return {
			"range_value": int(eff_stats.get("range_value", 1)),
			"weapon_kind": eff_stats.get("weapon_kind", &""),
		}
	return {"range_value": 1, "weapon_kind": &""}


## 强制使用：牌归瑟尔基尔先用，直接走 use_action_card 动作（主动使用），由动作把牌放入瑟尔基尔临时区使用。
## 事后语义：牌在抽牌者手牌（owner=抽牌者）。force_use 先从抽牌者手牌移除 + 改 owner=瑟尔基尔
## （"这个牌就该他先用"；owner==执行者，根本不涉及 pilot_009 受控使用校验），然后直接调
## use_action_card -- 不手动设 temp_zone，由 use_action_card 的 _step_card_to_temp_zone 把牌移入瑟尔基尔临时区。
## passive 攻击，source_action_id 非空跳过攻击数消耗/校验。
## face_up_bury 标签已由 _handle_pilot_003_immediately_use 移除。
## "不拿走" = 不把牌加进瑟尔基尔 action_hand，而是直接进使用流程（临时区->使用->结算弃）。


## 即时生效：为此牌查找一个可即时生效的进行中攻击动作。
## 条件：attack 在 active_actions 且未到判断命中步(current_step_index<4) + 此牌监听该 attack 的时点 + 基本条件满足。
## 迎击牌(AVAILABILITY+AVAIL_RESPOND_ATTACK)：瑟尔基尔自身被攻击(target_id含owner_mech) + 攻击未响应(!responded)。
## 掩护(cover_effect1_direct DIRECT MODIFY_ATTACK_MIGHT)：瑟尔基尔范围内任意机甲被攻击(含自身) + 攻击者≠瑟尔基尔。
## 满足返回 attack_id，否则返回空（回退普通 effect_02 逻辑）。
func _p003_find_immediate_attack_for_card(card, owner_mech) -> StringName:
	if card == null or card.def == null or card.def.card_kind != &"action":
		return &""
	if owner_mech == null or owner_mech.destroyed:
		return &""
	if context == null or context.game_state == null or context.action_registry == null:
		return &""
	var card_mappings: Array = _GeneratedActionEffects.get_effects_for_card(card.def.card_id)
	if card_mappings.is_empty():
		return &""
	var all_effects: Dictionary = _GeneratedActionEffects.build_all_effects()
	# 判定此牌类型：是否迎击牌(有 AVAILABILITY+AVAIL_RESPOND_ATTACK) / 是否掩护(DIRECT MODIFY_ATTACK_MIGHT)
	var is_counter_card := false
	var is_cover_card := false
	for _imm_map in card_mappings:
		var _imm_eid: StringName = _imm_map.get("effect_id", &"") if _imm_map is Dictionary else &""
		var _imm_eff = all_effects.get(_imm_eid)
		if _imm_eff == null:
			continue
		if _imm_eff.mode == _TC.MODE_AVAILABILITY and _imm_eff.availability_condition == _TC.AVAIL_RESPOND_ATTACK:
			is_counter_card = true
		if _imm_eff.mode == _TC.MODE_DIRECT:
			for _imm_act in _imm_eff.actions:
				var _imm_atype: StringName = _imm_act.get("type", &"") if _imm_act is Dictionary else &""
				if _imm_atype == &"MODIFY_ATTACK_MIGHT":
					is_cover_card = true
	if not is_counter_card and not is_cover_card:
		return &""  # 非即时生效牌类
	# 遍历进行中 attack 找符合的
	for _imm_aid in context.action_registry.active_actions:
		var _imm_attack = context.action_registry.active_actions[_imm_aid]
		if _imm_attack == null or _imm_attack.action_type != &"attack":
			continue
		# 未到判断命中步(idx<4)：extract/weapon/target/execute 四步内允许即时生效
		if _imm_attack.current_step_index >= 4:
			continue
		if _imm_attack.state == &"completed" or _imm_attack.state == &"cancelled":
			continue
		var _imm_attacker: StringName = _imm_attack.record.get("attacker_id", &"")
		# 排除瑟尔基尔自身发出的攻击（即时生效只针对他人发动的攻击）
		if _imm_attacker == owner_mech.mech_id:
			continue
		# 收集攻击目标（单目标 target_id + 多目标 target_ids）
		var _imm_targets: Array = []
		var _imm_tid: StringName = _imm_attack.record.get("target_id", &"")
		if _imm_tid != &"":
			_imm_targets.append(_imm_tid)
		for _imm_etid in _imm_attack.record.get("target_ids", []):
			var _imm_etid_sn: StringName = StringName(_imm_etid)
			if _imm_etid_sn != &"":
				_imm_targets.append(_imm_etid_sn)
		if is_counter_card:
			# 迎击：瑟尔基尔自身被攻击 + 攻击未响应
			var _imm_self_targeted := _imm_targets.has(owner_mech.mech_id)
			if not _imm_self_targeted:
				continue
			if bool(_imm_attack.record.get("responded", false)) or bool(_imm_attack.record.get("counter_attacked", false)):
				continue  # 已响应，迎击不可
			return _imm_attack.action_id
		if is_cover_card:
			# 掩护：目标在瑟尔基尔掩护范围内（含自身）。复用 TARGET_IN_COVER_RANGE 逻辑。
			for _imm_ctid in _imm_targets:
				if _p003_target_in_cover_range(_imm_ctid, owner_mech):
					return _imm_attack.action_id
	return &""


## 掩护范围判定：target 是 holder 自身 OR 在 holder 最大武器范围内。
## 仿 ConditionChecker.TARGET_IN_COVER_RANGE，提取为可复用 helper（即时生效不建 EffectBinding）。
func _p003_target_in_cover_range(target_mech_id: StringName, holder_mech) -> bool:
	if holder_mech == null or target_mech_id == &"":
		return false
	if target_mech_id == holder_mech.mech_id:
		return true  # 自身被攻击，掩护可保护自己
	var _tcr_target_mech = context.game_state.mechs.get(target_mech_id)
	if _tcr_target_mech == null:
		return false
	var _tcr_max_range: int = 1
	for _tcr_wid in holder_mech.get_weapon_ids():
		var _tcr_rv: int = 1
		var _tcr_wid_str := String(_tcr_wid)
		if _tcr_wid_str.begins_with("frame_base_weapon_"):
			var _tcr_si: int = _tcr_wid_str.trim_prefix("frame_base_weapon_").to_int() - 1
			var _tcr_bw: Dictionary = holder_mech.get_base_weapon(_tcr_si)
			if not _tcr_bw.is_empty():
				_tcr_rv = int(_tcr_bw.get("range_value", 1))
		else:
			var _tcr_wc = context.game_state.get_card(_tcr_wid)
			if _tcr_wc != null and _tcr_wc.def != null and "range_value" in _tcr_wc.def:
				_tcr_rv = int(_tcr_wc.def.range_value)
		_tcr_max_range = max(_tcr_max_range, _tcr_rv)
	var _tcr_cells: Dictionary = context.game_state.map_state.cells if context.game_state.map_state else {}
	var _tcr_aura: Dictionary = context.map_service.get_attack_aura_cells()
	# 掩护射程同样受机甲障碍影响（与 ConditionChecker.TARGET_IN_COVER_RANGE 口径一致）
	var _tcr_blocked: Dictionary = context.map_service.get_attack_blocked_keys(holder_mech.mech_id)
	return _RangeCalculator.is_in_weapon_range(holder_mech.position, _tcr_target_mech.position, _tcr_max_range, _tcr_cells, _tcr_aura, _tcr_blocked)

func _pilot_003_force_use(card_id: StringName, owner_pid: StringName, owner_mech_id: StringName, attack_action_id: StringName = &"") -> void:
	if context == null or context.action_service == null:
		return
	var card = context.game_state.get_card(card_id)
	if card != null:
		# 从抽牌者手牌移除（owner=抽牌者 != 瑟尔基尔 时）；瑟尔基尔自己抽到自己埋的牌则无需移
		var drawer_pid: StringName = card.owner_player_id
		if drawer_pid != &"" and drawer_pid != owner_pid:
			var drawer = context.game_state.players.get(drawer_pid)
			if drawer != null:
				drawer.action_hand.erase(card_id)
		# 牌归瑟尔基尔先用（owner==执行者，不进 pilot_009 受控使用校验分支，与 009 无关）
		card.owner_player_id = owner_pid
		# 不设 temp_zone：由 use_action_card 的 _step_card_to_temp_zone 放入瑟尔基尔临时区
	context.game_state.write_log(&"pilot_003_force_use", {
		"card_id": String(card_id),
		"player_id": String(owner_pid),
	})
	var _fu_params: Dictionary = {
		"card_instance_id": card_id,
		"player_id": owner_pid,
		"mech_id": owner_mech_id,
		"source_action_id": &"pilot_003_force_use",
		"reason": &"pilot_003_force_use",
		"executor": &"pilot_003_force_use",
	}
	# 即时生效：attack_action_id 作为 execute params 传入（在 record_keys 白名单内，写进 record），
	# 使迎击牌 validate（has_availability 须 attack_action_id 非空）在第一步就通过 + counter_e1 的
	# RESPOND_ATTACK / 掩护 MODIFY_ATTACK_MIGHT 经 payload.attack_action_id 定位 attack。
	if attack_action_id != &"":
		_fu_params["attack_action_id"] = attack_action_id
	var _fu_result: Dictionary = context.action_service.execute(&"use_action_card", _fu_params)
	if attack_action_id != &"" and _fu_result.get("action_id", &"") != &"":
		var _fu_ua = context.action_registry.get_action(_fu_result["action_id"]) if context.action_registry != null else null
		if _fu_ua != null:
			_fu_ua.record["attack_action_id"] = attack_action_id
	# 记录 force_use 创建的 use_action_card id，供 _p003_process_next_e02 判断是否挂起 + 完成回调续跑
	_p003_e02_force_action_id = _fu_result.get("action_id", &"")


## 无法使用回退：公开弃置该正面牌 + 瑟尔基尔拥有者抽1。
## 事后语义：牌在抽牌者手牌（被抽走）或弃牌堆（从牌堆弃置）。discard_card 经
## remove_card_from_all_zones 自动从抽牌者手牌移除入弃牌堆；已在弃牌堆则跳过（不重复弃置
## 致离场效果二次触发）。瑟尔基尔抽1（即使牌已在弃牌堆也抽）。face_up_bury 标签已由
## _handle_pilot_003_immediately_use 移除。
func _pilot_003_unusable_discard(card_id: StringName, owner_pid: StringName, _owner_mech_id: StringName) -> void:
	if context == null or context.game_state == null:
		return
	var card = context.game_state.get_card(card_id)
	var already_discarded: bool = card != null and card.zone == &"discard"
	context.game_state.write_log(&"pilot_003_unusable", {
		"card_id": String(card_id),
		"player_id": String(owner_pid),
	})
	if not already_discarded and context.deck_service != null:
		context.deck_service.discard_card(card_id, &"pilot_003_unusable_face_up_card")
	if owner_pid != &"":
		# 走 gain_card 动作拿 GAIN_CARD 时点（gain_card 委托 draw_action_cards，保留 pilot_003 跳过/effect_02/hook）
		context.action_service.execute(&"gain_card", {
			"from_zone": &"action_deck", "card_kind": &"action", "count": 1,
			"player_id": owner_pid, "reason": &"pilot_003_unusable_compensation"
		})


# ═══════════════════════════════════════════════════════════════════════
# 即时使用（通用机制）
#
# 攻击进行中（未到 check_hit）玩家设置装备 / 抽到行动牌时，若该牌监听 ATTACK_PRE/AT 且
# 基本条件满足，弹出效果窗让玩家即时发动。复用 p003 的检测逻辑（_p003_find_immediate_attack_for_card）。
# 编排容器为 immediate_use 子动作（immediate_use_action.gd），父动作（set_equipment/gain_card）等待其完成。
# ═══════════════════════════════════════════════════════════════════════

## 生成 immediate_use 子动作并挂到 parent_action。items = [{effect, payload}, ...]。
## source 为即时使用发动方来源（{player_id, mech_id, card_instance_id}），供 _execute_effect 日志/播报。
## 返回 true 表示子动作已挂起（父动作应返回 effect_action_created 暂停）；false 表示无条目或同步完成。
func _spawn_immediate_use(parent_action, items: Array, source: Dictionary) -> bool:
	if context == null or context.action_registry == null:
		return false
	if items.is_empty():
		return false
	var imm: Action = _create_action(&"immediate_use", {})
	if imm == null:
		return false
	imm.record["_imm_items"] = items
	imm.record["_imm_index"] = 0
	if not source.is_empty():
		imm.source = source
	context.action_registry.register(imm)
	# 显式登记父子关系（仿 execute_sub_action）
	if parent_action != null:
		imm.parent_action_id = parent_action.action_id
		parent_action.pending_effect_action_ids.append(imm.action_id)
		imm.record["parent_action_id"] = parent_action.action_id
	SLog.log_raw("[IMM_USE] 生成即时使用子动作 %s 父=%s 条目=%d" % [String(imm.action_id), String(parent_action.action_id) if parent_action != null else &"", items.size()])
	context.action_engine.execute_action(imm)
	return _immediate_use_paused(imm)


func _immediate_use_paused(imm) -> bool:
	if imm == null:
		return false
	return imm.state == &"waiting_timing" or imm.state == &"waiting_effect_action"


## 装备即时使用入口（set_equipment._step_activate_equip 注册效果后调用）。
## 若攻击进行中且装备有 LISTEN ATTACK_PRE 效果（该时点已 fire，需补触发），生成补触发条目并 spawn。
## 返回 true 表示已生成挂起的即时使用子动作（调用方应返回 effect_action_created）。
func try_equipment_immediate_use(parent_action, card, mech_id: StringName, slot_id: StringName) -> bool:
	if context == null or context.game_state == null or context.action_registry == null:
		return false
	if card == null or card.def == null:
		return false
	# 备用区白板（face_down）不注册效果，也不补触发
	if card.get("face_down") == true:
		return false
	var attack_id: StringName = _find_ongoing_attack_for_mech(mech_id)
	if attack_id == &"":
		return false
	var items: Array = _build_equipment_immediate_use_items(card, mech_id, slot_id, attack_id)
	if items.is_empty():
		return false
	var source: Dictionary = {
		"player_id": card.owner_player_id,
		"mech_id": mech_id,
		"card_instance_id": card.instance_id,
		"effect_id": &"immediate_use_equipment",
	}
	return _spawn_immediate_use(parent_action, items, source)


## 查找机甲涉及的进行中攻击（未到 check_hit，机甲为攻击方或目标）。复用 p003 的 idx<4 阈值。
func _find_ongoing_attack_for_mech(mech_id: StringName) -> StringName:
	if context == null or context.game_state == null or context.action_registry == null:
		return &""
	if mech_id == &"":
		return &""
	for aid in context.action_registry.active_actions:
		var atk = context.action_registry.active_actions[aid]
		if atk == null or atk.action_type != &"attack":
			continue
		if atk.current_step_index >= 4:  # 已到/过 check_hit，不可即时
			continue
		if atk.state == &"completed" or atk.state == &"cancelled":
			continue
		var attacker: StringName = atk.record.get("attacker_id", &"")
		var involved := (attacker == mech_id)
		if not involved:
			var tgt: StringName = atk.record.get("target_id", &"")
			involved = (tgt == mech_id)
		if not involved:
			for etid in atk.record.get("target_ids", []):
				if StringName(etid) == mech_id:
					involved = true
					break
		if involved:
			return atk.action_id
	return &""


## 收集装备的 LISTEN ATTACK_PRE 效果（该时点已 fire，需补触发），构建即时使用条目。
## ATTACK_AT 效果未 fire，攻击恢复到 ATTACK_AT 步时会正常触发，无需补触发。
func _build_equipment_immediate_use_items(card, mech_id: StringName, slot_id: StringName, attack_id: StringName) -> Array:
	var items: Array = []
	if card == null or card.def == null:
		return items
	var effect_ids: Array = _GenEquipEffects.get_effects_for_card(card.def.card_id, context)
	if effect_ids.is_empty():
		return items
	var all_effects: Dictionary = _GenEquipEffects.build_equipment_effects()
	var atk = context.action_registry.get_action(attack_id) if context.action_registry != null else null
	if atk == null:
		return items
	var player_id: StringName = card.owner_player_id
	var bind_ctx: Dictionary = {
		"card_instance_id": card.instance_id,
		"mech_id": mech_id,
		"player_id": player_id,
		"card_def_id": card.def.card_id,
		"slot_id": slot_id if slot_id != &"" else card.slot_id,
	}
	for effect_id in effect_ids:
		var effect = all_effects.get(effect_id)
		if effect == null:
			continue
		if effect.mode != _TC.MODE_LISTEN:
			continue
		if effect.listen_timing != _TC.ATTACK_PRE:
			continue  # 仅补触发 ATTACK_PRE（已 fire）
		var payload: Dictionary = atk.record.duplicate()
		payload["action_id"] = atk.action_id
		payload["attack_action_id"] = atk.action_id
		payload["action_type"] = atk.action_type
		payload["timing_name"] = String(_TC.ATTACK_PRE)
		payload["binding_context"] = bind_ctx
		items.append({"effect": effect, "payload": payload})
	return items


## 掩护即时使用入口（gain_card._step_settle 抽到行动牌后调用）。
## 对每张新抽到的掩护牌（跳过 p003 延迟处理的正面牌 / AI），若存在可即时生效的进行中攻击，
## 构造合成 CHOOSE_ONE（使用/不使用）效果条目并 spawn。返回 true 表示已生成挂起子动作。
func try_cover_immediate_use(parent_action, drawn_card_ids: Array, player_id: StringName, cause_action_id: StringName) -> bool:
	if context == null or context.game_state == null or context.action_registry == null:
		return false
	if player_id == &"" or drawn_card_ids.is_empty():
		return false
	var player = context.game_state.players.get(player_id)
	if player == null or player.is_human == false:
		return false  # AI 不做即时使用弹窗（用户：先不管 AI 逻辑）
	var owner_mech = context.game_state.get_mech_for_player(player_id)
	if owner_mech == null:
		return false
	var items: Array = []
	for card_id in drawn_card_ids:
		var card_id_sn: StringName = StringName(card_id)
		var card = context.game_state.get_card(card_id_sn)
		if card == null or card.def == null or card.def.card_kind != &"action":
			continue
		# 跳过 p003 延迟处理的正面牌（避免与 p003 force_use 双重处理）
		if _is_p003_deferred_card(cause_action_id, card_id_sn):
			continue
		# 仅掩护可即时使用（counter 迎击走响应窗口；这里只处理掩护 DIRECT MODIFY_ATTACK_MIGHT）
		if not _is_cover_action_card(card):
			continue
		var attack_id: StringName = _p003_find_immediate_attack_for_card(card, owner_mech)
		if attack_id == &"":
			continue
		var eff = _make_cover_instant_use_effect(card_id_sn, player_id, owner_mech.mech_id, attack_id)
		if eff == null:
			continue
		var payload: Dictionary = {
			"action_id": cause_action_id,
			"attack_action_id": attack_id,
			"binding_context": {
				"card_instance_id": card_id_sn,
				"mech_id": owner_mech.mech_id,
				"player_id": player_id,
			},
		}
		items.append({"effect": eff, "payload": payload})
	if items.is_empty():
		return false
	var source: Dictionary = {
		"player_id": player_id,
		"mech_id": owner_mech.mech_id,
		"effect_id": &"immediate_use_cover",
	}
	return _spawn_immediate_use(parent_action, items, source)


## 判定行动牌是否为掩护（DIRECT MODIFY_ATTACK_MIGHT，如掩护 action_006）。
func _is_cover_action_card(card) -> bool:
	if card == null or card.def == null:
		return false
	var mappings: Array = _GeneratedActionEffects.get_effects_for_card(card.def.card_id)
	if mappings.is_empty():
		return false
	var all_effects: Dictionary = _GeneratedActionEffects.build_all_effects()
	for m in mappings:
		var eid: StringName = m.get("effect_id", &"") if m is Dictionary else &""
		var eff = all_effects.get(eid)
		if eff == null:
			continue
		if eff.mode == _TC.MODE_DIRECT:
			for act in eff.actions:
				var atype: StringName = act.get("type", &"") if act is Dictionary else &""
				if atype == &"MODIFY_ATTACK_MIGHT":
					return true
	return false


## 构造掩护即时使用的合成 ActionEffect：optional CHOOSE_ONE（使用/不使用）。
## 确认「使用」-> EXECUTE_USE_ACTION_CARD(带 attack_action_id) 打出掩护，掩护 DIRECT MODIFY_ATTACK_MIGHT -5 命中攻击。
func _make_cover_instant_use_effect(card_id: StringName, player_id: StringName, mech_id: StringName, attack_action_id: StringName) -> ActionEffect:
	var eff: ActionEffect = _ActionEffect.new()
	eff.effect_id = &"immediate_use_cover"
	eff.display_name = "掩护·即时使用"
	eff.mode = _TC.MODE_DIRECT
	eff.description = "即时使用掩护（该攻击威力-5）"
	eff.set_conditions([])
	eff.set_target_rules([{"rule": &"NO_TARGET"}])
	eff.set_costs([])
	eff.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{
				"label": "使用掩护（该攻击威力-5）",
				"actions": [{"type": &"EXECUTE_USE_ACTION_CARD", "params": {
					"card_instance_id": card_id,
					"player_id": player_id,
					"mech_id": mech_id,
					"attack_action_id": attack_action_id,
				}}],
			}],
		},
	}])
	return eff


## 判定牌是否在 p003 effect_02 延迟处理队列中（避免掩护即时使用与 p003 force_use 双重）。
func _is_p003_deferred_card(cause_action_id: StringName, card_id: StringName) -> bool:
	if not _p003_deferred_e02_map.has(cause_action_id):
		return false
	for entry in _p003_deferred_e02_map[cause_action_id]:
		if entry is Dictionary and entry.get("card_id", &"") == card_id:
			return true
	return false


## 构建来源信息（替代原 EffectBinding 的来源提取，用于日志）
func _build_source_info_from_parent(parent_action) -> Dictionary:
	var info := {}
	if parent_action == null:
		return info
	info["effect_id"] = parent_action.source.get("effect_id", &"") if parent_action.source is Dictionary else &""
	info["card_id"] = parent_action.source.get("card_instance_id", &"") if parent_action.source is Dictionary else &""
	info["mech_id"] = parent_action.source.get("mech_id", &"") if parent_action.source is Dictionary else &""
	info["player_id"] = parent_action.source.get("player_id", &"") if parent_action.source is Dictionary else &""
	return info


## 解析原效果动作参数中的变量引用 + 自动注入来源信息
## 移植自原 AtomicActionResolver._resolve_params / _resolve_value
func _resolve_atomic_params(raw_params: Dictionary, payload: Dictionary, parent_action) -> Dictionary:
	var result: Dictionary = {}
	for key in raw_params.keys():
		result[key] = _resolve_atomic_value(raw_params[key], payload, parent_action)

	# 来源信息（parent_action.source 优先，退回 payload）。
	# 坑：source 里的 mech_id/player_id 常以空 StringName 键存在（如 UI 打牌只传 player_id 不传 mech_id，
	# _build_source_from_params 仍建 "mech_id":"" 键），Dictionary.get(key, 默认值) 遇空键返回空串而非默认值，
	# 使来源解析落空（回收/回忆等 EXECUTE_GAIN_CARD 从弃牌堆取牌时 mech_ids 为空、牌不发给任何人）。
	# 故空串一律视为「未提供」再回退 payload 链。
	var src: Dictionary = parent_action.source if (parent_action != null and parent_action.source is Dictionary) else {}
	if not result.has("source_card_id"):
		var _src_cid: StringName = src.get("card_instance_id", &"")
		if _src_cid == &"":
			_src_cid = payload.get("card_instance_id", &"")
		if _src_cid == &"":
			_src_cid = payload.get("card_id", &"")
		result["source_card_id"] = _src_cid
	if not result.has("source_mech_id"):
		var _src_mid: StringName = src.get("mech_id", &"")
		if _src_mid == &"":
			_src_mid = payload.get("source_mech_id", &"")
		if _src_mid == &"":
			_src_mid = payload.get("mech_id", &"")
		result["source_mech_id"] = _src_mid
	if not result.has("player_id"):
		var _src_pid: StringName = src.get("player_id", &"")
		if _src_pid == &"":
			_src_pid = payload.get("player_id", &"")
		result["player_id"] = _src_pid
	# 武器：优先 selected_weapon_id，再 weapon_id
	if not result.has("weapon_id"):
		var sel_weapon = payload.get("selected_weapon_id", payload.get("weapon_id", &""))
		if sel_weapon != null and String(sel_weapon) != "":
			result["weapon_id"] = sel_weapon
	# 目标机甲：优先 target_id / target_mech_id；未指定时默认以来源机甲为对象
	if not result.has("target_id"):
		var sel_target = payload.get("target_id", payload.get("target_mech_id", &""))
		if sel_target != null and String(sel_target) != "":
			result["target_id"] = sel_target
		else:
			result["target_id"] = result.get("source_mech_id", &"")
	return result


## 递归解析参数值中的变量引用
## 移植自原 AtomicActionResolver._resolve_value
func _resolve_atomic_value(value, payload: Dictionary, parent_action):
	# 数组：逐项解析
	if typeof(value) == TYPE_ARRAY:
		var arr: Array = []
		for v in value:
			arr.append(_resolve_atomic_value(v, payload, parent_action))
		return arr
	# 字典：递归解析
	if typeof(value) == TYPE_DICTIONARY:
		return _resolve_atomic_params(value, payload, parent_action)
	# 非字符串：直接返回
	if typeof(value) == TYPE_STRING_NAME:
		value = String(value)  # StringName 转 String 以走 $payload/$binding_context 解析
	elif typeof(value) != TYPE_STRING:
		return value

	var s: String = String(value)
	# $payload.xxx → 从 payload 取值
	if s.begins_with("$payload."):
		var key: String = s.replace("$payload.", "")
		return payload.get(key)
	if s.begins_with("$binding_context."):
		var bc_key: String = s.replace("$binding_context.", "")
		var bind_ctx: Dictionary = payload.get("binding_context", {}) if payload != null else {}
		return bind_ctx.get(bc_key)
	# $chosen_card.xxx -> 从 payload.chosen_card 取值（CHOOSE_MANY_CARDS 逐张执行 per_card_actions 时注入）
	if s.begins_with("$chosen_card."):
		var cc_key: String = s.replace("$chosen_card.", "")
		var chosen: Dictionary = payload.get("chosen_card", {}) if payload != null else {}
		return chosen.get(cc_key)
	# $variables.xxx / $choice.xxx -> 已由 TimingEngine._eval_expr 在 CHOOSE_INTEGER 阶段解析为具体值；
	# 此处兜底从 payload.choice / payload.variables 取
	if s.begins_with("$variables."):
		var v_key: String = s.replace("$variables.", "")
		var vars: Dictionary = payload.get("variables", {}) if payload != null else {}
		return vars.get(v_key)
	if s.begins_with("$choice."):
		var ch_key: String = s.replace("$choice.", "")
		var ch: Dictionary = payload.get("choice", {}) if payload != null else {}
		return ch.get(ch_key)
	# $runtime.xxx -> 从 payload 取值（CHOOSE_MANY_CARDS store_result_key 存入 payload[key]）
	if s.begins_with("$runtime."):
		var rt_key: String = s.replace("$runtime.", "")
		return payload.get(rt_key)
	# $discard_equipment_cost → 从 DISCARD payload 的 discard_snapshots 取第一张被弃装备牌的 cost
	# （通用表达式：任何监听 DISCARD_* 时点、按被弃装备牌面价值给金币的效果用，如霍克 pilot_055
	#   卖出×2 补发1倍卖价。卖出金币已由 sell_equipment 先行发放，amount=卖价即实现×2）。
	if s == "$discard_equipment_cost":
		var dec_snaps: Array = payload.get("discard_snapshots", [])
		for dec_snap: Dictionary in dec_snaps:
			var dec_cid: StringName = dec_snap.get("card_id", &"")
			if dec_cid == &"":
				continue
			var dec_card = context.game_state.get_card(dec_cid) if (context != null and context.game_state != null) else null
			if dec_card != null and dec_card.def != null and dec_card.def.card_kind == &"equipment":
				return int(dec_card.def.cost)
		return 0
	# $source.xxx → 从 parent_action.source 取值
	var src: Dictionary = parent_action.source if (parent_action != null and parent_action.source is Dictionary) else {}
	if s == "$source.card_instance_id":
		return src.get("card_instance_id", &"")
	if s == "$source.mech_id":
		return src.get("mech_id", &"")
	if s == "$source.owner_player_id":
		return src.get("player_id", &"")
	# $current_target.xxx -> 从 payload["current_target"] 取（FOR_EACH_TARGET 注入 {mech_id: ...}）
	if s.begins_with("$current_target."):
		var ct_key: String = s.replace("$current_target.", "")
		var ct: Dictionary = payload.get("current_target", {}) if payload != null else {}
		# $current_target.owner_player_id -> 当前目标机甲的所属玩家（弥雅 pilot_071 等
		# 「被选机甲玩家弃自己牌」效果用；FOR_EACH_TARGET 只注入 mech_id，所属玩家须反查）。
		# 通用表达式，任何「作用于当前目标机甲所属玩家」的原子/子动作参数都可复用。
		if ct_key == "owner_player_id":
			var ct_mech_id: StringName = ct.get("mech_id", &"")
			if ct_mech_id != &"" and context != null and context.game_state != null:
				var ct_player = context.game_state.get_player_for_mech(ct_mech_id)
				if ct_player != null:
					return ct_player.player_id
			return &""
		return ct.get(ct_key)
	# 裸 $key（如 $selected_targets）-> 从 payload 取
	# （TargetChecker.ALL_CURRENT_ATTACK_MECH_TARGETS / ALL_HIT_TARGETS_* 在 check_single 里注入 payload["selected_targets"]）
	if s.begins_with("$"):
		var bare_key: String = s.substr(1)
		if payload != null and payload.has(bare_key):
			return payload.get(bare_key)
	# 无匹配：原样返回
	return value


## 原效果动作分发：act_type → context.game_actions.xxx
## 移植自原 AtomicActionResolver.resolve 的 match 分支
func _dispatch_atomic_action(act_type: StringName, params: Dictionary, payload: Dictionary, _source_info: Dictionary) -> void:
	if context == null or context.game_actions == null:
		push_error("ActionService: context 或 game_actions 未初始化")
		return

	var ga = context.game_actions
	match act_type:
		# ── 攻击相关 ──
		&"START_ATTACK_DECLARE_ATTACK":
			ga.start_attack_declare_attack(params)
		&"MODIFY_ATTACK_POWER":
			ga.modify_attack_power(params)
		&"MODIFY_ATTACK_MARKERS":
			# 已在 _execute_atomic_action 顶部特判处理（写 parent_action.record["extra_markers"]）
			push_warning("ActionService: MODIFY_ATTACK_MARKERS 应在 _execute_atomic_action 特判处理，此处 noop")
		&"MODIFY_ATTACK_MIGHT":
			# 已在 _execute_atomic_action 顶部特判处理（写 parent_action.record["extra_might"]）
			push_warning("ActionService: MODIFY_ATTACK_MIGHT 应在 _execute_atomic_action 特判处理，此处 noop")
		&"RESPOND_ATTACK":
			# 已在 _execute_atomic_action 顶部特判处理（写原 attack 动作的 responded 等字段）
			pass
		&"MODIFY_ATTACK_TEMP_ARMOR":
			# 已在 _execute_atomic_action 顶部特判处理（写原 attack 动作的 temporary_armor_bonus）
			pass
		&"MODIFY_ATTACK_RANGE":
			ga.modify_attack_range(params)
		&"NEGATE_ATTACK":
			# 已在 _execute_atomic_action 顶部特判处理（设 parent_action.negated）
			pass
		&"SET_ATTACK_UNNEGATABLE":
			# 已在 _execute_atomic_action 顶部特判处理（设 parent_action.unnegatable）
			pass
		&"APPLY_CANNOT_RESPOND":
			ga.apply_cannot_respond(params)
		&"APPLY_OR_CHECK_LOCKED":
			ga.apply_or_check_locked(params)
		&"OPEN_OR_USE_RESPONSE":
			ga.open_or_use_response(params)
		&"CONSUME_NEXT_ATTACK_POWER_BUFF":
			ga.consume_next_attack_power_buff(params)
		# ── 属性修改 ──
		&"MODIFY_ARMOR":
			ga.modify_armor(params)
		&"MODIFY_MECH_POWER":
			ga.modify_mech_power(params)
		&"SPEND_POWER":
			ga.spend_power(params)
		&"RESTORE_POWER":
			ga.restore_power(params)
		&"RESTORE_WEAPON_POWER":
			ga.restore_weapon_power(params)
		# ── 抽牌/获得 ──（DRAW_ACTION/DRAW_EQUIPMENT 已统一走 gain_card 动作拿 GAIN_CARD 时点）
		&"GAIN_SPECIFIC_CARD":
			ga.gain_specific_card(params)
		&"RANDOM_DRAW_FROM_DISCARD_OR_DECK":
			ga.random_draw_from_discard_or_deck(params)
		&"TRANSFER_ACTION_CARDS":
			ga.transfer_action_cards(params)
		&"GAIN_GOLD":
			ga.gain_gold(params)
		&"SPEND_GOLD":
			ga.spend_gold(params)
		&"SHOP_BUY_MODIFIER":
			ga.shop_buy_modifier(params)
		# ── 伤害/损伤 ──
		&"DEAL_DAMAGE":
			ga.deal_damage(params)
		&"PLACE_DAMAGE_TOKENS":
			ga.place_damage_tokens(params)
		&"MODIFY_DAMAGE_TOKENS":
			ga.modify_damage_tokens(params)
		&"REMOVE_DAMAGE_TOKENS":
			ga.remove_damage_tokens(params)
		&"REMOVE_DAMAGE_TOKENS_FROM_DISCARD_ORIGIN_SLOT":
			_remove_damage_tokens_from_discard_origin_slot(params, payload)
		&"REMOVE_DAMAGE_TOKENS_OTHER_SLOTS":
			_remove_damage_tokens_other_slots(params, payload)
		&"REDIRECT_DAMAGE_TOKENS":
			ga.redirect_damage_tokens(params)
		&"HEAL_HP":
			ga.heal_hp(params)
		# ── 移动/设置 ──
		&"MOVE_MECH":
			ga.move_mech(params)
		&"SET_CARD_TO_SLOT":
			ga.set_card_to_slot(params)
		&"PLACE_OR_TRIGGER_TRAP":
			ga.place_or_trigger_trap(params)
		&"MOVE_MAP_MARKER":
			# 通用标记迁移：from 格标记移到 dest 格；explode_if_mech 且落格有机甲时触发标准陷阱爆炸
			ga.move_map_marker(params)
		# ── 弃牌/破坏 ──
		&"DISCARD_CARD":
			ga.discard_card(params)
		&"DISCARD_ACTION_CARD":
			ga.discard_action_card(params)
		&"DISCARD_TEMP_ZONE_CARDS":
			# pilot_011 迪恩转化 / pilot_015 诺拉全牌转化：把 cost 阶段移入临时区的燃料牌入弃牌堆
			# （不触发 Action Engine 时点，走 legacy GameActions.discard_card 仅 fire ON_CARD_DISCARDED hook）。
			# card_ids 已由 _resolve_atomic_params 从 $payload.temp_zone_card_ids 解析为数组。
			# 守卫：跳过已不在临时区的牌（pilot_015 首张虚拟牌已被 use_action_card._step_settle
			# 经 deck_service.discard_card 入弃牌堆，zone=discard，不可重复弃置否则 ON_CARD_DISCARDED hook 重复 fire）。
			var dtz_ids: Array = params.get("card_ids", [])
			var dtz_reason: StringName = params.get("reason", &"PILOT_011_FUEL")
			for dtz_cid in dtz_ids:
				if dtz_cid == null or String(dtz_cid) == "" or context.game_state == null or not context.game_state.cards.has(dtz_cid):
					continue
				var _dtz_card = context.game_state.cards[dtz_cid]
				if _dtz_card != null and String(_dtz_card.zone) == &"discard":
					continue
				ga.discard_card({"card_id": dtz_cid, "reason": dtz_reason})
		&"MOVE_ACTION_CARDS_TO_TEMP_ZONE":
			# 通用件：把选中的行动牌移入临时区（不弃置、不触发弃牌时点），并累加到
			# payload.temp_zone_card_ids 供链末 DISCARD_TEMP_ZONE_CARDS 统一入弃牌堆。
			# 供效果分支内的转化使用（布鲁克 effect_02 转化防御分支：CHOOSE_MANY_CARDS 选1张燃料牌
			# → 此处移入临时区 → 当作防御 → 链末弃牌）。card_ids 来自 $runtime 选中结果。
			var mtz_ids: Array = params.get("card_ids", [])
			var mtz_bind: Dictionary = payload.get("binding_context", {}) if payload != null else {}
			var mtz_player: StringName = mtz_bind.get("player_id", payload.get("player_id", &""))
			for mtz_cid in mtz_ids:
				if mtz_cid == null or String(mtz_cid) == "":
					continue
				var mtz_sn: StringName = StringName(mtz_cid)
				if context != null and context.game_state != null:
					var mtz_ps = context.game_state.players.get(mtz_player)
					if mtz_ps != null:
						mtz_ps.action_hand.erase(mtz_sn)
					if context.timing_engine != null:
						context.timing_engine.unregister_listeners_for_card(mtz_sn)
					var mtz_card = context.game_state.get_card(mtz_sn)
					if mtz_card != null:
						mtz_card.zone = &"temp_zone"
				if payload != null:
					var mtz_existing: Array = payload.get("temp_zone_card_ids", [])
					mtz_existing.append(mtz_sn)
					payload["temp_zone_card_ids"] = mtz_existing
		&"DESTROY_CARD":
			ga.destroy_card(params)
		&"PLAY_AS_CARD":
			ga.play_as_card(params)
		# ── 状态 ──
		&"ADD_STATUS":
			_dispatch_add_status(params, payload)
		&"REMOVE_STATUS":
			# 状态监听器触发的 REMOVE_STATUS（如锁定命中后清除）需按 status_id 精确移除，
			# 否则会误删目标身上其他来源的同类状态（如多个 locker 的 LOCKED）。
			# status_id 由 TimingEngine 从 binding_context 注入 payload。
			# target_id 可能被 _resolve_atomic_params 注入为 &""（空串），按值为空判断补齐。
			var rs_params: Dictionary = params
			var rs_bind: Dictionary = payload.get("binding_context", {}) if payload != null else {}
			var rs_need_dup: bool = false
			if not (rs_params.has("target_id") and String(rs_params.get("target_id", &"")) != ""):
				var rs_mid: StringName = rs_bind.get("target_id", &"")
				if rs_mid != &"":
					rs_need_dup = true
			if not (rs_params.has("status_id") and String(rs_params.get("status_id", &"")) != ""):
				if rs_bind.get("status_id", &"") != &"":
					rs_need_dup = true
			if rs_need_dup:
				rs_params = params.duplicate()
				if not (rs_params.has("target_id") and String(rs_params.get("target_id", &"")) != ""):
					var rs_mid2: StringName = rs_bind.get("target_id", &"")
					if rs_mid2 != &"":
						rs_params["target_id"] = rs_mid2
				if not (rs_params.has("status_id") and String(rs_params.get("status_id", &"")) != ""):
					var rs_sid2: StringName = rs_bind.get("status_id", &"")
					if rs_sid2 != &"":
						rs_params["status_id"] = rs_sid2
			ga.remove_status(rs_params)
		&"DECREMENT_STATUS_DURATION":
			# 状态监听器触发时（如锁定回合-1）payload 是所属动作 record，可能无 target_id。
			# 从 binding_context 注入被锁机甲（target_id）与 status_id，实现各状态独立结算。
			# 注意 _resolve_atomic_params 会注入 target_id=&""（空串但 key 存在），
			# 故此处按"值为空"判断而非 has(key)。
			var dsd_params: Dictionary = params
			var dsd_bind: Dictionary = payload.get("binding_context", {}) if payload != null else {}
			var dsd_has_mech: bool = dsd_params.has("mech_id") and String(dsd_params.get("mech_id", &"")) != ""
			var dsd_has_tgt: bool = dsd_params.has("target_id") and String(dsd_params.get("target_id", &"")) != ""
			if not dsd_has_mech and not dsd_has_tgt:
				var dsd_mid: StringName = dsd_bind.get("target_id", &"")
				if dsd_mid != &"":
					dsd_params = params.duplicate()
					dsd_params["mech_id"] = dsd_mid
			if not (dsd_params.has("status_id") and String(dsd_params.get("status_id", &"")) != ""):
				var dsd_sid: StringName = dsd_bind.get("status_id", &"")
				if dsd_sid != &"":
					if dsd_params == params:
						dsd_params = params.duplicate()
					dsd_params["status_id"] = dsd_sid
			ga.decrement_status_duration(dsd_params)
		&"ADD_RULE_MODIFIER":
			ga.add_rule_modifier(params)
		# ── 事件/计时 ──
		&"REDUCE_EVENT_TIMER":
			ga.reduce_event_timer(params)
		&"SET_EVENT_TIMER":
			ga.set_event_timer(params)
		&"TRACK_EVENT_PROGRESS":
			ga.track_event_progress(params)
		# ── 其他 ──
		&"REVEAL_OR_PEEK_CARD":
			ga.reveal_or_peek_card(params)
		&"ROLL_D6":
			ga.roll_d6(params)
		&"TOGGLE_AURA_TARGET":
			ga.toggle_aura_target(params, payload)
		&"CUSTOM_EFFECT_CHECK_TEXT":
			ga.custom_effect_check_text(params)
		# ── 新增动作（批次3原语扩展） ──
		&"APPLY_ENERGY_TO_WEAPON":
			ga.apply_energy_to_weapon(params)
		&"STEAL_ACTION_CARD":
			ga.steal_action_card(params)
		&"RANDOM_DISCARD_ACTION_CARD":
			# 通用捕获（肯兹尔 pilot_045 弃3行动后取攻击牌等）：随机弃置结果按 capture_store_key
			# 写回 payload[capture_store_key]（FOR_EACH_TARGET 逐目标累加）；capture_attack_only=true
			# 时只捕获攻击牌（卡 def card_kind=action 且 action_type=攻击），其余被弃牌仍进弃牌堆。
			var rd_result: Array = ga.random_discard_action_card(params)
			var rd_store: StringName = params.get("capture_store_key", &"")
			if rd_store != &"" and payload != null and not rd_result.is_empty():
				var rd_captured: Array = rd_result
				if bool(params.get("capture_attack_only", false)):
					rd_captured = []
					for rd_cid: StringName in rd_result:
						# rd_cid 是卡牌实例 id（hand 存 instance_id），经 gs.cards 解析实例再取 def
						var rd_inst = context.game_state.cards.get(rd_cid) if context != null and context.game_state != null else null
						var rd_def = rd_inst.def if rd_inst != null else null
						if rd_def != null and rd_def.card_kind == &"action" and rd_def.action_type == &"攻击":
							rd_captured.append(rd_cid)
				if payload.has(rd_store) and payload[rd_store] is Array:
					payload[rd_store].append_array(rd_captured)
				else:
					payload[rd_store] = rd_captured
		&"PLACE_TRAP_MARKER":
			ga.place_trap_marker(params)
		&"CONVERT_WEAPON_KIND":
			ga.convert_weapon_kind(params)
		# ── 新增动作（阶段1原语扩展） ──
		&"PLACE_DAMAGE_TOKENS_ON_SLOT":
			ga.place_damage_tokens_on_slot(params)
		&"PLAY_CARD_AS_TYPE":
			ga.play_card_as_type(params)
		&"MODIFY_ACTION_HAND_LIMIT":
			ga.modify_action_hand_limit(params)
		&"MODIFY_ATTACK_COUNT":
			ga.modify_attack_count(params)
		&"APPLY_NEXT_OWNER_TURN_ATTACK_BONUS":
			ga.apply_next_owner_turn_attack_bonus(params)
		&"APPLY_NEXT_OWNER_TURN_ACTION_HAND_BONUS":
			ga.apply_next_owner_turn_action_hand_bonus(params)
		&"MARK_EFFECT_ONCE_PER_TURN_USED":
			# 通用件：标记某来源牌实例的每回合N次额度 +1（跨效果共享额度，如布鲁克 effect_02
			# 转化防御分支消耗 effect_01 的每回合1次）。来源实例取 payload.binding_context.card_instance_id。
			var meo_key_m: StringName = params.get("once_per_turn_key", &"")
			var meo_bind_m: Dictionary = payload.get("binding_context", {})
			var meo_cid_m: StringName = meo_bind_m.get("card_instance_id", payload.get("card_instance_id", &""))
			if meo_key_m != &"" and meo_cid_m != &"" and context != null and context.timing_engine != null:
				context.timing_engine.mark_once_per_turn_key_used(meo_key_m, meo_cid_m)
		&"INCREMENT_VARIABLE":
			ga.increment_variable(params)
		&"CHOOSE_ONE":
			ga.choose_one(params)
		&"FORCE_MECH_ACTION":
			ga.force_mech_action(params)
		&"TREAT_CARD_AS_NAMED_TYPE":
			ga.treat_card_as_named_type(params)
		&"GRANT_EFFECT_TO_FACTION":
			ga.grant_effect_to_faction(params)
		&"TOGGLE_EFFECT_ON_MECH":
			ga.toggle_effect_on_mech(params)
		&"NEGATE_EQUIPMENT_EFFECT":
			ga.negate_equipment_effect(params)
		&"MOVE_WITHOUT_POWER":
			ga.move_without_power(params)
		&"MODIFY_WEAPON_POWER":
			ga.modify_weapon_power(params)
		&"RECORD_WEAPON_ATTACK_COUNT":
			ga.record_weapon_attack_count(params)
		&"DECAY_WEAPON_BY_RECORDED_COUNT":
			ga.decay_weapon_by_recorded_count(params)
		&"SET_WEAPON_STATS":
			ga.set_weapon_stats(params)
		&"SET_WEAPON_COOLDOWN":
			ga.set_weapon_cooldown(params)
		&"DISCARD_ALL_FACE_UP_PARTS":
			ga.discard_all_face_up_parts(params, payload)
		&"SET_WEAPON_CONVERSION":
			ga.set_weapon_conversion(params)
		&"CHOOSE_MANY_MAP_CELLS":
			# 由 TimingEngine._execute_actions 拦截弹选格 UI（同 CHOOSE_ONE/OFFER_DAMAGE_REDIRECT）
			pass
		&"CONVERT_ARMOR_TO_POWER":
			ga.convert_armor_to_power(params)
		# REDIRECT_HEAL_TO_DAMAGE / REDIRECT_REMOVE_TO_PLACE_TOKENS 已在 _execute_atomic_action
		# 顶部 special case 处理（需 parent_action 修改被监听动作 record），不会走到此通用分发。
		&"MODIFY_NEXT_DAMAGE_DEALT":
			ga.modify_next_damage_dealt(params)
		&"ADD_WEAPON_TAG":
			ga.add_weapon_tag(params)
		&"DECLARE_CARD_TYPE":
			ga.declare_card_type(params)
		&"DRAW_ADVANCED_EQUIPMENT":
			ga.draw_advanced_equipment(params)
		&"PLACE_CARD_IN_DECK_FACE_UP":
			ga.place_card_in_deck_face_up(params)
		# ── 新增动作（阶段4机师效果支持） ──
		&"SWAP_HAND_LIMIT_AND_ATTACK_COUNT":
			ga.swap_hand_limit_and_attack_count(params)
		&"REPLACE_USED_ACTION_EFFECT_BY_SEQUENCE":
			# 顶部特殊处理（需 parent_action），此处不会到。保留兜底。
			pass
		&"CLEAR_SOURCE_STAT_MODIFIERS":
			ga.clear_source_stat_modifiers(params)
		_:
			push_error("ActionService: 未知原效果动作 %s" % act_type)


## ── 装备牌效果专用 helper（C-H 阶段）──

## 从所在区域清空装备牌（弃置本牌前调用，确保 slot.equipped_card = null）
func _clear_equipped_card_from_slot(card_id: StringName) -> void:
	if context == null or context.game_state == null or card_id == &"":
		return
	var card = context.game_state.get_card(card_id)
	if card == null or card.mech_id == &"" or card.slot_id == &"":
		return
	var mech = context.game_state.mechs.get(card.mech_id)
	if mech == null or not mech.slots.has(card.slot_id):
		return
	var slot = mech.slots[card.slot_id]
	if slot.equipped_card != null and slot.equipped_card.instance_id == card_id:
		slot.equipped_card = null


## REMOVE_DAMAGE_TOKENS_FROM_DISCARD_ORIGIN_SLOT：移除本牌原区域全部损伤
## 读 payload.discard_snapshots 取 from_mech_id/from_slot_id，amount=-1 表全部
func _remove_damage_tokens_from_discard_origin_slot(params: Dictionary, payload: Dictionary) -> void:
	if context == null or context.game_actions == null:
		return
	var amount: int = int(params.get("amount", -1))
	var snapshots: Array = payload.get("discard_snapshots", [])
	var bind_ctx: Dictionary = payload.get("binding_context", {})
	var self_card_id: StringName = bind_ctx.get("card_instance_id", payload.get("card_instance_id", &""))
	for snap: Dictionary in snapshots:
		if self_card_id != &"" and String(snap.get("card_id", &"")) != String(self_card_id):
			continue
		var from_mech: StringName = snap.get("from_mech_id", &"")
		var from_slot: StringName = snap.get("from_slot_id", &"")
		if from_mech == &"" or from_slot == &"":
			continue
		var remove_amt: int = amount
		if amount == -1:
			# 全部：取该区域现有损伤数
			var mech = context.game_state.mechs.get(from_mech) if context.game_state != null else null
			var slot = mech.slots.get(from_slot) if mech != null else null
			if slot != null:
				var rd: int = int(slot.region_damage_tokens) if "region_damage_tokens" in slot else 0
				if slot.equipped_card != null and "damage_tokens" in slot.equipped_card:
					rd += int(slot.equipped_card.damage_tokens)
				remove_amt = rd
		if remove_amt > 0:
			context.game_actions.remove_damage_tokens({"mech_id": from_mech, "slot_id": from_slot, "amount": remove_amt})
		break


## REMOVE_DAMAGE_TOKENS_OTHER_SLOTS：移除原机甲除原区域外最多N损伤
## 读 payload.discard_snapshots 取 from_mech_id/from_slot_id，从其他区域各移除直到达 amount
func _remove_damage_tokens_other_slots(params: Dictionary, payload: Dictionary) -> void:
	if context == null or context.game_actions == null:
		return
	var amount: int = int(params.get("amount", 1))
	var snapshots: Array = payload.get("discard_snapshots", [])
	var bind_ctx: Dictionary = payload.get("binding_context", {})
	var self_card_id: StringName = bind_ctx.get("card_instance_id", payload.get("card_instance_id", &""))
	var from_mech: StringName = &""
	var from_slot: StringName = &""
	for snap: Dictionary in snapshots:
		if self_card_id != &"" and String(snap.get("card_id", &"")) != String(self_card_id):
			continue
		from_mech = snap.get("from_mech_id", &"")
		from_slot = snap.get("from_slot_id", &"")
		break
	if from_mech == &"" or context.game_state == null:
		return
	var mech = context.game_state.mechs.get(from_mech)
	if mech == null:
		return
	# 遍历其他区域，逐个移除损伤直到达 amount
	var remaining: int = amount
	for sid in mech.slots:
		if remaining <= 0:
			break
		if StringName(String(sid)) == from_slot:
			continue
		var slot = mech.slots[sid]
		if slot == null:
			continue
		var region_dmg: int = int(slot.region_damage_tokens) if "region_damage_tokens" in slot else 0
		var card_dmg: int = int(slot.equipped_card.damage_tokens) if (slot.equipped_card != null and "damage_tokens" in slot.equipped_card) else 0
		var avail: int = region_dmg + card_dmg
		if avail <= 0:
			continue
		var take: int = mini(remaining, avail)
		context.game_actions.remove_damage_tokens({"mech_id": from_mech, "slot_id": StringName(String(sid)), "amount": take})
		remaining -= take


## ADD_STATUS 特殊参数处理（移植自原 AtomicActionResolver 的 ADD_STATUS 分支）
## 支持简化参数格式（status_type + duration）与完整参数格式（target_id + status dict）
## target_card_instance_id：武器牌级状态（如 weapon_used_this_turn）存 card.counters，非机甲状态。
func _dispatch_add_status(params: Dictionary, payload: Dictionary) -> void:
	if context == null or context.game_actions == null:
		return
	var status_type: StringName = params.get("status_type", &"")
	var duration = params.get("duration", 1)
	var target_is_attack_target: bool = params.get("target_is_attack_target", false)

	# 武器牌级状态：存 card.counters[status_type]=true（effect_112 weapon_used_this_turn）
	# 仅当显式传 target_card_instance_id 时走此路径；勿用自动注入的 weapon_id（否则 effect_088
	# 等机甲级 ADD_STATUS 会被误当武器牌状态，CANNOT_RESTORE_POWER 错挂到牌上）。
	if params.has("target_card_instance_id") and status_type != &"":
		var target_card_id: StringName = params.get("target_card_instance_id", &"")
		if target_card_id != &"":
			var wcard = context.game_state.get_card(target_card_id) if context.game_state != null else null
			if wcard != null:
				if not "counters" in wcard:
					wcard.counters = {}
				wcard.counters[status_type] = true
				return

	var target_id: StringName = params.get("target_id", &"")
	if target_id == &"":
		if target_is_attack_target:
			# payload 是触发时点的动作 record 副本（fire_timing 时 duplicate），
			# ATTACK_PRE 时 target_id 已由 _step_select_target 写入。优先读 payload，
			# 不再依赖 game_state.current_attack_id（新攻击流程不设置它，永远为空）。
			target_id = payload.get("target_id", &"")
		if target_id == &"" and context.game_state.current_attack_id != &"":
			var attack: Dictionary = context.game_state.attacks.get(context.game_state.current_attack_id, {})
			target_id = attack.get("target_id", &"")
		if target_id == &"":
			target_id = params.get("source_mech_id", &"")

	if target_id == &"" or status_type == &"":
		push_error("ADD_STATUS 缺少 target_id/status_type")
		return

	var status: Dictionary = {
		"type": status_type,
		"duration": duration,
		"source_card_id": params.get("source_card_id", &""),
		"source_player_id": params.get("player_id", &""),
	}
	if params.has("stacks"):
		status["stacks"] = params["stacks"]
	# 联合/锁定等状态需要的额外绑定字段（unite/locker 等）原样透传
	for extra_key in ["unite", "locker", "weapon_id", "source_mech_id"]:
		if params.has(extra_key):
			status[extra_key] = params[extra_key]

	# 联合状态去重在 GameActions.add_status 统一处理（覆盖所有施加路径）

	context.game_actions.add_status({
		"target_id": target_id,
		"status": status,
	})


## ── 动作工厂方法 ──


func _create_attack_action(params: Dictionary) -> Action:
	var action = AttackAction.new()
	action.setup_steps()
	return action


## 多目标攻击（双连等）派生"复制攻击"子动作：深拷贝主攻击 record（快照发动前武器状态），
## 从 step 3（execute_attack / ATTACK_AT）开始执行，跳过 extract/weapon/target 选择。
## 主攻击只发 ATTACK_BEFORE/PRE，复制攻击各自发完整 ATTACK_AT/AFTER/SETTLE。
## fork_record 已是主攻击 record 的深拷贝（含 weapon_might/extra_might/extra_range 等快照）。
func create_fork_attack(parent_attack: Action, fork_record: Dictionary, start_step_index: int) -> Action:
	var fork: Action = _create_attack_action({})
	if fork == null:
		return null
	fork.context = context
	fork.source = parent_attack.source.duplicate(true)
	fork.record = fork_record
	fork.current_step_index = start_step_index
	context.action_registry.register(fork)
	fork.parent_action_id = parent_attack.action_id
	parent_attack.pending_effect_action_ids.append(fork.action_id)
	return fork


func _create_use_action_card_action(params: Dictionary) -> Action:
	var action = UseActionCardAction.new()
	action.setup_steps()
	return action


func _create_stat_modify_action(params: Dictionary) -> Action:
	var action = StatModifyAction.new()
	action.setup_steps()
	return action


func _create_basic_move_action(params: Dictionary) -> Action:
	var action = BasicMoveAction.new()
	action.setup_steps()
	return action


func _create_single_move_action(params: Dictionary) -> Action:
	var action = SingleMoveAction.new()
	action.setup_steps()
	return action


func _create_set_equipment_action(params: Dictionary) -> Action:
	var action = SetEquipmentAction.new()
	action.setup_steps()
	return action


func _create_set_event_card_action(params: Dictionary) -> Action:
	var action = _SetEventCardAction.new()
	action.setup_steps()
	return action


func _create_gain_card_action(params: Dictionary) -> Action:
	var action = GainCardAction.new()
	action.setup_steps()
	return action


func _create_discard_card_action(params: Dictionary) -> Action:
	var action = DiscardCardAction.new()
	action.setup_steps()
	return action


func _create_steal_action_card_action(params: Dictionary) -> Action:
	var action = StealActionCardAction.new()
	action.setup_steps()
	return action


func _create_awaken_action(params: Dictionary) -> Action:
	var action = _AwakenAction.new()
	action.setup_steps()
	return action


func _create_effect_fire_action(params: Dictionary) -> Action:
	var action = EffectFireAction.new()
	action.setup_steps()
	return action


func _create_hp_change_action(params: Dictionary) -> Action:
	var action = HpChangeAction.new()
	action.setup_steps()
	return action


func _create_damage_change_action(params: Dictionary) -> Action:
	var action = DamageChangeAction.new()
	action.setup_steps()
	return action


func _create_show_card_action(params: Dictionary) -> Action:
	var action = ShowCardAction.new()
	action.setup_steps()
	return action


func _create_trap_explosion_action(params: Dictionary) -> Action:
	var action = _TrapExplosionAction.new()
	action.setup_steps()
	return action


func _create_immediate_use_action(params: Dictionary) -> Action:
	var action = _ImmediateUseAction.new()
	action.setup_steps()
	return action


## ── 效果动作参数提取 ──

func _extract_attack_params(action_def: Dictionary, payload: Dictionary, parent_action) -> Dictionary:
	var params: Dictionary = action_def.get("params", {})
	var result: Dictionary = {}
	result["attacker_id"] = params.get("attacker_id", payload.get("attacker_id", payload.get("source_mech_id", &"")))
	result["target_id"] = params.get("target_id", payload.get("target_id", &""))
	result["weapon_id"] = params.get("weapon_id", payload.get("weapon_id", &""))
	result["attack_card_id"] = params.get("attack_card_id", payload.get("attack_card_id", payload.get("card_instance_id", &"")))
	result["target_count"] = params.get("target_count", 1)
	# pilot_006 里昂狩猎标签豁免：从父 use_action_card record 继承到 attack record，
	# select_target 据此约束只能选标记机甲，settle 据此对标记目标不+1攻击数。
	if bool(payload.get("pilot_006_zero_exemption", false)):
		result["pilot_006_zero_exemption"] = true
		result["pilot_006_forced_target"] = payload.get("pilot_006_forced_target", &"")
	result["source"] = _build_source_from_payload(payload, parent_action)
	# 闪击等再攻型效果：使用上一次攻击的武器（目标可锁定或重选，见下方各 flag）
	# attack B 的 payload 是 attack A 的 record（含 attack_source=发动方信息）。
	# _build_source_from_payload 从顶层 player_id/source_mech_id 取，但 attack A 的 record
	# 没有这些顶层字段（它们在 attack_source 里），故再攻型 attack B 的 source 会全空，
	# 导致其响应窗口/损伤执行者等无法识别发动方。这里从 attack_source 继承补齐。
	if params.get("use_previous_weapon", false) or params.get("use_previous_target", false):
		var prev_source: Dictionary = payload.get("attack_source", {})
		if result["source"].get("player_id", &"") == &"" and prev_source.get("player_id", &"") != &"":
			result["source"]["player_id"] = prev_source["player_id"]
		if result["source"].get("mech_id", &"") == &"" and prev_source.get("mech_id", &"") != &"":
			result["source"]["mech_id"] = prev_source["mech_id"]
		if result["source"].get("card_instance_id", &"") == &"" and prev_source.get("card_instance_id", &"") != &"":
			result["source"]["card_instance_id"] = prev_source["card_instance_id"]
	if params.get("use_previous_weapon", false):
		result["weapon_id"] = payload.get("weapon_id", &"")
		result["skip_weapon_select"] = true
	if params.get("use_previous_target", false):
		result["target_id"] = payload.get("target_id", &"")
		result["skip_target_select"] = true
	# 闪击再攻：用攻击A的武器，但目标可在武器范围内重选（不锁定攻击A的目标）。
	# choose_new_target 清空上方 fallback 继承的 payload.target_id，使 attack B 走
	# select_attack_target 流程让玩家在武器范围内任选目标。
	if params.get("choose_new_target", false):
		result["target_id"] = &""
		result["skip_target_select"] = false
	# 反击 effect2：监听攻击1的攻击结算时点后发动攻击2。payload 是原 attack 动作 record。
	# 攻击2的发动方=迎击牌持有者（由注册 effect2 时通过 binding_context 携带）。
	# 目标不锁定为原攻击者——按规则攻击2是一个完整新攻击，发动方重新选武器、
	# 在所选武器攻击范围内任选目标（可打原攻击者，也可打范围内其他机甲）。
	if params.get("counter_strike", false):
		var bind_ctx: Dictionary = payload.get("binding_context", {})
		var responder_mech: StringName = bind_ctx.get("responder_mech_id", &"")
		if responder_mech != &"":
			result["attacker_id"] = responder_mech
		# 攻击2的发动方=迎击牌持有者，从 binding_context 补齐 source
		var responder_player: StringName = bind_ctx.get("responder_player_id", &"")
		var responder_card: StringName = bind_ctx.get("responder_card_id", &"")
		if responder_player != &"":
			result["source"]["player_id"] = responder_player
		if responder_mech != &"":
			result["source"]["mech_id"] = responder_mech
		if responder_card != &"":
			result["source"]["card_instance_id"] = responder_card
		result["weapon_id"] = &""  # 攻击2需发动方重新选武器
		result["target_id"] = &""  # counter_strike 不锁定目标：清空上方 fallback 的 payload.target_id
		result["skip_target_select"] = false
		# target_id 留空 → _step_select_target 走 select_attack_target 流程，范围内任选
	# effect_128 直攻免牌：weapon_instance_id 指定武器，不创建 use_action_card/不消耗攻击牌，
	# 默认消耗本回合攻击次数。params 用 $binding_context.mech_id/card_instance_id，需解析。
	if params.get("cardless_weapon_attack", false):
		var cw_attacker = params.get("attacker_id", &"")
		if String(cw_attacker).begins_with("$"):
			cw_attacker = _resolve_atomic_value(cw_attacker, payload, parent_action)
		if cw_attacker != &"":
			result["attacker_id"] = cw_attacker
		var cw_weapon = params.get("weapon_instance_id", params.get("weapon_id", &""))
		if String(cw_weapon).begins_with("$"):
			cw_weapon = _resolve_atomic_value(cw_weapon, payload, parent_action)
		result["weapon_id"] = cw_weapon
		result["attack_card_id"] = &""  # 免攻击牌
		result["skip_weapon_select"] = true
		var cw_bind: Dictionary = payload.get("binding_context", {})
		if cw_bind.get("player_id", &"") != &"":
			result["source"]["player_id"] = cw_bind["player_id"]
		if cw_bind.get("mech_id", &"") != &"":
			result["source"]["mech_id"] = cw_bind["mech_id"]
		if cw_bind.get("card_instance_id", &"") != &"":
			result["source"]["card_instance_id"] = cw_bind["card_instance_id"]
		result["cardless_weapon_attack"] = true
		result["consume_turn_attack_count"] = bool(params.get("consume_turn_attack_count", true))
	return result


func _extract_stat_mod_params(action_def: Dictionary, payload: Dictionary, parent_action) -> Dictionary:
	var params: Dictionary = action_def.get("params", {})
	var result: Dictionary = {}
	# target_id: 解析 $expr（$binding_context.mech_id / $current_target.mech_id）；未指定时退回 payload
	var sm_target_default = payload.get("target_id", payload.get("mech_id", payload.get("source_mech_id", &"")))
	result["target_id"] = _resolve_atomic_value(params.get("target_id", sm_target_default), payload, parent_action)
	result["stat_type"] = params.get("stat_type", &"armor")
	result["stat_types"] = params.get("stat_types", [])
	# stat_changes 数组（pilot_013 effect_02a）：透传（字面值，无 $expr）
	result["stat_changes"] = params.get("stat_changes", [])
	# 数值：显式 value 优先；否则若指定 value_multiplier_by_stacks（如聚能"威力+4*X"），
	# 按 payload.binding_context 定位的状态层数算出 value = multiplier * stacks。
	# 修复前此参数从未被解析 -> value 恒为 0 -> stat_modify 提前返回 -> 聚能不加威力。
	var mult_by_stacks: StringName = params.get("value_multiplier_by_stacks", &"")
	if mult_by_stacks != &"":
		var mult: int = int(params.get("value_multiplier", 0))
		result["value"] = mult * _count_status_stacks_for_payload(payload, mult_by_stacks)
	else:
		result["value"] = params.get("value", 0)
	result["method"] = params.get("method", &"add")
	result["duration"] = params.get("duration", &"")
	result["attack_action_id"] = params.get("attack_action_id", payload.get("action_id", &""))
	result["player_id"] = params.get("player_id", payload.get("player_id", &""))
	# pilot_004 玛沙 转换层：mode(cap_bonus)/runtime_tag/source_card_id 透传到 stat_modify record
	result["mode"] = params.get("mode", &"")
	result["runtime_tag"] = params.get("runtime_tag", &"")
	# source_card_id: 解析 $expr（$binding_context.card_instance_id）；空则退回 binding_context
	var sm_src_card = _resolve_atomic_value(params.get("source_card_id", &""), payload, parent_action)
	if sm_src_card == &"" or sm_src_card == null:
		sm_src_card = payload.get("binding_context", {}).get("card_instance_id", &"")
	result["source_card_id"] = sm_src_card
	# pilot_013 effect_02a：duration_owner_id/source_effect_id/source_key/source_target_id 透传到 record
	result["duration_owner_id"] = _resolve_atomic_value(params.get("duration_owner_id", &""), payload, parent_action)
	result["source_effect_id"] = params.get("source_effect_id", &"")
	result["source_key"] = params.get("source_key", &"")
	result["source_target_id"] = _resolve_atomic_value(params.get("source_target_id", &""), payload, parent_action)
	result["source"] = _build_source_from_payload(payload, parent_action)
	return result


## 按 payload.binding_context 统计指定状态类型的层数（供 value_multiplier_by_stacks 解析）。
## 聚能：状态监听器在 binding_context 携带 status_id（精确）/ weapon_id / target_id(机甲)，
## 据此定位该武器的 ENERGY_CHARGE 状态并读其 stacks（多张聚能叠在同一武器上时 stacks 累加）。
func _count_status_stacks_for_payload(payload: Dictionary, status_type: StringName) -> int:
	if context == null or context.game_state == null:
		return 0
	var bind_ctx: Dictionary = payload.get("binding_context", {}) if payload != null else {}
	var status_id: StringName = bind_ctx.get("status_id", &"")
	var mech_id: StringName = bind_ctx.get("target_id", &"")
	if mech_id == &"":
		mech_id = payload.get("attacker_id", payload.get("source_mech_id", payload.get("mech_id", &"")))
	if mech_id == &"":
		return 0
	var mech = context.game_state.mechs.get(mech_id)
	if mech == null:
		return 0
	var weapon_id: StringName = bind_ctx.get("weapon_id", payload.get("weapon_id", &""))
	var total: int = 0
	for s: Dictionary in mech.statuses:
		if s.get("type", &"") != status_type:
			continue
		if status_id != &"":
			if s.get("status_id", &"") == status_id:
				total += int(s.get("stacks", 1))
		elif weapon_id != &"":
			if s.get("weapon_id", &"") == weapon_id:
				total += int(s.get("stacks", 1))
		else:
			total += int(s.get("stacks", 1))
	return total


func _extract_move_params(action_def: Dictionary, payload: Dictionary, parent_action) -> Dictionary:
	var params: Dictionary = action_def.get("params", {})
	var result: Dictionary = {}
	result["mech_id"] = params.get("mech_id", payload.get("source_mech_id", &""))
	result["target_cell"] = params.get("target_cell", &"")
	result["available_power"] = params.get("available_power", 0)
	result["free_move"] = params.get("free_move", false)
	result["source"] = _build_source_from_payload(payload, parent_action)
	return result


func _extract_single_move_params(action_def: Dictionary, payload: Dictionary, parent_action) -> Dictionary:
	var params: Dictionary = action_def.get("params", {})
	var result: Dictionary = {}
	# mech_id 优先级：显式 params > source_mech_id（迎击/辅助牌 use_action_card 上下文）>
	# mech_id（basic_move payload，机动装·头部 effect_017 监听 BASIC_MOVE_AFTER：移动主体=本牌机甲）>
	# attacker_id（强袭 effect2 等监听 attack 动作、在补跑路径执行的 effect：移动主体是攻击发起方）。
	var move_mech: StringName = params.get("mech_id", payload.get("source_mech_id", &""))
	if move_mech == &"":
		move_mech = payload.get("mech_id", &"")
	if move_mech == &"":
		move_mech = payload.get("attacker_id", &"")
	# 装备离场诱发效果（effect_064 近战右腿等）：payload 是 discard_card 动作 record，
	# 无顶层 source_mech_id/mech_id，机甲只在 binding_context.mech_id（permanent listener 注入）
	# 或 parent_action.source.mech_id。RESTORE_POWER 经 _resolve_atomic_params 自动注入 source_mech_id，
	# 但 EXECUTE_SINGLE_MOVE 走 _extract_single_move_params 不注入 -> 缺 mech_id 致移动静默失效。
	if move_mech == &"":
		var _sm_bind_ctx: Dictionary = payload.get("binding_context", {}) if payload != null else {}
		move_mech = _sm_bind_ctx.get("mech_id", &"")
	if move_mech == &"" and parent_action != null and parent_action.source is Dictionary:
		move_mech = parent_action.source.get("mech_id", parent_action.source.get("source_mech_id", &""))
	result["mech_id"] = move_mech
	result["available_power"] = params.get("available_power", 0)
	result["power_fraction"] = params.get("power_fraction", 0.0)
	result["loop_until_cancel"] = params.get("loop_until_cancel", false)
	# 狙击腿免费相邻1格移动（effect_026/027）
	result["max_cells"] = params.get("max_cells", 0)
	result["free_move"] = params.get("free_move", false)
	result["adjacent_only"] = params.get("adjacent_only", false)
	result["source"] = _build_source_from_payload(payload, parent_action)
	return result


func _extract_set_equip_params(action_def: Dictionary, payload: Dictionary, parent_action) -> Dictionary:
	var params: Dictionary = action_def.get("params", {})
	var result: Dictionary = {}
	result["card_id"] = params.get("card_id", payload.get("card_id", &""))
	result["mech_id"] = params.get("mech_id", payload.get("source_mech_id", &""))
	# slot_id：显式指定优先（机师效果如约书亚 1b 选定目标槽位直接设置，跳过 need_input 选槽窗）。
	var p_se_slot = params.get("slot_id", &"")
	if p_se_slot == &"":
		p_se_slot = payload.get("slot_id", &"")
	result["slot_id"] = p_se_slot
	result["source"] = _build_source_from_payload(payload, parent_action)
	return result


## EXECUTE_SET_EVENT_CARD：设置事件牌到机甲事件区域（事件标记触发/e007 到期换新等）。
## params: mech_id（支持 $binding_context.mech_id 占位符）、event_card_id（可选，缺省抽牌堆顶）。
func _extract_set_event_card_params(action_def: Dictionary, payload: Dictionary, parent_action) -> Dictionary:
	var params: Dictionary = action_def.get("params", {})
	var resolved: Dictionary = _resolve_atomic_params(params, payload, parent_action)
	var result: Dictionary = {}
	result["mech_id"] = resolved.get("mech_id", payload.get("mech_id", payload.get("source_mech_id", &"")))
	if result["mech_id"] == &"":
		result["mech_id"] = payload.get("mech_id", &"")
	result["event_card_id"] = resolved.get("event_card_id", &"")
	result["source"] = _build_source_from_payload(payload, parent_action)
	return result


## EXECUTE_TRAP_EXPLOSION：效果链内以子动作发起标准陷阱爆炸（通用件，不绑机师；
## 墨尘 pilot_080「移至标记格使其再生效」的陷阱分支复用）。params 原样透传
## trigger_q/trigger_r/trigger_mech_id（与 MarkerService 触发陷阱同参）。
func _extract_trap_explosion_params(action_def: Dictionary, payload: Dictionary, parent_action) -> Dictionary:
	var params: Dictionary = action_def.get("params", {})
	var resolved: Dictionary = _resolve_atomic_params(params, payload, parent_action)
	var result: Dictionary = {}
	result["trigger_q"] = int(resolved.get("trigger_q", 0))
	result["trigger_r"] = int(resolved.get("trigger_r", 0))
	result["trigger_mech_id"] = resolved.get("trigger_mech_id", payload.get("mech_id", payload.get("source_mech_id", &"")))
	result["source"] = _build_source_from_payload(payload, parent_action)
	return result


func _extract_gain_card_params(action_def: Dictionary, payload: Dictionary, parent_action) -> Dictionary:
	var params: Dictionary = action_def.get("params", {})
	# 解析 $-占位符（player_id="$binding_context.player_id" 等）并注入 player_id/source_mech_id。
	# 仿原子动作 _execute_atomic_action 末尾的 _resolve_atomic_params；此前 EXECUTE_GAIN_CARD 不解析，
	# $binding_context.player_id 以字面字符串传入致 draw_action_cards 拿不到玩家。
	var resolved: Dictionary = _resolve_atomic_params(params, payload, parent_action)
	var result: Dictionary = {}
	result["card_ids"] = resolved.get("card_ids", [])
	# mech_ids：优先从 params 指定，否则从注入的 source_mech_id 取
	result["mech_ids"] = resolved.get("mech_ids", [])
	if result["mech_ids"].is_empty():
		var source_mech: StringName = resolved.get("source_mech_id", payload.get("mech_id", &""))
		if source_mech != &"":
			result["mech_ids"] = [source_mech]
	result["from_zone"] = resolved.get("from_zone", &"")
	result["reason"] = resolved.get("reason", &"effect")
	result["count"] = resolved.get("count", 1)
	result["random"] = resolved.get("random", false)
	result["card_kind"] = resolved.get("card_kind", &"")
	result["player_id"] = resolved.get("player_id", &"")
	# 明确指定 mech_ids（效果 params 显式给出，非 source 回退填充）：目标玩家由机甲反查
	# （gain_card_action 走 mech_ids[0] -> get_player_for_mech）。不能采用 _resolve_atomic_params
	# 从来源注入的 player_id——否则给目标机甲抽牌会错误发给效果来源玩家（莱特 pilot_031 目标抽）。
	var has_explicit_mech_ids: bool = false
	if params.has("mech_ids") and params["mech_ids"] is Array and not (params["mech_ids"] as Array).is_empty():
		has_explicit_mech_ids = true
	if has_explicit_mech_ids:
		result["player_id"] = &""
	elif result["player_id"] == &"":
		# LISTEN 效果的 player_id 在 binding_context（非 payload 顶层），_resolve_atomic_params 注入不到时回退取
		var _gc_bc: Dictionary = payload.get("binding_context", {}) if payload != null else {}
		result["player_id"] = _gc_bc.get("player_id", &"")
	result["source"] = _build_source_from_payload(payload, parent_action)
	# 透传 _ 前缀私有键（如 _draw_result_sink 父动作抽取结果回写、_pilot_022_draw_pending 等），
	# 供 gain_card_action._tag_draw 写回父 record（塔莉娅 effect_01 抽3张的循环回写依赖）。
	for k in params:
		if String(k).begins_with("_"):
			result[k] = params[k]
	return result


func _extract_discard_params(action_def: Dictionary, payload: Dictionary, parent_action) -> Dictionary:
	var params: Dictionary = action_def.get("params", {})
	var result: Dictionary = {}
	# card_ids 支持 $runtime.xxx（提比里安 pilot_021 effect_01 弃甲铸威：CHOOSE_MANY_CARDS
	# store_result_key 把选中牌存入 payload["pilot_021_weapon"]，此处解析为具体牌 id 数组）。
	result["card_ids"] = _resolve_atomic_value(params.get("card_ids", []), payload, parent_action)
	# count 支持 $runtime.xxx（pilot_007 effect_02 弃/抽 X+1 由 PILOT_007_COMPUTE_X 写入 payload.pilot_007_flaw_count）。
	result["count"] = int(_resolve_atomic_value(params.get("count", 1), payload, parent_action))
	# from_opposing（肯特 granted 帝国压制）：从对侧（非 source_mech 的攻击参与方）弃牌，使用方选 2 张暗牌。
	# source_mech=binding_context.mech_id（肯特被授予机甲）；player_id/executor 由 discard_card_action 反查。
	# 提前 return 避免与 from_target/自选弃置逻辑冲突（player_id 须=对侧而非使用方）。
	var from_opposing: bool = bool(params.get("from_opposing", false))
	result["from_opposing"] = from_opposing
	if from_opposing:
		var _fo_bind: Dictionary = payload.get("binding_context", {}) if payload != null else {}
		result["source_mech"] = _fo_bind.get("mech_id", payload.get("source_mech_id", payload.get("mech_id", &"")))
		result["target_id"] = payload.get("target_id", &"")
		result["attacker_id"] = payload.get("attacker_id", &"")
		result["attack_action_id"] = payload.get("attack_action_id", &"")
		result["executor"] = &""  # discard_card_action._step_determine_cards 从 source_mech 反查使用方
		result["choose"] = bool(params.get("choose", true))
		result["face_up"] = bool(params.get("face_up", false))
		result["no_cancel"] = bool(params.get("no_cancel", false))
		result["reason"] = params.get("reason", &"effect")
		result["source"] = _build_source_from_payload(payload, parent_action)
		return result
	# from_target=true 表示从攻击目标玩家手牌弃牌（预判 effect2）。
	# 透传 from_target/target_id/attacker_id，由 discard_card_action._step_determine_cards
	# 从 target_id 反查目标玩家（_extract_discard_params 无 context 访问，反查放到动作里）。
	var from_target: bool = params.get("from_target", false)
	result["from_target"] = from_target
	# target_id 支持 $current_target.mech_id（FOR_EACH_TARGET 逐目标，珀修斯 pilot_007 类型破绽双连）
	# 与 $payload.xxx 等动态表达式，统一经 _resolve_atomic_value 解析（原直接透传字面量，$ 表达式无法命中机甲）
	var ft_target_id: StringName = StringName(params.get("target_id", payload.get("target_id", &"")))
	if String(ft_target_id) != "" and String(ft_target_id).begins_with("$"):
		result["target_id"] = _resolve_atomic_value(ft_target_id, payload, parent_action)
	else:
		result["target_id"] = ft_target_id
	result["attacker_id"] = payload.get("attacker_id", &"")
	# attack_action_id：响应路径下 use_action_card 注入，供 _step_determine_cards 回退解析
	# target_id/attacker_id（新流程攻击信息只在攻击动作 record 里）。
	result["attack_action_id"] = payload.get("attack_action_id", &"")
	# from_target 且未指定 executor 时默认 system_random（对手手牌暗牌随机弃）。
	# executor 支持 $ 表达式（如 $current_target.owner_player_id，弥雅 pilot_071 被选机甲玩家自弃），
	# 经 _resolve_atomic_value 解析；字面玩家 id 原样返回不影响现有效果。
	if from_target and String(params.get("executor", &"")) == "":
		result["executor"] = &"system_random"
	else:
		result["executor"] = _resolve_atomic_value(params.get("executor", &""), payload, parent_action)
	# params 显式指定 player_id（被弃方玩家）：支持 $ 表达式解析。未指定时沿用下方
	# choose 自弃回退 / discard_all_action_hand 补全，不影响现有效果。
	if params.has("player_id"):
		result["player_id"] = _resolve_atomic_value(params.get("player_id", &""), payload, parent_action)
	# from_target=false + choose=true：持有者从己方手牌自选弃置（多功能机械臂「弃2抽2」等）。
	# executor 须置为来源玩家才触发 select_discard_cards UI；否则 executor 空走 system_default
	# 弃前N张牌（非玩家所选）。player_id 一并置上供 UI discard_player_id 路由。
	if not from_target and bool(params.get("choose", false)) and String(result.get("executor", &"")) == "":
		var _self_choose_pid: StringName = StringName(payload.get("player_id", &""))
		if _self_choose_pid == &"" and parent_action != null and parent_action.source is Dictionary:
			_self_choose_pid = parent_action.source.get("player_id", &"")
		# 通用回退：LISTEN 被动效果（如索伦 pilot_044 自弃）player_id 在 binding_context 而非 payload 顶层，
		# 回退取，保证 choose=true 自弃能弹弃牌选择 UI（否则 executor 空走 system_default 弃前N张）。
		if _self_choose_pid == &"":
			var _sc_bc: Dictionary = payload.get("binding_context", {}) if payload != null else {}
			_self_choose_pid = _sc_bc.get("player_id", &"")
		if _self_choose_pid != &"":
			result["executor"] = _self_choose_pid
			result["player_id"] = _self_choose_pid
	result["discard_all_action_hand"] = bool(params.get("discard_all_action_hand", false))
	result["auto_discard_all_if_covered"] = bool(params.get("auto_discard_all_if_covered", false))
	# 弃全部手牌行动牌（德伦迪 pilot_042 弃所有）：player_id 缺失时从 binding_context 补全，
	# 供 discard_card_action._step_determine_cards 取该玩家全部行动手牌。
	if result["discard_all_action_hand"] and String(result.get("player_id", &"")) == "":
		var _da_bind: Dictionary = payload.get("binding_context", {}) if payload != null else {}
		var _da_pid: StringName = StringName(_da_bind.get("player_id", payload.get("player_id", &"")))
		if _da_pid == &"" and parent_action != null and parent_action.source is Dictionary:
			_da_pid = StringName(parent_action.source.get("player_id", &""))
		if _da_pid != &"":
			result["player_id"] = _da_pid
	result["choose"] = params.get("choose", false)
	result["face_up"] = params.get("face_up", true)
	result["no_cancel"] = bool(params.get("no_cancel", false))
	result["reason"] = params.get("reason", &"effect")
	result["source"] = _build_source_from_payload(payload, parent_action)
	return result


## 提取偷牌动作参数（识破效果1）
## from_attacker=true：从攻击者手牌偷1张给防御方（识破使用者）。
## 攻击方信息经 attack_action_id 在动作步骤内解析（新流程不写 current_attack_id）。
func _extract_steal_params(action_def: Dictionary, payload: Dictionary, parent_action) -> Dictionary:
	var params: Dictionary = action_def.get("params", {})
	var result: Dictionary = {}
	result["from_attacker"] = params.get("from_attacker", false)
	result["from_target"] = params.get("from_target", false)
	result["count"] = params.get("count", 1)
	result["choose"] = params.get("choose", false)
	# attack_action_id：响应窗口发起 use_action_card 时注入（TimingEngine.handle_response_selection）
	result["attack_action_id"] = payload.get("attack_action_id", &"")
	# 透传 attack record 字段（非响应路径下 parent 可能就是 attack）
	result["attacker_id"] = payload.get("attacker_id", &"")
	result["target_id"] = payload.get("target_id", &"")
	# 获得方 = 识破使用者（防御方）
	result["to_player_id"] = payload.get("player_id", &"")
	result["player_id"] = payload.get("player_id", &"")
	result["executor"] = params.get("executor", &"")
	# pilot_012：from_target_id / to_target_id（机甲id）/ chooser_id（玩家id）
	# 这些是 $expr 变量（$current_target.mech_id / $binding_context.*），需解析
	var ft_id = params.get("from_target_id", &"")
	if String(ft_id) != "":
		result["from_target_id"] = _resolve_atomic_value(ft_id, payload, parent_action)
	else:
		result["from_target_id"] = &""
	var tt_id = params.get("to_target_id", &"")
	if String(tt_id) != "":
		result["to_target_id"] = _resolve_atomic_value(tt_id, payload, parent_action)
	else:
		result["to_target_id"] = &""
	var chooser = params.get("chooser_id", &"")
	if String(chooser) != "":
		result["chooser_id"] = _resolve_atomic_value(chooser, payload, parent_action)
	else:
		result["chooser_id"] = &""
	result["card_kind"] = params.get("card_kind", &"ACTION")
	result["optional"] = params.get("optional", false)
	# 青瞳 pilot_037：明牌显示攻击方手牌（face_up=true）+ 不可取消（no_cancel=true，强制获得1张）
	result["face_up"] = params.get("face_up", false)
	result["no_cancel"] = params.get("no_cancel", false)
	# 已预选牌（玩家选完恢复 / 测试注入）
	result["determined_card_ids"] = payload.get("determined_card_ids", [])
	result["selected_action_card_ids"] = payload.get("selected_action_card_ids", [])
	result["source"] = _build_source_from_payload(payload, parent_action)
	return result


## 提取觉醒动作参数（行动牌 action_024_觉醒 DIRECT 效果）
## payload 来自 use_action_card 的 record（含 player_id / source_mech_id）。
func _extract_awaken_params(action_def: Dictionary, payload: Dictionary, parent_action) -> Dictionary:
	var result: Dictionary = {}
	result["player_id"] = payload.get("player_id", &"")
	result["mech_id"] = payload.get("source_mech_id", payload.get("mech_id", &""))
	result["source_mech_id"] = result["mech_id"]
	result["source"] = _build_source_from_payload(payload, parent_action)
	return result


func _extract_hp_change_params(action_def: Dictionary, payload: Dictionary, parent_action) -> Dictionary:
	var params: Dictionary = action_def.get("params", {})
	var result: Dictionary = {}
	# 通用：mech_ids 支持 $payload.target_id / $binding_context.mech_id 等表达式
	# （塞万提斯 pilot_034 effect_02b 复仇反击额外3伤害 / 回复3生命用）。逐项解析。
	result["mech_ids"] = _resolve_atomic_value(params.get("mech_ids", []), payload, parent_action)
	result["value"] = params.get("value", 0)
	result["method"] = params.get("method", &"decrease")
	result["reason"] = params.get("reason", &"")
	# pilot_013 effect_01：攻击步骤7发起的 hp_change 写入权威标记，进 record -> payload，
	# 供 ConditionChecker.HP_CHANGE_REASON_IS_NOT_ATTACK_DAMAGE 优先判定为攻击伤害（不免疫）。
	result["created_by_attack_damage_step"] = bool(params.get("created_by_attack_damage_step", false))
	result["source"] = _build_source_from_payload(payload, parent_action)
	# 显式来源机甲（效果伤害来源，如塞万提斯 +3 的效果伤害，来源=其所属机甲）覆盖 source.mech_id。
	var hp_src_expr: StringName = params.get("source_mech_id", &"")
	if hp_src_expr != &"":
		var hp_src_mech: StringName = _resolve_atomic_value(hp_src_expr, payload, parent_action)
		result["source"]["mech_id"] = hp_src_mech
	return result


func _extract_damage_change_params(action_def: Dictionary, payload: Dictionary, parent_action) -> Dictionary:
	var params: Dictionary = action_def.get("params", {})
	var result: Dictionary = {}
	result["mech_ids"] = params.get("mech_ids", [])
	result["value"] = params.get("value", 0)
	result["method"] = params.get("method", &"increase")
	# executor 解析 $binding_context.mech_id 等表达式（effect_031 近战右腿离场移除损伤用）。
	# 不解析则保留字面 "$binding_context.mech_id"，_popup_owner 的 damage_token_placement 路由
	# _owner_of_mechid 返回空 -> PvP 两端都弹窗（仅持有者应弹+执行）。
	result["executor"] = _resolve_atomic_value(params.get("executor", &""), payload, parent_action)
	result["reason"] = params.get("reason", &"")
	# fixed_slot：直接置X点到指定 slot（规则2"设置X损伤到此牌/区域上"），跳过转移窗与逐点UI。
	# effect_035/039 用：target_mech_id/target_slot_id 从 $binding_context 解析（来源装备牌机甲/槽）。
	result["fixed_slot"] = bool(params.get("fixed_slot", false))
	# direct_remove：设装备移除旧区域损伤走 damage_change(decrease) 时用，直接从指定 slot 区域
	# 移除 value 个损伤（不弹面板）。pilot_008 effect_03 逆转时清除此标志改走 increase 放置面板。
	result["direct_remove"] = bool(params.get("direct_remove", false))
	result["target_mech_id"] = _resolve_atomic_value(params.get("target_mech_id", &""), payload, parent_action)
	result["target_slot_id"] = _resolve_atomic_value(params.get("target_slot_id", &""), payload, parent_action)
	# exclude_slot_id：decrease 移除损伤时排除此槽（effect_079 离场移除"其他区域"损伤，排除来源槽）
	result["exclude_slot_id"] = _resolve_atomic_value(params.get("exclude_slot_id", &""), payload, parent_action)
	# allow_cancel：decrease 移除损伤面板显示「取消」按钮（薇尔 pilot_059 等"最多移除"效果，
	# 取消=不移除直接结算，不走 cancel_action 以免整棵父动作链被取消）。
	# max_mode：decrease 移除损伤面板显示「完成」按钮（剩余不强制移除，可提前结束）。
	result["allow_cancel"] = bool(params.get("allow_cancel", false))
	result["max_mode"] = bool(params.get("max_mode", false))
	result["source_label"] = params.get("source_label", &"")
	result["source"] = _build_source_from_payload(payload, parent_action)
	return result


## pilot_002 批次使用：丢弃整批牌（保留首张作虚拟牌）+ use_action_card virtual_transform。
## named_type=进攻 -> as_card_def_id=action_001_进攻；防御 -> action_009_防御。
## 裁定：整批牌作为代价进弃牌堆，生成1张虚拟"进攻/防御"使用；进攻消耗攻击数（主动），防御响应窗口。
func _extract_pilot_002_batch_use_params(action_def: Dictionary, payload: Dictionary, parent_action) -> Dictionary:
	var params: Dictionary = action_def.get("params", {})
	var as_card_def_id: StringName = params.get("as_card_def_id", &"action_001_进攻")
	var bind_ctx: Dictionary = payload.get("binding_context", {})
	# 丢弃批次（保留首张作虚拟牌）
	var virtual_cid: StringName = &""
	if context != null and context.game_actions != null:
		virtual_cid = context.game_actions.pilot_002_discard_batch(params, payload)
	var result: Dictionary = {
		"card_instance_id": virtual_cid,
		"as_card_def_id": as_card_def_id,
		"virtual_transform": true,
		"target_count": 1,
	}
	# mech_id/player_id 从 binding_context（批次使用者是目标机甲）
	var target_mech: StringName = bind_ctx.get("mech_id", &"")
	result["mech_id"] = target_mech
	if target_mech != &"" and context != null and context.game_state != null:
		var p = context.game_state.get_player_for_mech(target_mech)
		if p != null:
			result["player_id"] = p.player_id
	# source：进攻分支(attack_is_active=true)消耗回合攻击数（source_action_id 空）；防御分支(被动)跳过
	var is_active: bool = bool(params.get("attack_is_active", true))
	# 进攻转化消耗1次攻击次数（virtual_transform 默认不消耗，此处显式开启；见 use_action_card_action.gd）
	result["consume_attack_count"] = is_active
	var src: Dictionary = {}
	src["player_id"] = result.get("player_id", &"")
	src["mech_id"] = target_mech
	src["card_instance_id"] = bind_ctx.get("card_instance_id", &"")
	if not is_active and parent_action != null:
		src["source_action_id"] = parent_action.action_id
	result["source"] = src
	# 防御响应：attack_action_id 供 _step_validate_card 放行 AVAILABILITY 牌
	var p002_atk_id: StringName = payload.get("attack_action_id", payload.get("action_id", &""))
	if p002_atk_id != &"":
		result["attack_action_id"] = p002_atk_id
	return result


## 提取通用 PLAY_AS_NAMED 参数：把临时区燃料牌当作具名行动牌使用。
## 复用莱比尔 PILOT_002_USE_BATCH_AS_NAMED 的 virtual_transform 模式：
##   燃料牌来源两种：
##     ① cost 阶段（DISCARD_ALL_ACTION_CARDS / DISCARD_ACTION_CARD to_temp_zone）已把选中手牌
##       移入临时区并写 payload.temp_zone_card_ids（诺拉全牌当进攻/防御）；
##     ② MOVE_ACTION_CARDS_TO_TEMP_ZONE 原子动作把 CHOOSE_MANY_CARDS 选中的燃料牌移入临时区
##       并写 payload.temp_zone_card_ids（伏特2张当强袭/猛击/破甲、布鲁克转化防御同款流程）。
##   此处取首张作虚拟牌（zone 已是 temp_zone），当作 as_card_def_id 使用。
##   链末 DISCARD_TEMP_ZONE_CARDS 把临时区全部牌（含首张虚拟牌）入弃牌堆。
## 进攻分支(attack_is_active=true)消耗回合攻击数；防御分支(被动)跳过，attack_action_id 定位原攻击。
## 守卫：临时区燃料牌为空（成本未付/流程异常）时返回空字典，execute_sub_action 据此不创建子动作。
func _extract_play_as_named_params(action_def: Dictionary, payload: Dictionary, parent_action) -> Dictionary:
	var params: Dictionary = action_def.get("params", {})
	var as_card_def_id: StringName = params.get("as_card_def_id", &"action_001_进攻")
	var bind_ctx: Dictionary = payload.get("binding_context", {})
	# 燃料牌已移入临时区，取首张作虚拟牌
	var temp_ids: Array = payload.get("temp_zone_card_ids", [])
	var virtual_cid: StringName = &""
	if not temp_ids.is_empty():
		virtual_cid = temp_ids[0]
	else:
		return {}
	var result: Dictionary = {
		"card_instance_id": virtual_cid,
		"as_card_def_id": as_card_def_id,
		"virtual_transform": true,
		"target_count": 1,
	}
	# mech_id/player_id 从 binding_context（使用者是诺拉所属机甲）
	var target_mech: StringName = bind_ctx.get("mech_id", &"")
	result["mech_id"] = target_mech
	if target_mech != &"" and context != null and context.game_state != null:
		var p = context.game_state.get_player_for_mech(target_mech)
		if p != null:
			result["player_id"] = p.player_id
	# source：进攻分支(attack_is_active=true)消耗回合攻击数（source_action_id 空）；
	# 防御分支(被动)跳过攻击数（source_action_id=parent 标被动）。
	var is_active: bool = bool(params.get("attack_is_active", true))
	# 进攻转化消耗1次攻击次数（virtual_transform 默认不消耗，此处显式开启；见 use_action_card_action.gd）
	result["consume_attack_count"] = is_active
	var src: Dictionary = {}
	src["player_id"] = result.get("player_id", &"")
	src["mech_id"] = target_mech
	src["card_instance_id"] = bind_ctx.get("card_instance_id", &"")
	if not is_active and parent_action != null:
		src["source_action_id"] = parent_action.action_id
	result["source"] = src
	# 防御响应：attack_action_id 供 _step_validate_card 放行 AVAILABILITY 牌
	var p015_atk_id: StringName = payload.get("attack_action_id", payload.get("action_id", &""))
	if p015_atk_id != &"":
		result["attack_action_id"] = p015_atk_id
	return result


func _extract_show_card_params(action_def: Dictionary, payload: Dictionary, parent_action) -> Dictionary:
	var params: Dictionary = action_def.get("params", {})
	var result: Dictionary = {}
	result["card_ids"] = params.get("card_ids", [])
	result["show_to_mech_ids"] = params.get("show_to_mech_ids", [])
	result["persistent"] = params.get("persistent", false)
	result["source"] = _build_source_from_payload(payload, parent_action)
	return result


func _extract_effect_fire_params(action_def: Dictionary, payload: Dictionary, parent_action) -> Dictionary:
	var params: Dictionary = action_def.get("params", {})
	var result: Dictionary = {}
	result["effect_id"] = params.get("effect_id", &"")
	result["targets"] = params.get("targets", [])
	result["source"] = _build_source_from_payload(payload, parent_action)
	return result


## 提取使用行动牌效果动作参数（联合状态效果1：Target使用1张攻击牌）
## params: {card_action_type: "攻击", target_count: 1, optional: true}
func _extract_use_action_card_params(action_def: Dictionary, payload: Dictionary, parent_action) -> Dictionary:
	var params: Dictionary = action_def.get("params", {})
	var result: Dictionary = {}
	var bind_ctx: Dictionary = payload.get("binding_context", {})
	# 优先用显式参数（联合攻击：已选定具体攻击牌+Target机甲），否则从 binding_context 推导
	var target_mech_id: StringName = params.get("mech_id", bind_ctx.get("target_id", payload.get("source_mech_id", &"")))
	result["mech_id"] = target_mech_id
	# 玩家ID：优先显式参数，否则从机甲反查
	if params.has("player_id") and String(params.get("player_id", &"")) != "":
		result["player_id"] = params["player_id"]
	elif target_mech_id != &"" and context != null and context.game_state != null:
		var player = context.game_state.get_player_for_mech(target_mech_id)
		if player != null:
			result["player_id"] = player.player_id
	# 联合攻击：直接指定要使用的攻击牌（玩家弹窗选定），透传到 use_action_card record。
	# 无显式 card_instance_id 时为空（旧 CHOOSE_ONE 路径，已废弃），use_action_card 会报缺牌。
	# 转化行动牌（effect_130/135）传 $chosen_card.card_instance_id 表达式，需解析（_extract_sub_action_params 不解析 $）。
	# 布鲁克 effect_02 实体防御牌传 $runtime.pilot_030_defend_card（CHOOSE_MANY_CARDS store_result_key 存 Array）。
	# 数组 size==1 时解包为单 id（max_count=1 单张选择）；多张场景保持数组原样（card_ids 类参数仍用数组）。
	if params.has("card_instance_id") and String(params.get("card_instance_id", &"")) != "":
		var ua_cid: Variant = _resolve_atomic_value(params.get("card_instance_id", &""), payload, parent_action)
		if typeof(ua_cid) == TYPE_ARRAY and (ua_cid as Array).size() == 1:
			ua_cid = (ua_cid as Array)[0]
		result["card_instance_id"] = ua_cid
	# 攻击牌过滤参数（供 use_action_card_action 在需要选牌时使用）
	result["card_action_type_filter"] = params.get("card_action_type", &"")
	result["target_count"] = params.get("target_count", 1)
	result["is_virtual"] = params.get("is_virtual", false)
	# effect_130/135 维修臂：把选定的行动牌当作 as_card_def_id（如维修）打出，
	# 效果按 as_card_def_id 定义执行，原牌实例进临时区/弃牌堆。
	result["as_card_def_id"] = params.get("as_card_def_id", &"")
	result["consume_original_card"] = bool(params.get("consume_original_card", false))
	# virtual_transform：转化行动牌为虚拟牌（不消耗攻击次数、不受类型限制），
	# 供 use_action_card _step_validate_card / _step_settle 跳过攻击次数校验/结算。
	result["virtual_transform"] = bool(params.get("virtual_transform", false))
	result["source"] = _build_source_from_payload(payload, parent_action)
	# attack_action_id：掩护经 CHOOSE_MANY_CARDS as_use_action_card 批量打出时，需定位当前 attack
	# 供 cover_effect1_direct(MODIFY_ATTACK_MIGHT -5) 改威力。优先显式 params，退回 payload（ATTACK_PRE
	# fire 时 payload.action_id 即 attack action_id；迎击牌 USE_ACTION_AT 时 payload.attack_action_id）。
	result["attack_action_id"] = params.get("attack_action_id", payload.get("attack_action_id", payload.get("action_id", &"")))
	return result


func _build_source_from_payload(payload: Dictionary, parent_action) -> Dictionary:
	var source: Dictionary = {}
	source["player_id"] = payload.get("player_id", &"")
	source["mech_id"] = payload.get("source_mech_id", payload.get("mech_id", &""))
	source["card_instance_id"] = payload.get("card_instance_id", payload.get("card_id", &""))
	source["effect_id"] = payload.get("effect_id", &"")
	if parent_action != null:
		source["source_action_id"] = parent_action.action_id
	return source


## 提比里安 pilot_021 effect_02：取攻击武器「原本威力」（牌面威力，不含增减/衰减修正）。
## 供 PILOT_022_MULTIPLY_ATTACK_MIGHT 计算 1.5 倍（delta=floor(原威力/2)）累加到 extra_might。
## 与 attack_action._get_weapon_stats 的读取逻辑对齐：
##   基础武器(frame_base_weapon_N) → base_weapon.might
##   实体/虚拟武器 → def.might（虚拟神莺躯干经 def.might=20）
## 注意：不走 get_effective_weapon_stats（那含聚能等临时修正，非「原本威力」）。
func _pilot_021_printed_weapon_might(attacker, weapon_id: StringName) -> int:
	if weapon_id == &"":
		return 0
	var wid_str := String(weapon_id)
	# 基础武器虚拟ID
	if wid_str.begins_with("frame_base_weapon"):
		if attacker == null or not attacker.has_method("get_base_weapon"):
			return 0
		var slot_index: int = 0
		if wid_str.begins_with("frame_base_weapon_"):
			slot_index = wid_str.trim_prefix("frame_base_weapon_").to_int() - 1
		var base_weapon = attacker.get_base_weapon(slot_index)
		if not base_weapon.is_empty():
			return int(base_weapon.get("might", 0))
	# 实体/虚拟武器：读 CardDef.might（牌面原本威力）
	if context != null and context.game_state != null:
		var weapon_card = context.game_state.get_card(weapon_id)
		if weapon_card != null and weapon_card.def != null:
			# 虚拟武器（神莺躯干 effect_087）：当作威力20/范围6远程武器，def 无 might 字段，
			# 原本威力取虚拟武器字典的 might=20。
			if _GenEquipEffects.get_virtual_weapon_from_equipment(weapon_card).get("is_virtual", false) == true:
				return 20
			return int(weapon_card.def.might) if "might" in weapon_card.def else 0
	return 0
