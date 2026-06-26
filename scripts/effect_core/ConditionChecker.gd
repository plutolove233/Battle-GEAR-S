## ConditionChecker.gd — 效果条件检查器
##
## ConditionChecker 负责检查效果触发的前置条件。
## 每个条件是一个字典 { op: StringName, ... }，op 决定检查逻辑。
## check_all 要求所有条件都满足才返回 true。
## 当前实现的条件操作符：
##   ALWAYS, SOURCE_OWNER_IS_ATTACKER, SOURCE_OWNER_IS_TARGET,
##   IS_OWNER_MAIN_PHASE, PAYLOAD_WEAPON_HAS_TAG,
##   HAS_ACTION_CARD_IN_HAND, PAYLOAD_CARD_HAS_TAG,
##   SOURCE_OWNER_HAS_STATUS, PAYLOAD_ATTACK_HIT, PAYLOAD_ATTACK_MISS,
##   TARGET_HAS_STATUS, MECH_HP_BELOW, EQUIPPED_WEAPON_KIND,
##   IS_FIRST_ATTACK_THIS_TURN, GOLD_ABOVE, HAS_EQUIPMENT_IN_SLOT,
##   MECH_HAS_DAMAGE_TOKENS
extends RefCounted
class_name ConditionChecker

## Preloaded references for cross-file custom types
const _EffectBinding = preload("res://scripts/effect_core/EffectBinding.gd")


## 检查所有条件是否满足
static func check_all(binding, payload: Dictionary, conditions: Array[Dictionary]) -> bool:
	if conditions.is_empty():
		return true
	for condition in conditions:
		if not check_single(binding, payload, condition):
			return false
	return true


## 检查单个条件
static func check_single(binding, payload: Dictionary, condition: Dictionary) -> bool:
	var op: StringName = condition.get("op", &"ALWAYS")
	match op:
		&"ALWAYS":
			return true

		&"SOURCE_OWNER_IS_ATTACKER":
			# 来源牌的拥有者是当前攻击的攻击方
			var owner_id: StringName = binding.get_owner_player_id()
			var attack: Dictionary = payload.get("attack", {})
			if attack.is_empty():
				return false
			return owner_id == attack.get("attacker_player_id", &"")

		&"SOURCE_OWNER_IS_TARGET":
			# 来源牌的拥有者是当前攻击的目标方
			var owner_id: StringName = binding.get_owner_player_id()
			var attack: Dictionary = payload.get("attack", {})
			if attack.is_empty():
				return false
			return owner_id == attack.get("target_player_id", &"")

		&"IS_OWNER_MAIN_PHASE":
			# 来源牌的拥有者处于主阶段
			# 需要通过 binding 获取 context，但 ConditionChecker 是静态的
			# 这里用 payload 中的 phase 信息判断
			var phase: StringName = payload.get("phase", &"")
			return phase == &"MAIN"

		&"PAYLOAD_WEAPON_HAS_TAG":
			# payload 中的武器牌拥有指定标签
			var weapon_id: StringName = payload.get("weapon_id", &"")
			var tag: StringName = condition.get("tag", &"")
			if weapon_id == &"" or tag == &"":
				return false
			# 需要从 payload 或 binding 获取武器信息
			var weapon_tags: Array = payload.get("weapon_tags", [])
			return tag in weapon_tags

		&"HAS_ACTION_CARD_IN_HAND":
			# 来源牌的拥有者手牌中有行动牌
			var owner_id: StringName = binding.get_owner_player_id()
			var hand_count: int = payload.get("owner_action_hand_count", -1)
			if hand_count >= 0:
				return hand_count > 0
			# 回退：从 payload 中检查
			var hand: Array = payload.get("action_hand", [])
			return not hand.is_empty()

		&"PAYLOAD_CARD_HAS_TAG":
			# payload 中的卡牌拥有指定标签
			var card_id: StringName = payload.get("card_id", &"")
			var tag: StringName = condition.get("tag", &"")
			if card_id == &"" or tag == &"":
				return false
			var card_tags: Array = payload.get("card_tags", [])
			return tag in card_tags

		&"SOURCE_OWNER_HAS_STATUS":
			var owner_id: StringName = binding.get_owner_player_id()
			var status_type: StringName = condition.get("status", &"")
			if status_type == &"":
				return false
			var statuses: Array = payload.get("owner_statuses", [])
			return statuses.any(func(s: Dictionary) -> bool: return s.get("type", &"") == status_type)

		&"PAYLOAD_ATTACK_HIT":
			return payload.get("hit", false) == true

		&"PAYLOAD_ATTACK_MISS":
			return payload.get("miss", false) == true

		&"TARGET_HAS_STATUS":
			var target_statuses: Array = payload.get("target_statuses", [])
			var status_type: StringName = condition.get("status", &"")
			if status_type == &"":
				return false
			return target_statuses.any(func(s: Dictionary) -> bool: return s.get("type", &"") == status_type)

		&"MECH_HP_BELOW":
			var threshold: int = int(condition.get("threshold", 50))
			var hp_percent: int = payload.get("mech_hp_percent", 100)
			return hp_percent < threshold

		&"EQUIPPED_WEAPON_KIND":
			var weapon_kind: StringName = condition.get("weapon_kind", &"")
			if weapon_kind == &"":
				return false
			var equipped_kinds: Array = payload.get("equipped_weapon_kinds", [])
			return weapon_kind in equipped_kinds

		&"IS_FIRST_ATTACK_THIS_TURN":
			var attack_count: int = payload.get("attack_count_this_turn", 0)
			return attack_count == 0

		&"GOLD_ABOVE":
			var threshold: int = int(condition.get("threshold", 0))
			var gold: int = payload.get("owner_gold", 0)
			return gold > threshold

		&"HAS_EQUIPMENT_IN_SLOT":
			var slot_id: StringName = condition.get("slot_id", &"")
			if slot_id == &"":
				return false
			var equipped_slots: Array = payload.get("equipped_slots", [])
			return slot_id in equipped_slots

		&"MECH_HAS_DAMAGE_TOKENS":
			var token_count: int = payload.get("mech_damage_token_count", 0)
			return token_count > 0

		_:
			push_warning("ConditionChecker: 未知条件操作符 %s，默认返回 true" % op)
			return true
