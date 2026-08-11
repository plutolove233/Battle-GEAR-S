## damage_change_action.gd — 损伤变动动作
##
## 按新规则文档定义：
##   ① 提取损伤变动信息 → 发出 DAMAGE_CHANGE_BEFORE
##   ② 弹出设置损伤UI → 发出 DAMAGE_CHANGE_AFTER
##   ③ 损伤变动结算 → 发出 DAMAGE_CHANGE_SETTLE
##
## 如果执行者是机甲，弹出UI让玩家逐个设置/移除损伤
extends Action
class_name DamageChangeAction

const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")


func _init() -> void:
	action_type = &"damage_change"


func setup_steps() -> void:
	# 损伤转移窗口（A6）：在放置损伤前 fire DAMAGE_REDIRECT_WINDOW，
	# 转移效果（联邦右臂/机动右臂）监听并弹汇总窗选转移点数，提交后写 record["redirect_plan"]。
	steps = [
		{step_name = &"extract_info",   timing_point = _TimingConst.DAMAGE_CHANGE_BEFORE,   handler = _step_extract_info},
		{step_name = &"offer_redirect", timing_point = _TimingConst.DAMAGE_REDIRECT_WINDOW,  handler = _step_offer_redirect},
		{step_name = &"set_damage",     timing_point = _TimingConst.DAMAGE_CHANGE_AFTER,    handler = _step_set_damage},
		{step_name = &"settle",         timing_point = _TimingConst.DAMAGE_CHANGE_SETTLE,   handler = _step_settle},
	]


func get_display_name() -> String:
	return "损伤变动"


func _step_extract_info(action: Action) -> Dictionary:
	# 暴露 total_points（= value）供 DAMAGE_REDIRECT_WINDOW 的转移效果读取
	var value: int = action.record.get("value", 0)
	action.record["total_points"] = value
	# 开启放置日志记录（guard flag），并清空上一次的逐枚放置临时日志，
	# 供本动作 _step_settle 回写父 attack damage_placement_log（effect_101/119 同区/非同区判定）。
	# flag 在 _step_settle 关闭，使 effect_101 在 ATTACK_SETTLE 追加的 +2 损伤不计入日志。
	if context != null and context.game_state != null:
		context.game_state.temp_values["logging_damage_placement"] = true
		context.game_state.temp_values["last_damage_placement_log"] = []
	# fixed_slot：直接置X点到指定 slot（规则2），不开损伤转移窗（050歧义2 fixed_slot 不可转移）。
	# 把 offer_redirect step 的 timing_point 置空，_execute_step 阶段3 不 fire DAMAGE_REDIRECT_WINDOW。
	if bool(action.record.get("fixed_slot", false)):
		for s in action.steps:
			if s.get("timing_point", &"") == _TimingConst.DAMAGE_REDIRECT_WINDOW:
				s["timing_point"] = &""
	return {}


func _step_offer_redirect(action: Action) -> Dictionary:
	# DAMAGE_REDIRECT_WINDOW 时点由 ActionEngine 自动 fire（timing_point 配置）。
	# 转移效果此时点触发，弹汇总窗选转移点数，提交后写 action.record["redirect_plan"]。
	# 此 handler 无需做事；若 redirect_plan 已写入则继续，若无转移效果监听则直接进 set_damage。
	return {}


func _step_set_damage(action: Action) -> Dictionary:
	var result: Dictionary = {}
	var mech_ids: Array = action.record.get("mech_ids", [])
	var value: int = action.record.get("value", 0)
	var method: StringName = action.record.get("method", &"increase")
	var redirect_plan: Array = action.record.get("redirect_plan", [])
	# effect_136 太空合金盾牌在 ATTACK_AFTER（damage_change 之前）已把 redirect_plan 写入父 attack record。
	# 本动作 record 无 redirect_plan 时兜底从父 attack 取。
	if redirect_plan.is_empty():
		var parent_atk = _get_parent_attack(action)
		if parent_atk != null:
			redirect_plan = parent_atk.record.get("redirect_plan", [])

	if value == 0:
		return result

	# fixed_slot：直接置X点到指定 slot（规则2"设置X损伤到此牌/区域上"），不弹逐点UI、不开转移窗。
	# place_damage_tokens_on_slot 逐点放置（优先装备牌，再 region），之后检查耐久弃置（规则1）。
	# effect_035（置1损伤减威力4）/ effect_039（置2损伤减3攻击损伤）用。
	if bool(action.record.get("fixed_slot", false)) and method == &"increase":
		var fs_mech_raw = action.record.get("target_mech_id", &"")
		var fs_slot_raw = action.record.get("target_slot_id", &"")
		var fs_mech: StringName = StringName(fs_mech_raw) if fs_mech_raw != null else &""
		var fs_slot: StringName = StringName(fs_slot_raw) if fs_slot_raw != null else &""
		if fs_mech != &"" and fs_slot != &"" and context != null and context.game_actions != null:
			context.game_actions.place_damage_tokens_on_slot({"mech_id": fs_mech, "slot_id": fs_slot, "amount": value})
			if context.game_actions.has_method("_check_equipment_broken_after_damage"):
				context.game_actions._check_equipment_broken_after_damage(fs_mech, fs_slot)
		return result

	# executor：record.executor 为空时从 action.source 推导（_create_action 把 source
	# 注入 action.source 而非 record）。损伤移除/增加由维修使用者决定，即使对其他机甲
	# 使用也由使用者操作损伤框；_popup_owner 的 damage_token_placement 据此路由到发起方，
	# 避免双端都弹窗（否则维修能被两端各操作一次 = 作用多次）。
	var executor: StringName = StringName(action.record.get("executor", &""))
	if executor == &"" and action.source is Dictionary:
		executor = StringName(action.source.get("player_id", &""))

	if method == &"increase":
		# 若有转移计划（DAMAGE_REDIRECT_WINDOW 写入），先把转移点直接放到目标区域，
		# 剩余的走原 UI 逐点/自动放置。
		var remaining: int = value
		if not redirect_plan.is_empty():
			remaining = _apply_redirect_plan(mech_ids, redirect_plan, action)

		var already_placed: bool = bool(action.record.get("placed", false)) or bool(action.record.get("auto_placed", false))
		if remaining > 0 and not already_placed:
			return {
				"need_input": true,
				"input_type": &"place_damage_tokens",
				"input_params": {
					"mech_ids": mech_ids,
					"amount": remaining,
					"executor": executor,
				},
			}
		# 损伤已放置完毕，进入结算
		return result
	elif method == &"decrease":
		# direct_remove：设装备移除旧区域损伤走 damage_change(decrease) 时用。
		# 直接从指定 slot 区域移除 value 个损伤（不弹面板），pilot_008 effect_03 逆转时
		# 会清除 direct_remove 改 method=increase 走下方放置面板。
		if bool(action.record.get("direct_remove", false)):
			var dr_mech: StringName = StringName(action.record.get("target_mech_id", &""))
			var dr_slot: StringName = StringName(action.record.get("target_slot_id", &""))
			if dr_mech != &"" and dr_slot != &"" and context.game_actions != null:
				context.game_actions.remove_damage_tokens_from_slot_region(dr_mech, dr_slot, value)
			return result
		# 减少损伤：弹损伤框让玩家逐一选择从哪些槽位移除（与 increase 的放置框对称，
		# 复用 damage_placement_panel 的 removal 模式）。AI 路径由 ActionUIBridge 自动移除。
		# 已回填 placed（玩家手动完成）/auto_placed（AI）则跳过，进入结算。
		var already_removed: bool = bool(action.record.get("placed", false)) or bool(action.record.get("auto_placed", false))
		if value > 0 and not already_removed:
			var dec_exclude: StringName = StringName(action.record.get("exclude_slot_id", &""))
			var dec_input: Dictionary = {
				"mech_ids": mech_ids,
				"amount": value,
				"executor": executor,
				"removal_mode": true,
			}
			if dec_exclude != &"":
				dec_input["exclude_slot_id"] = dec_exclude
			return {
				"need_input": true,
				"input_type": &"place_damage_tokens",
				"input_params": dec_input,
			}
		# 已移除完毕（placed/auto_placed），fall through 进入结算

	return result


## 沿父动作链找 attack（damage_change 是 attack 的子动作）。
## effect_136 在 ATTACK_AFTER 把 redirect_plan/redirect_absorbed 写入父 attack record，此处兜底读取。
func _get_parent_attack(action: Action):
	if context == null or context.action_registry == null:
		return null
	var pid: StringName = action.parent_action_id
	while pid != &"":
		var parent = context.action_registry.get_action(pid)
		if parent == null:
			break
		if parent.action_type == &"attack":
			return parent
		pid = parent.parent_action_id
	return null


## 应用转移计划：把转移点直接放到目标 slot，返回剩余待放置点数
## redirect_plan = [{to_mech_id, to_slot_id, count}, ...]
func _apply_redirect_plan(mech_ids: Array, redirect_plan: Array, action: Action) -> int:
	var placed: int = 0
	for entry: Dictionary in redirect_plan:
		var to_mech: StringName = entry.get("to_mech_id", &"")
		var to_slot: StringName = entry.get("to_slot_id", &"")
		var count: int = int(entry.get("count", 0))
		if to_mech == &"" or to_slot == &"" or count <= 0:
			continue
		if context.game_actions != null:
			context.game_actions.place_damage_tokens_on_slot({"mech_id": to_mech, "slot_id": to_slot, "amount": count})
		placed += count
	# 转移的点也照常做耐久判断（place_damage_tokens_on_slot 后 _check_equipment_broken_after_damage 由 place_damage_tokens 路径处理）
	# 此处直接放置到 slot 不走逐点 hook，故手动检查目标 slot 装备是否损坏
	for entry: Dictionary in redirect_plan:
		var to_mech: StringName = entry.get("to_mech_id", &"")
		var to_slot: StringName = entry.get("to_slot_id", &"")
		var count: int = int(entry.get("count", 0))
		if to_mech == &"" or to_slot == &"" or count <= 0:
			continue
		if context.game_actions != null and context.game_actions.has_method("_check_equipment_broken_after_damage"):
			context.game_actions._check_equipment_broken_after_damage(to_mech, to_slot)
	# redirect_absorbed：本动作 record 优先，兜底从父 attack record 取（effect_136 在 ATTACK_AFTER 写入）。
	var rd_absorbed: int = int(action.record.get("redirect_absorbed", 0))
	if rd_absorbed == 0:
		var parent_atk = _get_parent_attack(action)
		if parent_atk != null:
			rd_absorbed = int(parent_atk.record.get("redirect_absorbed", 0))
	return int(action.record.get("value", 0)) - placed - rd_absorbed


func _step_settle(action: Action) -> Dictionary:
	# 回写本次损伤放置日志到父 attack（供 effect_101/119 同区/非同区判定读 damage_placement_log）
	if context != null and context.game_state != null:
		var log_arr: Array = context.game_state.temp_values.get("last_damage_placement_log", [])
		var parent_id: StringName = action.parent_action_id
		if not log_arr.is_empty() and parent_id != &"" and context.action_registry != null:
			var parent_atk = context.action_registry.get_action(parent_id)
			if parent_atk != null and parent_atk.action_type == &"attack":
				if not parent_atk.record.has("damage_placement_log"):
					parent_atk.record["damage_placement_log"] = []
				for s in log_arr:
					parent_atk.record["damage_placement_log"].append(s)
				# single_damage_slot_id：唯一受损区域（effect_101 追加2损伤目标）
				var distinct: Dictionary = {}
				for s in log_arr:
					distinct[s] = true
				if distinct.size() == 1:
					parent_atk.record["single_damage_slot_id"] = StringName(String(log_arr[0]))
		context.game_state.temp_values["last_damage_placement_log"] = []
		context.game_state.temp_values["logging_damage_placement"] = false
	return {}
