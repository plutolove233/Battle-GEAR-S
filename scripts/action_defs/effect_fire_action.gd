## effect_fire_action.gd — 效果发动动作
##
## 按新规则文档定义：
##   ① 提取效果信息 → 发出 EFFECT_FIRE_BEFORE
##   ② 正式执行效果 → 发出 EFFECT_FIRE_AFTER
##   ③ 效果发动结算 → 发出 EFFECT_FIRE_SETTLE
extends Action
class_name EffectFireAction

const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")


func _init() -> void:
	action_type = &"effect_fire"


func setup_steps() -> void:
	steps = [
		{step_name = &"extract_info",  timing_point = _TimingConst.EFFECT_FIRE_BEFORE, handler = _step_extract_info},
		{step_name = &"execute_effect", timing_point = _TimingConst.EFFECT_FIRE_AFTER, handler = _step_execute_effect},
		{step_name = &"settle",        timing_point = _TimingConst.EFFECT_FIRE_SETTLE, handler = _step_settle},
	]


func get_display_name() -> String:
	return "效果发动"


func _step_extract_info(action: Action) -> Dictionary:
	# 提取效果信息到record
	var effect_id: StringName = action.record.get("effect_id", &"")
	var targets: Array = action.record.get("targets", [])
	action.record["effect_count"] = 1 if effect_id != &"" else 0
	action.record["target_count"] = targets.size()
	# 注入来源机甲到 record，供 DIRECT 主动效果的子动作（如 EXECUTE_STAT_MODIFY）经
	# _extract_stat_mod_params 的 payload.source_mech_id 解析 target。
	# _create_action record_keys 不含 source_mech_id，effect_fire 主动效果需在此补。
	if action.source is Dictionary and action.record.get("source_mech_id", &"") == &"":
		action.record["source_mech_id"] = action.source.get("mech_id", &"")
	return {}


func _step_execute_effect(action: Action) -> Dictionary:
	var result: Dictionary = {}
	var effect_id: StringName = action.record.get("effect_id", &"")

	if effect_id == &"":
		return result

	# 通过TimingEngine执行效果
	if context != null and context.timing_engine != null:
		context.timing_engine._execute_effect_by_id(effect_id, action.record, action)

	return result


func _step_settle(action: Action) -> Dictionary:
	# 效果发动结算后清理本动作信息
	return {}
