## stat_modify_action.gd — 数值修正动作
##
## 按新规则文档定义的数值修正动作生命周期：
##   ① 提取数值修正信息 → 发出 STAT_MOD_BEFORE
##   ② 执行数值修正 → 发出 STAT_MOD_AFTER
##   ③ 数值修正结算 → 发出 STAT_MOD_SETTLE
##
## 数值修正类型：护甲、动力、威力、范围、金币
## 修正方式：增加、减少、回复（回复不能超出上限而增加可以）
##
## 参考：new_logic/各动作的生命周期与时点.docx "数值修正动作"
extends Action
class_name StatModifyAction

const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _SLog = preload("res://scripts/services/slog.gd")


func _init() -> void:
	action_type = &"stat_modify"


func setup_steps() -> void:
	steps = [
		{step_name = &"extract_info",   timing_point = _TimingConst.STAT_MOD_BEFORE, handler = _step_extract_info},
		{step_name = &"execute_mod",    timing_point = _TimingConst.STAT_MOD_AFTER,  handler = _step_execute_mod},
		{step_name = &"settle",         timing_point = _TimingConst.STAT_MOD_SETTLE, handler = _step_settle},
	]


func get_display_name() -> String:
	return "数值修正"


## ① 提取数值修正信息
## 记录：修正对象、类型、数值、修正方式
func _step_extract_info(action: Action) -> Dictionary:
	# 信息已在 record 中，直接透传
	return {}


## ② 执行数值修正
func _step_execute_mod(action: Action) -> Dictionary:
	var result: Dictionary = {}
	# stat_changes 数组模式（pilot_013 effect_02a）：每项 {stat_type, max_delta, current_delta}
	# 护甲/动力上限与当前值原子修正（apply_max_and_current_atomically）。与单 stat_type+value 路径互斥。
	var stat_changes: Array = action.record.get("stat_changes", [])
	if not stat_changes.is_empty():
		if context.game_actions == null:
			return result
		for change: Dictionary in stat_changes:
			_apply_stat_change(action, change)
		result["stat_changes"] = stat_changes
		return result
	var stat_type: StringName = action.record.get("stat_type", &"armor")
	var stat_types: Array = action.record.get("stat_types", [])
	if stat_types.is_empty():
		stat_types = [stat_type]
	var value: int = action.record.get("value", 0)
	var method: StringName = action.record.get("method", &"add")

	if value == 0:
		return result

	if context.game_actions == null:
		return result

	for type_value in stat_types:
		_apply_one_stat(action, StringName(type_value), value, method)

	result["stat_type"] = stat_type
	result["stat_types"] = stat_types
	result["value"] = value
	result["method"] = method
	return result


func _apply_one_stat(action: Action, stat_type: StringName, value: int, method: StringName) -> void:
	var is_decrease: bool = method in [&"decrease", &"reduce", &"sub"]
	# add/increase 路径保留 value 原始符号：effect_009 帝国躯干 armor value=-2 method=add
	# 需 delta=-2（护甲-2），此前用 abs(value) 丢负号变成 +2。
	var delta: int = -abs(value) if is_decrease else value
	var target_id: StringName = action.record.get("target_id", &"")
	match stat_type:
		&"armor":
			context.game_actions.modify_armor({
				"mech_id": target_id,
				"delta": delta,
				"duration": action.record.get("duration", &"THIS_TURN") if action.record.get("duration", &"") != &"" else &"THIS_TURN",
				"runtime_tag": action.record.get("runtime_tag", &""),
				"source_card_id": action.record.get("source_card_id", &""),
			})
		&"power":
			if method in [&"restore", &"heal"]:
				context.game_actions.restore_power({"mech_id": target_id, "amount": abs(value)})
			else:
				context.game_actions.modify_mech_power({
					"mech_id": target_id, "delta": delta,
					"duration": action.record.get("duration", &"THIS_TURN") if action.record.get("duration", &"") != &"" else &"THIS_TURN",
					"mode": action.record.get("mode", &""),
					"runtime_tag": action.record.get("runtime_tag", &""),
					"source_card_id": action.record.get("source_card_id", &""),
				})
		&"might":
			var attack = _get_target_attack(action)
			if attack != null:
				attack.record["extra_might"] = int(attack.record.get("extra_might", 0)) + delta
		&"range":
			var attack = _get_target_attack(action)
			if attack != null:
				attack.record["extra_range"] = int(attack.record.get("extra_range", 0)) + delta
		&"gold":
			if method == &"add" or method == &"increase":
				context.game_actions.gain_gold({"player_id": action.record.get("player_id", &""), "amount": abs(value)})
			elif method == &"decrease" or method == &"reduce":
				context.game_actions.spend_gold({"player_id": action.record.get("player_id", &""), "amount": abs(value)})


## stat_changes 数组单项处理（pilot_013 effect_02a 护甲/动力上限+当前值原子修正）。
## 护甲为衍生值（get_armor=装备+派生+modifier），无 max/current 区分：
##   - max_delta 忽略（护甲无上限概念）
##   - current_delta -> ARMOR_MODIFIER（duration=UNTIL_NEXT_OWNER_TURN+duration_owner_id，
##     计入 get_armor，_clean_until_next_owner_turn 到期移除后恢复）
## 动力有 max_power/power：
##   - max_delta -> POWER_CAP_MODIFIER（计入 get_total_power/max_power，UNTIL_NEXT_OWNER_TURN 到期恢复）
##   - current_delta -> current_only 直接减本身动力（clamp [0, max_power]，本身不恢复；
##     但 max_delta 到期恢复 + 下回合开始 restore_power 回满 => 当前动力到期恢复）
func _apply_stat_change(action: Action, change: Dictionary) -> void:
	var stat_type: StringName = change.get("stat_type", &"armor")
	var max_delta: int = int(change.get("max_delta", 0))
	var current_delta: int = int(change.get("current_delta", 0))
	if max_delta == 0 and current_delta == 0:
		return
	if context == null or context.game_state == null or context.game_actions == null:
		return
	var target_id: StringName = action.record.get("target_id", &"")
	var mech = context.game_state.mechs.get(target_id)
	if mech == null:
		push_error("stat_changes: 找不到机甲 %s" % String(target_id))
		return
	var duration: StringName = action.record.get("duration", &"UNTIL_NEXT_OWNER_TURN")
	var source_card_id: StringName = action.record.get("source_card_id", action.record.get("source_card_instance_id", &""))
	var duration_owner_id: StringName = action.record.get("duration_owner_id", &"")
	var source_effect_id: StringName = action.record.get("source_effect_id", &"")
	match stat_type:
		&"armor":
			if current_delta != 0:
				context.game_actions.modify_armor({
					"mech_id": target_id, "delta": current_delta,
					"duration": duration,
					"runtime_tag": source_effect_id if source_effect_id != &"" else &"pilot_013_armor_current",
					"source_card_id": source_card_id,
					"duration_owner_id": duration_owner_id,
				})
		&"power":
			# max_delta -> POWER_CAP_MODIFIER（计入 max_power，到期恢复）
			if max_delta != 0:
				var cap_status := {
					"status_id": context.game_state.next_id(&"status"),
					"type": &"POWER_CAP_MODIFIER",
					"delta": max_delta,
					"duration": duration,
					"source_card_id": source_card_id,
					"runtime_tag": source_effect_id if source_effect_id != &"" else &"pilot_013_power_cap",
					"duration_owner_id": duration_owner_id,
				}
				mech.statuses.append(cap_status)
				mech.max_power = mech.get_total_power()
				_SLog.log_stat_modify(
					context.game_state.current_attack_id,
					target_id, "mech", "动力上限", max_delta, "sub" if max_delta < 0 else "add",
					{"effect_id": source_effect_id, "card_id": source_card_id, "mech_id": target_id}
				)
			# current_delta -> current_only（直接减本身动力，clamp [0, max_power]，不恢复）
			if current_delta != 0:
				context.game_actions.modify_mech_power({
					"mech_id": target_id, "delta": current_delta, "method": &"add", "mode": &"current_only",
					"min_value": 0, "duration": &"",
					"source_card_id": source_card_id,
				})


func _get_target_attack(action: Action):
	if context == null or context.action_registry == null:
		return null
	var attack_id: StringName = action.record.get("attack_action_id", action.record.get("attack_id", &""))
	if attack_id != &"":
		var attack = context.action_registry.get_action(attack_id)
		if attack != null and attack.action_type == &"attack":
			return attack
	var parent_id: StringName = action.parent_action_id
	while parent_id != &"":
		var parent = context.action_registry.get_action(parent_id)
		if parent == null:
			break
		if parent.action_type == &"attack":
			return parent
		parent_id = parent.parent_action_id
	return null


## ③ 数值修正结算
func _step_settle(action: Action) -> Dictionary:
	return {}
