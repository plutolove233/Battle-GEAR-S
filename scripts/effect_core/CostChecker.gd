## CostChecker.gd — 效果费用检查与支付
##
## CostChecker 负责在效果触发前检查和支付费用。
## 每个费用是一个字典 { cost_type: StringName, ... }，cost_type 决定支付逻辑。
## 先 can_pay_all 检查全部费用是否可支付，再 pay_all 一次性支付。
## 当前实现的费用类型：
##   DISCARD_ACTION_CARD, SPEND_POWER, SPEND_GOLD,
##   SPEND_ATTACK_CHANCE, TAKE_SELF_DAMAGE, DISCARD_EQUIPMENT_CARD
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
			var player_state = ctx.game_state.players.get(player_id)
			if player_state == null:
				return false
			return player_state.action_hand.size() >= count

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
			if ctx.game_actions == null:
				return false
			# 选择并弃置行动牌
			for i in range(count):
				var card_id: StringName = &""
				# 优先使用指定牌ID，否则由玩家选择
				if cost.has("card_id"):
					card_id = cost["card_id"]
				elif payload.has("selected_action_card_id"):
					card_id = payload["selected_action_card_id"]
				if card_id != &"":
					ctx.game_actions.discard_action_card({
						"player_id": player_id,
						"card_id": card_id,
						"reason": &"EFFECT_COST"
					})
			return true

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

		_:
			push_warning("CostChecker: 未知费用类型 %s，跳过支付" % cost_type)
			return true
