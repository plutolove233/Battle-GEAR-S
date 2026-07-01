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
## P2-2: 支持 ignore_lock 参数（识破无视锁定）
## ignore_lock=true 时仅作为"无视锁定"标记动作：不施加状态、不校验目标，
## 仅供 ResponsePanel/AI 在响应窗口识别"此牌无视锁定"用。
func apply_or_check_locked(params: Dictionary) -> bool:
	var ignore_lock: bool = bool(params.get("ignore_lock", false))
	if ignore_lock:
		return true  # 无视锁定标记：识破等牌的标记动作，不产生状态

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
		"source_card_id": params.get("source_card_id", &""),
		"source_player_id": params.get("source_player_id", params.get("player_id", &"")),
	}

	context.game_state.add_status_to_target(target_id, status)

	context.effect_engine.fire_hook(&"ON_STATUS_ADDED", {
		"target_id": target_id,
		"status": status
	})

	return true


## 移除目标身上由指定来源玩家施加的锁定状态
## 实现"锁定"的生命周期：A 的攻击命中 B 后，解除 A 施加在 B 上的 LOCKED。
## source_player_id 为空时移除目标身上所有 LOCKED 状态。
func remove_locked_status_from_target(target_id: StringName, source_player_id: StringName = &"") -> void:
	var mech = context.game_state.mechs.get(target_id)
	if mech == null:
		return
	mech.statuses = mech.statuses.filter(func(s: Dictionary) -> bool:
		if String(s.get("type", &"")) != "LOCKED":
			return true  # 非锁定状态保留
		# 仅移除指定来源玩家施加的锁定；来源不匹配则保留
		if source_player_id != &"" and String(s.get("source_player_id", &"")) != String(source_player_id):
			return true
		return false
	)


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
## P2-2: 如果 duration=THIS_ATTACK 且有活跃的攻击上下文，同时写入 attack_context["temporary_armor_bonus"]
func modify_armor(params: Dictionary) -> void:
	var mech_id: StringName = params.get("mech_id", params.get("source_mech_id", &""))
	if mech_id == &"" or not context.game_state.mechs.has(mech_id):
		push_error("MODIFY_ARMOR 找不到 mech_id")
		return

	var delta: int = int(params.get("delta", 0))
	if delta == 0:
		return

	var duration: StringName = params.get("duration", &"THIS_TURN")

	var status := {
		"status_id": params.get("status_id", context.game_state.next_id(&"status")),
		"type": &"ARMOR_MODIFIER",
		"slot_id": params.get("slot_id", &""),
		"delta": delta,
		"duration": duration,
		"source_card_id": params.get("source_card_id", &"")
	}

	context.game_state.mechs[mech_id].statuses.append(status)

	# P2-2: 如果是 THIS_ATTACK 持续时间的护甲修改，同时写入 attack_context
	if duration == &"THIS_ATTACK":
		var attack_id: StringName = params.get("attack_id", context.game_state.current_attack_id)
		if attack_id != &"" and context.game_state.attacks.has(attack_id):
			var attack: Dictionary = context.game_state.attacks[attack_id]
			var current_bonus: int = int(attack.get("temporary_armor_bonus", 0))
			attack["temporary_armor_bonus"] = current_bonus + delta
			context.game_state.attacks[attack_id] = attack

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
	var duration: StringName = params.get("duration", &"")

	# ── 始终立即应用动力修改 ──
	# THIS_TURN / THIS_ATTACK 临时动力增益允许超过当前上限
	var before: int = mech.power
	if duration == &"THIS_TURN" or duration == &"THIS_ATTACK":
		mech.power = maxi(0, mech.power + delta)
	else:
		mech.power = clamp(mech.power + delta, 0, _get_max_power(mech_id))
	context.effect_engine.fire_hook(&"ON_POWER_CHANGED", {
		"mech_id": mech_id,
		"delta": mech.power - before,
		"current_power": mech.power
	})

	# ── 如果指定了 duration，注册状态追踪以便回合结束时还原 ──
	if duration != &"":
		var status := {
			"status_id": params.get("status_id", context.game_state.next_id(&"status")),
			"type": &"POWER_MODIFIER",
			"delta": delta,
			"duration": duration,
			"source_card_id": params.get("source_card_id", &""),
			"mech_id": mech_id,
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

	var player_state = context.game_state.players.get(player_id)
	var drawn: Array[StringName] = []

	for i in range(max(0, count)):
		var drawn_one: Array[StringName] = []
		if context.deck_service != null:
			drawn_one = context.deck_service.draw_from_deck(&"action_deck", 1)
		if drawn_one.is_empty():
			continue
		var card_id: StringName = drawn_one[0]

		drawn.append(card_id)

		# 将抽到的行动牌加入玩家手牌（draw_from_deck 仅更新 zone，不维护手牌数组）
		if player_state != null and not player_state.action_hand.has(card_id):
			player_state.action_hand.append(card_id)

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

	var player_state = context.game_state.players.get(player_id)
	var drawn: Array[StringName] = []

	for i in range(max(0, count)):
		var drawn_one: Array[StringName] = []
		if context.deck_service != null:
			drawn_one = context.deck_service.draw_from_deck(deck_type, 1)
		if drawn_one.is_empty():
			continue
		var card_id: StringName = drawn_one[0]

		drawn.append(card_id)

		# 将抽到的装备牌加入玩家手牌（draw_from_deck 仅更新 zone，不维护手牌数组）
		if player_state != null and not player_state.equipment_hand.has(card_id):
			player_state.equipment_hand.append(card_id)

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
	# 兼容两种参数命名：效果定义用 "type"，部分调用用 "card_kind"
	var card_kind: StringName = params.get("card_kind", params.get("type", &""))

	if player_id == &"":
		push_error("RANDOM_DRAW_FROM_DISCARD_OR_DECK 缺少 player_id")
		return

	var pool: Array[StringName] = []

	if source_zone == &"discard":
		if card_kind == &"equipment":
			pool = context.game_state.deck_state.equipment_discard_pile.duplicate()
		elif card_kind == &"action":
			pool = context.game_state.deck_state.action_discard_pile.duplicate()
		else:
			pool = (context.game_state.deck_state.action_discard_pile + context.game_state.deck_state.equipment_discard_pile).duplicate()
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
		pool = (context.game_state.deck_state.action_discard_pile + context.game_state.deck_state.equipment_discard_pile).duplicate()

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
## P2-1: 如果 params 包含 extra_markers_only=true，则不直接放置，
## 而是写入 attack_context["extra_markers"]（破甲等效果绕过统一的损伤放置UI）
func place_damage_tokens(params: Dictionary) -> void:
	var target_id: StringName = params.get("target_id", params.get("mech_id", &""))
	var amount: int = int(params.get("amount", params.get("count", 0)))
	var chooser_player_id: StringName = params.get("chooser_player_id", &"")

	# P2-1: 破甲等效果的 extra_markers_only 模式
	var extra_markers_only: bool = bool(params.get("extra_markers_only", false))
	if extra_markers_only:
		var attack_id: StringName = params.get("attack_id", context.game_state.current_attack_id)
		if attack_id != &"" and context.game_state.attacks.has(attack_id):
			var attack: Dictionary = context.game_state.attacks[attack_id]
			var current_extra: int = int(attack.get("extra_markers", 0))
			attack["extra_markers"] = current_extra + amount
			context.game_state.attacks[attack_id] = attack
		return

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
## 优先写回 attack_context（有 attack_id 作用域，不会跨攻击残留），
## 同时向后兼容 damage_contexts 和 temp_values
func modify_damage_tokens(params: Dictionary) -> void:
	var delta: int = int(params.get("delta", 0))

	# 优先写回 attack_context
	var attack_id: StringName = params.get("attack_id", context.game_state.current_attack_id)
	if attack_id != &"" and context.game_state.attacks.has(attack_id):
		var attack: Dictionary = context.game_state.attacks[attack_id]
		var current_markers: int = int(attack.get("markers", 0))
		attack["markers"] = max(0, current_markers + delta)
		context.game_state.attacks[attack_id] = attack

	# 向后兼容：也写入 temp_values
	context.game_state.temp_values["modified_markers"] = max(0, int(context.game_state.temp_values.get("modified_markers", 0)) + delta)

	# 向后兼容：也写入 damage_contexts（如果存在）
	var context_id: StringName = params.get("damage_context_id", context.game_state.current_damage_context_id)
	if context_id != &"" and context.game_state.damage_contexts.has(context_id):
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
## 如果未指定 slot_id，自动从损伤最多的槽位开始移除
func remove_damage_tokens(params: Dictionary) -> void:
	var mech_id: StringName = params.get("mech_id", params.get("target_id", &""))
	var slot_id: StringName = params.get("slot_id", &"")
	var amount: int = int(params.get("amount", params.get("count", 1)))

	if mech_id == &"" or amount <= 0:
		return

	var mech = context.game_state.mechs.get(mech_id)
	if mech == null:
		return

	# 如果指定了 slot_id，从该槽位移除
	if slot_id != &"":
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
		return

	# 未指定 slot_id：自动从损伤最多的槽位开始移除
	var remaining := amount
	var total_removed := 0
	# 按损伤标记数降序排列槽位
	var sorted_slots: Array[Dictionary] = []
	for sid: StringName in mech.slots:
		var s = mech.slots[sid]
		var total_tokens: int = s.region_damage_tokens
		if s.equipped_card != null:
			total_tokens += s.equipped_card.damage_tokens
		if total_tokens > 0:
			sorted_slots.append({"slot_id": sid, "total_tokens": total_tokens})
	sorted_slots.sort_custom(func(a, b): return a["total_tokens"] > b["total_tokens"])

	for entry: Dictionary in sorted_slots:
		if remaining <= 0:
			break
		var sid: StringName = entry["slot_id"]
		var s = mech.slots[sid]
		var removed := 0
		while removed < remaining and s.region_damage_tokens > 0:
			s.region_damage_tokens -= 1
			removed += 1
		if removed < remaining and s.equipped_card != null:
			var card = s.equipped_card
			while removed < remaining and card.damage_tokens > 0:
				card.damage_tokens -= 1
				removed += 1
		remaining -= removed
		total_removed += removed
		if removed > 0:
			context.effect_engine.fire_hook(&"ON_DAMAGE_TOKEN_REMOVED", {
				"mech_id": mech_id,
				"slot_id": sid,
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

	# 按卡牌类型分入对应弃牌堆
	var target_pile: Array = context.game_state.deck_state.action_discard_pile
	if card.def and card.def.card_kind == &"equipment":
		target_pile = context.game_state.deck_state.equipment_discard_pile
	if not target_pile.has(card_id):
		target_pile.append(card_id)

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

	if bool(params.get("from_target", false)):
		var target_id: StringName = params.get("target_id", &"")
		if target_id == &"" and context.game_state.current_attack_id != &"":
			var attack: Dictionary = context.game_state.attacks.get(context.game_state.current_attack_id, {})
			target_id = attack.get("target_id", &"")
		var target_player = context.game_state.get_player_for_mech(target_id)
		if target_player:
			player_id = target_player.player_id

	if bool(params.get("from_attacker", false)):
		var attacker_id: StringName = params.get("attacker_id", &"")
		if attacker_id == &"" and context.game_state.current_attack_id != &"":
			var attack: Dictionary = context.game_state.attacks.get(context.game_state.current_attack_id, {})
			attacker_id = attack.get("attacker_id", &"")
		var attacker_player = context.game_state.get_player_for_mech(attacker_id)
		if attacker_player:
			player_id = attacker_player.player_id

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


## 随机弃置行动牌
func random_discard_action_card(params: Dictionary) -> void:
	var player_id: StringName = params.get("player_id", params.get("target_player_id", &""))
	var count: int = int(params.get("count", 1))

	# 解析 from_target / from_attacker（与 discard_action_card 相同逻辑）
	if bool(params.get("from_target", false)):
		var target_id: StringName = params.get("target_id", &"")
		if target_id == &"" and context.game_state.current_attack_id != &"":
			var attack: Dictionary = context.game_state.attacks.get(context.game_state.current_attack_id, {})
			target_id = attack.get("target_id", &"")
		var target_player = context.game_state.get_player_for_mech(target_id)
		if target_player:
			player_id = target_player.player_id
	if bool(params.get("from_attacker", false)):
		var attacker_id: StringName = params.get("attacker_id", &"")
		if attacker_id == &"" and context.game_state.current_attack_id != &"":
			var attack: Dictionary = context.game_state.attacks.get(context.game_state.current_attack_id, {})
			attacker_id = attack.get("attacker_id", &"")
		var attacker_player = context.game_state.get_player_for_mech(attacker_id)
		if attacker_player:
			player_id = attacker_player.player_id

	if player_id == &"":
		push_error("RANDOM_DISCARD_ACTION_CARD 缺少 player_id")
		return

	var player_state = context.game_state.players.get(player_id)
	if player_state == null:
		return

	var is_last_before_discard: bool = (player_state.action_hand.size() <= count)

	# 随机选择要弃置的牌
	var indices: Array[int] = []
	for i in range(player_state.action_hand.size()):
		indices.append(i)
	indices.shuffle()

	var cards_to_discard: Array[StringName] = []
	for i in range(min(count, indices.size())):
		cards_to_discard.append(player_state.action_hand[indices[i]])

	# 设置临时标记供条件检查（弃置后是否为最后一张行动牌）
	if is_last_before_discard:
		context.game_state.temp_values["is_last_action_card_in_hand"] = true

	for card_id in cards_to_discard:
		discard_action_card({
			"player_id": player_id,
			"card_id": card_id,
			"reason": params.get("reason", &"EFFECT_RANDOM_DISCARD"),
		})

	# 触发随机弃牌钩子
	context.effect_engine.fire_hook(&"ON_ACTION_CARD_RANDOMLY_DISCARDED", {
		"player_id": player_id,
		"card_ids": cards_to_discard,
		"was_last_card": is_last_before_discard,
	})


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


## 对武器施加聚能效果（下次攻击威力+N）
func apply_energy_to_weapon(params: Dictionary) -> void:
	var mech_id: StringName = params.get("mech_id", params.get("source_mech_id", &""))
	var weapon_id: StringName = params.get("weapon_id", params.get("selected_weapon_id", &""))
	var delta: int = int(params.get("delta", 4))

	if mech_id == &"" or weapon_id == &"":
		push_error("APPLY_ENERGY_TO_WEAPON 缺少 mech_id / weapon_id")
		return

	var status := {
		"status_id": params.get("status_id", context.game_state.next_id(&"status")),
		"type": &"NEXT_ATTACK_POWER_BUFF",
		"weapon_id": weapon_id,
		"delta": delta,
		"consume_on_next_attack": true,
		"duration": params.get("duration", &"THIS_TURN"),
		"source_card_id": params.get("source_card_id", &"")
	}

	var mech = context.game_state.mechs.get(mech_id)
	if mech != null:
		mech.statuses.append(status)

	context.effect_engine.fire_hook(&"ON_ENERGY_APPLIED_TO_WEAPON", {
		"mech_id": mech_id,
		"weapon_id": weapon_id,
		"delta": delta,
		"status": status
	})


## 从对手手牌偷取行动牌
func steal_action_card(params: Dictionary) -> void:
	var from_player_id: StringName = params.get("from_player_id", &"")
	var to_player_id: StringName = params.get("to_player_id", params.get("player_id", &""))
	var count: int = int(params.get("count", 1))
	var discard: bool = bool(params.get("discard", false))

	if from_player_id == &"" and bool(params.get("from_target", false)):
		var target_id: StringName = &""
		if context.game_state.current_attack_id != &"":
			var attack: Dictionary = context.game_state.attacks.get(context.game_state.current_attack_id, {})
			target_id = attack.get("target_id", &"")
		if target_id == &"":
			target_id = params.get("target_id", &"")
		var target_player = context.game_state.get_player_for_mech(target_id)
		if target_player:
			from_player_id = target_player.player_id
	if from_player_id == &"" and bool(params.get("from_attacker", false)):
		var attacker_id: StringName = &""
		if context.game_state.current_attack_id != &"":
			var attack: Dictionary = context.game_state.attacks.get(context.game_state.current_attack_id, {})
			attacker_id = attack.get("attacker_id", &"")
		if attacker_id == &"":
			attacker_id = params.get("attacker_id", &"")
		var attacker_player = context.game_state.get_player_for_mech(attacker_id)
		if attacker_player:
			from_player_id = attacker_player.player_id
	if from_player_id == &"":
		from_player_id = params.get("target_player_id", &"")

	if from_player_id == &"" or (to_player_id == &"" and not discard):
		push_error("STEAL_ACTION_CARD 缺少 from_player_id / to_player_id")
		return

	var from_state = context.game_state.players.get(from_player_id)
	var to_state = context.game_state.players.get(to_player_id) if not discard else null
	if from_state == null or (not discard and to_state == null):
		return

	if discard:
		for i in range(min(count, from_state.action_hand.size())):
			var card_id: StringName = from_state.action_hand[0]
			discard_action_card({
				"player_id": from_player_id,
				"card_id": card_id,
				"reason": params.get("reason", &"EFFECT_DISCARD"),
			})
			context.effect_engine.fire_hook(&"ON_CARD_DISCARDED_BY_EFFECT", {
				"card_id": card_id,
				"from_player_id": from_player_id,
				"reason": &"DISCARDED_BY_STEAL_ACTION_CARD"
			})
		return

	var stolen: Array[StringName] = []
	for i in range(min(count, from_state.action_hand.size())):
		var card_id: StringName = from_state.action_hand.pop_front()
		stolen.append(card_id)

		to_state.action_hand.append(card_id)
		var card = context.game_state.cards.get(card_id)
		if card != null:
			card.owner_player_id = to_player_id

	for card_id in stolen:
		context.effect_engine.fire_hook(&"ON_CARD_TRANSFERRED", {
			"card_id": card_id,
			"from_player_id": from_player_id,
			"to_player_id": to_player_id,
			"reason": &"STOLEN"
		})


## 放置陷阱标记到地图格
func place_trap_marker(params: Dictionary) -> void:
	var cell_id: StringName = params.get("cell_id", &"")
	var mech_id: StringName = params.get("mech_id", params.get("source_mech_id", &""))

	if cell_id == &"":
		# 如果未指定 cell_id，使用机甲当前位置
		if mech_id == &"" or not context.game_state.mechs.has(mech_id):
			push_error("PLACE_TRAP_MARKER 缺少 cell_id / mech_id")
			return
		var mech = context.game_state.mechs[mech_id]
		cell_id = String(mech.position.get("q", 0)) + "," + String(mech.position.get("r", 0))

	if not context.game_state.map_state.cells.has(cell_id):
		push_error("PLACE_TRAP_MARKER 找不到 cell_id: %s" % cell_id)
		return

	var marker_id: StringName = context.game_state.next_id(&"marker")
	var marker := {
		"marker_id": marker_id,
		"marker_type": &"TRAP",
		"cell_id": cell_id,
		"owner_player_id": params.get("player_id", params.get("source_owner_player_id", &"")),
		"damage": int(params.get("damage", 3)),
		"range": int(params.get("range", 1)),
		"tokens": int(params.get("tokens", 1))
	}

	context.game_state.map_state.markers[marker_id] = marker
	context.game_state.map_state.cells[cell_id]["marker_id"] = marker_id

	context.effect_engine.fire_hook(&"ON_MAP_MARKER_PLACED", {
		"marker_id": marker_id,
		"marker_type": &"TRAP",
		"cell_id": cell_id
	})


## 转换武器类型（如远程→近战）
func convert_weapon_kind(params: Dictionary) -> void:
	var weapon_id: StringName = params.get("weapon_id", params.get("selected_weapon_id", &""))
	var new_kind: StringName = params.get("new_kind", &"近战")

	if weapon_id == &"":
		push_error("CONVERT_WEAPON_KIND 缺少 weapon_id")
		return

	var card = context.game_state.cards.get(weapon_id)
	if card == null or card.def == null:
		push_error("CONVERT_WEAPON_KIND 找不到 weapon card: %s" % weapon_id)
		return

	var old_kind: StringName = card.def.weapon_kind if "weapon_kind" in card.def else &""
	card.def.weapon_kind = new_kind

	var status := {
		"status_id": params.get("status_id", context.game_state.next_id(&"status")),
		"type": &"WEAPON_KIND_CONVERTED",
		"weapon_id": weapon_id,
		"old_kind": old_kind,
		"new_kind": new_kind,
		"duration": params.get("duration", &"WHILE_SOURCE_ACTIVE"),
		"source_card_id": params.get("source_card_id", &"")
	}

	var mech_id: StringName = card.mech_id
	if mech_id != &"" and context.game_state.mechs.has(mech_id):
		context.game_state.mechs[mech_id].statuses.append(status)

	context.effect_engine.fire_hook(&"ON_STATUS_ADDED", {
		"mech_id": mech_id,
		"status": status
	})


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



## 互换行动牌上限与回合攻击数
func swap_hand_limit_and_attack_count(params: Dictionary) -> void:
	var player_id: StringName = params.get("player_id", params.get("source_owner_player_id", &""))
	var mech_id: StringName = params.get("mech_id", params.get("source_mech_id", &""))
	if player_id == &"" or mech_id == &"":
		push_error("SWAP_HAND_LIMIT_AND_ATTACK_COUNT 缺少 player_id / mech_id")
		return
	var player = context.game_state.players.get(player_id)
	var mech = context.game_state.mechs.get(mech_id)
	if player == null or mech == null:
		return
	# 交换当前值
	var old_limit: int = player.action_card_limit
	var old_attack: int = mech.attack_limit_this_turn
	player.action_card_limit = old_attack
	mech.attack_limit_this_turn = old_limit
	# 添加状态以在回合结束时恢复
	player.statuses.append({"type": &"swapped_hand_limit", "original": old_limit, "duration": &"THIS_TURN"})
	mech.statuses.append({"type": &"swapped_attack_count", "original": old_attack, "duration": &"THIS_TURN"})
	# 交换后立即抽牌到新的上限
	var draw_count: int = max(0, player.action_card_limit - player.action_hand.size())
	if draw_count > 0:
		draw_action_cards({"player_id": player_id, "count": draw_count, "reason": &"SWAP_DRAW"})
	context.effect_engine.fire_hook(&"ON_STATUS_ADDED", {
		"player_id": player_id,
		"mech_id": mech_id,
		"status_type": &"swap_hand_limit_and_attack_count",
		"old_limit": old_limit,
		"old_attack": old_attack,
	})

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


## ────────────────────────────────────────────
## 阶段1新增动作（280+效果支持）
## ────────────────────────────────────────────

## 在指定区域/此牌上设置损伤（slot 级别）
func place_damage_tokens_on_slot(params: Dictionary) -> void:
	var mech_id: StringName = params.get("mech_id", params.get("source_mech_id", &""))
	var slot_id: StringName = params.get("slot_id", &"")
	var amount: int = int(params.get("amount", 1))
	if mech_id == &"" or slot_id == &"":
		push_error("PLACE_DAMAGE_TOKENS_ON_SLOT 缺少 mech_id 或 slot_id")
		return
	var mech = context.game_state.mechs.get(mech_id)
	if mech == null:
		return
	var slot = mech.slots.get(slot_id)
	if slot == null:
		return
	slot.damage_tokens += amount
	context.effect_engine.fire_hook(&"ON_AFTER_DAMAGE_TOKEN_PLACED", {
		"mech_id": mech_id,
		"slot_id": slot_id,
		"amount": amount,
		"source_card_id": params.get("source_card_id", &""),
	})


## 将行动牌当作指定类型使用
func play_card_as_type(params: Dictionary) -> void:
	var player_id: StringName = params.get("player_id", &"")
	var card_id: StringName = params.get("card_id", &"")
	var as_type: StringName = params.get("as_type", &"")
	if player_id == &"" or card_id == &"" or as_type == &"":
		push_error("PLAY_CARD_AS_TYPE 缺少 player_id / card_id / as_type")
		return
	# 标记此牌在当前回合被视为指定类型
	if context.game_state == null:
		return
	context.effect_engine.fire_hook(&"ON_CARD_PLAYED", {
		"player_id": player_id,
		"card_id": card_id,
		"play_as_type": as_type,
	})


## 修改行动牌上限
func modify_action_hand_limit(params: Dictionary) -> void:
	var player_id: StringName = params.get("player_id", params.get("source_owner_player_id", &""))
	var delta: int = int(params.get("delta", 0))
	var duration: String = String(params.get("duration", "THIS_TURN"))
	if player_id == &"":
		push_error("MODIFY_ACTION_HAND_LIMIT 缺少 player_id")
		return
	var player = context.game_state.players.get(player_id)
	if player == null:
		return
	player.action_card_limit += delta
	if duration != "PERMANENT":
		# THIS_TURN 效果回合结束时自动恢复
		player.statuses.append({"type": &"action_hand_limit_modifier", "delta": delta, "duration": duration})
	context.effect_engine.fire_hook(&"ON_STATUS_ADDED", {
		"player_id": player_id,
		"status_type": &"action_hand_limit_modifier",
		"delta": delta,
	})


## 修改可攻击次数
func modify_attack_count(params: Dictionary) -> void:
	var mech_id: StringName = params.get("mech_id", params.get("source_mech_id", &""))
	var delta: int = int(params.get("delta", 0))
	var duration: String = String(params.get("duration", "THIS_TURN"))
	if mech_id == &"":
		push_error("MODIFY_ATTACK_COUNT 缺少 mech_id")
		return
	var mech = context.game_state.mechs.get(mech_id)
	if mech == null:
		return
	mech.attack_limit_this_turn += delta
	if duration != "PERMANENT":
		mech.statuses.append({"type": &"attack_count_modifier", "delta": delta, "duration": duration})
	context.effect_engine.fire_hook(&"ON_STATUS_ADDED", {
		"mech_id": mech_id,
		"status_type": &"attack_count_modifier",
		"delta": delta,
	})


## 使自定义计数器 X+1
func increment_variable(params: Dictionary) -> void:
	var variable_name: StringName = params.get("variable_name", &"default_counter")
	var delta: int = int(params.get("delta", 1))
	var player_id: StringName = params.get("player_id", params.get("source_owner_player_id", &""))
	var mech_id: StringName = params.get("mech_id", params.get("source_mech_id", &""))
	if context.game_state == null:
		return
	# 使用 game_state.variables 存储自定义计数器
	var key: String = "%s_%s_%s" % [player_id, mech_id, variable_name]
	var current: int = int(context.game_state.variables.get(key, 0))
	context.game_state.variables[key] = current + delta


## 选择多个效果之一执行（效果路由）
func choose_one(params: Dictionary) -> void:
	# 此动作是 UI 层的分支选择信号，实际由 EffectEngine 处理
	# payload 中的 chosen_effect_id 由玩家选择后传入
	var chosen_effect_id: StringName = params.get("chosen_effect_id", &"")
	if chosen_effect_id == &"":
		return
	# 触发已选择的效果
	var effect = context.card_database.get_effect(chosen_effect_id)
	if effect == null:
		push_error("CHOOSE_ONE: 未找到效果 %s" % chosen_effect_id)
		return
	# 委托 EffectEngine 使用选中的效果
	var source_card_id: StringName = params.get("source_card_id", &"")
	var binding = context.effect_registry.get_active_effect(source_card_id, chosen_effect_id)
	if binding == null:
		return
	context.effect_engine._try_resolve_binding(binding, params, true)


## 强制其他机甲执行行动
func force_mech_action(params: Dictionary) -> void:
	var target_mech_id: StringName = params.get("target_mech_id", &"")
	var action_type: StringName = params.get("action_type", &"attack")
	if target_mech_id == &"":
		push_error("FORCE_MECH_ACTION 缺少 target_mech_id")
		return
	# 标记目标机甲需要在本回合执行指定行动
	var mech = context.game_state.mechs.get(target_mech_id)
	if mech == null:
		return
	mech.statuses.append({"type": &"forced_action", "action_type": action_type, "source_mech_id": params.get("source_mech_id", &"")})


## 将牌视作指定命名类型使用
func treat_card_as_named_type(params: Dictionary) -> void:
	# 与 PLAY_AS_CARD 类似，但标记为指定的命名类型（强袭/闪击/预判等）
	var player_id: StringName = params.get("player_id", &"")
	var card_id: StringName = params.get("card_id", &"")
	var named_type: StringName = params.get("named_type", &"")
	if named_type == &"":
		push_error("TREAT_CARD_AS_NAMED_TYPE 缺少 named_type")
		return
	context.effect_engine.fire_hook(&"ON_CARD_PLAYED", {
		"player_id": player_id,
		"card_id": card_id,
		"treat_as_named_type": named_type,
	})


## 使阵营机甲获得效果（光环效果）
func grant_effect_to_faction(params: Dictionary) -> void:
	var faction: StringName = params.get("faction", &"")
	var effect_id: StringName = params.get("effect_id", &"")
	if faction == &"" or effect_id == &"":
		push_error("GRANT_EFFECT_TO_FACTION 缺少 faction 或 effect_id")
		return
	# 遍历所有机甲，为指定阵营的机甲注册效果
	if context.game_state == null:
		return
	for mech_id in context.game_state.mechs:
		var mech = context.game_state.mechs[mech_id]
		if mech.faction == faction:
			mech.statuses.append({"type": &"faction_effect_grant", "effect_id": effect_id, "source_player_id": params.get("player_id", &"")})


## 取消/恢复机甲获得的效果
func toggle_effect_on_mech(params: Dictionary) -> void:
	var mech_id: StringName = params.get("target_mech_id", &"")
	var effect_id: StringName = params.get("effect_id", &"")
	var toggle: String = String(params.get("toggle", "cancel"))
	if mech_id == &"" or effect_id == &"":
		push_error("TOGGLE_EFFECT_ON_MECH 缺少 mech_id 或 effect_id")
		return
	var mech = context.game_state.mechs.get(mech_id)
	if mech == null:
		return
	if toggle == "cancel":
		mech.statuses.append({"type": &"effect_cancelled", "effect_id": effect_id})
	else:
		# 移除取消状态
		mech.statuses = mech.statuses.filter(func(s): return not (s.get("type", &"") == &"effect_cancelled" and s.get("effect_id", &"") == effect_id))


## 使装备效果无效直到回合结束
func negate_equipment_effect(params: Dictionary) -> void:
	var target_card_id: StringName = params.get("target_card_id", &"")
	var duration: String = String(params.get("duration", "THIS_TURN"))
	if target_card_id == &"":
		push_error("NEGATE_EQUIPMENT_EFFECT 缺少 target_card_id")
		return
	# 将目标装备牌标记为效果无效
	var card = context.game_state.find_card_instance(target_card_id)
	if card == null:
		return
	card.disabled = true
	if duration == "THIS_TURN":
		card.statuses.append({"type": &"effect_negated", "duration": &"THIS_TURN"})


## 无视动力移动
func move_without_power(params: Dictionary) -> void:
	var mech_id: StringName = params.get("mech_id", params.get("source_mech_id", &""))
	var cells: int = int(params.get("cells", 1))
	if mech_id == &"":
		push_error("MOVE_WITHOUT_POWER 缺少 mech_id")
		return
	if context.map_service != null:
		context.map_service.move_mech_without_power(mech_id, cells)


## 修改武器威力（非仅回复）
func modify_weapon_power(params: Dictionary) -> void:
	var weapon_id: StringName = params.get("weapon_id", params.get("target_weapon_id", &""))
	var delta: int = int(params.get("delta", 0))
	if weapon_id == &"":
		push_error("MODIFY_WEAPON_POWER 缺少 weapon_id")
		return
	var weapon = context.game_state.find_card_instance(weapon_id)
	if weapon == null:
		return
	weapon.might_modifiers.append({"delta": delta, "duration": params.get("duration", &"PERMANENT")})


## 设置武器属性为指定值
func set_weapon_stats(params: Dictionary) -> void:
	var weapon_id: StringName = params.get("weapon_id", params.get("target_weapon_id", &""))
	var new_might: int = int(params.get("might", -1))
	var new_range: int = int(params.get("range", -1))
	if weapon_id == &"":
		push_error("SET_WEAPON_STATS 缺少 weapon_id")
		return
	var weapon = context.game_state.find_card_instance(weapon_id)
	if weapon == null:
		return
	if new_might >= 0:
		weapon.might_override = new_might
	if new_range >= 0:
		weapon.range_override = new_range


## 将护甲转化为动力
func convert_armor_to_power(params: Dictionary) -> void:
	var mech_id: StringName = params.get("mech_id", params.get("source_mech_id", &""))
	var amount: int = int(params.get("armor_amount", 0))
	var draw_per_2: int = int(params.get("draw_per_2_armor", 1))
	if mech_id == &"":
		push_error("CONVERT_ARMOR_TO_POWER 缺少 mech_id")
		return
	var mech = context.game_state.mechs.get(mech_id)
	if mech == null:
		return
	# 每转化2点护甲，抽1张行动牌
	mech.current_hp = maxi(1, mech.current_hp - amount)
	var draw_count: int = (amount / 2) * draw_per_2
	if draw_count > 0:
		draw_action_cards({"player_id": params.get("player_id", &""), "count": draw_count})
	modify_mech_power({"mech_id": mech_id, "delta": amount})


## 将回复生命改为受到等量伤害
func redirect_heal_to_damage(params: Dictionary) -> void:
	var target_mech_id: StringName = params.get("target_mech_id", &"")
	var amount: int = int(params.get("amount", 0))
	if target_mech_id == &"":
		push_error("REDIRECT_HEAL_TO_DAMAGE 缺少 target_mech_id")
		return
	var mech = context.game_state.mechs.get(target_mech_id)
	if mech == null:
		return
	# 将回复效果改为伤害
	mech.current_hp = maxi(0, mech.current_hp - amount)
	context.effect_engine.fire_hook(&"ON_DAMAGE_DEALT", {
		"mech_id": target_mech_id,
		"amount": amount,
		"source": &"redirected_heal",
	})


## 将移除损伤改为设置等量损伤
func redirect_remove_to_place_tokens(params: Dictionary) -> void:
	var target_mech_id: StringName = params.get("target_mech_id", &"")
	var amount: int = int(params.get("amount", 0))
	var slot_id: StringName = params.get("slot_id", &"")
	if target_mech_id == &"":
		push_error("REDIRECT_REMOVE_TO_PLACE_TOKENS 缺少 target_mech_id")
		return
	# 改为设置损伤
	place_damage_tokens({"mech_id": target_mech_id, "slot_id": slot_id, "amount": amount})


## 使下次造成的伤害+N
func modify_next_damage_dealt(params: Dictionary) -> void:
	var delta: int = int(params.get("delta", 0))
	var mech_id: StringName = params.get("mech_id", params.get("source_mech_id", &""))
	if context.game_state == null:
		return
	var key: String = "next_damage_bonus_%s" % mech_id
	context.game_state.variables[key] = delta


## 给武器添加名称标签（热能/光束）
func add_weapon_tag(params: Dictionary) -> void:
	var weapon_id: StringName = params.get("weapon_id", params.get("target_weapon_id", &""))
	var tag: StringName = params.get("tag", &"")
	var duration: String = String(params.get("duration", "THIS_TURN"))
	if weapon_id == &"" or tag == &"":
		push_error("ADD_WEAPON_TAG 缺少 weapon_id 或 tag")
		return
	var weapon = context.game_state.find_card_instance(weapon_id)
	if weapon == null:
		return
	weapon.def.tags.append(tag)
	if duration == "THIS_TURN":
		weapon.statuses.append({"type": &"temporary_tag", "tag": tag})


## 宣言行动牌类型
func declare_card_type(params: Dictionary) -> void:
	var player_id: StringName = params.get("player_id", params.get("source_owner_player_id", &""))
	var declared_type: StringName = params.get("declared_type", &"")
	if player_id == &"" or declared_type == &"":
		push_error("DECLARE_CARD_TYPE 缺少 player_id 或 declared_type")
		return
	var player = context.game_state.players.get(player_id)
	if player == null:
		return
	player.statuses.append({"type": &"declared_card_type", "declared_type": declared_type, "duration": &"THIS_TURN"})


## 抽高级装备牌
func draw_advanced_equipment(params: Dictionary) -> void:
	var player_id: StringName = params.get("player_id", params.get("source_owner_player_id", &""))
	var count: int = int(params.get("count", 1))
	if player_id == &"":
		push_error("DRAW_ADVANCED_EQUIPMENT 缺少 player_id")
		return
	if context.deck_service != null:
		for i in range(count):
			context.deck_service.draw_advanced_equipment(player_id)


## 正面朝上放入牌堆
func place_card_in_deck_face_up(params: Dictionary) -> void:
	var player_id: StringName = params.get("player_id", params.get("source_owner_player_id", &""))
	var card_ids: Array = params.get("card_ids", [])
	var top_card_id: StringName = params.get("top_card_id", &"")
	if player_id == &"":
		push_error("PLACE_CARD_IN_DECK_FACE_UP 缺少 player_id")
		return
	var player = context.game_state.players.get(player_id)
	if player == null:
		return
	# 将指定牌正面朝上放入行动牌堆
	for card_id in card_ids:
		player.action_deck_face_up.append(card_id)
	# 如果指定了牌堆顶的牌，重排牌堆
	if top_card_id != &"":
		# 移除该牌然后放到顶部
		var deck: Array = player.action_deck
		var idx: int = deck.find(top_card_id)
		if idx >= 0:
			deck.remove_at(idx)
			deck.push_front(top_card_id)
