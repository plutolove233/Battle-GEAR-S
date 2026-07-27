## hp_change_action.gd — 生命变动动作
##
## 按新规则文档定义：
##   ① 提取生命变动信息 → 发出 HP_CHANGE_BEFORE
##   ② 正式变动生命 → 发出 HP_CHANGE_AFTER
##   ③ 生命变动结算 → 发出 HP_CHANGE_SETTLE
extends Action
class_name HpChangeAction

const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")


func _init() -> void:
	action_type = &"hp_change"


func setup_steps() -> void:
	steps = [
		{step_name = &"extract_info",    timing_point = _TimingConst.HP_CHANGE_BEFORE, handler = _step_extract_info},
		{step_name = &"change_hp",       timing_point = _TimingConst.HP_CHANGE_AFTER,  handler = _step_change_hp},
		{step_name = &"settle",         timing_point = _TimingConst.HP_CHANGE_SETTLE, handler = _step_settle},
	]


func get_display_name() -> String:
	return "生命变动"


func _step_extract_info(action: Action) -> Dictionary:
	return {}


func _step_change_hp(action: Action) -> Dictionary:
	var result: Dictionary = {}
	var mech_ids: Array = action.record.get("mech_ids", [])
	var value: int = action.record.get("value", 0)
	var method: StringName = action.record.get("method", &"decrease")

	if value == 0:
		return result

	for mech_id: StringName in mech_ids:
		var mech = context.game_state.mechs.get(mech_id)
		if mech == null:
			continue
		var old_hp: int = mech.current_hp
		match method:
			&"decrease", &"reduce":
				mech.current_hp = max(0, mech.current_hp - value)
				if mech.current_hp <= 0:
					if context.game_actions != null:
						context.game_actions.destroy_mech({"mech_id": mech_id, "source": &"damage"})
			&"increase", &"add":
				mech.current_hp = mech.current_hp + value
			&"restore", &"heal":
				mech.current_hp = min(mech.max_hp, mech.current_hp + value)
		# 记录首个机甲的 HP 前后值，供 HP_CHANGE_AFTER 消息显示（C1 修复，此前读 payload 默认 0->0）
		if not result.has("old_hp"):
			result["old_hp"] = old_hp
			result["new_hp"] = mech.current_hp
	return result


func _step_settle(action: Action) -> Dictionary:
	return {}
