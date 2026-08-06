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
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _Action = preload("res://scripts/action_core/Action.gd")


## 从指定牌堆抽牌
## 如果牌堆为空，将弃牌堆洗入后再抽
## 返回抽到的卡牌 instance_id 列表
## pilot_003 effect_02：抽到瑟尔基尔埋入的正面牌时，先 fire CARD_LEAVE_ACTION_DECK_BEFORE 拦截，
## 拦截牌不交给调用方（改由瑟尔基尔拥有者立即使用/弃置+补抽），且不计入本次已抽数量（while 循环续抽）。
func draw_from_deck(deck_key: StringName, count: int) -> Array[StringName]:
	var gs: GameState = context.game_state
	var deck_state: DeckState = gs.deck_state
	var drawn: Array[StringName] = []

	# while 而非 for：被拦截的正面牌弹出后不计入 drawn，需续抽补足 count。
	while drawn.size() < count:
		var deck: Array = _get_deck_array(deck_key)
		if deck.is_empty():
			# 尝试洗入弃牌堆
			_reshuffle_discard_into_deck(deck_key)
			deck = _get_deck_array(deck_key)
			if deck.is_empty():
				break  # 无牌可抽

		var card_id: StringName = deck.pop_front() as StringName
		var card: CardInstance = gs.get_card(card_id)

		# pilot_003 effect_02：正面牌离开行动牌堆前 fire CARD_LEAVE_ACTION_DECK_BEFORE。
		# 监听器（CANCEL_PARENT_CARD_TRANSFER + IMMEDIATELY_USE_DECK_CARD_OR_FALLBACK）同步执行；
		# 拦截后该牌由独立顶层 use_action_card 使用（或弃置+补抽），不交给原获取者。
		var intercepted := false
		if deck_key == &"action_deck" and card != null and bool(card.counters.get("pilot_003_face_up_leave_use", false)):
			intercepted = _fire_pilot_003_card_leave_deck(card_id)
			if intercepted:
				card.counters.erase("pilot_003_intercepted")
				continue

		drawn.append(card_id)
		# 更新卡牌实例的区域标记
		if card:
			card.zone = &"hand"

	return drawn


## pilot_003 effect_02：用轻量虚拟 Action（仿 TurnService._fire_timing）fire CARD_LEAVE_ACTION_DECK_BEFORE。
## 返回是否被拦截（监听器 CANCEL_PARENT_CARD_TRANSFER 在卡片 counters 写 pilot_003_intercepted）。
func _fire_pilot_003_card_leave_deck(card_id: StringName) -> bool:
	if context == null or context.timing_engine == null or context.game_state == null:
		return false
	var card: CardInstance = context.game_state.get_card(card_id)
	if card == null:
		return false
	var virtual_action = _Action.new()
	virtual_action.action_type = &"card_zone_change"
	virtual_action.record = {
		"card_instance_id": card_id,
		"from_zone": &"action_deck",
		"to_zone": &"hand",
		# metadata owner（埋牌者/瑟尔基尔拥有者）作为 UI 路由归属；离堆牌原 owner_player_id 即埋牌者
		"player_id": StringName(card.counters.get("pilot_003_leave_deck_owner_pid", card.owner_player_id)),
	}
	virtual_action.state = &"running"
	virtual_action.context = context
	context.timing_engine.fire_timing(_TimingConst.CARD_LEAVE_ACTION_DECK_BEFORE, virtual_action)
	return bool(card.counters.get("pilot_003_intercepted", false))


## 将卡牌移到牌堆底部
func move_card_to_deck_bottom(card_id: StringName, deck_key: StringName) -> void:
	var gs: GameState = context.game_state
	var deck_state: DeckState = gs.deck_state

	# 更新卡牌实例区域
	var card: CardInstance = gs.get_card(card_id)
	if card:
		card.zone = &"deck"

	# 按卡牌类型加入对应牌堆底部
	var deck_array = _get_deck_array(deck_key)
	if deck_array != null:
		deck_array.append(card_id)


## 弃牌
## 转发到 discard_card 动作（走动作时点体系：DISCARD_BEFORE/AFTER/SETTLE）。
## reason 记录在动作快照里，供离场效果（联邦躯干/左臂、近战右腿等）监听 DISCARD_AFTER 时按 reason 过滤。
## 弃置流程：快照来源→移入 tmp_zone→DISCARD_AFTER(离场效果此时点触发)→移入弃牌堆→DISCARD_SETTLE。
## 装备牌弃置时若有离场效果（需玩家选择/产生子动作），动作会暂停在 waiting_timing，
## 由 ActionUIBridge 接线驱动玩家选择后 continue_action 恢复；调用方不阻塞。
func discard_card(card_id: StringName, reason: StringName) -> void:
	if card_id == &"":
		return
	if context == null:
		return
	# 优先走 discard_card 动作（发时点，触发离场效果）
	if context.action_service != null:
		var src: Dictionary = {"reason": String(reason)}
		# 从卡牌实例补全来源
		var card = context.game_state.get_card(card_id) if context.game_state != null else null
		if card != null:
			src["card_instance_id"] = card_id
			src["mech_id"] = card.mech_id
			src["player_id"] = card.owner_player_id
		context.action_service.execute(&"discard_card", {
			"card_ids": [card_id],
			"reason": reason,
			"executor": &"system_default",
			"source": src,
		})
		return
	# 退路：action_service 未就绪（初始化/测试），走 legacy 同步移牌
	_discard_card_legacy(card_id, reason)


## Legacy 同步弃牌（action_service 未就绪时退路，不发育动作时点）
func _discard_card_legacy(card_id: StringName, reason: StringName) -> void:
	var gs: GameState = context.game_state
	var deck_state: DeckState = gs.deck_state

	var card: CardInstance = gs.get_card(card_id)
	var from_zone: StringName = &""
	var owner_player_id: StringName = &""
	if card:
		from_zone = card.zone
		owner_player_id = card.owner_player_id
		card.zone = &"discard"
		if card.def and card.def.card_kind == &"action" and context.has_method("unregister_hand_card_availability"):
			context.unregister_hand_card_availability(card_id)

	if card and card.def:
		match card.def.card_kind:
			&"action":
				deck_state.action_discard_pile.append(card_id)
			&"equipment":
				deck_state.equipment_discard_pile.append(card_id)
			_:
				deck_state.action_discard_pile.append(card_id)
	else:
		deck_state.action_discard_pile.append(card_id)

	gs.write_log(&"card_discarded", {
		"card_id": String(card_id),
		"reason": String(reason),
	})

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


## 洗牌（Fisher-Yates，走 context.rng 同步随机，锁步双端一致）
func _shuffle_array(arr: Array) -> void:
	if context != null and context.rng != null:
		context.synced_shuffle(arr)
		return
	for i: int in range(arr.size() - 1, 0, -1):
		var j: int = randi() % (i + 1)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp
