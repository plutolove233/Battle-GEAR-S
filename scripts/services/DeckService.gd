## DeckService.gd — 牌堆管理服务
##
## 负责：
## - 从牌堆抽牌（空堆时自动洗入弃牌堆）
## - 弃牌到弃牌堆
## - 根据配置构建行动牌/装备牌牌堆
class_name DeckService
extends RefCounted

var context = null  # type: GameContext

const _EffectConst = preload("res://scripts/effect_core/EffectConst.gd")


## 从指定牌堆抽牌
## 如果牌堆为空，将弃牌堆洗入后再抽
## 返回抽到的卡牌 instance_id 列表
func draw_from_deck(deck_key: StringName, count: int) -> Array[StringName]:
	var gs: GameState = context.game_state
	var deck_state: DeckState = gs.deck_state
	var drawn: Array[StringName] = []

	for i: int in range(count):
		var deck: Array = _get_deck_array(deck_key)
		if deck.is_empty():
			# 尝试洗入弃牌堆
			_reshuffle_discard_into_deck(deck_key)
			deck = _get_deck_array(deck_key)
			if deck.is_empty():
				break  # 无牌可抽

		var card_id: StringName = deck.pop_front() as StringName
		drawn.append(card_id)

		# 更新卡牌实例的区域标记
		var card: CardInstance = gs.get_card(card_id)
		if card:
			card.zone = &"hand"

	return drawn


## 弃牌
## 将卡牌移到弃牌堆，并触发对应钩子
func discard_card(card_id: StringName, reason: StringName) -> void:
	var gs: GameState = context.game_state
	var deck_state: DeckState = gs.deck_state

	# 更新卡牌实例区域
	var card: CardInstance = gs.get_card(card_id)
	var from_zone: StringName = &""
	var owner_player_id: StringName = &""
	if card:
		from_zone = card.zone
		owner_player_id = card.owner_player_id
		card.zone = &"discard"

	# 按卡牌类型分入对应弃牌堆
	if card and card.def:
		match card.def.card_kind:
			&"action":
				deck_state.action_discard_pile.append(card_id)
			&"equipment":
				deck_state.equipment_discard_pile.append(card_id)
			_:
				# 其他类型（事件、机师等）归入行动弃牌堆
				deck_state.action_discard_pile.append(card_id)
	else:
		deck_state.action_discard_pile.append(card_id)

	gs.write_log(&"card_discarded", {
		"card_id": String(card_id),
		"reason": String(reason),
	})

	# 通知消息面板（不绑定任何效果，不改变游戏行为）
	# 先写日志再发通知，使面板 _advance_log_index 能跳过该日志条目，避免重复
	if context.effect_engine:
		context.effect_engine.fire_hook(_EffectConst.HOOK_CARD_DISCARDED_NOTIFY, {
			"card_id": String(card_id),
			"owner_player_id": String(owner_player_id),
			"from_zone": String(from_zone),
			"reason": String(reason),
		})


## 根据教学战役配置构建牌堆
## 创建行动牌和装备牌的 CardInstance 并填充到对应牌堆
func build_decks_from_config(config: Dictionary) -> void:
	var gs: GameState = context.game_state
	var deck_state: DeckState = gs.deck_state

	# ── 构建行动牌牌堆 ──
	var action_deck_ids: Array = config.get("starting_action_deck", [])
	deck_state.action_deck.clear()
	for card_def_id: String in action_deck_ids:
		var instance_id: StringName = _create_card_instance_from_def(
			StringName(card_def_id), &"action_deck"
		)
		if instance_id != &"":
			deck_state.action_deck.append(instance_id)

	# 洗牌
	_shuffle_array(deck_state.action_deck)

	# ── 构建装备牌牌堆 ──
	var equipment_pool: Array = config.get("starting_equipment_pool", [])
	deck_state.equipment_deck.clear()
	for card_def_id: String in equipment_pool:
		var instance_id: StringName = _create_card_instance_from_def(
			StringName(card_def_id), &"equipment_deck"
		)
		if instance_id != &"":
			deck_state.equipment_deck.append(instance_id)

	# 洗牌
	_shuffle_array(deck_state.equipment_deck)


## ── 内部方法 ──


## 获取指定牌堆的数组引用
func _get_deck_array(deck_key: StringName) -> Array:
	var deck_state: DeckState = context.game_state.deck_state
	match deck_key:
		&"action_deck":
			return deck_state.action_deck
		&"equipment_deck":
			return deck_state.equipment_deck
		&"advanced_equipment_deck":
			return deck_state.advanced_equipment_deck
		&"pilot_deck":
			return deck_state.pilot_deck
		&"event_deck":
			return deck_state.event_deck
		_:
			return []


## 将弃牌堆洗入指定牌堆
func _reshuffle_discard_into_deck(deck_key: StringName) -> void:
	var gs: GameState = context.game_state
	var deck_state: DeckState = gs.deck_state

	# 根据牌堆类型选择对应的弃牌堆
	var source_discard: Array[StringName] = []
	match deck_key:
		&"action_deck":
			source_discard = deck_state.action_discard_pile
		&"equipment_deck":
			source_discard = deck_state.equipment_discard_pile
		&"advanced_equipment_deck":
			source_discard = deck_state.equipment_discard_pile
		_:
			# 其他牌堆合并两个弃牌堆
			source_discard = deck_state.action_discard_pile + deck_state.equipment_discard_pile

	if source_discard.is_empty():
		return

	# 将弃牌堆中的卡牌按原始牌堆分类放回
	var cards_to_return: Array[StringName] = []
	var remaining_discard: Array[StringName] = []

	for card_id: StringName in source_discard:
		var card: CardInstance = gs.get_card(card_id)
		if card and card.def:
			var belongs: bool = false
			match deck_key:
				&"action_deck":
					belongs = card.def.card_kind == &"action"
				&"equipment_deck":
					belongs = card.def.card_kind == &"equipment"
				&"advanced_equipment_deck":
					belongs = card.def.card_kind == &"equipment"
				_:
					belongs = true  # 其他牌堆全部放回

			if belongs:
				cards_to_return.append(card_id)
				card.zone = &"deck"
			else:
				remaining_discard.append(card_id)
		else:
			remaining_discard.append(card_id)

	# 洗牌后放回牌堆
	_shuffle_array(cards_to_return)
	var deck: Array = _get_deck_array(deck_key)
	deck.append_array(cards_to_return)

	# 更新对应弃牌堆
	match deck_key:
		&"action_deck":
			deck_state.action_discard_pile = remaining_discard
		&"equipment_deck", &"advanced_equipment_deck":
			deck_state.equipment_discard_pile = remaining_discard
		_:
			# 清空两个弃牌堆（全部洗入了）
			deck_state.action_discard_pile.clear()
			deck_state.equipment_discard_pile.clear()


## 根据卡牌定义ID创建 CardInstance 并注册到 GameState
func _create_card_instance_from_def(card_def_id: StringName, zone: StringName) -> StringName:
	var gs: GameState = context.game_state

	# 尝试从 CardDatabase 获取定义
	# 注意：不类型标注为 CardDef，因为子类（ActionCardDef 等）因 Godot 跨文件
	# extends 限制直接 extends RefCounted，as CardDef 会返回 null。
	var card_def = null
	if context.card_database:
		card_def = context.card_database.get_card(card_def_id)

	var instance_id: StringName = gs.next_id("card")
	var instance: CardInstance = CardInstance.new(instance_id, card_def)
	instance.zone = zone
	gs.cards[instance_id] = instance
	return instance_id


## 洗牌（Fisher-Yates 洗牌算法）
func _shuffle_array(arr: Array) -> void:
	for i: int in range(arr.size() - 1, 0, -1):
		var j: int = randi() % (i + 1)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp
