## gain_card_action.gd — 获取牌动作
##
## 按新规则文档定义：
##   ① 提取牌信息 → 发出 GAIN_CARD_BEFORE
##   ② 转移牌给机甲 → 发出 GAIN_CARD_AFTER
##   ③ 获取牌结算 → 发出 GAIN_CARD_SETTLE
extends Action
class_name GainCardAction

const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")


func _init() -> void:
	action_type = &"gain_card"


func setup_steps() -> void:
	steps = [
		{step_name = &"extract_info",  timing_point = _TimingConst.GAIN_CARD_BEFORE, handler = _step_extract_info},
		{step_name = &"transfer_card", timing_point = _TimingConst.GAIN_CARD_AFTER,  handler = _step_transfer_card},
		{step_name = &"settle",        timing_point = _TimingConst.GAIN_CARD_SETTLE, handler = _step_settle},
	]


func get_display_name() -> String:
	return "获取牌"


func _step_extract_info(action: Action) -> Dictionary:
	return {}


func _step_transfer_card(action: Action) -> Dictionary:
	var result: Dictionary = {}
	var card_ids: Array = action.record.get("card_ids", [])
	var mech_ids: Array = action.record.get("mech_ids", [])
	var from_zone: StringName = action.record.get("from_zone", &"")
	var reason: StringName = action.record.get("reason", &"effect")

	# 处理随机从弃牌堆/牌堆获取的情况
	if card_ids.is_empty():
		card_ids = _resolve_card_sources(action)

	# 如果只有1个 mech_id 但有多张牌，将所有牌发给同一个机甲
	var target_mech_id: StringName = &""
	if mech_ids.size() == 1:
		target_mech_id = mech_ids[0]

	for i in range(card_ids.size()):
		var card_id: StringName = card_ids[i]
		var mech_id: StringName = target_mech_id if target_mech_id != &"" else (mech_ids[i] if i < mech_ids.size() else &"")
		if mech_id == &"":
			continue

		var card = context.game_state.get_card(card_id)
		if card == null:
			continue

		var player = context.game_state.get_player_for_mech(mech_id)
		if player == null:
			continue

		# 从原区域移除
		context.game_state.remove_card_from_all_zones(card_id)

		# 加入玩家手牌
		if card.def != null:
			if card.def.card_kind == &"action":
				player.action_hand.append(card_id)
				card.zone = &"action_hand"
				# 注册AVAILABILITY效果到TimingEngine
				if context != null:
					context.register_hand_card_availability(card_id)
			elif card.def.card_kind == &"equipment":
				player.equipment_hand.append(card_id)
				card.zone = &"equipment_hand"

		card.owner_player_id = player.player_id
		card.mech_id = mech_id

	return result


## 解析获取牌的来源（随机从弃牌堆/牌堆获取）
func _resolve_card_sources(action: Action) -> Array:
	var from_zone: StringName = action.record.get("from_zone", &"")
	var count: int = action.record.get("count", 1)
	var random: bool = action.record.get("random", false)
	var card_kind: StringName = action.record.get("card_kind", &"")

	if from_zone == &"" or not random:
		return []

	var pool: Array = []
	if from_zone == &"equipment_discard":
		pool = context.game_state.deck_state.equipment_discard_pile.duplicate()
	elif from_zone == &"action_discard":
		pool = context.game_state.deck_state.action_discard_pile.duplicate()
	elif from_zone == &"action_deck":
		pool = context.game_state.deck_state.action_deck.duplicate()
	elif from_zone == &"equipment_deck":
		pool = context.game_state.deck_state.equipment_deck.duplicate()

	if card_kind != &"":
		pool = pool.filter(func(card_id: StringName) -> bool:
			var card = context.game_state.cards.get(card_id)
			if card == null or card.def == null:
				return false
			return card.def.card_kind == card_kind
		)

	if context != null and context.rng != null:
		context.synced_shuffle(pool)
	else:
		pool.shuffle()
	return pool.slice(0, min(count, pool.size()))


func _step_settle(action: Action) -> Dictionary:
	return {}
