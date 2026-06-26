## ShopService.gd — 商店服务
##
## 负责商店初始化、购买、刷新、补牌。
## 商店包含3张普通装备、1张高级装备、1张隐藏高级装备。
class_name ShopService
extends RefCounted

const _GameConfig = preload("res://scripts/config/GameConfig.gd")

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
	shop.hidden_revealed = false

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
func buy_normal_equipment(player_id: StringName, slot_index: int) -> Dictionary:
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

	# 获取价格
	var card = gs.get_card(card_id)
	var price: int = _get_buy_price(card)
	if player.gold < price:
		return {"ok": false, "message": "金币不足（需要%d，当前%d）" % [price, player.gold]}

	# 扣除金币
	player.gold -= price

	# 卡牌移到玩家装备手牌
	if card:
		card.zone = &"equipment_hand"
		card.face_down = false
	player.equipment_hand.append(card_id)

	# 清空槽位
	shop.normal_slots[slot_index] = &""

	# 补牌
	_replenish_normal_slot(slot_index)

	return {"ok": true, "message": "购买成功", "card_id": String(card_id), "price": price}


## 购买高级装备
func buy_advanced_equipment(player_id: StringName) -> Dictionary:
	var gs = context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return {"ok": false, "message": "玩家不存在"}

	var shop = gs.shop_state
	if shop.advanced_slot == &"":
		return {"ok": false, "message": "高级装备槽为空"}

	var card_id: StringName = shop.advanced_slot
	var card = gs.get_card(card_id)
	var price: int = _get_buy_price(card)
	if player.gold < price:
		return {"ok": false, "message": "金币不足"}

	player.gold -= price
	if card:
		card.zone = &"equipment_hand"
	player.equipment_hand.append(card_id)
	shop.advanced_slot = &""

	# 补牌
	var drawn: Array[StringName] = context.deck_service.draw_from_deck(&"advanced_equipment_deck", 1)
	if drawn.size() > 0:
		var new_card = gs.get_card(drawn[0])
		if new_card:
			new_card.zone = &"shop"
		shop.advanced_slot = drawn[0]

	return {"ok": true, "message": "购买高级装备成功"}


## 直接购买隐藏高级装备（不看直接买）
func buy_hidden_advanced(player_id: StringName) -> Dictionary:
	var gs = context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return {"ok": false, "message": "玩家不存在"}

	var shop = gs.shop_state
	if shop.hidden_advanced_slot == &"":
		return {"ok": false, "message": "隐藏高级装备槽为空"}

	var price: int = _GameConfig.SHOP_BUY_HIDDEN_COST
	if player.gold < price:
		return {"ok": false, "message": "金币不足（需要%d）" % price}

	player.gold -= price
	var card_id: StringName = shop.hidden_advanced_slot
	var card = gs.get_card(card_id)
	if card:
		card.zone = &"equipment_hand"
		card.face_down = false
	player.equipment_hand.append(card_id)
	shop.hidden_advanced_slot = &""

	return {"ok": true, "message": "购买隐藏高级装备成功"}


## 查看隐藏高级装备
func reveal_hidden_advanced(player_id: StringName) -> Dictionary:
	var gs = context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return {"ok": false, "message": "玩家不存在"}

	var shop = gs.shop_state
	if shop.hidden_advanced_slot == &"":
		return {"ok": false, "message": "隐藏高级装备槽为空"}
	if shop.hidden_revealed:
		return {"ok": true, "message": "已经查看过了"}

	var price: int = _GameConfig.SHOP_REVEAL_COST
	if player.gold < price:
		return {"ok": false, "message": "金币不足（需要%d）" % price}

	player.gold -= price
	shop.hidden_revealed = true
	var card = gs.get_card(shop.hidden_advanced_slot)
	if card:
		card.face_down = false

	return {"ok": true, "message": "已查看隐藏高级装备"}


## 刷新商店（花费金币，重新抽取所有槽位）
func refresh_shop(player_id: StringName) -> Dictionary:
	var gs = context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return {"ok": false, "message": "玩家不存在"}

	var price: int = _GameConfig.SHOP_REFRESH_COST
	if player.gold < price:
		return {"ok": false, "message": "金币不足（需要%d）" % price}

	player.gold -= price

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


## ── 内部方法 ──


## 获取购买价格（基于稀有度）
func _get_buy_price(card) -> int:
	if card and card.def:
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
