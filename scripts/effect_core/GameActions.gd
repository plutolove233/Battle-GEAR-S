## GameActions.gd — 游戏动作执行器
##
## GameActions 是所有原子动作的具体实现。
## 每个方法：验证参数 → 修改 GameState → 通过 context.effect_engine.fire_hook 触发结果 hook。
## 从 Effect全牌表.xlsx "GameActions完整代码" 适配而来。
## 所有 GameState/EffectEngine/EffectRegistry 引用通过 context 依赖注入，
## 替代了原设计的 Autoload 全局单例。
extends RefCounted
class_name GameActions

## Preloaded references for cross-file custom types
const _GameContext = preload("res://scripts/runtime/GameContext.gd")
const _GameState = preload("res://scripts/runtime/GameState.gd")
const _MechState = preload("res://scripts/runtime/MechState.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _CardDef = preload("res://scripts/card_defs/CardDef.gd")
const _EffectBinding = preload("res://scripts/effect_core/EffectBinding.gd")
const _EffectEngine = preload("res://scripts/effect_core/EffectEngine.gd")
const _AtomicActionResolver = preload("res://scripts/effect_core/AtomicActionResolver.gd")
const _EventCardDef = preload("res://scripts/card_defs/EventCardDef.gd")

## 依赖注入：GameContext 容器
var context = null


## ────────────────────────────────────────────
## 攻击相关
## ────────────────────────────────────────────

## 创建攻击上下文并触发攻击宣言流程
func start_attack_declare_attack(params: Dictionary) -> void:
	var attacker_id: StringName = params.get("attacker_id", params.get("source_mech_id", &""))
	var target_id: StringName = params.get("target_id", &"")
	var weapon_id: StringName = params.get("weapon_id", params.get("target_weapon_id", &""))
	var attack_card_id: StringName = params.get("attack_card_id", params.get("card_id", &""))

	if attacker_id == &"" or target_id == &"" or weapon_id == &"":
		push_error("START_ATTACK_DECLARE_ATTACK 缺少 attacker_id / target_id / weapon_id")
		return

	# 委托 AttackService 执行攻击宣言
	if context.attack_service != null:
		context.attack_service.declare_attack(attacker_id, target_id, weapon_id, attack_card_id)


## 修改攻击威力
func modify_attack_power(params: Dictionary) -> void:
	var attack_id: StringName = params.get("attack_id", context.game_state.current_attack_id)
	if attack_id == &"" or not context.game_state.attacks.has(attack_id):
		push_error("MODIFY_ATTACK_POWER 找不到 attack_id")
		return

	var delta: int = int(params.get("delta", 0))
	var attack: Dictionary = context.game_state.attacks[attack_id]

	attack["power"] = max(0, int(attack.get("power", 0)) + delta)

	if not attack.has("modifiers"):
		attack["modifiers"] = []

	attack["modifiers"].append({
		"type": &"attack_power",
		"delta": delta,
		"source_card_id": params.get("source_card_id", &""),
		"duration": params.get("duration", &"THIS_ATTACK")
	})

	context.game_state.attacks[attack_id] = attack


## 修改攻击范围
func modify_attack_range(params: Dictionary) -> void:
	var attack_id: StringName = params.get("attack_id", context.game_state.current_attack_id)
	if attack_id == &"" or not context.game_state.attacks.has(attack_id):
		push_error("MODIFY_ATTACK_RANGE 找不到 attack_id")
		return

	var delta: int = int(params.get("delta", 0))
	var attack: Dictionary = context.game_state.attacks[attack_id]

	attack["range_value"] = max(0, int(attack.get("range_value", 0)) + delta)

	if not attack.has("modifiers"):
		attack["modifiers"] = []

	attack["modifiers"].append({
		"type": &"attack_range",
		"delta": delta,
		"source_card_id": params.get("source_card_id", &""),
		"duration": params.get("duration", &"THIS_ATTACK")
	})

	context.game_state.attacks[attack_id] = attack


## 否定攻击
func negate_attack(params: Dictionary) -> void:
	var attack_id: StringName = params.get("attack_id", context.game_state.current_attack_id)
	if attack_id == &"" or not context.game_state.attacks.has(attack_id):
		return

	var attack: Dictionary = context.game_state.attacks[attack_id]
	if bool(attack.get("unnegatable", false)):
		return

	attack["cancelled"] = true
	attack["result"] = &"negated"
	context.game_state.attacks[attack_id] = attack

	context.effect_engine.fire_hook(&"ON_ATTACK_NEGATED", {
		"attack_id": attack_id,
		"source_card_id": params.get("source_card_id", &"")
	})


## 设置攻击不可否定
func set_attack_unnegatable(params: Dictionary) -> void:
	var attack_id: StringName = params.get("attack_id", context.game_state.current_attack_id)
	if attack_id == &"" or not context.game_state.attacks.has(attack_id):
		return

	var attack: Dictionary = context.game_state.attacks[attack_id]
	attack["unnegatable"] = true
	context.game_state.attacks[attack_id] = attack


## 施加不可响应状态
func apply_cannot_respond(params: Dictionary) -> void:
	var target_id: StringName = params.get("target_id", &"")
	if target_id == &"":
		push_error("APPLY_CANNOT_RESPOND 缺少 target_id")
		return

	var status := {
		"status_id": params.get("status_id", context.game_state.next_id(&"status")),
		"type": &"CANNOT_RESPOND",
		"attack_id": params.get("attack_id", context.game_state.current_attack_id),
		"duration": params.get("duration", &"THIS_ATTACK"),
		"source_card_id": params.get("source_card_id", &"")
	}

	context.game_state.add_status_to_target(target_id, status)

	context.effect_engine.fire_hook(&"ON_STATUS_ADDED", {
		"target_id": target_id,
		"status": status
	})


## 施加或检查锁定状态
func apply_or_check_locked(params: Dictionary) -> bool:
	var target_id: StringName = params.get("target_id", params.get("mech_id", &""))
	var mode: StringName = params.get("mode", &"apply")

	if target_id == &"":
		push_error("APPLY_OR_CHECK_LOCKED 缺少 target_id")
		return false

	if mode == &"check":
		return context.game_state.has_status(target_id, &"LOCKED")

	var status := {
		"status_id": params.get("status_id", context.game_state.next_id(&"status")),
		"type": &"LOCKED",
		"duration": params.get("duration", &"THIS_TURN"),
		"source_card_id": params.get("source_card_id", &"")
	}

	context.game_state.add_status_to_target(target_id, status)

	context.effect_engine.fire_hook(&"ON_STATUS_ADDED", {
		"target_id": target_id,
		"status": status
	})

	return true


## 消耗下次攻击威力增益
func consume_next_attack_power_buff(params: Dictionary) -> void:
	var attack_id: StringName = params.get("attack_id", context.game_state.current_attack_id)
	var attacker_id: StringName = params.get("attacker_id", params.get("source_mech_id", &""))
	var weapon_id: StringName = params.get("weapon_id", &"")

	if attack_id == &"" or attacker_id == &"" or weapon_id == &"":
		return

	var mech = context.game_state.mechs.get(attacker_id)
	if mech == null:
		return

	for status in mech.statuses:
		if status.get("type") != &"NEXT_ATTACK_POWER_BUFF":
			continue
		if status.get("weapon_id") != weapon_id:
			continue
		if status.get("disabled", false):
			continue

		modify_attack_power({
			"attack_id": attack_id,
			"delta": int(status.get("delta", 0)),
			"duration": &"THIS_ATTACK",
			"source_card_id": status.get("source_card_id", &"")
		})

		if status.get("consume_on_next_attack", false):
			status["disabled"] = true


## 打开或使用响应窗口
func open_or_use_response(params: Dictionary) -> void:
	var mode: StringName = params.get("mode", &"use")
	var attack_id: StringName = params.get("attack_id", context.game_state.current_attack_id)

	if mode == &"open":
		# Just fire the response window hook
		context.effect_engine.fire_hook(&"ON_ATTACK_RESPONSE_WINDOW", {"attack_id": attack_id})
		return

	var player_id: StringName = params.get("player_id", &"")
	var response_card_id: StringName = params.get("response_card_id", params.get("card_id", &""))

	if attack_id == &"" or player_id == &"" or response_card_id == &"":
		push_error("OPEN_OR_USE_RESPONSE 缺少 attack_id / player_id / response_card_id")
		return

	# Remove card from hand and discard it (bypass phase check)
	var player_state = context.game_state.players.get(player_id)
	if player_state != null:
		player_state.action_hand.erase(response_card_id)
	discard_card({"card_id": response_card_id, "reason": &"RESPONSE_PLAY"})

	var attack: Dictionary = context.game_state.attacks[attack_id]
	attack["responded_by_target"] = true
	context.game_state.attacks[attack_id] = attack


## ────────────────────────────────────────────
## 属性修改
## ────────────────────────────────────────────

## 修改护甲
func modify_armor(params: Dictionary) -> void:
	var mech_id: StringName = params.get("mech_id", params.get("source_mech_id", &""))
	if mech_id == &"" or not context.game_state.mechs.has(mech_id):
		push_error("MODIFY_ARMOR 找不到 mech_id")
		return

	var delta: int = int(params.get("delta", 0))
	if delta == 0:
		return

	var status := {
		"status_id": params.get("status_id", context.game_state.next_id(&"status")),
		"type": &"ARMOR_MODIFIER",
		"slot_id": params.get("slot_id", &""),
		"delta": delta,
		"duration": params.get("duration", &"THIS_TURN"),
		"source_card_id": params.get("source_card_id", &"")
	}

	context.game_state.mechs[mech_id].statuses.append(status)

	context.effect_engine.fire_hook(&"ON_STATUS_ADDED", {
		"mech_id": mech_id,
		"status": status
	})


## 修改机甲动力
func modify_mech_power(params: Dictionary) -> void:
	var mech_id: StringName = params.get("mech_id", params.get("source_mech_id", &""))
	if mech_id == &"" or not context.game_state.mechs.has(mech_id):
		push_error("MODIFY_MECH_POWER 找不到 mech_id")
		return

	var mech = context.game_state.mechs[mech_id]
	var delta: int = int(params.get("delta", 0))
	var mode: StringName = params.get("mode", &"current")

	if mode == &"current":
		var before: int = mech.power
		mech.power = clamp(mech.power + delta, 0, _get_max_power(mech_id))
		context.effect_engine.fire_hook(&"ON_POWER_CHANGED", {
			"mech_id": mech_id,
			"delta": mech.power - before,
			"current_power": mech.power
		})
		return

	# 模式修饰：添加持续动力修改状态
	var status := {
		"status_id": params.get("status_id", context.game_state.next_id(&"status")),
		"type": &"POWER_MODIFIER",
		"delta": delta,
		"duration": params.get("duration", &"THIS_TURN"),
		"source_card_id": params.get("source_card_id", &"")
	}
	mech.statuses.append(status)

	context.effect_engine.fire_hook(&"ON_STATUS_ADDED", {
		"mech_id": mech_id,
		"status": status
	})


## 支付动力
func spend_power(params: Dictionary) -> bool:
	var mech_id: StringName = params.get("mech_id", params.get("source_mech_id", &""))
	var amount: int = int(params.get("amount", params.get("count", 0)))

	if mech_id == &"" or not context.game_state.mechs.has(mech_id):
		push_error("SPEND_POWER 找不到 mech_id")
		return false

	var mech = context.game_state.mechs[mech_id]
	if amount <= 0:
		return true
	if mech.power < amount:
		return false

	mech.power -= amount

	context.effect_engine.fire_hook(&"ON_POWER_SPENT", {
		"mech_id": mech_id,
		"amount": amount,
		"reason": params.get("reason", &"")
	})

	context.effect_engine.fire_hook(&"ON_POWER_CHANGED", {
		"mech_id": mech_id,
		"delta": -amount,
		"current_power": mech.power,
		"reason": params.get("reason", &"")
	})

	return true


## 恢复动力
func restore_power(params: Dictionary) -> void:
	var mech_id: StringName = params.get("mech_id", params.get("source_mech_id", &""))
	if mech_id == &"" or not context.game_state.mechs.has(mech_id):
		push_error("RESTORE_POWER 找不到 mech_id")
		return

	var mech = context.game_state.mechs[mech_id]
	var max_power := _get_max_power(mech_id)
	var before: int = mech.power

	var amount_value = params.get("amount", params.get("count", &"full"))
	if amount_value == &"full" or String(amount_value) == "full":
		mech.power = max_power
	else:
		mech.power = clamp(mech.power + int(amount_value), 0, max_power)

	var restored: int = mech.power - before
	if restored <= 0:
		return

	context.effect_engine.fire_hook(&"ON_POWER_RESTORED", {
		"mech_id": mech_id,
		"amount": restored,
		"reason": params.get("reason", &"")
	})

	context.effect_engine.fire_hook(&"ON_POWER_CHANGED", {
		"mech_id": mech_id,
		"delta": restored,
		"current_power": mech.power,
		"reason": params.get("reason", &"")
	})


## 恢复武器耐久
func restore_weapon_power(params: Dictionary) -> void:
	var weapon_id: StringName = params.get("weapon_id", params.get("target_weapon_id", &""))
	if weapon_id == &"" or not context.game_state.cards.has(weapon_id):
		push_error("RESTORE_WEAPON_POWER 找不到 weapon_id")
		return

	var card = context.game_state.cards[weapon_id]
	var max_value := int(params.get("max_value", card.def.durability if card.def != null and "durability" in card.def else 0))
	var before := int(card.counters.get("weapon_power", max_value))

	var amount_value = params.get("amount", &"full")
	if amount_value == &"full" or String(amount_value) == "full":
		card.counters["weapon_power"] = max_value
	else:
		card.counters["weapon_power"] = clamp(before + int(amount_value), 0, max_value)

	context.effect_engine.fire_hook(&"ON_WEAPON_POWER_RESTORED", {
		"weapon_id": weapon_id,
		"before": before,
		"after": card.counters["weapon_power"]
	})


## ────────────────────────────────────────────
## 抽牌/获得
## ────────────────────────────────────────────

## 抽行动牌
func draw_action_cards(params: Dictionary) -> void:
	var player_id: StringName = params.get("player_id", params.get("target_player_id", &""))
	var count: int = int(params.get("count", params.get("amount", 1)))
	var reason: StringName = params.get("reason", &"EFFECT_DRAW")

	if player_id == &"":
		push_error("DRAW_ACTION 缺少 player_id")
		return

	var drawn: Array[StringName] = []

	for i in range(max(0, count)):
		var drawn_one: Array[StringName] = []
		if context.deck_service != null:
			drawn_one = context.deck_service.draw_from_deck(&"action_deck", 1)
		if drawn_one.is_empty():
			continue
		var card_id: StringName = drawn_one[0]

		drawn.append(card_id)

		context.effect_engine.fire_hook(&"ON_CARD_DRAWN", {
			"player_id": player_id,
			"card_id": card_id,
			"card_kind": &"action",
			"reason": reason
		})

		context.effect_engine.fire_hook(&"ON_ACTION_CARD_DRAWN", {
			"player_id": player_id,
			"card_id": card_id,
			"reason": reason
		})

	context.effect_engine.fire_hook(&"ON_DRAW_FINISHED", {
		"player_id": player_id,
		"card_ids": drawn,
		"card_kind": &"action",
		"count": drawn.size(),
		"reason": reason
	})


## 抽装备牌
func draw_equipment_cards(params: Dictionary) -> void:
	var player_id: StringName = params.get("player_id", params.get("target_player_id", &""))
	var count: int = int(params.get("count", params.get("amount", 1)))
	var deck_type: StringName = params.get("deck_type", &"equipment_deck")
	var reason: StringName = params.get("reason", &"EFFECT_DRAW")

	if player_id == &"":
		push_error("DRAW_EQUIPMENT 缺少 player_id")
		return

	var drawn: Array[StringName] = []

	for i in range(max(0, count)):
		var drawn_one: Array[StringName] = []
		if context.deck_service != null:
			drawn_one = context.deck_service.draw_from_deck(deck_type, 1)
		if drawn_one.is_empty():
			continue
		var card_id: StringName = drawn_one[0]

		drawn.append(card_id)

		context.effect_engine.fire_hook(&"ON_CARD_DRAWN", {
			"player_id": player_id,
			"card_id": card_id,
			"card_kind": &"equipment",
			"deck_type": deck_type,
			"reason": reason
		})

		context.effect_engine.fire_hook(&"ON_EQUIPMENT_CARD_DRAWN", {
			"player_id": player_id,
			"card_id": card_id,
			"deck_type": deck_type,
			"reason": reason
		})

	context.effect_engine.fire_hook(&"ON_DRAW_FINISHED", {
		"player_id": player_id,
		"card_ids": drawn,
		"card_kind": &"equipment",
		"count": drawn.size(),
		"reason": reason
	})


## 获得指定卡牌
func gain_specific_card(params: Dictionary) -> void:
	var player_id: StringName = params.get("player_id", params.get("target_player_id", &""))
	var card_def_id: StringName = params.get("card_def_id", params.get("card_id", &""))
	var zone: StringName = params.get("zone", &"hand")

	if player_id == &"" or card_def_id == &"":
		push_error("GAIN_SPECIFIC_CARD 缺少 player_id / card_def_id")
		return

	if context.card_database == null or not context.card_database.card_defs.has(card_def_id):
		push_error("GAIN_SPECIFIC_CARD 找不到 card_def_id: %s" % card_def_id)
		return

	var def = context.card_database.card_defs[card_def_id]
	var instance = _CardInstance.new(context.game_state.next_id(&"card"), def)
	instance.owner_player_id = player_id
	instance.zone = zone
	context.game_state.cards[instance.instance_id] = instance

	if zone == &"hand":
		var player_state = context.game_state.players.get(player_id)
		if player_state != null:
			if def.card_kind == &"action":
				player_state.action_hand.append(instance.instance_id)
			elif def.card_kind == &"equipment":
				player_state.equipment_hand.append(instance.instance_id)

	context.effect_engine.fire_hook(&"ON_CARD_GAINED", {
		"player_id": player_id,
		"card_id": instance.instance_id,
		"card_def_id": card_def_id,
		"zone": zone
	})


## 从弃牌堆或牌库随机抽牌
func random_draw_from_discard_or_deck(params: Dictionary) -> void:
	var player_id: StringName = params.get("player_id", params.get("target_player_id", &""))
	var count: int = int(params.get("count", 1))
	var source_zone: StringName = params.get("source_zone", &"discard")
	var card_kind: StringName = params.get("card_kind", &"")

	if player_id == &"":
		push_error("RANDOM_DRAW_FROM_DISCARD_OR_DECK 缺少 player_id")
		return

	var pool: Array[StringName] = []

	if source_zone == &"discard":
		pool = context.game_state.deck_state.discard_pile.duplicate()
	elif source_zone == &"action_deck":
		pool = context.game_state.deck_state.action_deck.duplicate()
	elif source_zone == &"equipment_deck":
		pool = context.game_state.deck_state.equipment_deck.duplicate()
	elif source_zone == &"advanced_equipment_deck":
		pool = context.game_state.deck_state.advanced_equipment_deck.duplicate()
	elif source_zone == &"pilot_deck":
		pool = context.game_state.deck_state.pilot_deck.duplicate()
	elif source_zone == &"event_deck":
		pool = context.game_state.deck_state.event_deck.duplicate()
	else:
		pool = context.game_state.deck_state.discard_pile.duplicate()

	if card_kind != &"":
		pool = pool.filter(func(card_id: StringName) -> bool:
			var card = context.game_state.cards.get(card_id)
			if card == null or card.def == null:
				return false
			return card.def.card_kind == card_kind
		)

	pool.shuffle()

	for i in range(min(count, pool.size())):
		var card_id: StringName = pool[i]
		context.game_state.remove_card_from_all_zones(card_id)
		context.game_state.move_card_to_player_hand(player_id, card_id)

		context.effect_engine.fire_hook(&"ON_CARD_GAINED", {
			"player_id": player_id,
			"card_id": card_id,
			"from_zone": source_zone
		})


## 转移行动牌
func transfer_action_cards(params: Dictionary) -> void:
	var from_player_id: StringName = params.get("from_player_id", &"")
	var to_player_id: StringName = params.get("to_player_id", params.get("player_id", &""))
	var card_ids: Array = params.get("card_ids", [])
	var count: int = int(params.get("count", 1))

	if from_player_id == &"" or to_player_id == &"":
		push_error("TRANSFER_ACTION_CARDS 缺少 from_player_id / to_player_id")
		return

	if card_ids.is_empty():
		var from_state = context.game_state.players.get(from_player_id)
		if from_state != null:
			card_ids = from_state.action_hand.slice(0, min(count, from_state.action_hand.size()))

	for card_id in card_ids:
		var from_state = context.game_state.players.get(from_player_id)
		var to_state = context.game_state.players.get(to_player_id)
		if from_state == null or to_state == null:
			continue
		if not from_state.action_hand.has(card_id):
			continue

		from_state.action_hand.erase(card_id)
		to_state.action_hand.append(card_id)

		var card = context.game_state.cards.get(card_id)
		if card != null:
			card.owner_player_id = to_player_id
			card.zone = &"hand"

		context.effect_engine.fire_hook(&"ON_CARD_TRANSFERRED", {
			"card_id": card_id,
			"from_player_id": from_player_id,
			"to_player_id": to_player_id
		})


## 获得金币
func gain_gold(params: Dictionary) -> void:
	var player_id: StringName = params.get("player_id", params.get("target_player_id", &""))
	var amount: int = int(params.get("amount", params.get("count", 0)))

	if player_id == &"" or amount <= 0:
		return

	var player_state = context.game_state.players.get(player_id)
	if player_state == null:
		return
	player_state.gold += amount

	context.effect_engine.fire_hook(&"ON_GOLD_GAINED", {
		"player_id": player_id,
		"amount": amount,
		"reason": params.get("reason", &"")
	})

	context.effect_engine.fire_hook(&"ON_GOLD_CHANGED", {
		"player_id": player_id,
		"delta": amount,
		"current_gold": player_state.gold,
		"reason": params.get("reason", &"")
	})


## 支付金币
func spend_gold(params: Dictionary) -> bool:
	var player_id: StringName = params.get("player_id", params.get("target_player_id", &""))
	var amount: int = int(params.get("amount", params.get("cost", 0)))

	if player_id == &"":
		push_error("SPEND_GOLD 缺少 player_id")
		return false

	if amount <= 0:
		return true

	var player_state = context.game_state.players.get(player_id)
	if player_state == null:
		return false
	if player_state.gold < amount:
		return false

	player_state.gold -= amount

	context.effect_engine.fire_hook(&"ON_GOLD_SPENT", {
		"player_id": player_id,
		"amount": amount,
		"reason": params.get("reason", &"")
	})

	context.effect_engine.fire_hook(&"ON_GOLD_CHANGED", {
		"player_id": player_id,
		"delta": -amount,
		"current_gold": player_state.gold,
		"reason": params.get("reason", &"")
	})

	return true


## 商店购买修正
func shop_buy_modifier(params: Dictionary) -> void:
	var player_id: StringName = params.get("player_id", params.get("target_player_id", &""))
	if player_id == &"":
		push_error("SHOP_BUY_MODIFIER 缺少 player_id")
		return

	var modifier := {
		"modifier_id": params.get("modifier_id", context.game_state.next_id(&"status")),
		"type": &"SHOP_BUY_MODIFIER",
		"delta": int(params.get("delta", 0)),
		"multiplier": float(params.get("multiplier", 1.0)),
		"scope": params.get("scope", &"ANY"),
		"duration": params.get("duration", &"THIS_TURN"),
		"source_card_id": params.get("source_card_id", &"")
	}

	var player_state = context.game_state.players.get(player_id)
	if player_state != null:
		player_state.statuses.append(modifier)

	context.effect_engine.fire_hook(&"ON_STATUS_ADDED", {
		"player_id": player_id,
		"status": modifier
	})


## ────────────────────────────────────────────
## 伤害/损伤
## ────────────────────────────────────────────

## 造成伤害
func deal_damage(params: Dictionary) -> void:
	var target_id: StringName = params.get("target_id", params.get("mech_id", &""))
	var amount: int = int(params.get("amount", 0))

	if target_id == &"" or not context.game_state.mechs.has(target_id) or amount <= 0:
		return

	var mech = context.game_state.mechs[target_id]
	mech.current_hp -= amount

	context.effect_engine.fire_hook(&"ON_DAMAGE_DEALT", {
		"target_id": target_id,
		"amount": amount,
		"current_hp": mech.current_hp,
		"source_attack_id": params.get("source_attack_id", &""),
		"source_card_id": params.get("source_card_id", &""),
		"damage_type": params.get("damage_type", &"effect")
	})

	if mech.current_hp <= 0:
		destroy_mech({"mech_id": target_id, "source": params.get("source", &"damage")})


## 放置损伤标记
func place_damage_tokens(params: Dictionary) -> void:
	var target_id: StringName = params.get("target_id", params.get("mech_id", &""))
	var amount: int = int(params.get("amount", params.get("count", 0)))
	var chooser_player_id: StringName = params.get("chooser_player_id", &"")

	if target_id == &"" or not context.game_state.mechs.has(target_id) or amount <= 0:
		return

	var mech = context.game_state.mechs[target_id]
	if chooser_player_id == &"":
		chooser_player_id = mech.owner_player_id

	for i in range(amount):
		var token_payload := {
			"target_id": target_id,
			"chooser_player_id": chooser_player_id,
			"index": i,
			"source_attack_id": params.get("source_attack_id", &""),
			"prefer_part_slot": params.get("prefer_part_slot", false),
			"cancelled": false,
			"forced_slot_id": params.get("slot_id", &"")
		}

		context.effect_engine.fire_hook(&"ON_BEFORE_DAMAGE_TOKEN_PLACED", token_payload)

		if token_payload.get("cancelled", false):
			continue

		var slot_id: StringName = token_payload.get("forced_slot_id", &"")
		if slot_id == &"":
			slot_id = context.game_state.ask_player_choose_damage_slot(
				chooser_player_id,
				target_id,
				params.get("prefer_part_slot", false)
			)

		context.game_state.place_one_damage_token(target_id, slot_id)

		context.effect_engine.fire_hook(&"ON_AFTER_DAMAGE_TOKEN_PLACED", {
			"target_id": target_id,
			"slot_id": slot_id,
			"chooser_player_id": chooser_player_id,
			"source_attack_id": params.get("source_attack_id", &"")
		})

		_check_equipment_broken_after_damage(target_id, slot_id)


## 修改损伤标记数量
func modify_damage_tokens(params: Dictionary) -> void:
	var context_id: StringName = params.get("damage_context_id", context.game_state.current_damage_context_id)
	if context_id == &"" or not context.game_state.damage_contexts.has(context_id):
		push_error("MODIFY_DAMAGE_TOKENS 找不到 damage_context_id")
		return

	var delta: int = int(params.get("delta", 0))
	var ctx: Dictionary = context.game_state.damage_contexts[context_id]

	ctx["damage_tokens"] = max(0, int(ctx.get("damage_tokens", 0)) + delta)

	if not ctx.has("modifiers"):
		ctx["modifiers"] = []

	ctx["modifiers"].append({
		"type": &"damage_tokens",
		"delta": delta,
		"source_card_id": params.get("source_card_id", &"")
	})

	context.game_state.damage_contexts[context_id] = ctx


## 移除损伤标记
func remove_damage_tokens(params: Dictionary) -> void:
	var mech_id: StringName = params.get("mech_id", params.get("target_id", &""))
	var slot_id: StringName = params.get("slot_id", &"")
	var amount: int = int(params.get("amount", params.get("count", 1)))

	if mech_id == &"" or slot_id == &"" or amount <= 0:
		return

	var mech = context.game_state.mechs.get(mech_id)
	if mech == null:
		return
	var slot_state = mech.slots.get(slot_id)
	if slot_state == null:
		return

	var removed := 0

	while removed < amount and slot_state.region_damage_tokens > 0:
		slot_state.region_damage_tokens -= 1
		removed += 1

	if removed < amount and slot_state.equipped_card != null:
		var card = slot_state.equipped_card
		while removed < amount and card.damage_tokens > 0:
			card.damage_tokens -= 1
			removed += 1

	if removed > 0:
		context.effect_engine.fire_hook(&"ON_DAMAGE_TOKEN_REMOVED", {
			"mech_id": mech_id,
			"slot_id": slot_id,
			"amount": removed
		})


## 重定向损伤标记
func redirect_damage_tokens(params: Dictionary) -> void:
	var context_id: StringName = params.get("damage_context_id", context.game_state.current_damage_context_id)
	if context_id == &"" or not context.game_state.damage_contexts.has(context_id):
		push_error("REDIRECT_DAMAGE_TOKENS 找不到 damage_context_id")
		return

	var ctx: Dictionary = context.game_state.damage_contexts[context_id]
	if not ctx.has("redirect_rules"):
		ctx["redirect_rules"] = []

	ctx["redirect_rules"].append({
		"from_slot_id": params.get("from_slot_id", &""),
		"to_slot_id": params.get("to_slot_id", &""),
		"amount": int(params.get("amount", 1)),
		"source_card_id": params.get("source_card_id", &"")
	})

	context.game_state.damage_contexts[context_id] = ctx


## 治疗生命
func heal_hp(params: Dictionary) -> void:
	var mech_id: StringName = params.get("mech_id", params.get("target_id", params.get("source_mech_id", &"")))
	var amount: int = int(params.get("amount", params.get("count", 0)))

	if mech_id == &"" or not context.game_state.mechs.has(mech_id) or amount <= 0:
		return

	var mech = context.game_state.mechs[mech_id]
	var before: int = mech.current_hp
	mech.current_hp = min(mech.max_hp, mech.current_hp + amount)

	var healed: int = mech.current_hp - before
	if healed <= 0:
		return

	context.effect_engine.fire_hook(&"ON_HP_HEALED", {
		"mech_id": mech_id,
		"amount": healed,
		"current_hp": mech.current_hp
	})


## ────────────────────────────────────────────
## 移动/设置
## ────────────────────────────────────────────

## 移动机甲
func move_mech(params: Dictionary) -> void:
	var mech_id: StringName = params.get("mech_id", params.get("source_mech_id", &""))
	var target_cell_id: StringName = params.get("target_cell_id", params.get("cell_id", &""))
	var ignore_cost: bool = bool(params.get("ignore_cost", false))

	if mech_id == &"" or target_cell_id == &"":
		push_error("MOVE_MECH 缺少 mech_id / target_cell_id")
		return

	if context.map_service != null:
		# Parse cell_id "q,r" to hex dict
		var parts := target_cell_id.split(",")
		var target_hex := {"q": int(parts[0]), "r": int(parts[1])}
		context.map_service.move_mech_to_hex(mech_id, target_hex)


## 设置卡牌到槽位
func set_card_to_slot(params: Dictionary) -> void:
	var card_id: StringName = params.get("card_id", &"")
	var mech_id: StringName = params.get("mech_id", params.get("source_mech_id", &""))
	var slot_id: StringName = params.get("slot_id", &"")
	var face_down: bool = bool(params.get("face_down", false))

	if card_id == &"" or mech_id == &"" or slot_id == &"":
		push_error("SET_CARD_TO_SLOT 缺少 card_id / mech_id / slot_id")
		return

	context.game_state.set_card_to_slot(card_id, mech_id, slot_id, face_down)

	var card = context.game_state.cards.get(card_id)
	if card == null:
		return

	context.effect_registry.refresh_card(card)

	if card.def != null:
		if card.def.card_kind == &"equipment":
			context.effect_engine.fire_hook(&"ON_EQUIPMENT_SET", {
				"player_id": card.owner_player_id,
				"mech_id": mech_id,
				"card_id": card_id,
				"slot_id": slot_id,
				"face_down": face_down
			})
		elif card.def.card_kind == &"event":
			context.effect_engine.fire_hook(&"ON_EVENT_SET", {
				"player_id": card.owner_player_id,
				"mech_id": mech_id,
				"event_card_id": card_id,
				"timer": card.timer
			})


## 放置或触发陷阱
func place_or_trigger_trap(params: Dictionary) -> void:
	var mode: StringName = params.get("mode", &"place")

	if mode == &"trigger":
		var marker_id: StringName = params.get("marker_id", &"")
		if marker_id != &"" and context.marker_service != null:
			# Find the marker hex and trigger it
			for marker in context.game_state.map_state.markers:
				if marker.get("marker_id", &"") == marker_id:
					context.marker_service.trigger_marker_at(&"", {"q": int(marker.get("q", 0)), "r": int(marker.get("r", 0))})
					break
		return

	var cell_id: StringName = params.get("cell_id", &"")
	if cell_id == &"" or not context.game_state.map_state.cells.has(cell_id):
		push_error("PLACE_OR_TRIGGER_TRAP 找不到 cell_id")
		return

	var marker_id: StringName = context.game_state.next_id(&"marker")
	var marker := {
		"marker_id": marker_id,
		"marker_type": &"TRAP",
		"cell_id": cell_id
	}

	context.game_state.map_state.markers[marker_id] = marker
	context.game_state.map_state.cells[cell_id]["marker_id"] = marker_id

	context.effect_engine.fire_hook(&"ON_MAP_MARKER_PLACED", {
		"marker_id": marker_id,
		"marker_type": &"TRAP",
		"cell_id": cell_id
	})


## ────────────────────────────────────────────
## 弃牌/破坏
## ────────────────────────────────────────────

## 弃置卡牌
func discard_card(params: Dictionary) -> void:
	var card_id: StringName = params.get("card_id", &"")
	if card_id == &"" or not context.game_state.cards.has(card_id):
		return

	var card = context.game_state.cards[card_id]
	var from_zone: StringName = card.zone

	context.effect_registry.unregister_card(card)
	context.game_state.remove_card_from_all_zones(card_id)

	card.zone = &"discard"
	card.slot_id = &""
	card.mech_id = &""
	card.face_down = false

	if not context.game_state.deck_state.discard_pile.has(card_id):
		context.game_state.deck_state.discard_pile.append(card_id)

	context.effect_engine.fire_hook(&"ON_CARD_DISCARDED", {
		"card_id": card_id,
		"owner_player_id": card.owner_player_id,
		"from_zone": from_zone,
		"reason": params.get("reason", &"")
	})


## 弃置行动牌
func discard_action_card(params: Dictionary) -> void:
	var player_id: StringName = params.get("player_id", params.get("target_player_id", &""))
	var card_id: StringName = params.get("card_id", params.get("selected_action_card_id", &""))
	var count: int = int(params.get("count", 1))

	if player_id == &"":
		push_error("DISCARD_ACTION_CARD 缺少 player_id")
		return

	var cards_to_discard: Array[StringName] = []

	if card_id != &"":
		cards_to_discard.append(card_id)
	else:
		var player_state = context.game_state.players.get(player_id)
		if player_state != null:
			cards_to_discard = player_state.action_hand.slice(0, min(count, player_state.action_hand.size()))

	for id in cards_to_discard:
		var player_state = context.game_state.players.get(player_id)
		if player_state != null and player_state.action_hand.has(id):
			player_state.action_hand.erase(id)
		discard_card({"card_id": id, "reason": params.get("reason", &"EFFECT_DISCARD")})


## 破坏卡牌
func destroy_card(params: Dictionary) -> void:
	var card_id: StringName = params.get("card_id", &"")
	if card_id == &"" or not context.game_state.cards.has(card_id):
		return

	var card = context.game_state.cards[card_id]

	context.effect_engine.fire_hook(&"ON_CARD_DESTROYED", {
		"card_id": card_id,
		"owner_player_id": card.owner_player_id,
		"reason": params.get("reason", &"")
	})

	discard_card({
		"card_id": card_id,
		"reason": params.get("reason", &"DESTROYED")
	})


## 作为另一张牌打出
func play_as_card(params: Dictionary) -> void:
	var player_id: StringName = params.get("player_id", &"")
	var original_card_id: StringName = params.get("original_card_id", &"")
	var virtual_card_id: StringName = params.get("virtual_card_id", &"")
	var targets: Dictionary = params.get("targets", {})

	if player_id == &"" or virtual_card_id == &"":
		push_error("PLAY_AS_CARD 缺少 player_id / virtual_card_id")
		return

	if original_card_id != &"":
		discard_card({
			"card_id": original_card_id,
			"reason": &"PLAY_AS_CARD_COST"
		})

	if context.card_database == null or not context.card_database.card_defs.has(virtual_card_id):
		push_error("PLAY_AS_CARD 找不到虚拟牌定义: %s" % virtual_card_id)
		return

	var virtual_def = context.card_database.card_defs[virtual_card_id]
	var virtual_instance = _CardInstance.new(
		context.game_state.next_id(&"card"),
		virtual_def
	)
	virtual_instance.owner_player_id = player_id

	virtual_instance.zone = &"virtual_resolving"
	virtual_instance.mech_id = context.game_state.get_mech_for_player(player_id).mech_id if context.game_state.get_mech_for_player(player_id) != null else &""
	context.game_state.cards[virtual_instance.instance_id] = virtual_instance

	context.effect_engine.fire_hook(&"ON_CARD_PLAYED", {
		"player_id": player_id,
		"card_id": virtual_instance.instance_id,
		"card_kind": virtual_def.card_kind,
		"virtual_card_id": virtual_card_id,
		"targets": targets
	})

	for effect in virtual_def.effects:
		var binding = _EffectBinding.new(virtual_instance, effect)
		var payload := targets.duplicate(true)
		payload["player_id"] = player_id
		payload["source_instance_id"] = virtual_instance.instance_id

		for action in effect.actions:
			_AtomicActionResolver.resolve(binding, payload, action, context)

	context.game_state.move_card_to_void(virtual_instance.instance_id)


## ────────────────────────────────────────────
## 状态
## ────────────────────────────────────────────

## 添加状态
func add_status(params: Dictionary) -> void:
	var target_id: StringName = params.get("target_id", params.get("mech_id", params.get("player_id", &"")))
	var status: Dictionary = params.get("status", {}).duplicate(true)

	if target_id == &"" or status.is_empty():
		push_error("ADD_STATUS 缺少 target_id/status")
		return

	if not status.has("status_id"):
		status["status_id"] = context.game_state.next_id(&"status")
	if not status.has("source_card_id"):
		status["source_card_id"] = params.get("source_card_id", &"")

	context.game_state.add_status_to_target(target_id, status)

	context.effect_engine.fire_hook(&"ON_STATUS_ADDED", {
		"target_id": target_id,
		"status": status
	})


## 移除状态
func remove_status(params: Dictionary) -> void:
	var target_id: StringName = params.get("target_id", params.get("mech_id", params.get("player_id", &"")))
	var status_id: StringName = params.get("status_id", &"")
	var status_type: StringName = params.get("status_type", &"")

	if target_id == &"":
		push_error("REMOVE_STATUS 缺少 target_id")
		return

	var removed: Array = context.game_state.remove_status_from_target(target_id, status_id, status_type)

	for status in removed:
		context.effect_engine.fire_hook(&"ON_STATUS_REMOVED", {
			"target_id": target_id,
			"status": status
		})


## 添加规则修正
func add_rule_modifier(params: Dictionary) -> void:
	var rule: Dictionary = {}
	if typeof(params.get("rule")) == TYPE_DICTIONARY:
		rule = params.get("rule").duplicate(true)
	else:
		rule = {
			"rule_id": params.get("rule_id", context.game_state.next_id(&"status")),
			"rule_type": params.get("rule_type", &"CUSTOM"),
			"value": params.get("rule", "")
		}

	if not rule.has("rule_id"):
		rule["rule_id"] = context.game_state.next_id(&"status")

	rule["source_card_id"] = params.get("source_card_id", &"")
	rule["duration"] = params.get("duration", &"WHILE_SOURCE_ACTIVE")

	context.game_state.rule_modifiers.append(rule)

	context.effect_engine.fire_hook(&"ON_RULE_MODIFIER_ADDED", {
		"rule": rule,
		"source_card_id": rule["source_card_id"]
	})


## ────────────────────────────────────────────
## 事件/计时
## ────────────────────────────────────────────

## 减少事件计时
func reduce_event_timer(params: Dictionary) -> void:
	var event_card_id: StringName = params.get("event_card_id", &"")
	var amount: int = int(params.get("amount", 1))

	if event_card_id == &"" or not context.game_state.cards.has(event_card_id):
		return

	var card = context.game_state.cards[event_card_id]
	card.timer -= amount

	context.effect_engine.fire_hook(&"ON_EVENT_TIMER_TICK", {
		"event_card_id": event_card_id,
		"timer": card.timer
	})

	if card.timer <= 0:
		context.effect_engine.fire_hook(&"ON_EVENT_TIMER_ZERO", {
			"event_card_id": event_card_id,
			"mech_id": card.mech_id
		})

		if card.def != null and card.def is _EventCardDef and card.def.discard_when_timer_zero:
			discard_card({
				"card_id": event_card_id,
				"reason": &"EVENT_TIMER_ZERO"
			})


## 设置事件计时
func set_event_timer(params: Dictionary) -> void:
	var event_card_id: StringName = params.get("event_card_id", &"")
	var value: int = int(params.get("value", 0))

	if event_card_id == &"" or not context.game_state.cards.has(event_card_id):
		return

	var card = context.game_state.cards[event_card_id]
	card.timer = value

	context.effect_engine.fire_hook(&"ON_EVENT_TIMER_SET", {
		"event_card_id": event_card_id,
		"timer": value
	})


## 追踪事件进度
func track_event_progress(params: Dictionary) -> void:
	var event_card_id: StringName = params.get("event_card_id", &"")
	var metric: StringName = params.get("metric", &"progress")
	var delta: int = int(params.get("delta", 1))

	if event_card_id == &"" or not context.game_state.cards.has(event_card_id):
		push_error("TRACK_EVENT_PROGRESS 找不到 event_card_id")
		return

	var card = context.game_state.cards[event_card_id]
	var before := int(card.counters.get(metric, 0))
	card.counters[metric] = before + delta

	context.effect_engine.fire_hook(&"ON_EVENT_PROGRESS_CHANGED", {
		"event_card_id": event_card_id,
		"metric": metric,
		"before": before,
		"after": card.counters[metric]
	})


## ────────────────────────────────────────────
## 其他
## ────────────────────────────────────────────

## 揭示或窥视卡牌
func reveal_or_peek_card(params: Dictionary) -> void:
	var player_id: StringName = params.get("player_id", &"")
	var mode: StringName = params.get("mode", &"reveal")
	var card_ids: Array = params.get("card_ids", [])

	if card_ids.is_empty() and params.has("card_id"):
		card_ids = [params.get("card_id")]

	if mode == &"peek":
		context.effect_engine.fire_hook(&"ON_CARD_PEEKED", {
			"player_id": player_id,
			"card_ids": card_ids
		})
		return

	context.effect_engine.fire_hook(&"ON_CARD_REVEALED", {
		"player_id": player_id,
		"card_ids": card_ids
	})


## 掷骰子
func roll_d6(params: Dictionary) -> int:
	var result := randi_range(1, 6)
	var store_key: StringName = params.get("store_key", &"")

	if store_key != &"":
		context.game_state.temp_values[store_key] = result

	context.effect_engine.fire_hook(&"ON_DICE_ROLLED", {
		"result": result,
		"sides": 6,
		"source_card_id": params.get("source_card_id", &"")
	})

	return result


## 切换光环目标
func toggle_aura_target(params: Dictionary) -> void:
	var target_id: StringName = params.get("target_id", &"")
	var aura_id: StringName = params.get("aura_id", params.get("source_card_id", &""))
	var enabled: bool = bool(params.get("enabled", true))

	if target_id == &"" or aura_id == &"":
		push_error("TOGGLE_AURA_TARGET 缺少 target_id / aura_id")
		return

	if enabled:
		context.game_state.enable_aura_for_target(aura_id, target_id)
	else:
		context.game_state.disable_aura_for_target(aura_id, target_id)

	context.effect_engine.fire_hook(&"ON_AURA_TARGET_CHANGED", {
		"target_id": target_id,
		"aura_id": aura_id,
		"enabled": enabled
	})


## 自定义效果文本检查（兜底）
func custom_effect_check_text(params: Dictionary) -> void:
	var item := {
		"effect_id": params.get("effect_id", &""),
		"source_card_id": params.get("source_card_id", &""),
		"text": params.get("text", params.get("effect_text", "")),
		"payload": params.get("payload", {})
	}

	context.game_state.pending_custom_effects.append(item)

	context.effect_engine.fire_hook(&"ON_CUSTOM_EFFECT_REQUIRED", item)


## ────────────────────────────────────────────
## 辅助方法
## ────────────────────────────────────────────

## 检查装备损伤后是否损坏
func _check_equipment_broken_after_damage(mech_id: StringName, slot_id: StringName) -> void:
	var mech = context.game_state.mechs.get(mech_id)
	if mech == null:
		return
	var slot_state = mech.slots.get(slot_id)
	if slot_state == null or slot_state.equipped_card == null:
		return

	var card = slot_state.equipped_card
	if card.def == null or card.def.card_kind != &"equipment":
		return

	if card.damage_tokens < slot_state.get_equipment_durability():
		return

	context.effect_engine.fire_hook(&"ON_EQUIPMENT_BROKEN", {
		"mech_id": mech_id,
		"slot_id": slot_id,
		"card_id": card.instance_id,
		"damage_tokens": card.damage_tokens,
		"durability": slot_state.get_equipment_durability()
	})

	# 规则：装备被弃置后，损伤保留在区域上
	# 注意：DamageTokenService 已经同时增加了 region_damage_tokens 和 card.damage_tokens
	# 因此不需要再将 card.damage_tokens 加到 region_damage_tokens（否则双重计算）
	discard_card({
		"card_id": card.instance_id,
		"reason": &"EQUIPMENT_BROKEN"
	})
	slot_state.equipped_card = null

	# ── 重算动力上限并调整当前动力 ──
	var old_max_power: int = mech.max_power
	mech.max_power = mech.get_total_power()
	var power_delta: int = mech.max_power - old_max_power
	mech.power = maxi(0, mech.power + power_delta)


## 破坏机甲
func destroy_mech(params: Dictionary) -> void:
	var mech_id: StringName = params.get("mech_id", params.get("target_id", &""))
	if mech_id == &"" or not context.game_state.mechs.has(mech_id):
		return

	var mech = context.game_state.mechs[mech_id]
	if mech.destroyed:
		return

	mech.destroyed = true

	context.effect_engine.fire_hook(&"ON_MECH_DESTROYED", {
		"mech_id": mech_id,
		"owner_player_id": mech.owner_player_id,
		"source": params.get("source", &"")
	})

	if context.victory_service != null:
		context.victory_service.check_victory()


## 获取机甲最大动力
func _get_max_power(mech_id: StringName) -> int:
	if context.game_state == null:
		return 0
	return context.game_state.get_max_power(mech_id)
