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
##   MECH_HAS_DAMAGE_TOKENS, ATTACK_COUNT_BELOW, HAS_FACTION,
##   SELF_DAMAGE_TOKENS_ABOVE, WEAPON_NAME_CONTAINS,
##   COUNT_EQUIPMENT_WITH_NAME_CONTAINS, ATTACK_SOURCE_IS_SELF,
##   MOVED_DISTANCE_THIS_TURN_ABOVE, POWER_SPENT_THIS_TURN_ABOVE,
##   ATTACK_DEALT_NO_HP_DAMAGE, ALLY_IN_WEAPON_RANGE_IS_TARGET,
##   CARD_MISSING_FROM_DISCARD, LAST_ACTION_CARD_IN_HAND,
##   DAMAGE_TOKENS_ALL_IN_SAME_SLOT, OWNER_ACTION_HAND_EMPTY,
##   ATTACK_COUNT_EQUALS, SELF_DAMAGE_TOKENS_BELOW,
##   SELF_DAMAGE_TOKENS_EQUALS, VARIABLE_ABOVE
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
			var owner_id: StringName = binding.get_owner_player_id()
			var attack: Dictionary = payload.get("attack", {})
			if attack.is_empty():
				return false
			return owner_id == attack.get("attacker_player_id", &"")

		&"SOURCE_OWNER_IS_TARGET":
			var owner_id: StringName = binding.get_owner_player_id()
			var attack: Dictionary = payload.get("attack", {})
			if attack.is_empty():
				return false
			return owner_id == attack.get("target_player_id", &"")

		&"IS_OWNER_MAIN_PHASE":
			var phase: StringName = payload.get("phase", &"")
			return phase == &"MAIN"

		&"PAYLOAD_WEAPON_HAS_TAG":
			var weapon_id: StringName = payload.get("weapon_id", &"")
			var tag: StringName = condition.get("tag", &"")
			if weapon_id == &"" or tag == &"":
				return false
			var weapon_tags: Array = payload.get("weapon_tags", [])
			return tag in weapon_tags

		&"HAS_ACTION_CARD_IN_HAND":
			var owner_id: StringName = binding.get_owner_player_id()
			var hand_count: int = payload.get("owner_action_hand_count", -1)
			if hand_count >= 0:
				return hand_count > 0
			var hand: Array = payload.get("action_hand", [])
			return not hand.is_empty()

		&"PAYLOAD_CARD_HAS_TAG":
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

		&"ATTACK_COUNT_BELOW":
			var max_count: int = int(condition.get("max_count", 1))
			var attack_count: int = payload.get("attack_count_this_turn", 0)
			return attack_count < max_count

		&"HAS_FACTION":
			var faction: StringName = condition.get("faction", &"")
			if faction == &"":
				return false
			var owner_faction: StringName = payload.get("owner_faction", &"")
			return owner_faction == faction

		&"SELF_DAMAGE_TOKENS_ABOVE":
			# 此牌(源卡)上设置的损伤 >= threshold（slot 级别，非机甲级别）
			var threshold: int = int(condition.get("threshold", 1))
			var self_tokens: int = payload.get("source_card_damage_tokens", 0)
			return self_tokens >= threshold

		&"WEAPON_NAME_CONTAINS":
			# 攻击武器名称包含指定子串（如"光束"、"热能"）
			var substring: String = String(condition.get("substring", &""))
			if substring == "":
				return false
			var weapon_name: String = String(payload.get("weapon_name", &""))
			return weapon_name.find(substring) >= 0

		&"COUNT_EQUIPMENT_WITH_NAME_CONTAINS":
			# 其他区域设置有N张名称包含指定子串的装备牌
			var substring: String = String(condition.get("substring", &""))
			var min_count: int = int(condition.get("min_count", 1))
			if substring == "":
				return false
			var match_count: int = payload.get("equipment_name_match_count", 0)
			return match_count >= min_count

		&"ATTACK_SOURCE_IS_SELF":
			# 攻击来自此牌（源卡是攻击使用的武器）
			var source_instance_id: StringName = binding.get_source_instance_id()
			var attack_weapon_id: StringName = payload.get("attack_weapon_instance_id", &"")
			return source_instance_id == attack_weapon_id

		&"MOVED_DISTANCE_THIS_TURN_ABOVE":
			# 本回合累积移动距离 >= threshold
			var threshold: int = int(condition.get("threshold", 8))
			var moved_cells: int = payload.get("moved_cells_this_turn", 0)
			return moved_cells >= threshold

		&"POWER_SPENT_THIS_TURN_ABOVE":
			# 本回合消耗动力 >= threshold
			var threshold: int = int(condition.get("threshold", 8))
			var power_spent: int = payload.get("power_spent_this_turn", 0)
			return power_spent >= threshold

		&"ATTACK_DEALT_NO_HP_DAMAGE":
			# 攻击未造成 HP 伤害（命中但伤害被护甲完全吸收）
			return payload.get("attack_dealt_no_hp_damage", false) == true

		&"ALLY_IN_WEAPON_RANGE_IS_TARGET":
			# 武器范围内存在机甲（包括我方）被指定为攻击目标
			return payload.get("ally_in_weapon_range_is_target", false) == true

		&"CARD_MISSING_FROM_DISCARD":
			# 弃牌堆缺少指定 card_id 的牌
			var card_id: StringName = condition.get("card_id", &"")
			if card_id == &"":
				return false
			var discard_has_card: bool = payload.get("discard_has_card_%s" % card_id, true)
			return not discard_has_card

		&"LAST_ACTION_CARD_IN_HAND":
			# 即将被弃置的牌是最后一张行动牌
			return payload.get("is_last_action_card_in_hand", false) == true

		&"DAMAGE_TOKENS_ALL_IN_SAME_SLOT":
			# 本次攻击产生的损伤全部放置于同一区域
			return payload.get("damage_tokens_all_in_same_slot", false) == true

		&"OWNER_ACTION_HAND_EMPTY":
			# 源牌拥有者行动手牌为空
			var hand_count: int = payload.get("owner_action_hand_count", -1)
			return hand_count == 0

		&"ATTACK_COUNT_EQUALS":
			# 本回合攻击次数等于 N（第N次攻击触发）
			var target_count: int = int(condition.get("count", 1))
			var attack_count: int = payload.get("attack_count_this_turn", 0)
			return attack_count == target_count

		&"SELF_DAMAGE_TOKENS_BELOW":
			# 此牌(源卡)上设置的损伤 < threshold（slot 级别）
			var threshold: int = int(condition.get("threshold", 1))
			var self_tokens: int = payload.get("source_card_damage_tokens", 0)
			return self_tokens < threshold

		&"SELF_DAMAGE_TOKENS_EQUALS":
			# 此牌(源卡)上设置的损伤 == threshold（slot 级别）
			var threshold: int = int(condition.get("threshold", 1))
			var self_tokens: int = payload.get("source_card_damage_tokens", 0)
			return self_tokens == threshold

		&"VARIABLE_ABOVE":
			# 自定义命名变量 X > threshold
			var variable_name: StringName = condition.get("variable_name", &"")
			var threshold: int = int(condition.get("threshold", 0))
			if variable_name == &"":
				return false
			var player_id: StringName = binding.get_owner_player_id()
			var mech_id: StringName = binding.get_source_mech_id()
			var key: String = "%s_%s_%s" % [player_id, mech_id, variable_name]
			var current_value: int = int(payload.get("variable_%s" % key, 0))
			return current_value > threshold


		_:
			push_warning("ConditionChecker: 未知条件操作符 %s，默认返回 true" % op)
			return true
