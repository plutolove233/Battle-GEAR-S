## CardPlayService.gd — 行动牌打出服务
##
## 负责验证和执行行动牌的打出：
## 验证手牌/阶段 → 解析效果（辅助牌直接执行）→ 触发钩子 → 弃牌
##
## P1-2: 重构辅助牌打出流程：
## - 创建 support_effects_snapshot = card.def.effects.duplicate(true)
## - 从手牌移除、EffectRegistry注销
## - 注入来源信息到payload（player_id/mech_id），不修改卡牌实例
## - 遍历snapshot中所有效果，按hook + condition + target + cost解析
## - CHOOSE_ONE → 从payload读chosen_effect_id
## - 需要武器/目标选择 → 从payload读，若无则返回需要选择的状态
## - 暂保留_inline_support_fallback，待所有辅助牌通过效果系统测试后再移除
class_name CardPlayService
extends RefCounted

var context = null  # type: GameContext

const _EffectConst = preload("res://scripts/effect_core/EffectConst.gd")
const _EffectBinding = preload("res://scripts/effect_core/EffectBinding.gd")
const _AtomicActionResolver = preload("res://scripts/effect_core/AtomicActionResolver.gd")
const _ConditionChecker = preload("res://scripts/effect_core/ConditionChecker.gd")
const _TargetChecker = preload("res://scripts/effect_core/TargetChecker.gd")
const _CostChecker = preload("res://scripts/effect_core/CostChecker.gd")


## 打出行动牌
## 验证牌在手中且处于主阶段 → 辅助牌快照解析效果 → 触发钩子 → 弃牌
func play_action_card(player_id: StringName, card_id: StringName, payload: Dictionary = {}) -> Dictionary:
	var gs = context.game_state
	var player = gs.players.get(player_id)

	# ── 验证玩家存在 ──
	if player == null:
		return {"ok": false, "message": "玩家不存在: %s" % String(player_id)}

	# ── 验证牌在手牌中 ──
	if not player.action_hand.has(card_id):
		return {"ok": false, "message": "行动牌不在手牌中"}

	# ── 验证当前阶段为主阶段 ──
	if gs.phase != &"MAIN":
		return {"ok": false, "message": "当前阶段不能打出行动牌: %s" % String(gs.phase)}

	# ── 获取卡牌定义，判断行动类型 ──
	var card = gs.get_card(card_id)
	var action_type: StringName = &""
	if card and card.def:
		action_type = card.def.action_type

	# ── 辅助牌：使用快照解析效果 ──
	if action_type == &"辅助":
		var support_result = _resolve_support_effects_snapshot(player_id, card_id, payload)
		if not support_result.get("ok", true):
			# 需要玩家选择（武器/目标/CHOOSE_ONE），返回选择请求
			return support_result

	# ── 触发行动牌打出钩子 ──
	_fire_hook(_EffectConst.HOOK_CARD_PLAYED, {
		"player_id": player_id,
		"card_id": card_id,
		"card_kind": &"action",
		"action_type": action_type,
		"payload": payload,
	})

	# ── 弃掉该牌 ──
	player.action_hand.erase(card_id)
	# P0-7: 从 EffectRegistry 注销
	if context.effect_registry:
		context.effect_registry.unregister_card(card)
	context.deck_service.discard_card(card_id, &"played")

	gs.write_log(&"action_card_played", {
		"player_id": String(player_id),
		"card_id": String(card_id),
	})
	return {"ok": true, "card_id": card_id}


## ── 内部方法 ──


## 触发效果钩子
func _fire_hook(hook_name: StringName, payload: Dictionary = {}) -> void:
	if context.effect_engine:
		context.effect_engine.fire_hook(hook_name, payload)


## P1-2: 快照解析辅助牌效果
## 不修改卡牌实例的mech_id，改为在payload中注入来源信息
## 遍历snapshot中所有效果，按hook + condition + target + cost全链路解析
func _resolve_support_effects_snapshot(player_id: StringName, card_id: StringName, payload: Dictionary) -> Dictionary:
	var gs = context.game_state
	var card = gs.get_card(card_id)
	if card == null or card.def == null:
		return {"ok": true}

	# 获取机甲ID
	var mech_id: StringName = &""
	for mid in gs.mechs:
		var mech = gs.mechs[mid]
		if mech and mech.owner_player_id == player_id:
			mech_id = mid
			break

	if mech_id == &"":
		push_warning("CardPlayService: 找不到玩家的机甲")
		return {"ok": true}

	# P1-2: 创建效果快照（深拷贝）
	var support_effects_snapshot: Array = card.def.effects.duplicate(true)

	# 构造 payload，提供执行上下文（不修改卡牌实例）
	var resolve_payload := payload.duplicate(true)
	resolve_payload["player_id"] = player_id
	resolve_payload["source_instance_id"] = card_id
	resolve_payload["source_mech_id"] = mech_id
	resolve_payload["source_player_id"] = player_id
	resolve_payload["mech_id"] = mech_id
	resolve_payload["manual"] = true
	# 如果 payload 中有 target_mech_id，也映射为 target_id
	if payload.has("target_mech_id") and not resolve_payload.has("target_id"):
		resolve_payload["target_id"] = payload["target_mech_id"]

	var resolved_any: bool = false
	var needs_choice: bool = false

	for effect in support_effects_snapshot:
		if effect == null:
			continue
		if effect.actions.size() == 0:
			continue

		# P1-2: ConditionChecker检查
		if not _ConditionChecker.check_all(card, resolve_payload, effect.conditions):
			continue

		# P1-2: TargetChecker检查
		# CHOOSE_OWN_WEAPON → 需要武器选择
		# CHOOSE_ENEMY_MECH → 需要目标选择
		var needs_weapon: bool = false
		var needs_target: bool = false
		for rule: Dictionary in effect.target_rules:
			var rule_name: StringName = rule.get("rule", &"")
			if rule_name == &"CHOOSE_OWN_WEAPON":
				if not resolve_payload.has("selected_weapon_id") or resolve_payload.get("selected_weapon_id", &"") == &"":
					needs_weapon = true
			elif rule_name == &"CHOOSE_ENEMY_MECH" or rule_name == &"CHOOSE_ENEMY_MECH_IN_RANGE":
				if not resolve_payload.has("target_id") or resolve_payload.get("target_id", &"") == &"":
					needs_target = true

		if needs_weapon:
			return {"ok": false, "needs": "weapon_select", "card_id": card_id, "effect_id": effect.effect_id}
		if needs_target:
			return {"ok": false, "needs": "target_select", "card_id": card_id, "effect_id": effect.effect_id}

		if not _TargetChecker.check_all(card, resolve_payload, effect.target_rules):
			continue

		# P1-2: CostChecker检查
		if not _CostChecker.can_pay_all(card, resolve_payload, effect.costs, context):
			continue

		# 支付费用
		_CostChecker.pay_all(card, resolve_payload, effect.costs, context)

		# 执行每个action
		var binding = _EffectBinding.new(card, effect)
		for action: Dictionary in effect.actions:
			var action_type: StringName = action.get("type", &"")
			if action_type == &"CHOOSE_ONE":
				# CHOOSE_ONE：从 payload 中获取玩家选择的效果ID
				var chosen_effect_id: StringName = StringName(resolve_payload.get("chosen_effect_id", &""))
				if chosen_effect_id == &"":
					# 没有选择信息，返回需要选择的状态
					needs_choice = true
					continue
				# 从 CardDatabase 获取被选中的效果并执行其 actions
				if context.card_database:
					var chosen_effect = context.card_database.get_effect(chosen_effect_id)
					if chosen_effect and chosen_effect.actions:
						binding.effect = chosen_effect
						for chosen_action: Dictionary in chosen_effect.actions:
							_AtomicActionResolver.resolve(binding, resolve_payload, chosen_action, context)
						resolved_any = true
			else:
				_AtomicActionResolver.resolve(binding, resolve_payload, action, context)
				resolved_any = true

	# 如果需要选择但尚未完成选择，返回选择请求
	if needs_choice and not resolved_any:
		return {"ok": false, "needs": "choose_one", "card_id": card_id}

	# Fallback: 如果快照解析未执行任何效果，尝试从 effect_defs 查找
	if not resolved_any and context.card_database:
		var card_def_id: StringName = card.def.card_id
		var effect_ids_map = _get_effect_ids_for_card(card_def_id)
		for eid: StringName in effect_ids_map:
			var effect_def = context.card_database.get_effect(eid)
			if effect_def and effect_def.actions:
				var binding = _EffectBinding.new(card, effect_def)
				for action: Dictionary in effect_def.actions:
					_AtomicActionResolver.resolve(binding, resolve_payload, action, context)
				resolved_any = true

	# 最终 Fallback：内联硬编码逻辑（确保维修/推进即使效果定义缺失也能工作）
	if not resolved_any:
		var card_def_id: StringName = card.def.card_id
		_inline_support_fallback(card_def_id, player_id, mech_id)

	return {"ok": true}


## 获取行动牌的 effect_ids 列表
## 从 DataRegistry 的原始 JSON 数据中读取 effect_ids
func _get_effect_ids_for_card(card_def_id: StringName) -> Array[StringName]:
	var registry = context.registry
	if registry == null:
		return []
	# 尝试从行动牌数据中查找
	var raw: Dictionary = registry.action_cards.get(String(card_def_id), {}) if registry.has_method("action_cards") else {}
	if raw.is_empty():
		raw = registry.equipment_parts.get(String(card_def_id), {}) if registry.has_method("equipment_parts") else {}
	if raw.is_empty():
		raw = registry.equipment_weapons.get(String(card_def_id), {}) if registry.has_method("equipment_weapons") else {}
	if raw.is_empty():
		return []
	var ids = raw.get("effect_ids", [])
	var result: Array[StringName] = []
	for eid in ids:
		if eid != "" and eid != null:
			result.append(StringName(eid))
	return result


## 内联 fallback：直接执行维修/推进等辅助牌效果
## 暂保留，待所有辅助牌通过效果系统测试后再移除
func _inline_support_fallback(card_def_id: StringName, player_id: StringName, mech_id: StringName) -> void:
	var gs = context.game_state
	if mech_id == &"":
		return
	var mech = gs.mechs.get(mech_id)
	if mech == null:
		return

	match String(card_def_id):
		"action_013_维修":
			# 回复2点生命
			mech.current_hp = min(mech.max_hp, mech.current_hp + 2)
			gs.write_log(&"support_effect", {
				"effect": "repair_heal",
				"player_id": String(player_id),
				"amount": 2,
			})
		"action_015_推进":
			# 动力+5
			mech.power = clamp(mech.power + 5, 0, mech.max_power)
			gs.write_log(&"support_effect", {
				"effect": "thrust_power",
				"player_id": String(player_id),
				"delta": 5,
			})
