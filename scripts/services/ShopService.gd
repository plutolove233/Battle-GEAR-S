## ShopService.gd — 商店服务
##
## 负责商店初始化、购买、刷新、补牌。
## 商店包含3张普通装备、1张高级装备、1张隐藏高级装备。
class_name ShopService
extends RefCounted

const _GameConfig = preload("res://scripts/config/GameConfig.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
## "原价购买"通用模块（莉诺 pilot_079 等）：查询/消耗剩余次数，与效果绑定不绑机师。
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")

var context = null  # type: GameContext


## 初始化商店
## 从装备牌堆抽取卡牌填充商店槽位
func initialize_shop() -> Dictionary:
	var gs = context.game_state
	var shop = gs.shop_state

	# 清空现有槽位
	shop.normal_slots.clear()
	shop.advanced_slot = &""
	shop.hidden_advanced_slot = &""

	# 填充3个普通装备槽
	for i: int in range(_GameConfig.SHOP_NORMAL_SLOTS):
		var drawn: Array[StringName] = context.deck_service.draw_from_deck(&"equipment_deck", 1)
		if drawn.size() > 0:
			var card = gs.get_card(drawn[0])
			if card:
				card.zone = &"shop"
			shop.normal_slots.append(drawn[0])

	# 填充1个高级装备槽
	var adv_drawn: Array[StringName] = context.deck_service.draw_from_deck(&"advanced_equipment_deck", 1)
	if adv_drawn.size() > 0:
		var card = gs.get_card(adv_drawn[0])
		if card:
			card.zone = &"shop"
		shop.advanced_slot = adv_drawn[0]

	# 填充1个隐藏高级装备槽
	var hidden_drawn: Array[StringName] = context.deck_service.draw_from_deck(&"advanced_equipment_deck", 1)
	if hidden_drawn.size() > 0:
		var card = gs.get_card(hidden_drawn[0])
		if card:
			card.zone = &"shop"
			card.face_down = true
		shop.hidden_advanced_slot = hidden_drawn[0]

	return {"ok": true, "message": "商店已初始化"}


## 购买普通装备
## slot_index: 0-2，商店槽位索引
## use_face_value: 是否使用原价购买（使用折扣效果）
## use_pilot_original: 是否使用原价购买（使用"原价购买"通用效果次数，如莉诺 pilot_079）
func buy_normal_equipment(player_id: StringName, slot_index: int, use_face_value: bool = false, use_pilot_original: bool = false) -> Dictionary:
	var gs = context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return {"ok": false, "message": "玩家不存在"}

	var shop = gs.shop_state
	if slot_index < 0 or slot_index >= shop.normal_slots.size():
		return {"ok": false, "message": "槽位索引无效"}

	var card_id: StringName = shop.normal_slots[slot_index]
	if card_id == &"":
		return {"ok": false, "message": "槽位为空"}

	# 原价购买次数/折扣次数守卫（防止弹窗展示后次数被并发消耗掉）
	if use_pilot_original:
		if int(_ActionPilotEffects.get_face_value_buy_uses(gs, player_id).get("uses", 0)) <= 0:
			return {"ok": false, "message": "原价购买次数不足"}
	if use_face_value and not has_discount(player_id):
		return {"ok": false, "message": "折扣次数不足"}

	# 获取价格
	var card = gs.get_card(card_id)
	var is_face: bool = use_face_value or use_pilot_original
	var price: int = _get_buy_price(card) if not is_face else _get_face_value_price(card)
	if player.gold < price:
		return {"ok": false, "message": "金币不足（需要%d，当前%d）" % [price, player.gold]}

	# 扣除金币
	player.gold -= price

	# 卡牌移到玩家装备手牌
	if card:
		card.zone = &"equipment_hand"
		card.face_down = false
		card.owner_player_id = player_id
		# 补持有者机甲归属（弃牌快照 from_mech_id 判定，同 GameActions.draw_equipment_cards）
		if card.mech_id == &"":
			var buy_holder_mech = gs.get_mech_for_player(player_id)
			if buy_holder_mech != null:
				card.mech_id = buy_holder_mech.mech_id
	player.equipment_hand.append(card_id)

	# 清空槽位
	shop.normal_slots[slot_index] = &""

	# 补牌
	_replenish_normal_slot(slot_index)

	# 消耗折扣/原价购买次数
	if use_face_value:
		_consume_discount_use(player)
	if use_pilot_original:
		_ActionPilotEffects.consume_face_value_buy_use(gs, player_id)

	_fire_shop_buy_after(player_id, card_id, price)

	return {"ok": true, "message": "购买成功", "card_id": String(card_id), "price": price, "use_face_value": use_face_value}


## 购买高级装备
## use_face_value: 是否使用原价购买（使用折扣效果）
## use_pilot_original: 是否使用原价购买（使用"原价购买"通用效果次数，如莉诺 pilot_079）
func buy_advanced_equipment(player_id: StringName, use_face_value: bool = false, use_pilot_original: bool = false) -> Dictionary:
	var gs = context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return {"ok": false, "message": "玩家不存在"}

	var shop = gs.shop_state
	if shop.advanced_slot == &"":
		return {"ok": false, "message": "高级装备槽为空"}

	# 原价购买次数/折扣次数守卫（防止弹窗展示后次数被并发消耗掉）
	if use_pilot_original:
		if int(_ActionPilotEffects.get_face_value_buy_uses(gs, player_id).get("uses", 0)) <= 0:
			return {"ok": false, "message": "原价购买次数不足"}
	if use_face_value and not has_discount(player_id):
		return {"ok": false, "message": "折扣次数不足"}

	var card_id: StringName = shop.advanced_slot
	var card = gs.get_card(card_id)
	var is_face: bool = use_face_value or use_pilot_original
	var price: int = _get_buy_price(card) if not is_face else _get_face_value_price(card)
	if player.gold < price:
		return {"ok": false, "message": "金币不足"}

	player.gold -= price
	if card:
		card.zone = &"equipment_hand"
		card.owner_player_id = player_id
		# 补持有者机甲归属（弃牌快照 from_mech_id 判定，同 GameActions.draw_equipment_cards）
		if card.mech_id == &"":
			var buy_holder_mech = gs.get_mech_for_player(player_id)
			if buy_holder_mech != null:
				card.mech_id = buy_holder_mech.mech_id
	player.equipment_hand.append(card_id)
	shop.advanced_slot = &""

	# 补牌
	var drawn: Array[StringName] = context.deck_service.draw_from_deck(&"advanced_equipment_deck", 1)
	if drawn.size() > 0:
		var new_card = gs.get_card(drawn[0])
		if new_card:
			new_card.zone = &"shop"
		shop.advanced_slot = drawn[0]

	# 消耗折扣/原价购买次数
	if use_face_value:
		_consume_discount_use(player)
	if use_pilot_original:
		_ActionPilotEffects.consume_face_value_buy_use(gs, player_id)

	_fire_shop_buy_after(player_id, card_id, price)

	return {"ok": true, "message": "购买高级装备成功", "price": price, "use_face_value": use_face_value}


## 直接购买隐藏高级装备（不看直接买）
## 买价按买家是否已得知该牌：已得知（全局公开揭示 或 known_to 含买家）→ 1.5x原价；
## 未得知 → 盲买 10金。
func buy_hidden_advanced(player_id: StringName) -> Dictionary:
	var gs = context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return {"ok": false, "message": "玩家不存在"}

	var shop = gs.shop_state
	if shop.hidden_advanced_slot == &"":
		return {"ok": false, "message": "隐藏高级装备槽为空"}

	var price: int = _hidden_advanced_price_for(player_id)
	if player.gold < price:
		return {"ok": false, "message": "金币不足（需要%d）" % price}

	player.gold -= price
	var card_id: StringName = shop.hidden_advanced_slot
	var card = gs.get_card(card_id)
	if card:
		card.zone = &"equipment_hand"
		card.face_down = false
		card.owner_player_id = player_id
		# 补持有者机甲归属（弃牌快照 from_mech_id 判定，同 GameActions.draw_equipment_cards）
		if card.mech_id == &"":
			var buy_holder_mech = gs.get_mech_for_player(player_id)
			if buy_holder_mech != null:
				card.mech_id = buy_holder_mech.mech_id
	player.equipment_hand.append(card_id)
	shop.hidden_advanced_slot = &""

	_fire_shop_buy_after(player_id, card_id, price)

	return {"ok": true, "message": "购买隐藏高级装备成功"}


## 购买成功后发出 SHOP_BUY_AFTER 时点（虚拟 action fire，仿 GameActions._fire_gold_virtual / TurnService._fire_timing）。
## 供"购买后触发"类效果（莉卡尔 pilot_051 等）监听。普通/高级/隐藏高级三条购买路径统一调用。
## 高级装备判断 = SR/SSR 稀有度（规则书：高级装备牌堆包含 SR、SSR 装备牌，二者相互独立）。
## payload: player_id/buyer_player_id/buyer_mech_id/card_id/price/is_advanced
func _fire_shop_buy_after(player_id: StringName, card_id: StringName, price: int) -> void:
	if context == null or context.timing_engine == null:
		return
	var gs = context.game_state
	var mech_id: StringName = &""
	if gs != null and player_id != &"":
		var gm = gs.get_mech_for_player(player_id)
		if gm != null:
			mech_id = gm.mech_id
	var is_advanced: bool = false
	if gs != null and card_id != &"":
		var card = gs.get_card(card_id)
		if card != null and card.def != null:
			var rar: String = String(card.def.rarity)
			is_advanced = (rar == "SR" or rar == "SSR")
	var virtual_action = Action.new()
	virtual_action.action_type = &"shop"
	virtual_action.record = {
		"player_id": player_id,
		"buyer_player_id": player_id,
		"buyer_mech_id": mech_id,
		"card_id": card_id,
		"price": price,
		"is_advanced": is_advanced,
	}
	virtual_action.state = &"running"
	virtual_action.context = context
	virtual_action.source = {"player_id": player_id, "mech_id": mech_id}
	# 注册到 registry 获取唯一 action_id（否则挂起效果的 action_id 冲突/无法 resume，见 TurnService._fire_timing 注释）
	if context.action_registry != null:
		context.action_registry.register(virtual_action)
	context.timing_engine.fire_timing(_TimingConst.SHOP_BUY_AFTER, virtual_action)
	# 未挂起（无监听器响应或已同步完成）立即清理；挂起（等玩家弹窗确认）保留待 resume 后 continue_action 清理。
	if context.action_registry != null and virtual_action.state != &"waiting_timing" and virtual_action.state != &"waiting_input" and virtual_action.state != &"waiting_effect_action":
		context.action_registry.cleanup_action(virtual_action.action_id)


## 查看隐藏高级装备（每玩家独立得知）
## 支付2金币，把该牌标记为「已得知」给查看者（card.known_to 追加 player_id，幂等）。
## 不再全局公开：仅查看者本人能在商店看到真名+1.5x 买价，其他人仍见 ★★★ 隐藏卡 ★★★。
func reveal_hidden_advanced(player_id: StringName) -> Dictionary:
	var gs = context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return {"ok": false, "message": "玩家不存在"}

	var shop = gs.shop_state
	if shop.hidden_advanced_slot == &"":
		return {"ok": false, "message": "隐藏高级装备槽为空"}
	var card = gs.get_card(shop.hidden_advanced_slot)
	if _card_known_to(card, player_id):
		return {"ok": true, "message": "已经查看过了"}

	var price: int = _GameConfig.SHOP_REVEAL_COST
	if player.gold < price:
		return {"ok": false, "message": "金币不足（需要%d）" % price}

	player.gold -= price
	_mark_card_known_to(card, player_id)

	return {"ok": true, "message": "已查看隐藏高级装备"}


## 玩家是否已得知商店隐藏牌（全局公开揭示 或 known_to 含该玩家）。槽空时返回 true（无牌无需得知）。
func is_hidden_advanced_known_to(player_id: StringName) -> bool:
	var gs = context.game_state
	if gs == null or gs.shop_state == null:
		return false
	var shop = gs.shop_state
	if shop.hidden_advanced_slot == &"":
		return true
	return _card_known_to(gs.get_card(shop.hidden_advanced_slot), player_id)


## card.known_to 是否含 player_id
func _card_known_to(card, player_id: StringName) -> bool:
	return card != null and card.known_to != null and card.known_to.has(player_id)


## 把 player_id 追加到 card.known_to（幂等去重）
func _mark_card_known_to(card, player_id: StringName) -> void:
	if card == null or player_id == &"" or card.known_to == null:
		return
	if not card.known_to.has(player_id):
		card.known_to.append(player_id)


## 隐藏高级装备对玩家的买价：已得知 → 1.5x原价；未得知 → 盲买 10金
func _hidden_advanced_price_for(player_id: StringName) -> int:
	var gs = context.game_state
	if gs == null or gs.shop_state == null or gs.shop_state.hidden_advanced_slot == &"":
		return 0
	if is_hidden_advanced_known_to(player_id):
		var card = gs.get_card(gs.shop_state.hidden_advanced_slot)
		return _get_buy_price(card)
	return _GameConfig.SHOP_BUY_HIDDEN_COST


## 刷新商店（每回合1次，花费3金币，将现有卡牌放回弃牌堆并重新抽取所有槽位）
func refresh_shop(player_id: StringName) -> Dictionary:
	var gs = context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return {"ok": false, "message": "玩家不存在"}

	# 每回合1次限制（once_per_turn_used 在 TURN_START 时清空）
	var refresh_key = &"refresh_shop"
	if player.once_per_turn_used.get(refresh_key, 0) > 0:
		return {"ok": false, "message": "本回合已使用过刷新商店"}

	var price: int = _GameConfig.SHOP_REFRESH_COST
	if player.gold < price:
		return {"ok": false, "message": "金币不足（需要%d）" % price}

	player.gold -= price
	player.once_per_turn_used[refresh_key] = 1

	# 将现有商店卡牌放回弃牌堆
	var shop = gs.shop_state
	for card_id: StringName in shop.normal_slots:
		if card_id != &"":
			context.deck_service.discard_card(card_id, &"shop_refresh")
	if shop.advanced_slot != &"":
		context.deck_service.discard_card(shop.advanced_slot, &"shop_refresh")
	if shop.hidden_advanced_slot != &"":
		context.deck_service.discard_card(shop.hidden_advanced_slot, &"shop_refresh")

	# 重新初始化
	return initialize_shop()


## 检查玩家是否有折扣可用（折扣层数 = mech DISCOUNT 状态 stacks）
func has_discount(player_id: StringName) -> bool:
	return get_discount_uses(player_id) > 0


## 获取折扣剩余次数（mech DISCOUNT 状态 stacks 之和）
func get_discount_uses(player_id: StringName) -> int:
	var gs = context.game_state
	var mech = gs.get_mech_for_player(player_id)
	if mech == null:
		return 0
	var total: int = 0
	for status in mech.statuses:
		if status.get("type", &"") == &"DISCOUNT":
			total += int(status.get("stacks", 0))
	return total


## ── 内部方法 ──


## 获取玩家折扣状态（返回首个 DISCOUNT 状态对象，供 _consume_discount_use 修改）
func _get_discount_status(player) -> Dictionary:
	var gs = context.game_state
	# player 是 PlayerState，需反查其机甲
	var mech = gs.get_mech_for_player(player.player_id) if player != null else null
	if mech == null:
		return {"uses": 0, "status": {}}
	for status in mech.statuses:
		if status.get("type", &"") == &"DISCOUNT":
			return {"uses": int(status.get("stacks", 0)), "status": status}
	return {"uses": 0, "status": {}}


## 消耗一次折扣层数（mech DISCOUNT 状态 stacks-1，归0时移除状态并注销监听器）
func _consume_discount_use(player) -> void:
	var gs = context.game_state
	var mech = gs.get_mech_for_player(player.player_id) if player != null else null
	if mech == null:
		return
	for status in mech.statuses:
		if status.get("type", &"") != &"DISCOUNT":
			continue
		var stacks: int = int(status.get("stacks", 0))
		if stacks <= 1:
			# 层数归0，移除状态（走 game_actions.remove_status 注销监听器）
			var status_id: StringName = status.get("status_id", &"")
			if context.game_actions != null and status_id != &"":
				context.game_actions.remove_status({
					"target_id": mech.mech_id,
					"status_id": status_id,
					"status_type": &"DISCOUNT",
				})
			else:
				mech.statuses.erase(status)
		else:
			status["stacks"] = stacks - 1
		return


## 获取购买价格（文档第133行：默认 cost×1.5 向上取整）
## 优先用卡牌 cost 字段；cost 缺省时退回稀有度查表
func _get_buy_price(card) -> int:
	if card and card.def:
		# EquipmentCardDef 有 cost 字段
		if "cost" in card.def and int(card.def.cost) > 0:
			return ceil(int(card.def.cost) * 1.5)
		var rarity: StringName = card.def.rarity
		match rarity:
			&"N":
				return 3
			&"R":
				return 5
			&"SR":
				return 8
			&"SSR":
				return 12
	return 3  # 默认N级价格


## 获取原价（不使用1.5倍）
func _get_face_value_price(card) -> int:
	if card and card.def and card.def is EquipmentCardDef:
		# 优先使用卡牌的 cost 字段
		return card.def.cost if card.def.cost > 0 else _get_buy_price(card)
	return _get_buy_price(card)


## 获取玩家折扣状态
## （旧版基于 player.statuses SHOP_BUY_MODIFIER 已废弃，统一改读 mech DISCOUNT stacks，
##  实现见上方 _get_discount_status；此占位保留以防外部误调用）
func _get_discount_status_legacy(player) -> Dictionary:
	return {"uses": 0, "modifier_id": &""}



## 补充普通装备槽位
func _replenish_normal_slot(slot_index: int) -> void:
	var gs = context.game_state
	var shop = gs.shop_state

	var drawn: Array[StringName] = context.deck_service.draw_from_deck(&"equipment_deck", 1)
	if drawn.size() > 0:
		var card = gs.get_card(drawn[0])
		if card:
			card.zone = &"shop"
		if slot_index < shop.normal_slots.size():
			shop.normal_slots[slot_index] = drawn[0]
		else:
			shop.normal_slots.append(drawn[0])
