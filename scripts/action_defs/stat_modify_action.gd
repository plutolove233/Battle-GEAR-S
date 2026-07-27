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
	var delta: int = -abs(value) if is_decrease else abs(value)
	var target_id: StringName = action.record.get("target_id", &"")
	match stat_type:
		&"armor":
			context.game_actions.modify_armor({
				"mech_id": target_id,
				"delta": delta,
				"duration": action.record.get("duration", &"THIS_TURN") if action.record.get("duration", &"") != &"" else &"THIS_TURN",
			})
		&"power":
			if method in [&"restore", &"heal"]:
				context.game_actions.restore_power({"mech_id": target_id, "amount": abs(value)})
			else:
				context.game_actions.modify_mech_power({
					"mech_id": target_id, "delta": delta,
					"duration": action.record.get("duration", &"THIS_TURN") if action.record.get("duration", &"") != &"" else &"THIS_TURN",
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
