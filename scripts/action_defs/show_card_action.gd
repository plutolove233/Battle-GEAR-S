## show_card_action.gd — 展示牌动作
##
## 按新规则文档定义：
##   ① 提取展示牌信息 → 发出 SHOW_CARD_BEFORE
##   ② 正式向对象展示 → 发出 SHOW_CARD_AFTER
##   ③ 展示牌结算 → 发出 SHOW_CARD_SETTLE
extends Action
class_name ShowCardAction

const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")


func _init() -> void:
	action_type = &"show_card"


func setup_steps() -> void:
	steps = [
		{step_name = &"extract_info",   timing_point = _TimingConst.SHOW_CARD_BEFORE, handler = _step_extract_info},
		{step_name = &"show_cards",     timing_point = _TimingConst.SHOW_CARD_AFTER,  handler = _step_show_cards},
		{step_name = &"settle",         timing_point = _TimingConst.SHOW_CARD_SETTLE, handler = _step_settle},
	]


func get_display_name() -> String:
	return "展示牌"


func _step_extract_info(action: Action) -> Dictionary:
	# 提取展示牌信息到record
	var card_ids: Array = action.record.get("card_ids", [])
	var show_to_mech_ids: Array = action.record.get("show_to_mech_ids", [])
	action.record["card_count"] = card_ids.size()
	action.record["viewer_count"] = show_to_mech_ids.size()
	return {}


func _step_show_cards(action: Action) -> Dictionary:
	var card_ids: Array = action.record.get("card_ids", [])
	var show_to_mech_ids: Array = action.record.get("show_to_mech_ids", [])
	var persistent: bool = action.record.get("persistent", false)

	# 标记牌为已知状态（对展示对象可见）
	for mech_id: StringName in show_to_mech_ids:
		var mech = context.game_state.mechs.get(mech_id)
		if mech == null:
			continue
		for card_id: StringName in card_ids:
			var card = context.game_state.cards.get(card_id)
			if card != null:
				# 如果是一直展示，标记牌为已知状态
				if persistent:
					if not card.known_to.has(mech.owner_player_id):
						card.known_to.append(mech.owner_player_id)

	# 通知UI展示牌
	return {
		"need_input": true,
		"input_type": &"show_cards",
		"input_params": {
			"card_ids": card_ids,
			"show_to_mech_ids": show_to_mech_ids,
			"persistent": persistent,
		},
	}


func _step_settle(action: Action) -> Dictionary:
	# 如果非一直展示，展示窗口关闭后牌信息不再可见
	# （已在UI层处理：玩家退出框后不能再看到）
	return {}
