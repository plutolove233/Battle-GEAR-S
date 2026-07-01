## CostChecker.gd — 效果费用检查与支付
##
## CostChecker 负责在效果触发前检查和支付费用。
## 每个费用是一个字典 { cost_type: StringName, ... }，cost_type 决定支付逻辑。
## 先 can_pay_all 检查全部费用是否可支付，再 pay_all 一次性支付。
## 当前实现的费用类型：
##   DISCARD_ACTION_CARD, SPEND_POWER, SPEND_GOLD,
##   SPEND_ATTACK_CHANCE, TAKE_SELF_DAMAGE, DISCARD_EQUIPMENT_CARD,
##   SPEND_ALL_POWER, SPEND_VARIABLE_GOLD, DISCARD_VARIABLE_ACTION_CARDS
extends RefCounted
class_name CostChecker

## Preloaded references for cross-file custom types
const _EffectBinding = preload("res://scripts/effect_core/EffectBinding.gd")
const _GameContext = preload("res://scripts/runtime/GameContext.gd")


## 检查所有费用是否可支付
static func can_pay_all(binding, payload: Dictionary, costs: Array[Dictionary], ctx) -> bool:
	if costs.is_empty():
		return true
	for cost in costs:
		if not can_pay_single(binding, payload, cost, ctx):
			return false
	return true


## 支付所有费用（调用前应先 can_pay_all 确认可支付）
static func pay_all(binding, payload: Dictionary, costs: Array[Dictionary], ctx) -> void:
	for cost in costs:
		pay_single(binding, payload, cost, ctx)


## 检查单个费用是否可支付
static func can_pay_single(binding, payload: Dictionary, cost: Dictionary, ctx) -> bool:
	if ctx == null or ctx.game_state == null:
		return false
	var cost_type: StringName = cost.get("cost_type", &"")
	match cost_type:
		&"DISCARD_ACTION_CARD":
			# 弃置行动牌：检查手牌中是否有足够的行动牌
			var player_id: StringName = cost.get("player_id", binding.get_owner_player_id())
			var count: int = int(cost.get("count", 1))
			var card_type_filter: StringName = cost.get("card_type_filter", &"")
			var player_state = ctx.game_state.players.get(player_id)
			if player_state == null:
				return false
			if card_type_filter == &"":
				return player_state.action_hand.size() >= count
			# 有 card_type_filter 时，只计算匹配类型的牌
			var matching_count: int = 0
			for card_id: StringName in player_state.action_hand:
				var card = ctx.game_state.cards.get(card_id)
				if card and card.def and card.def.action_type == card_type_filter:
					matching_count += 1
			return matching_count >= count

		&"SPEND_POWER":
			# 支付动力：检查机甲当前动力是否足够
			var mech_id: StringName = cost.get("mech_id", binding.get_source_mech_id())
			var amount: int = int(cost.get("amount", 0))
			var mech_state = ctx.game_state.mechs.get(mech_id)
			if mech_state == null:
				return false
			return mech_state.power >= amount

		&"SPEND_GOLD":
			# 支付金币：检查玩家当前金币是否足够
			var player_id: StringName = cost.get("player_id", binding.get_owner_player_id())
			var amount: int = int(cost.get("amount", 0))
			var player_state = ctx.game_state.players.get(player_id)
			if player_state == null:
				return false
			return player_state.gold >= amount

		&"SPEND_ATTACK_CHANCE":
			var mech_id: StringName = cost.get("mech_id", binding.get_source_mech_id())
			var mech_state = ctx.game_state.mechs.get(mech_id)
			if mech_state == null:
				return false
			return mech_state.can_attack()

		&"TAKE_SELF_DAMAGE":
			return true  # 总是可以对自己造成伤害

		&"DISCARD_EQUIPMENT_CARD":
			var player_id: StringName = cost.get("player_id", binding.get_owner_player_id())
			var count: int = int(cost.get("count", 1))
			var player_state = ctx.game_state.players.get(player_id)
			if player_state == null:
				return false
			return player_state.equipment_hand.size() >= count

		&"SPEND_ALL_POWER":
			# 消耗当前所有动力（动力不为0即可支付）
			var mech_id: StringName = cost.get("mech_id", binding.get_source_mech_id())
			var mech_state = ctx.game_state.mechs.get(mech_id)
			if mech_state == null:
				return false
			return mech_state.power > 0

		&"SPEND_VARIABLE_GOLD":
			# 消耗 2*n 金币（n 由玩家选择，至少为1）
			var player_id: StringName = cost.get("player_id", binding.get_owner_player_id())
			var n: int = int(payload.get("variable_gold_n", 1))
			var amount: int = 2 * n
			var player_state = ctx.game_state.players.get(player_id)
			if player_state == null:
				return false
			return player_state.gold >= amount

		&"DISCARD_VARIABLE_ACTION_CARDS":
			# 弃置任意张行动牌（至少1张，手牌不为空即可）
			var player_id: StringName = cost.get("player_id", binding.get_owner_player_id())
			var player_state = ctx.game_state.players.get(player_id)
			if player_state == null:
				return false
			return player_state.action_hand.size() > 0

		_:
			push_warning("CostChecker: 未知费用类型 %s，默认可支付" % cost_type)
			return true


## 支付单个费用
static func pay_single(binding, payload: Dictionary, cost: Dictionary, ctx) -> bool:
	if ctx == null or ctx.game_state == null:
		return false
	var cost_type: StringName = cost.get("cost_type", &"")
	match cost_type:
		&"DISCARD_ACTION_CARD":
			# 弃置行动牌
			var player_id: StringName = cost.get("player_id", binding.get_owner_player_id())
			var count: int = int(cost.get("count", 1))
			var card_type_filter: StringName = cost.get("card_type_filter", &"")
			if ctx.game_actions == null:
				return false

			# 优先使用玩家选择的牌ID列表
			var selected_ids: Array = payload.get("selected_action_card_ids", [])
			if selected_ids.size() >= count:
				for i in range(count):
					ctx.game_actions.discard_action_card({
						"player_id": player_id,
						"card_id": selected_ids[i],
						"reason": &"EFFECT_COST"
					})
				return true

			# 回退：自动选择前 N 张匹配的牌
			var player_state = ctx.game_state.players.get(player_id)
			if player_state == null:
				return false
			var discarded: int = 0
			# 先尝试使用 payload 中的单张选择
			if payload.has("selected_action_card_id"):
				var card_id: StringName = payload["selected_action_card_id"]
				if card_id != &"":
					ctx.game_actions.discard_action_card({
						"player_id": player_id,
						"card_id": card_id,
						"reason": &"EFFECT_COST"
					})
					discarded += 1
			# 再尝试使用 cost 中的指定牌
			if discarded < count and cost.has("card_id"):
				var card_id: StringName = cost["card_id"]
				if card_id != &"":
					ctx.game_actions.discard_action_card({
						"player_id": player_id,
						"card_id": card_id,
						"reason": &"EFFECT_COST"
					})
					discarded += 1
			# 剩余的从手牌中自动选取匹配的牌
			if discarded < count:
				var hand_copy: Array[StringName] = player_state.action_hand.duplicate()
				for card_id: StringName in hand_copy:
					if discarded >= count:
						break
					if card_type_filter != &"":
						var card = ctx.game_state.cards.get(card_id)
						if card == null or card.def == null or card.def.action_type != card_type_filter:
							continue
					ctx.game_actions.discard_action_card({
						"player_id": player_id,
						"card_id": card_id,
						"reason": &"EFFECT_COST"
					})
					discarded += 1
			return discarded >= count

		&"SPEND_POWER":
			# 支付动力
			var mech_id: StringName = cost.get("mech_id", binding.get_source_mech_id())
			var amount: int = int(cost.get("amount", 0))
			if ctx.game_actions == null:
				return false
			return ctx.game_actions.spend_power({
				"mech_id": mech_id,
				"amount": amount,
				"reason": &"EFFECT_COST"
			})

		&"SPEND_GOLD":
			# 支付金币
			var player_id: StringName = cost.get("player_id", binding.get_owner_player_id())
			var amount: int = int(cost.get("amount", 0))
			if ctx.game_actions == null:
				return false
			return ctx.game_actions.spend_gold({
				"player_id": player_id,
				"amount": amount,
				"reason": &"EFFECT_COST"
			})

		&"SPEND_ATTACK_CHANCE":
			var mech_id: StringName = cost.get("mech_id", binding.get_source_mech_id())
			var mech_state = ctx.game_state.mechs.get(mech_id)
			if mech_state == null:
				return false
			mech_state.attack_count_this_turn += 1
			return true

		&"TAKE_SELF_DAMAGE":
			var mech_id: StringName = cost.get("mech_id", binding.get_source_mech_id())
			var amount: int = int(cost.get("amount", 0))
			var mech_state = ctx.game_state.mechs.get(mech_id)
			if mech_state == null or ctx.game_actions == null:
				return false
			mech_state.current_hp = max(0, mech_state.current_hp - amount)
			if mech_state.current_hp <= 0:
				ctx.game_state.destroy_mech(mech_id, "effect_cost")
			return true

		&"DISCARD_EQUIPMENT_CARD":
			var player_id: StringName = cost.get("player_id", binding.get_owner_player_id())
			var count: int = int(cost.get("count", 1))
			var player_state = ctx.game_state.players.get(player_id)
			if player_state == null:
				return false
			for i in range(mini(count, player_state.equipment_hand.size())):
				var card_id: StringName = player_state.equipment_hand.pop_back()
				ctx.deck_service.discard_card(card_id, &"EFFECT_COST")
			return true

		&"SPEND_ALL_POWER":
			# 消耗当前所有动力
			var mech_id: StringName = cost.get("mech_id", binding.get_source_mech_id())
			var mech_state = ctx.game_state.mechs.get(mech_id)
			if mech_state == null or ctx.game_actions == null:
				return false
			var all_power: int = mech_state.power
			if all_power <= 0:
				return false
			return ctx.game_actions.spend_power({
				"mech_id": mech_id,
				"amount": all_power,
				"reason": &"EFFECT_COST"
			})

		&"SPEND_VARIABLE_GOLD":
			# 消耗 2*n 金币
			var player_id: StringName = cost.get("player_id", binding.get_owner_player_id())
			var n: int = int(payload.get("variable_gold_n", 1))
			var amount: int = 2 * n
			if ctx.game_actions == null:
				return false
			return ctx.game_actions.spend_gold({
				"player_id": player_id,
				"amount": amount,
				"reason": &"EFFECT_COST"
			})

		&"DISCARD_VARIABLE_ACTION_CARDS":
			# 弃置任意张行动牌（数量由 payload 指定）
			var player_id: StringName = cost.get("player_id", binding.get_owner_player_id())
			var count: int = int(payload.get("variable_discard_count", 1))
			if ctx.game_actions == null:
				return false
			var player_state = ctx.game_state.players.get(player_id)
			if player_state == null:
				return false
			var actual_count: int = mini(count, player_state.action_hand.size())
			for i in range(actual_count):
				var card_id: StringName = payload.get("selected_action_card_ids", [&""])[i] if payload.has("selected_action_card_ids") and i < payload.get("selected_action_card_ids", []).size() else &""
				if card_id != &"":
					ctx.game_actions.discard_action_card({
						"player_id": player_id,
						"card_id": card_id,
						"reason": &"EFFECT_COST"
					})
			return true

		_:
			push_warning("CostChecker: 未知费用类型 %s，跳过支付" % cost_type)
			return true


## 检查弃牌费用是否需要玩家选择弃置目标
## 返回空字典表示不需要选择，返回 {"needs": "discard_select", ...} 表示需要暂停等待玩家输入
static func needs_discard_select(binding, payload: Dictionary, costs: Array[Dictionary], ctx) -> Dictionary:
	for cost in costs:
		if cost.get("cost_type", &"") != &"DISCARD_ACTION_CARD":
			continue
		if cost.get("optional", false):
			continue  # 可选费用通过 pending action 机制处理
		var count: int = int(cost.get("count", 1))
		var player_id: StringName = cost.get("player_id", binding.get_owner_player_id())
		var card_type_filter: StringName = cost.get("card_type_filter", &"")

		# 如果 payload 中已提供选择的牌ID，则无需再选
		var selected_ids: Array = payload.get("selected_action_card_ids", [])
		if selected_ids.size() >= count:
			continue

		# 确定弃牌对象：自己则明牌，对手则暗牌
		var executor_player_id: StringName = binding.get_owner_player_id()
		var face_up: bool = (player_id == executor_player_id)
		# 如果对手手牌已明牌，也视为明牌
		if not face_up:
			var discard_player_state = ctx.game_state.players.get(player_id)
			if discard_player_state != null and discard_player_state.hand_revealed:
				face_up = true

		# 检查是否有足够的匹配牌
		var player_state = ctx.game_state.players.get(player_id)
		if player_state == null:
			continue
		var matching_count: int = 0
		for card_id: StringName in player_state.action_hand:
			if card_type_filter != &"":
				var card = ctx.game_state.cards.get(card_id)
				if card == null or card.def == null or card.def.action_type != card_type_filter:
					continue
			matching_count += 1
		if matching_count < count:
			continue  # 无法支付，后续 can_pay 检查会失败

		return {
			"needs": &"discard_select",
			"discard_player_id": player_id,
			"count": count,
			"face_up": face_up,
			"card_type_filter": card_type_filter,
		}

	return {}
