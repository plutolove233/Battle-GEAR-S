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
# 新增动作类用 preload 引用，避免 headless -s 模式下新 class_name 尚未注册到全局缓存
const _AwakenAction = preload("res://scripts/action_defs/awaken_action.gd")

## 动作类型到创建函数的映射
var _action_factories: Dictionary = {}

## 依赖注入：GameContext 容器
var context = null


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
		&"DRAW_ACTION", &"DRAW_EQUIPMENT", &"GAIN_SPECIFIC_CARD", \
		&"RANDOM_DRAW_FROM_DISCARD_OR_DECK", &"TRANSFER_ACTION_CARDS", \
		&"PLACE_DAMAGE_TOKENS", &"MODIFY_DAMAGE_TOKENS", &"REMOVE_DAMAGE_TOKENS", \
		&"HEAL_HP", &"DEAL_DAMAGE", &"DISCARD_CARD", &"DISCARD_ACTION_CARD", \
		&"DESTROY_CARD", &"SET_CARD_TO_SLOT", &"PLACE_OR_TRIGGER_TRAP", \
		&"REDUCE_EVENT_TIMER", &"SET_EVENT_TIMER", &"TRACK_EVENT_PROGRESS", \
		&"REVEAL_OR_PEEK_CARD", &"ROLL_D6", &"TOGGLE_AURA_TARGET", \
		&"CUSTOM_EFFECT_CHECK_TEXT", &"CHOOSE_ONE", &"MODIFY_ATTACK_COUNT", \
		&"MODIFY_ACTION_HAND_LIMIT", &"INCREMENT_VARIABLE", &"ADD_WEAPON_TAG", \
		&"CONVERT_WEAPON_KIND", &"NEGATE_EQUIPMENT_EFFECT", &"MODIFY_WEAPON_POWER", \
		&"SET_WEAPON_STATS", &"SHOP_BUY_MODIFIER", &"SWAP_HAND_LIMIT_AND_ATTACK_COUNT", \
		&"OPEN_OR_USE_RESPONSE", &"REDIRECT_DAMAGE_TOKENS", \
		&"REDIRECT_HEAL_TO_DAMAGE", &"REDIRECT_REMOVE_TO_PLACE_TOKENS", \
		&"MODIFY_NEXT_DAMAGE_DEALT", &"DECLARE_CARD_TYPE", \
		&"DRAW_ADVANCED_EQUIPMENT", &"PLACE_CARD_IN_DECK_FACE_UP", \
		&"DECREMENT_STATUS_DURATION", &"CANCEL_PARENT_ACTION", \
		&"SET_ATTACK_EFFECTIVE_WEAPON_KIND", &"REMOVE_DAMAGE_TOKENS_FROM_DISCARD_ORIGIN_SLOT", \
		&"OFFER_DAMAGE_REDIRECT", \
		&"DISCARD_SELF_AND_REDUCE_ATTACK_MARKERS", &"DISCARD_SELF_FROM_SLOT", &"REMOVE_DAMAGE_TOKENS_OTHER_SLOTS":
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
				&"choose", &"face_up", &"determined_card_ids", &"selected_action_card_ids", &"phase",
				&"max_cells", &"free_move", &"adjacent_only",
				&"target_slot_id", &"target_mech_id", &"fixed_slot", &"exclude_slot_id"]
			for key: String in params:
				if key in record_keys:
					action.record[key] = params[key]
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
		var prev: int = int(target_action.record.get("extra_markers", 0))
		target_action.record["extra_markers"] = prev + delta
		SLog.log_raw("[ACTION] %s extra_markers +%d (累计=%d)" % [String(target_action.action_id), delta, prev + delta])
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

	# 特殊处理 MODIFY_ATTACK_RANGE：把 delta 累加到父动作（attack A）的 record["extra_range"]。
	# 狙击头部（+1）/近战头部（-2）在 ATTACK_BEFORE 时点触发，parent_action 即 attack A。
	# _step_select_target/_step_check_hit 读取 weapon_range + extra_range 做范围/命中判断。
	# 支持 min_value 钳制（近战头部范围最低1）。
	if act_type == &"MODIFY_ATTACK_RANGE":
		if parent_action == null:
			push_warning("MODIFY_ATTACK_RANGE: 无父动作，无法写入 extra_range")
			return {"state": &"completed"}
		var params_range: Dictionary = action_def.get("params", {})
		var range_delta: int = int(params_range.get("delta", payload.get("delta", 0)))
		var range_prev: int = int(parent_action.record.get("extra_range", 0))
		var new_extra: int = range_prev + range_delta
		# min_value 钳制：最终有效范围 = weapon_range + extra_range 不低于 min_value
		var min_value: int = int(params_range.get("min_value", 0))
		if min_value > 0:
			var base_range: int = int(parent_action.record.get("weapon_range", 1))
			var effective: int = base_range + new_extra
			if effective < min_value:
				new_extra = min_value - base_range  # 钳制到 min_value
		parent_action.record["extra_range"] = new_extra
		SLog.log_raw("[ACTION] %s extra_range %+d (累计=%d)" % [String(parent_action.action_id), range_delta, new_extra])
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
		var amt_mech_id: StringName = payload.get("source_mech_id", payload.get("mech_id", &""))
		if amt_mech_id == &"" or context.game_state == null:
			push_warning("ADD_MECH_TEMP_ARMOR: 缺少 mech_id")
			return {"state": &"completed"}
		var amt_mech = context.game_state.mechs.get(amt_mech_id)
		if amt_mech == null:
			push_warning("ADD_MECH_TEMP_ARMOR: 找不到机甲 %s" % String(amt_mech_id))
			return {"state": &"completed"}
		var amt_params: Dictionary = action_def.get("params", {})
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
	if act_type == &"CANCEL_PARENT_ACTION":
		var cancel_params: Dictionary = action_def.get("params", {})
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

	# 来源信息（parent_action.source 优先，退回 payload）
	var src: Dictionary = parent_action.source if (parent_action != null and parent_action.source is Dictionary) else {}
	if not result.has("source_card_id"):
		result["source_card_id"] = src.get("card_instance_id", payload.get("card_instance_id", payload.get("card_id", &"")))
	if not result.has("source_mech_id"):
		result["source_mech_id"] = src.get("mech_id", payload.get("source_mech_id", payload.get("mech_id", &"")))
	if not result.has("player_id"):
		result["player_id"] = src.get("player_id", payload.get("player_id", &""))
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
	if typeof(value) != TYPE_STRING:
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
	# $source.xxx → 从 parent_action.source 取值
	var src: Dictionary = parent_action.source if (parent_action != null and parent_action.source is Dictionary) else {}
	if s == "$source.card_instance_id":
		return src.get("card_instance_id", &"")
	if s == "$source.mech_id":
		return src.get("mech_id", &"")
	if s == "$source.owner_player_id":
		return src.get("player_id", &"")
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
		# ── 抽牌/获得 ──
		&"DRAW_ACTION":
			ga.draw_action_cards(params)
		&"DRAW_EQUIPMENT":
			ga.draw_equipment_cards(params)
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
		# ── 弃牌/破坏 ──
		&"DISCARD_CARD":
			ga.discard_card(params)
		&"DISCARD_ACTION_CARD":
			ga.discard_action_card(params)
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
			ga.toggle_aura_target(params)
		&"CUSTOM_EFFECT_CHECK_TEXT":
			ga.custom_effect_check_text(params)
		# ── 新增动作（批次3原语扩展） ──
		&"APPLY_ENERGY_TO_WEAPON":
			ga.apply_energy_to_weapon(params)
		&"STEAL_ACTION_CARD":
			ga.steal_action_card(params)
		&"RANDOM_DISCARD_ACTION_CARD":
			ga.random_discard_action_card(params)
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
		&"SET_WEAPON_STATS":
			ga.set_weapon_stats(params)
		&"CONVERT_ARMOR_TO_POWER":
			ga.convert_armor_to_power(params)
		&"REDIRECT_HEAL_TO_DAMAGE":
			ga.redirect_heal_to_damage(params)
		&"REDIRECT_REMOVE_TO_PLACE_TOKENS":
			ga.redirect_remove_to_place_tokens(params)
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
func _dispatch_add_status(params: Dictionary, payload: Dictionary) -> void:
	if context == null or context.game_actions == null:
		return
	var status_type: StringName = params.get("status_type", &"")
	var duration = params.get("duration", 1)
	var target_is_attack_target: bool = params.get("target_is_attack_target", false)

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


## ── 效果动作参数提取 ──

func _extract_attack_params(action_def: Dictionary, payload: Dictionary, parent_action) -> Dictionary:
	var params: Dictionary = action_def.get("params", {})
	var result: Dictionary = {}
	result["attacker_id"] = params.get("attacker_id", payload.get("attacker_id", payload.get("source_mech_id", &"")))
	result["target_id"] = params.get("target_id", payload.get("target_id", &""))
	result["weapon_id"] = params.get("weapon_id", payload.get("weapon_id", &""))
	result["attack_card_id"] = params.get("attack_card_id", payload.get("attack_card_id", payload.get("card_instance_id", &"")))
	result["target_count"] = params.get("target_count", 1)
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
	return result


func _extract_stat_mod_params(action_def: Dictionary, payload: Dictionary, parent_action) -> Dictionary:
	var params: Dictionary = action_def.get("params", {})
	var result: Dictionary = {}
	result["target_id"] = params.get("target_id", payload.get("target_id", payload.get("mech_id", payload.get("source_mech_id", &""))))
	result["stat_type"] = params.get("stat_type", &"armor")
	result["stat_types"] = params.get("stat_types", [])
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
	result["source"] = _build_source_from_payload(payload, parent_action)
	return result


func _extract_gain_card_params(action_def: Dictionary, payload: Dictionary, parent_action) -> Dictionary:
	var params: Dictionary = action_def.get("params", {})
	var result: Dictionary = {}
	result["card_ids"] = params.get("card_ids", [])
	# mech_ids：优先从 params 指定，否则从 payload 提取 source_mech_id
	result["mech_ids"] = params.get("mech_ids", [])
	if result["mech_ids"].is_empty():
		var source_mech: StringName = payload.get("source_mech_id", payload.get("mech_id", &""))
		if source_mech != &"":
			result["mech_ids"] = [source_mech]
	result["from_zone"] = params.get("from_zone", &"")
	result["reason"] = params.get("reason", &"effect")
	result["count"] = params.get("count", 1)
	result["random"] = params.get("random", false)
	result["card_kind"] = params.get("card_kind", &"")
	result["source"] = _build_source_from_payload(payload, parent_action)
	return result


func _extract_discard_params(action_def: Dictionary, payload: Dictionary, parent_action) -> Dictionary:
	var params: Dictionary = action_def.get("params", {})
	var result: Dictionary = {}
	result["card_ids"] = params.get("card_ids", [])
	result["count"] = params.get("count", 1)
	# from_target=true 表示从攻击目标玩家手牌弃牌（预判 effect2）。
	# 透传 from_target/target_id/attacker_id，由 discard_card_action._step_determine_cards
	# 从 target_id 反查目标玩家（_extract_discard_params 无 context 访问，反查放到动作里）。
	var from_target: bool = params.get("from_target", false)
	result["from_target"] = from_target
	result["target_id"] = params.get("target_id", payload.get("target_id", &""))
	result["attacker_id"] = payload.get("attacker_id", &"")
	# attack_action_id：响应路径下 use_action_card 注入，供 _step_determine_cards 回退解析
	# target_id/attacker_id（新流程攻击信息只在攻击动作 record 里）。
	result["attack_action_id"] = payload.get("attack_action_id", &"")
	# from_target 且未指定 executor 时默认 system_random（对手手牌暗牌随机弃）。
	if from_target and String(params.get("executor", &"")) == "":
		result["executor"] = &"system_random"
	else:
		result["executor"] = params.get("executor", &"")
	result["choose"] = params.get("choose", false)
	result["face_up"] = params.get("face_up", true)
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
	result["mech_ids"] = params.get("mech_ids", [])
	result["value"] = params.get("value", 0)
	result["method"] = params.get("method", &"decrease")
	result["reason"] = params.get("reason", &"")
	result["source"] = _build_source_from_payload(payload, parent_action)
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
	result["target_mech_id"] = _resolve_atomic_value(params.get("target_mech_id", &""), payload, parent_action)
	result["target_slot_id"] = _resolve_atomic_value(params.get("target_slot_id", &""), payload, parent_action)
	# exclude_slot_id：decrease 移除损伤时排除此槽（effect_079 离场移除"其他区域"损伤，排除来源槽）
	result["exclude_slot_id"] = _resolve_atomic_value(params.get("exclude_slot_id", &""), payload, parent_action)
	result["source"] = _build_source_from_payload(payload, parent_action)
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
	if params.has("card_instance_id") and String(params.get("card_instance_id", &"")) != "":
		result["card_instance_id"] = params["card_instance_id"]
	# 攻击牌过滤参数（供 use_action_card_action 在需要选牌时使用）
	result["card_action_type_filter"] = params.get("card_action_type", &"")
	result["target_count"] = params.get("target_count", 1)
	result["is_virtual"] = params.get("is_virtual", false)
	result["source"] = _build_source_from_payload(payload, parent_action)
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
