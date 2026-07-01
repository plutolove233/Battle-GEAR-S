## DeckBuildService.gd — 牌堆构建服务
##
## 从 CardDatabase 构建各类牌堆（行动牌、装备牌、高级装备牌、机师牌、事件牌）。
## 与 DeckService 不同：DeckService 管理抽牌/弃牌，DeckBuildService 负责初始化构建。
class_name DeckBuildService
extends RefCounted

const _CardDef = preload("res://scripts/card_defs/CardDef.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")

var context = null  # type: GameContext


## 从 CardDatabase 构建所有牌堆
## 根据 CardDef 的 card_kind 和 rarity 分配到对应牌堆
func build_all_decks_from_card_database() -> Dictionary:
	if context == null or context.card_database == null:
		return {"ok": false, "message": "CardDatabase 未初始化"}

	var gs = context.game_state
	var deck_state = gs.deck_state

	# 清空所有牌堆
	deck_state.action_deck.clear()
	deck_state.equipment_deck.clear()
	deck_state.advanced_equipment_deck.clear()
	deck_state.pilot_deck.clear()
	deck_state.event_deck.clear()
	deck_state.action_discard_pile.clear()
	deck_state.equipment_discard_pile.clear()

	# 遍历所有卡牌定义，按类型和稀有度分配
	for card_id: StringName in context.card_database.card_defs:
		var card_def = context.card_database.card_defs[card_id]
		if card_def == null:
			continue
		# 机甲框架等不属于任何牌堆的卡牌类型跳过（避免被错误放入行动牌堆）
		if card_def.card_kind == &"mech_frame":
			continue

		# 根据卡牌的 count 字段决定创建多少张实例
		var count: int = card_def.count if card_def.count > 0 else 1

		for i: int in range(count):
			var instance_id: StringName = gs.next_id("card")
			var instance = _CardInstance.new(instance_id, card_def)

			# 根据卡牌类型分配到对应牌堆
			var deck_key: StringName = _get_deck_key_for_card(card_def)
			instance.zone = deck_key

			match deck_key:
				&"action_deck":
					deck_state.action_deck.append(instance_id)
				&"equipment_deck":
					deck_state.equipment_deck.append(instance_id)
				&"advanced_equipment_deck":
					deck_state.advanced_equipment_deck.append(instance_id)
				&"pilot_deck":
					deck_state.pilot_deck.append(instance_id)
				&"event_deck":
					deck_state.event_deck.append(instance_id)

			# 注册到 GameState
			gs.cards[instance_id] = instance

	# 洗牌
	_shuffle_deck(deck_state.action_deck)
	_shuffle_deck(deck_state.equipment_deck)
	_shuffle_deck(deck_state.advanced_equipment_deck)
	_shuffle_deck(deck_state.pilot_deck)
	_shuffle_deck(deck_state.event_deck)

	return {
		"ok": true,
		"action_deck": deck_state.action_deck.size(),
		"equipment_deck": deck_state.equipment_deck.size(),
		"advanced_equipment_deck": deck_state.advanced_equipment_deck.size(),
		"pilot_deck": deck_state.pilot_deck.size(),
		"event_deck": deck_state.event_deck.size(),
	}


## ── 内部方法 ──


## 根据卡牌类型和稀有度决定分配到哪个牌堆
func _get_deck_key_for_card(card_def) -> StringName:
	match card_def.card_kind:
		&"action":
			return &"action_deck"
		&"equipment":
			# 装备牌按稀有度分到普通/高级牌堆
			if card_def.rarity == &"SR" or card_def.rarity == &"SSR":
				return &"advanced_equipment_deck"
			return &"equipment_deck"
		&"pilot":
			return &"pilot_deck"
		&"event":
			return &"event_deck"
		_:
			return &"action_deck"  # 默认放行动牌堆


## Fisher-Yates 洗牌
func _shuffle_deck(deck: Array[StringName]) -> void:
	for i: int in range(deck.size() - 1, 0, -1):
		var j: int = randi() % (i + 1)
		var tmp: StringName = deck[i]
		deck[i] = deck[j]
		deck[j] = tmp
