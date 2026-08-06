## GameActions.gd — 游戏动作执行器
##
## GameActions 是所有原子动作的具体实现。
## 每个方法：验证参数 → 修改 GameState → 通过 context.effect_engine.fire_hook 触发结果 hook。
## 从 Effect全牌表.xlsx "GameActions完整代码" 适配而来。
## 所有 GameState/EffectEngine/EffectRegistry 引用通过 context 依赖注入，
## 替代了原设计的 Autoload 全局单例。
extends RefCounted
class_name GameActions
const SLog = preload("res://scripts/services/slog.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")

## Preloaded references for cross-file custom types
const _GameContext = preload("res://scripts/runtime/GameContext.gd")
const _GameState = preload("res://scripts/runtime/GameState.gd")
const _MechState = preload("res://scripts/runtime/MechState.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _CardDef = preload("res://scripts/card_defs/CardDef.gd")
const _EffectBinding = preload("res://scripts/action_core/EffectBinding.gd")
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

	# 记录数值修正
	var method := "add" if delta > 0 else "sub"
	SLog.log_stat_modify(
		attack_id, attack_id, "attack", "威力", delta, method,
		{"effect_id": &"MODIFY_ATTACK_POWER", "card_id": params.get("source_card_id", &"")}
	)


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

	# 记录数值修正
	var method := "add" if delta > 0 else "sub"
	SLog.log_stat_modify(
		attack_id, attack_id, "attack", "范围", delta, method,
		{"effect_id": &"MODIFY_ATTACK_RANGE", "card_id": params.get("source_card_id", &"")}
	)


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
	context.game_state.write_log(&"status_added", {
		"target_id": String(target_id),
		"status_type": String(status.get("type", &"")),
		"delta": int(status.get("delta", 0)),
		"source_card_id": String(status.get("source_card_id", &"")),
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

	# 注册锁定状态效果监听器（封锁响应/命中后清除/回合-1）
	_register_status_listeners(target_id, status)

	context.effect_engine.fire_hook(&"ON_STATUS_ADDED", {
		"target_id": target_id,
		"status": status
	})
	context.game_state.write_log(&"status_added", {
		"target_id": String(target_id),
		"status_type": String(status.get("type", &"")),
		"delta": int(status.get("delta", 0)),
		"source_card_id": String(status.get("source_card_id", &"")),
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
		"source_card_id": params.get("source_card_id", &""),
		"runtime_tag": params.get("runtime_tag", &"")
	}

	var mech = context.game_state.mechs[mech_id]
	var old_armor: int = mech.get_total_armor() if mech.has_method("get_total_armor") else 0
	mech.statuses.append(status)

	# P2-2: 如果是 THIS_ATTACK 持续时间的护甲修改，同时写入 attack_context
	if duration == &"THIS_ATTACK":
		var attack_id: StringName = params.get("attack_id", context.game_state.current_attack_id)
		if attack_id != &"" and context.game_state.attacks.has(attack_id):
			var attack: Dictionary = context.game_state.attacks[attack_id]
			var current_bonus: int = int(attack.get("temporary_armor_bonus", 0))
			attack["temporary_armor_bonus"] = current_bonus + delta
			context.game_state.attacks[attack_id] = attack

	# 记录数值修正
	var method := "add" if delta > 0 else "sub"
	SLog.log_stat_modify(
		context.game_state.current_attack_id,
		mech_id, "mech", "护甲", delta, method,
		{"effect_id": &"MODIFY_ARMOR", "card_id": params.get("source_card_id", &""), "mech_id": mech_id}
	)

	context.effect_engine.fire_hook(&"ON_STATUS_ADDED", {
		"mech_id": mech_id,
		"status": status
	})


## 修改机甲动力
## mode 扩展（effect_117/131/132 用）：
##   默认/无 mode：按 duration 决定（THIS_TURN/THIS_ATTACK 允许超上限，否则 clamp 到 max_power）。
##   &"current_only"：只改当前动力不改上限，clamp 到 [min_value, max_power]（effect_117 减目标动力-2）。
##   &"current_and_temporary_max"：当前动力与临时上限均+delta（effect_131/132 动力+4），回合结束移除临时上限。
func modify_mech_power(params: Dictionary) -> void:
	var mech_id: StringName = params.get("mech_id", params.get("target_id", params.get("source_mech_id", &"")))
	if mech_id == &"" or not context.game_state.mechs.has(mech_id):
		push_error("MODIFY_MECH_POWER 找不到 mech_id")
		return

	var mech = context.game_state.mechs[mech_id]
	var delta: int = int(params.get("delta", 0))
	var duration: StringName = params.get("duration", &"")
	var mode: StringName = params.get("mode", &"")
	var min_value: int = int(params.get("min_value", 0))

	# ── 始终立即应用动力修改 ──
	# 三种操作区分（用户裁定）：
	#  - 当前增加（临时）：正向 delta + THIS_TURN/THIS_ATTACK/current_and_temporary_max -> temp_power
	#    （消耗优先扣 temp_power，回合末清剩余，本身动力保留）。推进/手持推进器 +N 走此路径。
	#  - 回复/正向非临时（PERMANENT 等）：填本身动力至上限（保留 temp_power）。
	#  - 减动力（debuff，current_only 或负 delta）：减本身动力，不动 temp_power。
	var before: int = mech.power
	var is_temp_add: bool = delta > 0 and (duration == &"THIS_TURN" or duration == &"THIS_ATTACK" or mode == &"current_and_temporary_max")
	if is_temp_add:
		# 临时动力：power 与 temp_power 同步 +delta（允许超 max_power）
		mech.add_temp_power(delta)
		if duration == &"":
			duration = &"THIS_TURN"
	elif mode == &"cap_bonus":
		# pilot_004 玛沙 转换动力层：持久临时动力上限 +delta（POWER_CAP_MODIFIER，到下个我方回合前清），
		# current +delta（补满：上限+N 同时 current +N）。max_power 重算时 get_total_power 算入。
		# 裁定：转化护甲得到的动力会增加上限并补满。
		var cap_status := {
			"status_id": params.get("status_id", context.game_state.next_id(&"status")),
			"type": &"POWER_CAP_MODIFIER",
			"delta": delta,
			"duration": duration,
			"source_card_id": params.get("source_card_id", &""),
			"runtime_tag": params.get("runtime_tag", &""),
		}
		mech.statuses.append(cap_status)
		mech.power += delta  # 补满
		mech.max_power = mech.get_total_power()
	elif mode == &"current_only":
		# 只改本身动力，clamp 到 [min_value, max_power]，保留 temp_power
		var own: int = mech.get_own_power()
		var new_own: int = clampi(own + delta, min_value, _get_max_power(mech_id))
		mech.power += (new_own - own)
	elif delta > 0:
		# 正向非临时（PERMANENT 等）：填本身动力至上限
		mech.restore_own_power(delta)
	else:
		# 负向非 current_only：减本身动力
		var own2: int = mech.get_own_power()
		var new_own2: int = clampi(own2 + delta, 0, _get_max_power(mech_id))
		mech.power += (new_own2 - own2)

	# 记录数值修正
	var method := "add" if delta > 0 else "sub"
	SLog.log_stat_modify(
		context.game_state.current_attack_id,
		mech_id, "mech", "动力", delta, method,
		{"effect_id": &"MODIFY_MECH_POWER", "card_id": params.get("source_card_id", &""), "mech_id": mech_id}
	)

	context.effect_engine.fire_hook(&"ON_POWER_CHANGED", {
		"mech_id": mech_id,
		"delta": mech.power - before,
		"current_power": mech.power
	})
	context.game_state.write_log(&"power_changed", {
		"mech_id": String(mech_id),
		"delta": int(mech.power - before),
		"current_power": int(mech.power),
		"reason": String(params.get("reason", &"")),
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

	# 消耗动力优先扣减临时动力（temp_power），本身动力保留至回合末。
	mech.consume_power(amount)

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
	context.game_state.write_log(&"power_changed", {
		"mech_id": String(mech_id),
		"delta": -int(amount),
		"current_power": int(mech.power),
		"reason": String(params.get("reason", &"")),
	})

	return true


## 恢复动力
func restore_power(params: Dictionary) -> void:
	var mech_id: StringName = params.get("mech_id", params.get("source_mech_id", &""))
	if mech_id == &"" or not context.game_state.mechs.has(mech_id):
		push_error("RESTORE_POWER 找不到 mech_id")
		return

	var mech = context.game_state.mechs[mech_id]
	# CANNOT_RESTORE_POWER 状态：拦截回复（仅拦 method=restore，不拦临时+N 走 stat_modify）
	for _st in mech.statuses:
		if _st is Dictionary and _st.get("type", &"") == &"CANNOT_RESTORE_POWER":
			SLog.log_raw("[ACTION] %s 受 CANNOT_RESTORE_POWER 影响，无法回复动力" % String(mech_id))
			return
	var max_power := _get_max_power(mech_id)
	var before: int = mech.power

	var amount_value = params.get("amount", params.get("count", &"full"))
	if str(amount_value) == "full":
		# 回复本身动力至上限（保留 temp_power，不压回临时动力）
		mech.restore_own_power_to_full()
	else:
		mech.restore_own_power(int(amount_value))

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
	context.game_state.write_log(&"power_changed", {
		"mech_id": String(mech_id),
		"delta": int(restored),
		"current_power": int(mech.power),
		"reason": String(params.get("reason", &"")),
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
	if String(amount_value) == "full":
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

	# pilot_003 瑟尔基尔 effect_03：跳过正面牌。
	# 跳过行为对被勾选玩家都生效（is_pilot_003_skip_active）；
	# "抽牌数+1"仅当瑟尔基尔本人被勾选（is_pilot_003_self_skip_active，抽牌者=瑟尔基尔拥有者）。
	var p003_skip: bool = _ActionPilotEffects.is_pilot_003_skip_active(player_id)
	if _ActionPilotEffects.is_pilot_003_self_skip_active(player_id, context.game_state):
		count += 1

	for i in range(max(0, count)):
		var drawn_one: Array[StringName] = []
		if p003_skip and context.game_state != null:
			# 跳过正面牌：找牌堆中第一张非正面牌
			var p003_deck: Array = context.game_state.deck_state.action_deck
			var p003_found: int = -1
			for p003_i in range(p003_deck.size()):
				var p003_c = context.game_state.get_card(p003_deck[p003_i])
				if p003_c == null or not bool(p003_c.counters.get("face_up_in_deck", false)):
					p003_found = p003_i
					break
			if p003_found >= 0:
				drawn_one = [p003_deck[p003_found]]
				p003_deck.remove_at(p003_found)
			else:
				drawn_one = []
		elif context.deck_service != null:
			drawn_one = context.deck_service.draw_from_deck(&"action_deck", 1)
		if drawn_one.is_empty():
			continue
		var card_id: StringName = drawn_one[0]

		drawn.append(card_id)

		# 将抽到的行动牌加入玩家手牌（draw_from_deck 仅更新 zone，不维护手牌数组）
		if player_state != null and not player_state.action_hand.has(card_id):
			player_state.action_hand.append(card_id)
		# 标记归属玩家（条件检查/离场效果依赖 owner_player_id）
		var _dac = context.game_state.get_card(card_id)
		if _dac:
			_dac.owner_player_id = player_id
		# 注册 AVAILABILITY 效果（迎击牌等的响应窗口监听器）；
		# 否则被攻击时响应窗口不会弹出
		if context.has_method("register_hand_card_availability"):
			context.register_hand_card_availability(card_id)

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
	if not drawn.is_empty():
		context.game_state.write_log(&"cards_drawn", {
			"player_id": String(player_id),
			"card_kind": "action",
			"card_ids": drawn.map(func(c): return String(c)),
			"count": drawn.size(),
			"reason": String(reason),
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
		# 标记归属玩家
		var _dec = context.game_state.get_card(card_id)
		if _dec:
			_dec.owner_player_id = player_id

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
	if not drawn.is_empty():
		context.game_state.write_log(&"cards_drawn", {
			"player_id": String(player_id),
			"card_kind": "equipment",
			"card_ids": drawn.map(func(c): return String(c)),
			"count": drawn.size(),
			"reason": String(reason),
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
	context.game_state.write_log(&"card_gained", {
		"player_id": String(player_id),
		"card_id": String(instance.instance_id),
		"from_zone": String(params.get("from_zone", &"")),
		"reason": String(params.get("reason", &"")),
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

	if context != null and context.rng != null:
		context.synced_shuffle(pool)
	else:
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
	var old_gold: int = player_state.gold
	player_state.gold += amount

	# 记录数值修正
	SLog.log_stat_modify(
		context.game_state.current_attack_id,
		player_id, "mech", "金币", amount, "add",
		{"effect_id": &"GAIN_GOLD", "card_id": params.get("source_card_id", &""), "player_id": player_id}
	)

	context.effect_engine.fire_hook(&"ON_GOLD_GAINED", {
		"player_id": player_id,
		"amount": amount,
		"reason": params.get("reason", &"")
	})
	context.game_state.write_log(&"gold_gained", {
		"player_id": String(player_id),
		"amount": amount,
		"current_gold": int(player_state.gold),
		"reason": String(params.get("reason", &"")),
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

	var old_gold: int = player_state.gold
	player_state.gold -= amount

	# 记录数值修正
	SLog.log_stat_modify(
		context.game_state.current_attack_id,
		player_id, "mech", "金币", amount, "sub",
		{"effect_id": &"SPEND_GOLD", "card_id": params.get("source_card_id", &""), "player_id": player_id,
		 "old_gold": old_gold, "new_gold": player_state.gold}
	)

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
## 商店购买修饰符（已废弃：折扣统一改用 mech DISCOUNT 状态，见 GeneratedActionEffects.discount_direct）
## 保留为 noop 以兼容旧调用点，不再写 player.statuses SHOP_BUY_MODIFIER
func shop_buy_modifier(params: Dictionary) -> void:
	pass


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
	var old_hp: int = mech.current_hp
	mech.current_hp -= amount

	# 记录动作结果
	SLog.log_action_result(
		params.get("source_attack_id", context.game_state.current_attack_id),
		"deal_damage", "damage",
		{"target_id": target_id, "amount": amount, "old_hp": old_hp, "new_hp": mech.current_hp,
		 "source": params.get("source_card_id", &""), "damage_type": params.get("damage_type", &"effect")}
	)

	context.effect_engine.fire_hook(&"ON_DAMAGE_DEALT", {
		"target_id": target_id,
		"amount": amount,
		"current_hp": mech.current_hp,
		"source_attack_id": params.get("source_attack_id", &""),
		"source_card_id": params.get("source_card_id", &""),
		"damage_type": params.get("damage_type", &"effect")
	})
	context.game_state.write_log(&"damage_dealt", {
		"mech_id": String(target_id),
		"amount": int(amount),
		"current_hp": int(mech.current_hp),
		"source_card_id": String(params.get("source_card_id", &"")),
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
		# 放置日志已由 GameState.place_one_damage_token 统一记录（guard flag），
		# 此处不再重复追加，避免双计。

		context.effect_engine.fire_hook(&"ON_AFTER_DAMAGE_TOKEN_PLACED", {
			"target_id": target_id,
			"slot_id": slot_id,
			"chooser_player_id": chooser_player_id,
			"source_attack_id": params.get("source_attack_id", &"")
		})
		context.game_state.write_log(&"damage_token_placed", {
			"mech_id": String(target_id),
			"slot_id": String(slot_id),
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
		# 损伤变化后重算动力上限（effect_016/021/048 派生动力随损伤变）
		mech.recalc_power_limits()
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
	# 损伤变化后重算动力上限（effect_016/021/048 派生动力随损伤变）
	mech.recalc_power_limits()


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

	# 记录动作结果
	SLog.log_action_result(
		context.game_state.current_attack_id,
		"heal_hp", "heal",
		{"mech_id": mech_id, "amount": healed, "old_hp": before, "new_hp": mech.current_hp,
		 "source": params.get("source_card_id", &"")}
	)

	context.effect_engine.fire_hook(&"ON_HP_HEALED", {
		"mech_id": mech_id,
		"amount": healed,
		"current_hp": mech.current_hp
	})
	context.game_state.write_log(&"hp_healed", {
		"mech_id": String(mech_id),
		"amount": int(healed),
		"current_hp": int(mech.current_hp),
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
	var gs = context.game_state
	var map_state = gs.map_state

	# trigger：直接触发指定标记（效果由 MarkerService 执行，含爆炸/连锁）
	if mode == &"trigger":
		var marker_id: StringName = params.get("marker_id", &"")
		var trig_mech_id: StringName = params.get("mech_id", params.get("source_mech_id", &""))
		if marker_id != &"" and context.marker_service != null:
			for marker in map_state.markers:
				if marker.get("marker_id", &"") == marker_id:
					map_state.remove_marker(marker_id)
					context.marker_service.trigger_marker(trig_mech_id, marker)
					break
		return

	# place / place_each：在指定格子放置陷阱标记
	var cell_id: StringName = params.get("cell_id", &"")
	var cell_ids: Array = []
	if mode == &"place_each":
		cell_ids = params.get("cell_ids", [])
		if cell_ids.is_empty() and cell_id != &"":
			cell_ids = [cell_id]
	else:
		if cell_id != &"":
			cell_ids = [cell_id]
	for cid in cell_ids:
		var cid_sn: StringName = StringName(String(cid))
		if cid_sn == &"" or not map_state.cells.has(cid_sn):
			continue
		var parts := String(cid_sn).split(",")
		var q := int(parts[0])
		var r := int(parts[1])
		var new_marker_id: StringName = gs.next_id(&"marker")
		map_state.add_marker(new_marker_id, q, r, &"TRAP")
		gs.write_log(&"marker_trap_placed", {"cell_id": String(cid_sn), "marker_id": String(new_marker_id)})


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
		if target_id == &"":
			target_id = _resolve_attack_field_from_payload(params, &"target_id")
		var target_player = context.game_state.get_player_for_mech(target_id)
		if target_player:
			player_id = target_player.player_id

	if bool(params.get("from_attacker", false)):
		var attacker_id: StringName = params.get("attacker_id", &"")
		if attacker_id == &"":
			attacker_id = _resolve_attack_field_from_payload(params, &"attacker_id")
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
	# owner_id（机甲）解析：effect_123 传 owner_id=$binding_context.mech_id，反查玩家。
	if player_id == &"":
		var owner_mech_id: StringName = params.get("owner_id", &"")
		if owner_mech_id != &"" and context.game_state != null:
			var owner_player = context.game_state.get_player_for_mech(owner_mech_id)
			if owner_player != null:
				player_id = owner_player.player_id
	if bool(params.get("from_target", false)):
		var target_id: StringName = params.get("target_id", &"")
		if target_id == &"":
			target_id = _resolve_attack_field_from_payload(params, &"target_id")
		var target_player = context.game_state.get_player_for_mech(target_id)
		if target_player:
			player_id = target_player.player_id
	if bool(params.get("from_attacker", false)):
		var attacker_id: StringName = params.get("attacker_id", &"")
		if attacker_id == &"":
			attacker_id = _resolve_attack_field_from_payload(params, &"attacker_id")
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

	# 随机选择要弃置的牌（走 context.rng 同步随机，锁步双端一致）
	var indices: Array[int] = []
	for i in range(player_state.action_hand.size()):
		indices.append(i)
	if context != null and context.rng != null:
		context.synced_shuffle(indices)
	else:
		indices.shuffle()

	var cards_to_discard: Array[StringName] = []
	for i in range(min(count, indices.size())):
		cards_to_discard.append(player_state.action_hand[indices[i]])

	# 设置临时标记供条件检查（弃置后是否为最后一张行动牌）
	if is_last_before_discard:
		context.game_state.temp_values["is_last_action_card_in_hand"] = true
	# 写回父攻击动作的 attack 作用域变量（effect_124 读 VARIABLE_ABOVE(scope=attack, weapon_028_was_last)）
	var rdc_atk_id: StringName = params.get("parent_attack_id", &"")
	if rdc_atk_id != &"" and context.action_registry != null:
		var rdc_atk = context.action_registry.get_action(rdc_atk_id)
		if rdc_atk != null and rdc_atk.record is Dictionary:
			if not rdc_atk.record.has("variables"):
				rdc_atk.record["variables"] = {}
			rdc_atk.record["variables"]["weapon_028_was_last"] = 1 if is_last_before_discard else 0

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

	# 联合状态去重：同一Target同一unite机甲最多1个联合状态（规范）。
	# 已存在同 unite 的联合状态则不重复施加（避免重复监听/重复弹窗）。
	if String(status.get("type", &"")) == "UNITE":
		var dedup_unite: StringName = status.get("unite", &"")
		if dedup_unite != &"" and context.game_state != null:
			var dedup_mech = context.game_state.mechs.get(target_id)
			if dedup_mech != null:
				for s_dedup: Dictionary in dedup_mech.statuses:
					if s_dedup.get("type", &"") == &"UNITE" and String(s_dedup.get("unite", &"")) == String(dedup_unite):
						return  # 已存在同unite的联合状态，不重复施加

	if not status.has("status_id"):
		status["status_id"] = context.game_state.next_id(&"status")
	if not status.has("source_card_id"):
		status["source_card_id"] = params.get("source_card_id", &"")
	if not status.has("source_player_id"):
		status["source_player_id"] = params.get("source_player_id", params.get("player_id", &""))

	# 设陷状态可叠加：已存在则累加层数（复用既有状态对象与其回合末清除监听器，不新建）
	if String(status.get("type", &"")) == &"SET_TRAP":
		var _st_mech = context.game_state.mechs.get(target_id)
		if _st_mech != null:
			var _st_existing = _st_mech.get_status(&"SET_TRAP")
			if not _st_existing.is_empty():
				_st_existing["stacks"] = int(_st_existing.get("stacks", 1)) + int(status.get("stacks", 1))
				context.game_state.write_log(&"status_added", {
					"target_id": String(target_id),
					"status_type": "SET_TRAP",
					"delta": int(status.get("stacks", 1)),
					"source_card_id": String(status.get("source_card_id", &"")),
				})
				return

	context.game_state.add_status_to_target(target_id, status)

	context.effect_engine.fire_hook(&"ON_STATUS_ADDED", {
		"target_id": target_id,
		"status": status
	})
	context.game_state.write_log(&"status_added", {
		"target_id": String(target_id),
		"status_type": String(status.get("type", &"")),
		"delta": int(status.get("delta", 0)),
		"source_card_id": String(status.get("source_card_id", &"")),
	})

	# 注册状态效果监听器：按 status type 取对应 LISTEN 效果，注册为临时监听器，
	# 绑定到 status_id，并携带 binding_context（target_id/weapon_id/source_player_id 等），
	# 供 ConditionChecker 在 fire_timing 时精确匹配（如聚能只对该武器触发、锁定只对该攻击者触发）。
	_register_status_listeners(target_id, status)


## 为单个状态对象注册其对应的 LISTEN 效果监听器
func _register_status_listeners(target_id: StringName, status: Dictionary) -> void:
	if context == null or context.timing_engine == null:
		return
	var status_type: StringName = status.get("type", &"")
	var status_id: StringName = status.get("status_id", &"")
	if status_type == &"" or status_id == &"":
		return

	var effect_ids: Array = GeneratedActionEffects.get_effects_for_status(status_type)
	if effect_ids.is_empty():
		return

	var all_effects: Dictionary = GeneratedActionEffects.build_all_effects()

	# 绑定上下文：状态效果触发时需要知道是哪个机甲/武器/来源玩家的状态
	var binding_context: Dictionary = {
		"target_id": target_id,
		"status_id": status_id,
		"status_type": status_type,
		"source_player_id": status.get("source_player_id", &""),
		"source_card_id": status.get("source_card_id", &""),
	}
	# 聚能状态绑定到具体武器
	if status.has("weapon_id"):
		binding_context["weapon_id"] = status["weapon_id"]
	# 联合状态绑定 unite 机甲（出牌者=机甲1），供 UNITE_ATTACKER_IS_UNITE_MECH 判断
	# "unite机甲为发动攻击的机甲"时触发联合攻击弹窗。
	if status.has("unite"):
		binding_context["unite"] = status["unite"]

	for effect_id: StringName in effect_ids:
		var effect: ActionEffect = all_effects.get(effect_id)
		if effect == null:
			continue
		if effect.listen_timing == &"":
			continue
		context.timing_engine.register_status_listener(
			effect.listen_timing, effect, status_id, binding_context
		)


## 移除状态对象关联的所有监听器
func _unregister_status_listeners(status: Dictionary) -> void:
	if context == null or context.timing_engine == null:
		return
	var status_id: StringName = status.get("status_id", &"")
	if status_id != &"":
		context.timing_engine.unregister_listeners_for_status(status_id)


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
		# 注销该状态关联的所有监听器，确保状态效果不再触发
		_unregister_status_listeners(status)
		# 拘束钩爪 effect_104：LOCKED 状态被移除时（持有者命中解除 / 弃置解除），
		# 清除施加该锁定的武器 card.lock_target_mech_id 缓存，使本牌恢复可攻击。
		if String(status.get("type", &"")) == "LOCKED":
			_clear_weapon_lock_for_status(status)
		context.effect_engine.fire_hook(&"ON_STATUS_REMOVED", {
			"target_id": target_id,
			"status": status
		})


## 拘束钩爪 effect_104：清除施加某 LOCKED 状态的武器的 lock_target_mech_id 缓存。
## status.source_card_id = 施锁武器实例；清除后本牌恢复可攻击（WEAPON_IS_LOCKED_OUT 校验状态存活）。
func _clear_weapon_lock_for_status(status: Dictionary) -> void:
	if context == null or context.game_state == null:
		return
	var src_card_id: StringName = status.get("source_card_id", &"")
	if src_card_id == &"":
		return
	var wcard = context.game_state.get_card(src_card_id)
	if wcard != null and "lock_target_mech_id" in wcard:
		wcard.lock_target_mech_id = &""


## 拘束钩爪 effect_104：本牌弃置/替换（离开机甲区域）时，移除其施加的 LOCKED 状态并清缓存。
## 锁定持续到持有者下次命中或本牌离场；离场时立即解除，符合「此牌弃置则其施加的效果也解除」。
func remove_locked_status_by_source_card(src_card_id: StringName) -> void:
	if src_card_id == &"" or context == null or context.game_state == null:
		return
	var wcard = context.game_state.get_card(src_card_id)
	if wcard == null or not ("lock_target_mech_id" in wcard):
		return
	var lock_tgt: StringName = wcard.lock_target_mech_id
	if lock_tgt != &"" and context.game_state.mechs.has(lock_tgt):
		var mech = context.game_state.mechs[lock_tgt]
		if mech != null:
			var to_remove: Array = []
			for s in mech.statuses:
				if String(s.get("type", &"")) == "LOCKED" and String(s.get("source_card_id", &"")) == String(src_card_id):
					to_remove.append(s)
			for s in to_remove:
				mech.statuses.erase(s)
				_unregister_status_listeners(s)
				context.effect_engine.fire_hook(&"ON_STATUS_REMOVED", {"target_id": lock_tgt, "status": s})
	wcard.lock_target_mech_id = &""


## 减少状态持续时间，到期自动移除
## 若提供 status_id，只 tick 该具体状态（锁定等多 locker 场景，各状态独立结算）；
## 否则按 status_type tick 该机甲所有同类状态（折扣/联合等保留原行为）。
func decrement_status_duration(params: Dictionary) -> void:
	var mech_id: StringName = params.get("mech_id", params.get("target_id", &""))
	var status_type: StringName = params.get("status_type", &"")
	var status_id: StringName = params.get("status_id", &"")

	if mech_id == &"" or status_type == &"":
		push_error("DECREMENT_STATUS_DURATION 缺少 mech_id / status_type")
		return

	var mech = context.game_state.mechs.get(mech_id)
	if mech == null:
		return

	var removed: Array = []
	if status_id != &"":
		# 精确 tick 单个状态（按 status_id 定位）
		for i: int in range(mech.statuses.size()):
			var s: Dictionary = mech.statuses[i]
			if s.get("status_id", &"") != status_id:
				continue
			if s.get("type", &"") != status_type:
				continue
			var duration: int = int(s.get("duration", 0))
			if duration > 0:
				duration -= 1
				if duration <= 0:
					removed.append(s)
					mech.statuses.remove_at(i)
				else:
					s["duration"] = duration
			break
	else:
		# tick_status_duration 返回因 duration 归 0 被移除的状态对象列表（含 status_id）
		removed = mech.tick_status_duration(status_type)

	for status in removed:
		# 注销到期状态关联的所有监听器
		_unregister_status_listeners(status)
		context.effect_engine.fire_hook(&"ON_STATUS_REMOVED", {
			"target_id": mech_id,
			"status_type": status_type,
			"status": status,
			"reason": &"DURATION_EXPIRED"
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

	var mech = context.game_state.mechs.get(mech_id)
	if mech == null:
		return
	for existing: Dictionary in mech.statuses:
		if existing.get("type", &"") == &"ENERGY_CHARGE" and existing.get("weapon_id", &"") == weapon_id:
			existing["stacks"] = int(existing.get("stacks", 1)) + 1
			return

	var status := {
		"status_id": params.get("status_id", context.game_state.next_id(&"status")),
		"type": &"ENERGY_CHARGE",
		"weapon_id": weapon_id,
		"stacks": 1,
		"delta": delta,
		"duration": params.get("duration", &"THIS_TURN"),
		"source_card_id": params.get("source_card_id", &"")
	}
	mech.statuses.append(status)
	_register_status_listeners(mech_id, status)

	context.effect_engine.fire_hook(&"ON_ENERGY_APPLIED_TO_WEAPON", {
		"mech_id": mech_id,
		"weapon_id": weapon_id,
		"delta": delta,
		"status": status
	})


## 从 payload.attack_action_id 解析攻击动作 record 的字段（attacker_id / target_id）
## 新攻击流程不写 game_state.current_attack_id / attacks，攻击信息只在攻击动作 record 里。
## 旧路径（current_attack_id / attacks）保留作兼容退路。
func _resolve_attack_field_from_payload(params: Dictionary, field: StringName) -> StringName:
	var attack_action_id: StringName = params.get("attack_action_id", &"")
	if attack_action_id != &"" and context != null and context.action_registry != null:
		var atk = context.action_registry.get_action(attack_action_id)
		if atk != null and atk.record is Dictionary:
			var v: StringName = atk.record.get(field, &"")
			if v != &"":
				return v
	if context != null and context.game_state != null and context.game_state.current_attack_id != &"":
		var atk2: Dictionary = context.game_state.attacks.get(context.game_state.current_attack_id, {})
		return atk2.get(field, &"")
	return &""


## 从对手手牌偷取行动牌
func steal_action_card(params: Dictionary) -> void:
	var from_player_id: StringName = params.get("from_player_id", &"")
	var to_player_id: StringName = params.get("to_player_id", params.get("player_id", &""))
	var count: int = int(params.get("count", 1))
	var discard: bool = bool(params.get("discard", false))

	if from_player_id == &"" and bool(params.get("from_target", false)):
		var target_id: StringName = params.get("target_id", &"")
		if target_id == &"":
			target_id = _resolve_attack_field_from_payload(params, &"target_id")
		var target_player = context.game_state.get_player_for_mech(target_id)
		if target_player:
			from_player_id = target_player.player_id
	if from_player_id == &"" and bool(params.get("from_attacker", false)):
		var attacker_id: StringName = params.get("attacker_id", &"")
		if attacker_id == &"":
			attacker_id = _resolve_attack_field_from_payload(params, &"attacker_id")
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


## 掷骰子（走 context.rng 同步随机，锁步双端一致）
func roll_d6(params: Dictionary) -> int:
	var result: int = context.synced_randi_range(1, 6) if context != null and context.rng != null else randi_range(1, 6)
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
func toggle_aura_target(params: Dictionary, payload: Dictionary = {}) -> void:
	var target_id: StringName = payload.get("target_id", &"")
	if target_id == &"":
		var _ptid = params.get("target_id", params.get("target_mech_id", &""))
		if _ptid != &"" and not String(_ptid).begins_with("$"):
			target_id = _ptid
	var aura_id: StringName = payload.get("binding_context", {}).get("card_instance_id", &"")
	if aura_id == &"":
		var _psc = params.get("aura_id", params.get("source_card_id", &""))
		if _psc != &"" and not String(_psc).begins_with("$"):
			aura_id = _psc
	var enabled: bool = bool(params.get("enabled", true))

	if target_id == &"" or aura_id == &"":
		push_error("TOGGLE_AURA_TARGET 缺少 target_id / aura_id")
		return

	var toggle_mode: StringName = params.get("toggle", &"")
	if toggle_mode == &"toggle":
		# pilot_005 肯特 / pilot_002 莱比尔 新 aura：切换 ActionPilotEffects 状态（取消/恢复）
		_ActionPilotEffects.toggle_aura_target(aura_id, target_id)
	elif enabled:
		context.game_state.enable_aura_for_target(aura_id, target_id)
	else:
		context.game_state.disable_aura_for_target(aura_id, target_id)

	context.effect_engine.fire_hook(&"ON_AURA_TARGET_CHANGED", {
		"target_id": target_id,
		"aura_id": aura_id,
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
	# pilot_010 刻托：持久互换行动牌上限与回合攻击数（orientation 持久到下次互换/换机师）。
	# 互换 action_card_limit <-> attack_limit（max_attacks_per_turn 跟随 attack_limit）。
	# 旧实现用 mech.attack_limit_this_turn（MechState 无此字段，latent bug）+ THIS_TURN 回合末恢复 +
	# 自动抽到上限，不符合裁定（持久 orientation / 抽上限+1 / 剩余攻击数=新上限）。
	var old_hand: int = player.action_card_limit
	var old_attack: int = player.attack_limit
	player.action_card_limit = old_attack
	player.attack_limit = old_hand
	mech.max_attacks_per_turn = old_hand
	# 互换后本回合剩余攻击数 = 新攻击上限（重置已用攻击数）
	mech.attack_count_this_turn = 0
	# 互换后抽 新行动牌上限 + 1（裁定："抽互换后的当前行动牌上限+1"）
	var draw_count: int = player.action_card_limit + 1
	draw_action_cards({"player_id": player_id, "count": draw_count, "reason": &"pilot_010_after_swap"})
	context.effect_engine.fire_hook(&"ON_STATUS_ADDED", {
		"player_id": player_id,
		"mech_id": mech_id,
		"status_type": &"swap_hand_limit_and_attack_count",
		"old_limit": old_hand,
		"old_attack": old_attack,
	})


## pilot_010 刻托 effect_02：按攻击牌使用序号替换为强袭/闪击/预判的 effect 链。
## 设 parent_action(use_action_card) record["as_card_def_id"] 让 _step_execute_effects 用具名牌 effect 链；
## named_type 供 USED_NAMED_TYPE_IS 识别；计数+1（裁定：牌进临时区即计数，use_action 取消也计）。
## 序列：第1张->强袭，第2张->闪击，第3张->预判；第4张由 effect_03 在 validate 拦截。
func replace_used_action_effect_by_sequence(params: Dictionary, payload: Dictionary, parent_action) -> void:
	if parent_action == null or context == null or context.game_state == null:
		return
	var pilot_instance: StringName = payload.get("binding_context", {}).get("card_instance_id", &"")
	if pilot_instance == &"":
		# 兼容测试直传 params.source_card_id（effect 触发时 $binding_context 已在 payload）
		var _psc = params.get("source_card_id", &"")
		if _psc != &"" and not String(_psc).begins_with("$"):
			pilot_instance = _psc
	if pilot_instance == &"":
		return
	var pilot_card = context.game_state.get_card(pilot_instance)
	if pilot_card == null:
		return
	var turn: int = int(context.game_state.turn_number)
	var key := "pilot_010_uses_%d" % turn
	var uses: int = int(pilot_card.counters.get(key, 0)) if "counters" in pilot_card else 0
	var new_count: int = uses + 1
	# 序列：1->强袭, 2->闪击, 3->预判
	var sequence := {1: &"action_002_强袭", 2: &"action_006_闪击", 3: &"action_007_预判"}
	var named_id: StringName = sequence.get(new_count, &"")
	if named_id == &"":
		return  # 第4张不该到这（effect_03 在 validate 拦截）
	parent_action.record["as_card_def_id"] = named_id
	parent_action.record["named_type"] = named_id
	if not "counters" in pilot_card:
		pilot_card.counters = {}
	pilot_card.counters[key] = new_count
	SLog.log_raw("[pilot_010] 刻托第%d张攻击牌视为 %s" % [new_count, String(named_id)])


## pilot_004 玛沙 effect_02：清除本机师实例建立的 runtime_tag 临时 modifier（ARMOR_MODIFIER + POWER_CAP_MODIFIER）。
## 按 source_card_id + runtime_tags 过滤清除；清后重算 max_power 并钳制 current power。
func clear_source_stat_modifiers(params: Dictionary) -> void:
	var mech_id: StringName = params.get("mech_id", params.get("target_mech_id", &""))
	if mech_id == &"" or not context.game_state.mechs.has(mech_id):
		return
	var mech = context.game_state.mechs[mech_id]
	var source_card_id: StringName = params.get("source_card_id", &"")
	var tags: Array = params.get("runtime_tags", [])
	mech.statuses = mech.statuses.filter(func(s: Dictionary) -> bool:
		var stype: StringName = s.get("type", &"")
		if stype != &"ARMOR_MODIFIER" and stype != &"POWER_CAP_MODIFIER":
			return true
		if source_card_id != &"" and String(s.get("source_card_id", &"")) != String(source_card_id):
			return true
		if not tags.is_empty():
			var stag: StringName = s.get("runtime_tag", &"")
			var matched := false
			for t in tags:
				if String(t) == String(stag):
					matched = true
					break
			if not matched:
				return true
		return false  # 清除
	)
	# 重算 max_power + 钳制 current power（转换层清除后 current 不超新上限，保留 temp_power）
	mech.max_power = mech.get_total_power()
	var own: int = mech.get_own_power()
	var new_own: int = clampi(own, 0, mech.max_power)
	mech.power = new_own + mech.temp_power
	SLog.log_raw("[pilot_004] 清除转换层，max_power=%d power=%d" % [mech.max_power, mech.power])


## pilot_004 玛沙 effect_03：改 attack record 防御值来源（动力代护甲）。
## stat_source=&"current_power" -> attack_action._step_calculate_damage 用 target.power 代替 armor。
func set_attack_defense_stat_source(params: Dictionary, payload: Dictionary, parent_action) -> void:
	if parent_action == null:
		return
	var target_id: StringName = payload.get("target_id", &"")
	if target_id == &"":
		# 兼容测试直传 params.target_id
		var _ptid = params.get("target_id", &"")
		if _ptid != &"" and not String(_ptid).begins_with("$"):
			target_id = _ptid
	var stat_source: StringName = params.get("stat_source", &"current_power")
	if target_id == &"":
		return
	if not parent_action.record.has("defense_stat_override"):
		parent_action.record["defense_stat_override"] = {}
	parent_action.record["defense_stat_override"][target_id] = stat_source


## pilot_005 肯特 effect_01 授予能力：弃置对侧参与方2张行动牌（不足2弃全部，裁定歧义1）。
## 对侧 = 非本机甲的攻击参与方（攻击方->目标 / 目标->攻击方）。
## 简化：弃前 count 张（裁定要效果拥有者选，后续加 chooser UI）。
func pilot_005_discard_opposing(params: Dictionary, payload: Dictionary, parent_action) -> void:
	var bind_ctx: Dictionary = payload.get("binding_context", {})
	var source_mech: StringName = bind_ctx.get("mech_id", &"")
	var attacker_id: StringName = payload.get("attacker_id", &"")
	var target_id: StringName = payload.get("target_id", &"")
	var opposing: StringName = &""
	if source_mech == attacker_id:
		opposing = target_id
	elif source_mech == target_id:
		opposing = attacker_id
	if opposing == &"":
		return
	var opposing_player = context.game_state.get_player_for_mech(opposing)
	if opposing_player == null:
		return
	var count: int = mini(2, opposing_player.action_hand.size())
	if count <= 0:
		return
	for i in range(count):
		if opposing_player.action_hand.is_empty():
			break
		var cid: StringName = opposing_player.action_hand[0]
		opposing_player.action_hand.remove_at(0)
		var c = context.game_state.get_card(cid)
		if c != null:
			c.zone = &"discard"
		context.game_state.deck_state.action_discard_pile.append(cid)
	SLog.log_raw("[pilot_005] 帝国压制弃 %s %d 张" % [String(opposing), count])


## pilot_008 安德洛美达 effect_01a/01b：回收弃牌堆的维修入手牌 + X+1（max5）。
## X 绑 card_instance_id（换机师不转移）。裁定：回收具体那张维修（非生成新）。
func pilot_008_recover_repair(params: Dictionary, payload: Dictionary) -> void:
	var bind_ctx: Dictionary = payload.get("binding_context", {})
	var player_id: StringName = bind_ctx.get("player_id", &"")
	var pilot_card_id: StringName = bind_ctx.get("card_instance_id", &"")
	if player_id == &"" or context.game_state == null:
		return
	var player = context.game_state.players.get(player_id)
	if player == null:
		return
	var repair_cid: StringName = &""
	for i in range(context.game_state.deck_state.action_discard_pile.size()):
		var cid: StringName = context.game_state.deck_state.action_discard_pile[i]
		var c = context.game_state.get_card(cid)
		if c != null and c.def != null and String(c.def.card_id) == "action_013_维修":
			repair_cid = cid
			context.game_state.deck_state.action_discard_pile.remove_at(i)
			break
	if repair_cid == &"":
		return
	player.action_hand.append(repair_cid)
	var rc = context.game_state.get_card(repair_cid)
	if rc != null:
		rc.zone = &"action_hand"
		rc.owner_player_id = player_id
	if pilot_card_id != &"":
		var pilot_card = context.game_state.get_card(pilot_card_id)
		if pilot_card != null:
			if not "counters" in pilot_card:
				pilot_card.counters = {}
			var cur_x: int = int(pilot_card.counters.get("var_X", 0))
			pilot_card.counters["var_X"] = mini(cur_x + 1, 5)
	SLog.log_raw("[pilot_008] 回收维修 X+1")


## pilot_006 effect_01：设置本轮悬赏目标（标记到 source_pilot_instance）。
## 每轮 ROUND_START 选1台其他机甲，替换上一轮标记。
func set_round_marked_target(params: Dictionary, payload: Dictionary) -> void:
	var bind_ctx: Dictionary = payload.get("binding_context", {})
	var source_pilot: StringName = bind_ctx.get("card_instance_id", &"")
	var target_mech: StringName = payload.get("target_id", payload.get("target_mech_id", &""))
	if source_pilot == &"" or target_mech == &"":
		return
	_ActionPilotEffects.set_pilot_006_mark(source_pilot, target_mech, 0)


## pilot_006 effect_02：攻击方抽1张行动牌，若为攻击牌挂 passive_attack_bonus 标记（不立即用）。
## 裁定（歧义1）：抽到攻击牌不立即使用，只挂增益（不计回合攻击数，持续到离手）。
func draw_action_and_tag_if_attack(params: Dictionary, payload: Dictionary) -> void:
	var bind_ctx: Dictionary = payload.get("binding_context", {})
	var drawer_mech: StringName = payload.get("attacker_id", bind_ctx.get("mech_id", &""))
	if drawer_mech == &"" or context.game_state == null:
		return
	var player = context.game_state.get_player_for_mech(drawer_mech)
	if player == null:
		return
	if context.game_state.deck_state.action_deck.is_empty():
		return
	var cid: StringName = context.game_state.deck_state.action_deck[0]
	context.game_state.deck_state.action_deck.remove_at(0)
	player.action_hand.append(cid)
	var c = context.game_state.get_card(cid)
	if c != null:
		c.zone = &"action_hand"
		c.owner_player_id = player.player_id
	_ActionPilotEffects.pilot_006_tag_if_attack(c)
	SLog.log_raw("[pilot_006] 悬赏追击抽1，攻击牌=%s" % str(c != null and c.def != null and String(c.def.action_type) == "攻击"))


## pilot_007 effect_01：夺取攻击来源牌到我方手牌（改归属 + claimed 标记阻止原 use_action 弃置）。
## 裁定：当作转化/飞弹不触发（需实体攻击牌）；攻击未命中仍可夺；夺后可立即使用（EXECUTE_USE_ACTION_CARD）。
func claim_resolved_attack_source_card(params: Dictionary, payload: Dictionary) -> void:
	var bind_ctx: Dictionary = payload.get("binding_context", {})
	var new_owner: StringName = bind_ctx.get("player_id", &"")
	var attack_card_id: StringName = payload.get("attack_card_id", payload.get("card_instance_id", &""))
	if attack_card_id == &"" or new_owner == &"" or context.game_state == null:
		return
	var card = context.game_state.get_card(attack_card_id)
	if card == null:
		return
	var player = context.game_state.players.get(new_owner)
	if player == null:
		return
	card.owner_player_id = new_owner
	card.zone = &"action_hand"
	if not "counters" in card:
		card.counters = {}
	card.counters["claimed_by_pilot_007"] = true
	player.action_hand.append(attack_card_id)
	SLog.log_raw("[pilot_007] 夺取攻击牌 %s" % String(attack_card_id))


## pilot_009 effect_01：授予临时卡牌控制（非排他，到回合结束，换下立即解）。
## 裁定（歧义1/3/5）：双方可用先用者得；持续光环到回合结束；美杜莎换下立即解除。
func grant_temp_card_control(params: Dictionary, payload: Dictionary) -> void:
	var bind_ctx: Dictionary = payload.get("binding_context", {})
	var controller: StringName = bind_ctx.get("player_id", &"")
	var source_pilot: StringName = bind_ctx.get("card_instance_id", &"")
	var target_mech: StringName = payload.get("target_id", payload.get("target_mech_id", &""))
	var card_type: StringName = params.get("card_type", payload.get("card_type", &""))
	if controller == &"" or target_mech == &"" or card_type == &"" or String(card_type).begins_with("$"):
		return
	_ActionPilotEffects.grant_temp_card_control(target_mech, card_type, controller, source_pilot)
	SLog.log_raw("[pilot_009] 控制目标 %s 的 %s 牌（controller=%s）" % [String(target_mech), String(card_type), String(controller)])


## pilot_009 effect_01：立即弃置目标当前全部该类型受控牌（裁定：全弃，不可选部分，0张弃0）。
## 持续光环保留：控制到回合结束，目标后续再获同类型牌仍受控、美杜莎本回合仍可使用。
## 仿 pilot_005_discard_opposing 直接操作 state（不走 discard_card_action 时点，简化）。
func pilot_009_discard_all_controlled_type(params: Dictionary, payload: Dictionary) -> void:
	var target_mech: StringName = payload.get("target_id", payload.get("target_mech_id", &""))
	var card_type: StringName = params.get("card_type", payload.get("card_type", &""))
	if target_mech == &"" or card_type == &"" or String(card_type).begins_with("$"):
		return
	var target_player = context.game_state.get_player_for_mech(target_mech)
	if target_player == null:
		return
	var to_discard: Array = []
	for cid in target_player.action_hand:
		var c = context.game_state.get_card(cid)
		if c != null and c.def != null and String(c.def.action_type) == String(card_type):
			to_discard.append(cid)
	for cid in to_discard:
		target_player.action_hand.erase(cid)
		var c = context.game_state.get_card(cid)
		if c != null:
			c.zone = &"discard"
			c.slot_id = &""
			c.mech_id = &""
		context.game_state.deck_state.action_discard_pile.append(cid)
		context.game_state.write_log(&"card_discarded", {"card_id": String(cid), "reason": "pilot_009_immediate_discard"})
	SLog.log_raw("[pilot_009] 立即弃置目标 %s 全部 %s 牌 %d 张" % [String(target_mech), String(card_type), to_discard.size()])


## pilot_007 珀修斯 effect_02 类型破绽：对本次攻击的每个目标分别结算--
## peek 目标手牌 -> 算缺类型数 X(3-目标手牌中 攻击/迎击/辅助 的去重类型数) ->
## 弃目标 min(X+1, 手牌) 张（不足弃全部剩余）-> 珀修斯抽 X+1（X 决定抽牌数，与实际弃置量无关）。
## 裁定：多目标全部结算（每目标独立）；不足 X+1 弃全部剩余仍抽 X+1。
## peek 暂 write_log 记录（UI peek 弹窗后续补）；弃牌暂系统弃前N（choose 弃牌 UI 后续补）。
func pilot_007_type_flaw(params: Dictionary, payload: Dictionary) -> void:
	var attacker_mech: StringName = payload.get("attacker_id", &"")
	if attacker_mech == &"" or context.game_state == null:
		return
	var attacker_player = context.game_state.get_player_for_mech(attacker_mech)
	if attacker_player == null:
		return
	# 收集本次攻击的全部目标（单目标 target_id + 双连等多目标 target_ids）
	var targets: Array = []
	var _tid: StringName = payload.get("target_id", &"")
	if _tid != &"":
		targets.append(_tid)
	for t in payload.get("target_ids", []):
		if t != &"" and not targets.has(t):
			targets.append(t)
	if targets.is_empty():
		return
	for target_mech in targets:
		var tm: StringName = target_mech
		var target_player = context.game_state.get_player_for_mech(tm)
		if target_player == null:
			continue
		# 算 X = 3 - distinct(目标手牌中 攻击/迎击/辅助 类型数)
		var present: Dictionary = {}
		for cid in target_player.action_hand:
			var c = context.game_state.get_card(cid)
			if c != null and c.def != null:
				var tname: String = String(c.def.action_type)
				if tname in ["攻击", "迎击", "辅助"]:
					present[tname] = true
		var x: int = 3 - present.size()
		var draw_count: int = x + 1   # 抽牌数固定 X+1
		var discard_count: int = x + 1  # 弃牌数 X+1，不足弃全部剩余
		# peek 记录（UI peek 弹窗后续补）
		context.game_state.write_log(&"pilot_007_peek", {"target_mech": String(tm), "present": present.keys(), "missing_x": x})
		# 弃 min(discard_count, 目标手牌) 张（系统弃前N；choose 弃牌 UI 后续补）
		var actual_discard: int = mini(discard_count, target_player.action_hand.size())
		for i in range(actual_discard):
			if target_player.action_hand.is_empty():
				break
			var cid: StringName = target_player.action_hand[0]
			target_player.action_hand.remove_at(0)
			var c = context.game_state.get_card(cid)
			if c != null:
				c.zone = &"discard"
				c.slot_id = &""
				c.mech_id = &""
			context.game_state.deck_state.action_discard_pile.append(cid)
			context.game_state.write_log(&"card_discarded", {"card_id": String(cid), "reason": "pilot_007_missing_type_punish"})
		# 抽 X+1（固定，X 决定抽牌数）
		for i in range(draw_count):
			if context.game_state.deck_state.action_deck.is_empty():
				break
			var cid: StringName = context.game_state.deck_state.action_deck[0]
			context.game_state.deck_state.action_deck.remove_at(0)
			attacker_player.action_hand.append(cid)
			var c = context.game_state.get_card(cid)
			if c != null:
				c.zone = &"action_hand"
				c.owner_player_id = attacker_player.player_id
		SLog.log_raw("[pilot_007] 类型破绽：目标 %s X=%d 弃%d 抽%d" % [String(tm), x, actual_discard, draw_count])


## pilot_006 e3 战后逼迫4伤害（选项2/回落）：直接减 HP 4，不走 DEAL_DAMAGE 的 fire_hook，
## 避免在 ATTACK_SETTLE 挂起链中嵌套 legacy hook 触发内存问题。裁定：回落4伤害是直接伤害。
func pilot_006_deal_4_damage(params: Dictionary) -> void:
	var target_mech: StringName = params.get("mech_id", params.get("target_id", &""))
	if target_mech == &"" or context.game_state == null:
		return
	var mech = context.game_state.mechs.get(target_mech)
	if mech == null:
		return
	mech.current_hp -= 4
	context.game_state.write_log(&"damage_dealt", {"mech_id": String(target_mech), "amount": 4, "current_hp": int(mech.current_hp), "reason": "pilot_006_refused_attack"})
	if mech.current_hp <= 0:
		destroy_mech({"mech_id": target_mech, "source": "damage"})
	SLog.log_raw("[pilot_006] 战后逼迫4伤害 -> %s HP=%d" % [String(target_mech), mech.current_hp])


## pilot_002 effect_01：登记批次转化权限（接收者获一次性"当作具名牌使用"权限）。
## 裁定：交牌不进临时区直接给目标手牌（TRANSFER_ACTION_CARDS 已转）；离场后权限清除。
## 本 atomic 仅登记权限 + 标记批次牌；批次使用（virtual_transform）由 pilot_002_batch_use effect 触发。
func pilot_002_grant_transfer_batch(params: Dictionary, payload: Dictionary) -> void:
	var bind_ctx: Dictionary = payload.get("binding_context", {})
	var grant_source: StringName = bind_ctx.get("card_instance_id", &"")
	var target_mech: StringName = params.get("target_mech_id", payload.get("target_id", payload.get("target_mech_id", &"")))
	# batch_card_ids / named_type 可能是 $runtime.xxx 表达式，由调用前 _resolve_atomic_value 解析；
	# 若仍是 $ 字符串则从 payload runtime key 取
	var card_ids_raw = params.get("batch_card_ids", payload.get("pilot_002_transfer_batch", []))
	var card_ids: Array = card_ids_raw if card_ids_raw is Array else []
	var named_type: StringName = params.get("named_type", &"进攻")
	if String(named_type).begins_with("$"):
		named_type = &"进攻"
	if grant_source == &"" or target_mech == &"" or card_ids.is_empty():
		return
	var batch_id: String = "pilot002:%s:%s" % [String(grant_source), String(payload.get("action_id", &""))]
	_ActionPilotEffects.register_pilot_002_batch(batch_id, target_mech, card_ids, named_type, grant_source)
	# 存储 batch_id 到 payload 供后续 PILOT_002_USE_BATCH_AS_NAMED（防御链内立即使用）读取
	payload["pilot_002_current_batch_id"] = batch_id
	# 注册批次使用 listener 到目标（DIRECT 进攻 / AVAILABILITY 防御）
	if context.timing_engine != null:
		var all_eff: Dictionary = _ActionPilotEffects.build_pilot_effects()
		var bu_eff_id: StringName = &"pilot_002_batch_use_attack" if named_type == &"进攻" else &"pilot_002_batch_use_defense"
		var bu_effect = all_eff.get(bu_eff_id)
		if bu_effect != null:
			var target_player = context.game_state.get_player_for_mech(target_mech) if context.game_state != null else null
			var bu_ctx: Dictionary = {
				"card_instance_id": grant_source,
				"mech_id": target_mech,
				"player_id": target_player.player_id if target_player != null else &"",
				"slot_id": &"pilot",
				"card_def_id": &"pilot_002_莱比尔",
				"batch_id": batch_id,
			}
			var bu_timing: StringName = bu_eff_id if String(bu_effect.mode) == "DIRECT" else &"ATTACK_AT"
			context.timing_engine.register_permanent_listener(bu_timing, bu_effect, bu_ctx)
	SLog.log_raw("[pilot_002] 登记批次 %s：目标 %s %d张 当作%s" % [batch_id, String(target_mech), card_ids.size(), String(named_type)])


## pilot_002 批次使用：丢弃整批牌（代价）+ 标记批次已用。保留首张作为虚拟牌供 use_action_card。
## 返回保留的 card_instance_id（供 _extract_pilot_002_batch_use_params 设 card_instance_id）。
func pilot_002_discard_batch(params: Dictionary, payload: Dictionary) -> StringName:
	var bind_ctx: Dictionary = payload.get("binding_context", {})
	var batch_id: String = bind_ctx.get("batch_id", "")
	if batch_id == "":
		batch_id = String(payload.get("pilot_002_current_batch_id", ""))
	if batch_id == "" or context.game_state == null:
		return &""
	var batch: Dictionary = _ActionPilotEffects.get_pilot_002_batch(batch_id)
	if batch.is_empty():
		return &""
	var card_ids: Array = batch.get("card_ids", [])
	if card_ids.is_empty():
		return &""
	# 保留首张作为虚拟牌（供 use_action_card virtual_transform）
	var virtual_cid: StringName = card_ids[0]
	# 丢弃其余批次牌
	for i in range(1, card_ids.size()):
		var cid: StringName = card_ids[i]
		var target_player = context.game_state.get_player_for_mech(StringName(String(batch.get("target_mech", &""))))
		if target_player != null:
			target_player.action_hand.erase(cid)
		var c = context.game_state.get_card(cid)
		if c != null:
			c.zone = &"discard"
			c.slot_id = &""
			c.mech_id = &""
		context.game_state.deck_state.action_discard_pile.append(cid)
	# 标记批次已用
	_ActionPilotEffects.mark_pilot_002_batch_used(batch_id)
	SLog.log_raw("[pilot_002] 批次 %s 使用：丢弃%d张，保留虚拟牌 %s" % [batch_id, card_ids.size() - 1, String(virtual_cid)])
	return virtual_cid


## pilot_003 effect_03：切换瑟尔基尔拥有者"抽牌跳过正面牌"设置。
func toggle_pilot_003_skip(params: Dictionary, payload: Dictionary) -> void:
	var bind_ctx: Dictionary = payload.get("binding_context", {})
	var source_pilot: StringName = bind_ctx.get("card_instance_id", &"")
	var player_id: StringName = bind_ctx.get("player_id", &"")
	var enable: bool = bool(params.get("enable", true))
	if source_pilot == &"" or player_id == &"":
		return
	_ActionPilotEffects.toggle_pilot_003_skip(source_pilot, player_id, enable)
	SLog.log_raw("[pilot_003] 跳过正面牌 %s player=%s" % ["开启" if enable else "关闭", String(player_id)])


## pilot_003 effect_03 复选框提交：整组覆盖该瑟尔基尔来源的跳过玩家集合。
## player_ids 为 String 数组（空=全部不跳）。来自 need_input CHOOSE_MANY_PLAYERS resume。
func set_pilot_003_skip_players(params: Dictionary, payload: Dictionary) -> void:
	var bind_ctx: Dictionary = payload.get("binding_context", {})
	var source_pilot: StringName = bind_ctx.get("card_instance_id", &"")
	if source_pilot == &"":
		return
	var player_ids: Array = params.get("player_ids", [])
	_ActionPilotEffects.set_pilot_003_skip_players(source_pilot, player_ids)
	SLog.log_raw("[pilot_003] 复选框提交跳过玩家: %s" % str(player_ids))


## pilot_003 瑟尔基尔 effect_01：将手牌正面朝上随机插入行动牌堆。
## 每张牌标记 counters: face_up_in_deck/leave_deck_owner_mech/leave_deck_owner_pid/source_pilot/face_up_leave_use。
func pilot_003_insert_face_up_random(params: Dictionary, payload: Dictionary) -> void:
	var bind_ctx: Dictionary = payload.get("binding_context", {})
	var owner_mech: StringName = bind_ctx.get("mech_id", &"")
	var owner_pid: StringName = bind_ctx.get("player_id", &"")
	var source_pilot: StringName = bind_ctx.get("card_instance_id", &"")
	var card_ids: Array = params.get("card_ids", payload.get("pilot_003_face_up_cards", []))
	if card_ids.is_empty() or owner_pid == &"":
		return
	var player = context.game_state.players.get(owner_pid) if context.game_state != null else null
	if player == null:
		return
	var deck: Array = context.game_state.deck_state.action_deck
	for cid in card_ids:
		var card_id: StringName = cid
		player.action_hand.erase(card_id)
		var pos: int = deck.size()
		if not deck.is_empty() and context.rng != null:
			pos = int(context.rng.randf() * float(deck.size() + 1))
		deck.insert(pos, card_id)
		var c = context.game_state.get_card(card_id)
		if c != null:
			if not "counters" in c:
				c.counters = {}
			c.counters["face_up_in_deck"] = true
			c.counters["pilot_003_leave_deck_owner_mech"] = owner_mech
			c.counters["pilot_003_leave_deck_owner_pid"] = owner_pid
			c.counters["pilot_003_source_pilot"] = source_pilot
			c.counters["pilot_003_face_up_leave_use"] = true
			c.zone = &"action_deck"
	SLog.log_raw("[pilot_003] 插入 %d 张正面牌到行动牌堆" % card_ids.size())


## pilot_003 effect_01：将选中牌移到牌堆顶（保持正面）。
func pilot_003_move_to_deck_top(card_id: StringName) -> void:
	if card_id == &"" or context.game_state == null:
		return
	var deck: Array = context.game_state.deck_state.action_deck
	deck.erase(card_id)
	deck.insert(0, card_id)  # index 0 = top（draw_from_deck 取 [0]）


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

	# 委托 EquipmentBreakService.check_equipment_broken 走 discard_card 动作发 DISCARD_AFTER 时点，
	# 近战右腿（effect_031，只接受 reason=damage_durability）等离场效果此时点触发。
	# check_equipment_broken 内部已做：弃置（走动作）+ 清 slot + 重算动力。
	if context.equipment_break_service != null:
		context.equipment_break_service.check_equipment_broken(mech_id, slot_id)
		return

	# 退路：equipment_break_service 未就绪，走 legacy 同步弃置（不发时点）
	discard_card({
		"card_id": card.instance_id,
		"reason": &"EQUIPMENT_BROKEN"
	})
	slot_state.equipped_card = null

	# ── 重算动力上限并调整当前动力 ──
	var old_max_power: int = mech.max_power
	mech.max_power = mech.get_total_power()
	mech.sync_own_power_after_max_change(old_max_power)


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
	# 按规范放置：region + card 双计（与 DamageTokenService.place_one_token_at_slot / GameState.place_one_damage_token 一致）。
	# 损伤真正在区域上（装备弃置后仍保留），装备牌另记一份用于耐久损坏判定。
	# 原代码 `slot.damage_tokens` 误访问 MechSlotState 上不存在的属性（MechSlotState 用 region_damage_tokens，
	# 装备牌损伤在 equipped_card.damage_tokens），A6 损伤转移路径触发即报错。
	# place_one_damage_token 只放置不发 BEFORE hook（外层 _apply_redirect_plan 注释要求
	# 不走逐点 hook 避免再次触发转移），AFTER hook 在下方统一发一次。
	for _i in range(amount):
		context.game_state.place_one_damage_token(mech_id, slot_id)
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
func increment_variable(params: Dictionary, payload: Dictionary = {}) -> void:
	var variable_name: StringName = params.get("variable_name", &"default_counter")
	var delta: int = int(params.get("delta", 1))
	var max_value: int = int(params.get("max_value", -1))
	if context.game_state == null:
		return
	# pilot_008 X 绑 card_instance_id（换机师不转移）：source_card_instance_id 优先 params，回退 payload.binding_context
	var source_card_instance_id: StringName = params.get("source_card_instance_id", &"")
	if source_card_instance_id == &"" or String(source_card_instance_id).begins_with("$"):
		var bind_ctx: Dictionary = payload.get("binding_context", {})
		source_card_instance_id = bind_ctx.get("card_instance_id", &"")
	if source_card_instance_id != &"":
		var card = context.game_state.get_card(source_card_instance_id)
		if card == null:
			return
		if not "counters" in card:
			card.counters = {}
		var ckey := "var_" + String(variable_name)
		var current: int = int(card.counters.get(ckey, 0))
		var new_val: int = current + delta
		if max_value >= 0:
			new_val = mini(new_val, max_value)
		card.counters[ckey] = new_val
		return
	# 默认：game_state.variables
	var player_id: StringName = params.get("player_id", params.get("source_owner_player_id", &""))
	var mech_id: StringName = params.get("mech_id", params.get("source_mech_id", &""))
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
	var target_card_id: StringName = params.get("target_card_id", params.get("card_instance_id", &""))
	var duration: String = String(params.get("duration", "THIS_TURN"))
	if target_card_id == &"":
		push_error("NEGATE_EQUIPMENT_EFFECT 缺少 target_card_id")
		return
	# 将目标装备牌标记为"效果无效"（保留护甲/动力/耐久等牌面 stats，仅压制效果）
	var card = context.game_state.get_card(target_card_id)
	if card == null:
		return
	card.effect_negated = true  # TurnService 回合结束统一清除（UNTIL_TURN_END 语义）


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
## mode=increase（默认）：累加 delta 到 might_modifiers（delta 可负，如 effect_112 每攻击-4）。
## mode=restore：回补本 bucket 的负修正，restore_delta = min(delta, -bucket_sum)（不超 0，即不超 printed_might）。
## bucket 区分来源（weapon_decay 等），使 restore 只回补本机制衰减，不清其他来源。
## duration: &"PERMANENT"(默认) / &"THIS_OWNER_TURN" / &"THIS_TURN"（TurnService 回合结束清除临时项）。
func modify_weapon_power(params: Dictionary) -> void:
	var weapon_id: StringName = params.get("weapon_id", params.get("target_weapon_id", params.get("target_card_instance_id", &"")))
	var delta: int = int(params.get("delta", 0))
	if weapon_id == &"":
		push_error("MODIFY_WEAPON_POWER 缺少 weapon_id")
		return
	var weapon = context.game_state.get_card(weapon_id)
	if weapon == null:
		return
	var mode: StringName = params.get("mode", &"increase")
	var bucket: String = String(params.get("bucket", "default"))
	var duration: StringName = params.get("duration", &"PERMANENT")
	if not "might_modifiers" in weapon:
		weapon.might_modifiers = []
	if mode == &"restore":
		# 计算本 bucket 当前累计（通常为负）
		var bucket_sum: int = 0
		for m in weapon.might_modifiers:
			if m is Dictionary and String(m.get("bucket", "default")) == bucket:
				bucket_sum += int(m.get("delta", 0))
		# 只回补到 0（不超 printed_might），回补量为正
		var restore_delta: int = max(0, min(delta, -bucket_sum)) if bucket_sum < 0 else 0
		if restore_delta > 0:
			weapon.might_modifiers.append({"delta": restore_delta, "duration": duration, "bucket": bucket, "source_card_id": params.get("source_card_id", &"")})
	else:
		weapon.might_modifiers.append({"delta": delta, "duration": duration, "bucket": bucket, "source_card_id": params.get("source_card_id", &"")})
	SLog.log_raw("[ACTION] modify_weapon_power %s %+d mode=%s bucket=%s" % [String(weapon_id), delta, String(mode), bucket])


## 设置武器属性为指定值
## 旧版绝对覆盖：might/range（>=0 写 might_override/range_override）。
## 新版相对修正（effect_093/095 聚能临时）：might_delta/range_delta + duration + stack。
## target_card_instance_id 指定本武器实例；stack=true（默认）叠加，false 则替换同 bucket 项。
func set_weapon_stats(params: Dictionary) -> void:
	var weapon_id: StringName = params.get("weapon_id", params.get("target_weapon_id", params.get("target_card_instance_id", &"")))
	if weapon_id == &"":
		push_error("SET_WEAPON_STATS 缺少 weapon_id")
		return
	var weapon = context.game_state.get_card(weapon_id)
	if weapon == null:
		return
	# 绝对覆盖（旧接口）
	var new_might: int = int(params.get("might", -1))
	var new_range: int = int(params.get("range", -1))
	if new_might >= 0:
		weapon.might_override = new_might
	if new_range >= 0:
		weapon.range_override = new_range
	# 相对修正（新接口：聚能临时 might_delta/range_delta）
	var might_delta: int = int(params.get("might_delta", 0))
	var range_delta: int = int(params.get("range_delta", 0))
	var duration: StringName = params.get("duration", &"PERMANENT")
	var stack: bool = bool(params.get("stack", true))
	var bucket: String = String(params.get("bucket", "energy_temp"))
	if might_delta != 0:
		if not "might_modifiers" in weapon:
			weapon.might_modifiers = []
		if not stack:
			weapon.might_modifiers = weapon.might_modifiers.filter(func(m): return not (m is Dictionary and String(m.get("bucket", "")) == bucket))
		weapon.might_modifiers.append({"delta": might_delta, "duration": duration, "bucket": bucket, "source_card_id": params.get("source_card_id", &"")})
	if range_delta != 0:
		if not "range_modifiers" in weapon:
			weapon.range_modifiers = []
		if not stack:
			weapon.range_modifiers = weapon.range_modifiers.filter(func(m): return not (m is Dictionary and String(m.get("bucket", "")) == bucket))
		weapon.range_modifiers.append({"delta": range_delta, "duration": duration, "bucket": bucket, "source_card_id": params.get("source_card_id", &"")})
	SLog.log_raw("[ACTION] set_weapon_stats %s might_delta=%d range_delta=%d dur=%s" % [String(weapon_id), might_delta, range_delta, String(duration)])


## 设置/清除武器冷却（effect_125/126/129）
## clear=true：清除冷却（聚能后允许再攻）。否则设置冷却：counters["cooldown_active"]=true，
## cooldown_until_turn = 当前 turn_number + 2（1v1 轮换下到达下个我方回合），TurnService 在
## 我方回合 TURN_AFTER_END 且 turn_number >= cooldown_until_turn 时清除。
func set_weapon_cooldown(params: Dictionary) -> void:
	var weapon_id: StringName = params.get("weapon_id", params.get("target_card_instance_id", &""))
	if weapon_id == &"":
		push_error("SET_WEAPON_COOLDOWN 缺少 weapon_id")
		return
	var weapon = context.game_state.get_card(weapon_id)
	if weapon == null:
		return
	if not "counters" in weapon:
		weapon.counters = {}
	if bool(params.get("clear", false)):
		weapon.counters["cooldown_active"] = false
		weapon.cooldown_until_turn = -1
		SLog.log_raw("[ACTION] SET_WEAPON_COOLDOWN clear %s" % String(weapon_id))
	else:
		weapon.counters["cooldown_active"] = true
		var cur_turn: int = int(context.game_state.turn_number) if context.game_state != null else 0
		weapon.cooldown_until_turn = cur_turn + 2  # 下个我方回合（1v1 轮换）
		SLog.log_raw("[ACTION] SET_WEAPON_COOLDOWN set %s until_turn=%d" % [String(weapon_id), weapon.cooldown_until_turn])


## 质能全转换剑炮（effect_138）主动触发：快照当前护甲×2/动力写入 card.counters
## 威力变为机甲当前护甲数值*2，范围变为当前动力数值。算完保留，不随后续机甲数值改变而改变
##（除非再次使用此效果）。get_effective_weapon_stats 以 conversion_might/range 为基数替代牌面1/1。
func set_weapon_conversion(params: Dictionary) -> void:
	var weapon_id: StringName = params.get("weapon_instance_id", params.get("target_card_instance_id", &""))
	var mech_id: StringName = params.get("mech_id", params.get("source_mech_id", &""))
	if weapon_id == &"" or mech_id == &"" or not context.game_state.mechs.has(mech_id):
		push_error("SET_WEAPON_CONVERSION 缺少 weapon_id/mech_id")
		return
	var weapon = context.game_state.get_card(weapon_id)
	if weapon == null:
		return
	var mech = context.game_state.mechs[mech_id]
	if not "counters" in weapon:
		weapon.counters = {}
	var conv_might: int = max(0, int(mech.get_armor()) * 2)
	var conv_range: int = max(0, int(mech.power))
	weapon.counters["conversion_might"] = conv_might
	weapon.counters["conversion_range"] = conv_range
	context.game_state.write_log(&"weapon_conversion", {
		"weapon_id": String(weapon_id),
		"mech_id": String(mech_id),
		"conversion_might": conv_might,
		"conversion_range": conv_range,
	})
	SLog.log_raw("[ACTION] SET_WEAPON_CONVERSION %s might=%d(armor*2) range=%d(power)" % [String(weapon_id), conv_might, conv_range])


## 弃置机甲所有正面朝上的部件装备牌（effect_140 质能全转换剑炮攻击结算后代价）
## 按 slot_kinds 顺序（头->躯干->右臂->左臂->右腿->左腿）串行弃置，每张走标准 discard_card
## 生命周期（发 ON_CARD_DISCARDED->DISCARD_AFTER，触发离场效果）。preserve_slot_damage 保留区域损伤。
func discard_all_face_up_parts(params: Dictionary, payload: Dictionary = {}) -> void:
	var mech_id: StringName = params.get("target_mech_id", params.get("mech_id", &""))
	if mech_id == &"" or not context.game_state.mechs.has(mech_id):
		push_error("DISCARD_ALL_FACE_UP_PARTS 缺少 mech_id")
		return
	var mech = context.game_state.mechs[mech_id]
	var slot_kinds: Array = params.get("slot_kinds", [&"HEAD", &"TORSO", &"RIGHT_ARM", &"LEFT_ARM", &"RIGHT_LEG", &"LEFT_LEG"])
	var reason: StringName = params.get("reason", &"weapon_040_conversion_cost")
	# 建立 slot_id -> slot_kind 映射，按给定 slot_kinds 顺序遍历
	for sid in mech.slots:
		var slot = mech.slots[sid]
		if slot == null:
			continue
		var kind: StringName = slot.slot_kind if "slot_kind" in slot else &""
		if not (String(kind) in slot_kinds.map(func(k): return String(k))):
			continue
		var card = slot.get("equipped_card")
		if card == null or card.def == null:
			continue
		if card.def.card_kind != &"equipment":
			continue
		if card.get("equipment_kind") != &"PART":
			continue
		if card.get("face_down") == true:
			continue
		# 弃置该部件牌（discard_card 内部清 slot.equipped_card + 注销监听器 + 重算动力）
		discard_card({"card_id": card.instance_id, "reason": reason})
	SLog.log_raw("[ACTION] DISCARD_ALL_FACE_UP_PARTS %s slot_kinds=%s" % [String(mech_id), str(slot_kinds)])


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
	var weapon = context.game_state.get_card(weapon_id)
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


## 觉醒抽牌：检查弃牌堆中是否有预判/识破，有则直接获得，无则从弃牌堆+牌堆各取1张
func awaken_draw(params: Dictionary) -> void:
	var player_id: StringName = params.get("player_id", &"")
	if player_id == &"":
		push_error("AWAKEN_DRAW 缺少 player_id")
		return

	var player = context.game_state.players.get(player_id)
	var deck_state = context.game_state.deck_state
	if player == null or deck_state == null:
		return

	var cards_to_gain: Array[StringName] = []

	# Round 1: Check if 预判 (predict) exists in action discard
	var predict_in_discard: bool = false
	for card_id: StringName in deck_state.action_discard_pile:
		var card = context.game_state.cards.get(card_id)
		if card and card.def and String(card.def.card_id).find("predict") >= 0:
			predict_in_discard = true
			cards_to_gain.append(card_id)
			deck_state.action_discard_pile.erase(card_id)
			break

	if not predict_in_discard:
		# Player chooses a card type from discard, take 1 from discard + 1 from top of deck
		# Simplified: take the first action card from discard
		if deck_state.action_discard_pile.size() > 0:
			cards_to_gain.append(deck_state.action_discard_pile[0])
			deck_state.action_discard_pile.erase(deck_state.action_discard_pile[0])
		# + top of action deck
		if deck_state.action_deck.size() > 0:
			cards_to_gain.append(deck_state.action_deck.pop_front() as StringName)

	# Round 2: Check if 识破 (expose) exists in action discard
	var expose_in_discard: bool = false
	for card_id: StringName in deck_state.action_discard_pile:
		var card = context.game_state.cards.get(card_id)
		if card and card.def and String(card.def.card_id).find("expose") >= 0:
			expose_in_discard = true
			cards_to_gain.append(card_id)
			deck_state.action_discard_pile.erase(card_id)
			break

	if not expose_in_discard:
		if deck_state.action_discard_pile.size() > 0:
			cards_to_gain.append(deck_state.action_discard_pile[0])
			deck_state.action_discard_pile.erase(deck_state.action_discard_pile[0])
		if deck_state.action_deck.size() > 0:
			cards_to_gain.append(deck_state.action_deck.pop_front() as StringName)

	# Add all gained cards to player's hand
	for card_id: StringName in cards_to_gain:
		var card = context.game_state.cards.get(card_id)
		if card != null:
			card.owner_player_id = player_id
			card.zone = &"action_hand"
		player.action_hand.append(card_id)

		context.effect_engine.fire_hook(&"ON_CARD_GAINED", {
			"player_id": player_id,
			"card_id": card_id,
			"from_zone": &"awaken_draw",
			"reason": &"AWAKEN_DRAW"
		})


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
