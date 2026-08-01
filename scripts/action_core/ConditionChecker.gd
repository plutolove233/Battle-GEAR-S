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
const _EffectBinding = preload("res://scripts/action_core/EffectBinding.gd")
const _RangeCalculator = preload("res://scripts/battle/RangeCalculator.gd")


## 检查所有条件是否满足
static func check_all(binding, payload: Dictionary, conditions: Array) -> bool:
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

		&"IS_OWNER_TURN":
			# 装备所属玩家 == 当前回合玩家（持有者回合内可主动触发，DIRECT 主动按钮用）。
			# 不依赖 payload.phase（主动触发 payload 无 phase），从 binding.context 查 active_player_id。
			var iot_owner: StringName = binding.get_owner_player_id()
			var iot_ctx = binding.context if binding != null else null
			if iot_owner == &"" or iot_ctx == null or iot_ctx.get("game_state") == null:
				return false
			return iot_ctx.game_state.active_player_id == iot_owner

		&"PAYLOAD_WEAPON_HAS_TAG":
			var weapon_id: StringName = payload.get("weapon_id", &"")
			var tag: StringName = condition.get("tag", &"")
			if weapon_id == &"" or tag == &"":
				return false
			var weapon_tags: Array = payload.get("weapon_tags", [])
			return tag in weapon_tags

		&"HAS_ACTION_CARD_IN_HAND":
			# 持有至少1张行动牌。优先用 payload 预填字段；否则从 binding.context.game_state
			# 查实际手牌（fire_timing 的 payload 不自动带 hand 信息，需经 context 查询）。
			var owner_id: StringName = binding.get_owner_player_id()
			var hand_count: int = payload.get("owner_action_hand_count", -1)
			if hand_count >= 0:
				return hand_count > 0
			var hand: Array = payload.get("action_hand", [])
			if not hand.is_empty():
				return true
			var hh_ctx = binding.context if binding != null else null
			if owner_id != &"" and hh_ctx != null and hh_ctx.get("game_state") != null:
				var hh_player = hh_ctx.game_state.players.get(owner_id)
				if hh_player != null:
					return not hh_player.action_hand.is_empty()
			return false

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

		&"ATTACK_HIT":
			# 攻击命中（ATTACK_AFTER 时 payload 含 hit）。与 PAYLOAD_ATTACK_HIT 同义，
			# 仅为兼容 GeneratedActionEffects 里破甲/锁定使用的 ATTACK_HIT 命名。
			return payload.get("hit", false) == true

		&"ATTACK_WAS_RESPONDED":
			# 本次攻击被响应（迎击牌 RESPOND_ATTACK 写回 attack record.responded）。
			# 强袭在 ATTACK_AT 响应效果全部结算后补跑监听器，此时读取最新 responded。
			return payload.get("responded", false) == true

		&"ATTACK_CAN_BE_NEGATED":
			# 攻击未带"不可无效"标记（effect_081 一角兽躯干置4损伤无效攻击前置条件）
			var acn_attack_id: StringName = payload.get("action_id", payload.get("attack_action_id", &""))
			var acn_ctx = binding.context if binding != null else null
			if acn_attack_id != &"" and acn_ctx != null and acn_ctx.get("action_registry") != null:
				var acn_action = acn_ctx.action_registry.get_action(acn_attack_id)
				if acn_action != null:
					return not bool(acn_action.unnegatable)
			return true  # 无攻击上下文时默认可无效

		&"ATTACK_TARGET_ALIVE":
			# 攻击目标机甲仍存活（未被摧毁）。binding.context 由 TimingEngine 注入。
			var alive_target_id: StringName = payload.get("target_id", &"")
			if alive_target_id == &"":
				return false
			var alive_ctx = binding.context if binding != null else null
			if alive_ctx == null or alive_ctx.get("game_state") == null:
				return false
			var alive_mech = alive_ctx.game_state.mechs.get(alive_target_id)
			return alive_mech != null and not alive_mech.destroyed

		&"WEAPON_CAN_ATTACK_AGAIN":
			# 闪击再攻前置：攻击者存活、武器仍在攻击者武器列表中（目标是否在射程内由
			# WEAPON_HAS_ATTACKABLE_TARGET_IN_RANGE 单独检查：再攻可在武器范围内另选目标）。
			# 第一版不检查 mech.can_attack()——效果产生的攻击不消耗回合攻击数
			# （use_action_card 对攻击牌 +1 attack_count 是另一处已知 bug，不在本次范围）。
			var wc_attacker_id: StringName = payload.get("attacker_id", &"")
			var wc_weapon_id: StringName = payload.get("weapon_id", &"")
			if wc_attacker_id == &"" or wc_weapon_id == &"":
				return false
			var wc_ctx = binding.context if binding != null else null
			if wc_ctx == null or wc_ctx.get("game_state") == null:
				return false
			var wc_attacker = wc_ctx.game_state.mechs.get(wc_attacker_id)
			if wc_attacker == null or wc_attacker.destroyed:
				return false
			# 武器仍属于攻击者（未被破坏/替换）
			var weapon_still_equipped: bool = false
			for wid in wc_attacker.get_weapon_ids():
				if wid == wc_weapon_id:
					weapon_still_equipped = true
					break
			return weapon_still_equipped

		&"WEAPON_HAS_ATTACKABLE_TARGET_IN_RANGE":
			# 闪击再攻：攻击A的武器攻击范围内存在可攻击的机甲（存活且在范围内）。
			# 再攻不锁定攻击A的目标，玩家可在武器范围内任选，故只须保证范围内有任意可攻击目标。
			# 有效范围 = 武器基础范围 + extra_range（与 attack_action._step_select_target 一致）。
			# payload = 攻击A 的 record（含 attacker_id / weapon_id / weapon_range / extra_range）。
			var wt_attacker_id: StringName = payload.get("attacker_id", &"")
			var wt_weapon_id: StringName = payload.get("weapon_id", &"")
			if wt_attacker_id == &"" or wt_weapon_id == &"":
				return false
			var wt_ctx = binding.context if binding != null else null
			if wt_ctx == null or wt_ctx.get("game_state") == null:
				return false
			var wt_attacker = wt_ctx.game_state.mechs.get(wt_attacker_id)
			if wt_attacker == null or wt_attacker.destroyed:
				return false
			var wt_range: int = max(1, int(payload.get("weapon_range", 1)) + int(payload.get("extra_range", 0)))
			var wt_cells: Dictionary = wt_ctx.game_state.map_state.cells if wt_ctx.game_state.map_state else {}
			for mech_id_wt: StringName in wt_ctx.game_state.mechs:
				if mech_id_wt == wt_attacker_id:
					continue
				var m_wt = wt_ctx.game_state.mechs[mech_id_wt]
				if m_wt == null or m_wt.destroyed:
					continue
				if _RangeCalculator.is_in_weapon_range(wt_attacker.position, m_wt.position, wt_range, wt_cells):
					return true
			return false


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
			var gold: int = int(payload.get("owner_gold", -1))
			if gold < 0:
				# 装备 DIRECT/LISTEN 效果：从 binding_context.player_id 查玩家金币
				var ga_bind: Dictionary = payload.get("binding_context", {})
				var ga_pid: StringName = ga_bind.get("player_id", &"")
				var ga_ctx = binding.context if binding != null else null
				if ga_pid != &"" and ga_ctx != null and ga_ctx.get("game_state") != null:
					var ga_player = ga_ctx.game_state.players.get(ga_pid)
					gold = ga_player.gold if ga_player != null else 0
				else:
					gold = 0
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

		&"TARGET_HP_NOT_FULL":
			# 维修 CHOOSE_ONE：目标 HP 未满（current_hp < max_hp）才可选"回复生命"。
			# 直接查 context.game_state（CHOOSE_ONE 时点 payload 无预填 HP 字段）。
			var tnf_target_id: StringName = payload.get("target_id", payload.get("target_mech_id", &""))
			var tnf_ctx = binding.context if binding != null else null
			if tnf_target_id == &"" or tnf_ctx == null or tnf_ctx.get("game_state") == null:
				return false
			var tnf_mech = tnf_ctx.game_state.mechs.get(tnf_target_id)
			if tnf_mech == null:
				return false
			return tnf_mech.current_hp < tnf_mech.max_hp

		&"TARGET_HAS_DAMAGE":
			# 维修 CHOOSE_ONE：目标有损伤（区域或装备牌）才可选"移除损伤"。
			# effect_079 离场移除损伤：DISCARD_AFTER payload 无 target_id，回退 binding_context.mech_id（来源装备所属机甲）
			var thd_target_id: StringName = payload.get("target_id", payload.get("target_mech_id", &""))
			if thd_target_id == &"":
				thd_target_id = payload.get("binding_context", {}).get("mech_id", &"")
			var thd_ctx = binding.context if binding != null else null
			if thd_target_id == &"" or thd_ctx == null or thd_ctx.get("game_state") == null:
				return false
			var thd_mech = thd_ctx.game_state.mechs.get(thd_target_id)
			if thd_mech == null:
				return false
			for thd_sid in thd_mech.slots:
				var thd_slot = thd_mech.slots[thd_sid]
				if thd_slot == null:
					continue
				if thd_slot.region_damage_tokens > 0:
					return true
				if thd_slot.equipped_card != null and thd_slot.equipped_card.damage_tokens > 0:
					return true
			return false

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
			var self_tokens: int = _source_card_damage_tokens(binding, payload)
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
			# 被动监听时从 payload 取；主动触发（DIRECT 按钮）时 payload 无此字段，
			# 从机甲状态 cells_moved_this_turn 查（effect_012/013 改主动后走此路径）
			var md_threshold: int = int(condition.get("threshold", 8))
			var moved_cells: int = 0
			if payload != null and payload.has("moved_cells_this_turn"):
				moved_cells = int(payload.get("moved_cells_this_turn"))
			else:
				moved_cells = _mech_cells_moved(binding, payload)
			return moved_cells >= md_threshold

		&"POWER_SPENT_THIS_TURN_ABOVE":
			# 本回合消耗动力 >= threshold
			# 被动监听时从 payload 取；主动触发时从机甲状态 power_spent_this_turn 查
			var ps_threshold: int = int(condition.get("threshold", 8))
			var power_spent: int = 0
			if payload != null and payload.has("power_spent_this_turn"):
				power_spent = int(payload.get("power_spent_this_turn"))
			else:
				power_spent = _mech_power_spent(binding, payload)
			return power_spent >= ps_threshold

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
			var self_tokens: int = _source_card_damage_tokens(binding, payload)
			return self_tokens < threshold

		&"SELF_DAMAGE_TOKENS_EQUALS":
			# 此牌(源卡)上设置的损伤 == threshold（slot 级别）
			var threshold: int = int(condition.get("threshold", 1))
			var self_tokens: int = _source_card_damage_tokens(binding, payload)
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

		&"WEAPON_HAS_ENERGY_CHARGE":
			# 当前攻击使用的武器拥有聚能状态。
			# 状态监听器在 binding_context 中携带 weapon_id（聚能只对该武器触发）；
			# 非状态监听器退回 payload.weapon_has_energy_charge 标志。
			var bind_ctx: Dictionary = payload.get("binding_context", {})
			var bound_weapon_id: StringName = bind_ctx.get("weapon_id", &"")
			if bound_weapon_id != &"":
				var attack_weapon_id: StringName = payload.get("weapon_id", &"")
				return attack_weapon_id == bound_weapon_id and attack_weapon_id != &""
			# 退路：payload 标志或 source_mech_statuses
			var weapon_has_energy: bool = payload.get("weapon_has_energy_charge", false)
			if weapon_has_energy:
				return true
			var source_mech_id: StringName = binding.get_source_mech_id()
			if source_mech_id == &"":
				return false
			var mech_statuses: Array = payload.get("source_mech_statuses", [])
			return mech_statuses.any(func(s: Dictionary) -> bool: return s.get("type", &"") == &"ENERGY_CHARGE")

		&"HAS_DISCOUNT_STATUS":
			# 源牌所属机甲拥有折扣状态。
			# 状态监听器在 binding_context.target_id 携带拥有折扣的机甲；
			# 当攻击的攻击者 == 该机甲时满足（折扣机甲发起攻击）。
			var discount_ctx: Dictionary = payload.get("binding_context", {})
			var discount_mech_id: StringName = discount_ctx.get("target_id", &"")
			if discount_mech_id != &"":
				var attacker_id_d: StringName = payload.get("attacker_id", &"")
				return attacker_id_d == discount_mech_id and attacker_id_d != &""
			var source_mech_id_d: StringName = binding.get_source_mech_id()
			if source_mech_id_d == &"":
				return false
			var mech_statuses_d: Array = payload.get("source_mech_statuses", [])
			return mech_statuses_d.any(func(s: Dictionary) -> bool: return s.get("type", &"") == &"DISCOUNT")

		&"TARGET_HAS_LOCK_FROM_ATTACKER":
			# 攻击目标被本次攻击的攻击者锁定。
			# 锁定状态监听器在 binding_context 携带 target_id（被锁机甲）与
			# source_player_id（施放锁定的玩家）。满足条件需：攻击目标 == 被锁机甲，
			# 且攻击者玩家 == 锁定来源玩家。
			var lock_ctx: Dictionary = payload.get("binding_context", {})
			var locked_target_id: StringName = lock_ctx.get("target_id", &"")
			var locker_player_id: StringName = lock_ctx.get("source_player_id", &"")
			var attack_target_id: StringName = payload.get("target_id", &"")
			if locked_target_id == &"" or attack_target_id == &"":
				return false
			if attack_target_id != locked_target_id:
				return false
			# 攻击者玩家：优先从 attack_source.player_id 取，退回从机甲反查
			var attack_source: Dictionary = payload.get("attack_source", {})
			var attacker_player_id: StringName = attack_source.get("player_id", &"")
			if attacker_player_id == &"":
				return locker_player_id == &""  # 无锁定来源信息时退回宽松匹配
			return attacker_player_id == locker_player_id

		&"TARGET_HAS_LOCK_FROM_ANYONE":
			# 攻击目标 == 被锁机甲（不限攻击者是否为 locker）。
			# 用于锁定命中后清除：B 被任何人命中都解除 B 身上该 locker 施加的锁定。
			var lock_ctx_any: Dictionary = payload.get("binding_context", {})
			var locked_target_id_any: StringName = lock_ctx_any.get("target_id", &"")
			var attack_target_id_any: StringName = payload.get("target_id", &"")
			if locked_target_id_any == &"" or attack_target_id_any == &"":
				return false
			return attack_target_id_any == locked_target_id_any

		&"UNITE_ATTACKER_IS_UNITE_MECH":
			# 联合状态效果1：unite机甲（出牌者=机甲1）为发动攻击的机甲时触发。
			# unite 机甲 id 由 _register_status_listeners 从 status.unite 注入 binding_context.unite。
			# （旧实现误用 target_id=被联合Target，导致 Target 自己攻击时才触发，与规范相反。）
			var unite_ctx: Dictionary = payload.get("binding_context", {})
			var unite_mech_id: StringName = unite_ctx.get("unite", &"")
			if unite_mech_id == &"":
				return false
			var unite_attacker_id: StringName = payload.get("attacker_id", &"")
			return unite_attacker_id == unite_mech_id and unite_attacker_id != &""

		# ════════════════════════════════════════════════════════════
		# 装备牌效果专用条件（C-H 阶段）
		# 来源装备牌信息从 payload.binding_context 取（permanent listener 注册时注入）：
		#   {card_instance_id, mech_id, player_id, card_def_id}
		# 被监听时点所属动作的 record 字段从 payload 取（attacker_id/target_id/markers 等）。
		# ════════════════════════════════════════════════════════════

		&"SELF_MECH_IS_ATTACK_TARGET":
			# 本牌所属机甲 = 攻击目标
			var smi_mech_id: StringName = _equip_mech_id(binding, payload)
			var smi_target: StringName = payload.get("target_id", &"")
			return smi_mech_id != &"" and smi_mech_id == smi_target

		&"SELF_MECH_IS_ATTACKER":
			# 本牌所属机甲 = 攻击发起方
			var sma_mech_id: StringName = _equip_mech_id(binding, payload)
			var sma_attacker: StringName = payload.get("attacker_id", &"")
			return sma_mech_id != &"" and sma_mech_id == sma_attacker

		&"SELF_MECH_IS_MOVE_SUBJECT":
			# 本牌所属机甲 = 基础移动的主体（basic_move record.mech_id）
			var sms_mech_id: StringName = _equip_mech_id(binding, payload)
			var sms_subject: StringName = payload.get("mech_id", payload.get("source_mech_id", &""))
			return sms_mech_id != &"" and sms_mech_id == sms_subject

		&"ATTACK_MARKERS_ABOVE":
			# 本次攻击产生的损伤标记数 > threshold
			var am_threshold: int = int(condition.get("threshold", 0))
			var am_markers: int = int(payload.get("markers", 0)) + int(payload.get("extra_markers", 0))
			return am_markers > am_threshold

		&"ATTACK_EFFECTIVE_WEAPON_KIND":
			# 攻击的有效武器类型（近战头部转换后读 effective_weapon_type）== weapon_kind
			var aew_kind: StringName = condition.get("weapon_kind", &"")
			if aew_kind == &"":
				return false
			var aew_eff: StringName = payload.get("effective_weapon_type", &"")
			if aew_eff == &"":
				# 退回实体武器 kind（ATTACK_BEFORE 转换前）
				aew_eff = payload.get("weapon_kind", &"")
			return aew_eff == aew_kind

		&"ATTACK_EFFECTIVE_WEAPON_KIND_NOT":
			# 攻击的有效武器类型 != weapon_kind（近战头部：非近战武器才转换）
			var aewn_kind: StringName = condition.get("weapon_kind", &"")
			if aewn_kind == &"":
				return false
			var aewn_eff: StringName = payload.get("effective_weapon_type", &"")
			if aewn_eff == &"":
				aewn_eff = payload.get("weapon_kind", &"")
			return aewn_eff != aewn_kind

		&"OWNER_ACTION_HAND_ABOVE":
			# 装备牌所属玩家行动手牌数 > threshold（重甲/机动躯干弃2牌成本前置）
			var oah_threshold: int = int(condition.get("threshold", 1))
			var oah_player_id: StringName = _equip_player_id(binding, payload)
			var oah_ctx = binding.context if binding != null else null
			if oah_player_id == &"" or oah_ctx == null or oah_ctx.get("game_state") == null:
				return false
			var oah_player = oah_ctx.game_state.players.get(oah_player_id)
			if oah_player == null:
				return false
			return oah_player.action_hand.size() > oah_threshold

		&"OWNER_POWER_ABOVE_OR_EQUAL":
			# 装备牌所属机甲当前动力 >= threshold（机动头部消耗4动力前置）
			var op_threshold: int = int(condition.get("threshold", 0))
			var op_mech_id: StringName = _equip_mech_id(binding, payload)
			var op_ctx = binding.context if binding != null else null
			if op_mech_id == &"" or op_ctx == null or op_ctx.get("game_state") == null:
				return false
			var op_mech = op_ctx.game_state.mechs.get(op_mech_id)
			if op_mech == null:
				return false
			return op_mech.power >= op_threshold

		&"OWNER_POWER_EQUALS":
			# 装备牌所属机甲当前动力 == value（机动装·头部 effect_017：消耗动力后动力恰为0）
			# 兼容 value / threshold 两种参数名。BASIC_MOVE_AFTER fire 时动力已扣除，读 mech.power。
			var ope_value: int = int(condition.get("value", condition.get("threshold", 0)))
			var ope_mech_id: StringName = _equip_mech_id(binding, payload)
			var ope_ctx = binding.context if binding != null else null
			if ope_mech_id == &"" or ope_ctx == null or ope_ctx.get("game_state") == null:
				return false
			var ope_mech = ope_ctx.game_state.mechs.get(ope_mech_id)
			if ope_mech == null:
				return false
			return ope_mech.power == ope_value

		&"DISCARD_IS_SELF_FROM_SLOT":
			# 弃置的牌是本牌（来源装备），且从设置区域弃置（from_slot_id 非空，非手牌/临时区）
			var dis_card_id: StringName = _equip_card_instance_id(binding, payload)
			if dis_card_id == &"":
				return false
			var dis_snapshots: Array = payload.get("discard_snapshots", [])
			for snap: Dictionary in dis_snapshots:
				if String(snap.get("card_id", &"")) == String(dis_card_id):
					var from_slot: StringName = snap.get("from_slot_id", &"")
					var from_zone: StringName = snap.get("from_zone", &"")
					# 从区域弃置：slot_id 非空 且 zone 是装备/武器/备用区
					if from_slot != &"" and (from_zone == &"equipment_slot" or from_zone == &"weapon_slot" or from_zone == &"reserve_slot" or from_zone == &"equipped"):
						return true
			return false

		&"SET_EQUIP_IS_SELF":
			# 本次正式设置的牌实例是本牌（精英装·头部/腿 effect_033：设置时抽1行动牌）
			# set_equipment record.card_id = 设置牌 instance_id；binding_context.card_instance_id = 本牌
			var ses_card_id: StringName = payload.get("card_id", payload.get("card_instance_id", &""))
			var ses_self_id: StringName = _equip_card_instance_id(binding, payload)
			return ses_card_id != &"" and String(ses_card_id) == String(ses_self_id)

		&"DISCARD_REASON_IS":
			# 弃置原因 == condition.reason（近战右腿只接受 damage_durability）
			var dr_reason: StringName = condition.get("reason", &"")
			if dr_reason == &"":
				return false
			var dr_snapshots: Array = payload.get("discard_snapshots", [])
			var dis_card_id_dr: StringName = _equip_card_instance_id(binding, payload)
			for snap: Dictionary in dr_snapshots:
				# 若有来源牌，只匹配本牌的快照；无来源牌则匹配任意快照
				if dis_card_id_dr != &"" and String(snap.get("card_id", &"")) != String(dis_card_id_dr):
					continue
				if String(snap.get("reason", &"")) == String(dr_reason):
					return true
			return false

		&"REDIRECT_TARGET_HAS_FACTION_EQUIP":
			# 损伤转移：原攻击目标 slot 的装备名含 faction_substring（联邦右臂）
			var rth_substring: String = String(condition.get("faction_substring", &""))
			if rth_substring == "":
				return false
			var rth_ctx = binding.context if binding != null else null
			if rth_ctx == null or rth_ctx.get("game_state") == null:
				return false
			var rth_target_id: StringName = payload.get("target_id", &"")
			if rth_target_id == &"":
				return false
			# 遍历本次待放置损伤涉及的目标机甲，检查是否有装备名含 faction_substring 的 slot
			var rth_mech_ids: Array = payload.get("mech_ids", [rth_target_id])
			for mid: StringName in rth_mech_ids:
				var rth_mech = rth_ctx.game_state.mechs.get(mid)
				if rth_mech == null:
					continue
				for sid in rth_mech.slots:
					var rth_slot = rth_mech.slots[sid]
					if rth_slot == null:
						continue
					var rth_card = rth_slot.get("equipped_card")
					if rth_card == null or rth_card.def == null:
						continue
					var rth_name: String = String(rth_card.def.display_name) if "display_name" in rth_card.def else ""
					if rth_name.find(rth_substring) >= 0:
						return true
			return false

		&"REDIRECT_TARGET_HAS_ANY_EQUIP":
			# 损伤转移：原攻击目标 slot 有任意装备牌（联邦右臂新文本：不限联邦，任意装备即将设置损伤即可转）
			var rta_ctx = binding.context if binding != null else null
			if rta_ctx == null or rta_ctx.get("game_state") == null:
				return false
			var rta_target_id: StringName = payload.get("target_id", &"")
			if rta_target_id == &"":
				return false
			var rta_mech_ids: Array = payload.get("mech_ids", [rta_target_id])
			for mid: StringName in rta_mech_ids:
				var rta_mech = rta_ctx.game_state.mechs.get(mid)
				if rta_mech == null:
					continue
				for sid in rta_mech.slots:
					var rta_slot = rta_mech.slots[sid]
					if rta_slot == null:
						continue
					var rta_card = rta_slot.get("equipped_card")
					if rta_card != null and rta_card.def != null:
						return true
			return false

		&"TARGET_IS_OWN_MECH":
			# 损伤转移：目标机甲包含本牌所在机甲（我方机甲）。effect_004 联邦右臂用。
			var tom_mech_id: StringName = _equip_mech_id(binding, payload)
			if tom_mech_id == &"":
				return false
			var tom_mech_ids: Array = payload.get("mech_ids", [])
			if tom_mech_ids.is_empty():
				var tom_t: StringName = payload.get("target_id", payload.get("target_mech_id", &""))
				if tom_t != &"":
					tom_mech_ids = [tom_t]
			for mid in tom_mech_ids:
				if String(mid) == String(tom_mech_id):
					return true
			return false

		&"REDIRECT_HAS_DESTROYABLE_EQUIP":
			# 损伤转移：有机甲装备即将因本次损伤弃置（机动右臂）
			# 简化判定：目标机甲上有装备且其耐久 <= 待放置损伤总数（粗略，精确判定在 OFFER_DAMAGE_REDIRECT 弹窗内做）
			var rhd_ctx = binding.context if binding != null else null
			if rhd_ctx == null or rhd_ctx.get("game_state") == null:
				return false
			var rhd_total: int = int(payload.get("total_points", payload.get("value", 0)))
			if rhd_total <= 0:
				return false
			var rhd_mech_ids: Array = payload.get("mech_ids", [])
			if rhd_mech_ids.is_empty():
				var rhd_t: StringName = payload.get("target_id", &"")
				if rhd_t != &"":
					rhd_mech_ids = [rhd_t]
			for mid: StringName in rhd_mech_ids:
				var rhd_mech = rhd_ctx.game_state.mechs.get(mid)
				if rhd_mech == null:
					continue
				for sid in rhd_mech.slots:
					var rhd_slot = rhd_mech.slots[sid]
					if rhd_slot == null:
						continue
					var rhd_card = rhd_slot.get("equipped_card")
					if rhd_card == null or rhd_card.def == null:
						continue
					var rhd_dur: int = int(rhd_slot.get_equipment_durability()) if rhd_slot.has_method("get_equipment_durability") else 0
					# 该 slot 现有损伤 + 待放置总数 可能击穿耐久
					# 区域损伤 + 装备卡自身损伤（MechSlotState: equipped_card.damage_tokens >= durability 才判破坏）
					var rhd_existing: int = int(rhd_slot.region_damage_tokens) if "region_damage_tokens" in rhd_slot else 0
					rhd_existing += int(rhd_card.damage_tokens)
					if rhd_existing + rhd_total > rhd_dur and rhd_dur > 0:
						return true
			return false

		&"USED_CARD_TYPE_IS":
			# use_action_card 打出的牌 action_type == card_type（狙击腿：打出攻击牌/迎击牌）
			var uct_type: String = String(condition.get("card_type", &""))
			if uct_type == "":
				return false
			var uct_card_id: StringName = payload.get("card_instance_id", payload.get("card_id", &""))
			if uct_card_id == &"":
				return false
			var uct_ctx = binding.context if binding != null else null
			if uct_ctx == null or uct_ctx.get("game_state") == null:
				return false
			var uct_card = uct_ctx.game_state.get_card(uct_card_id)
			if uct_card == null or uct_card.def == null:
				return false
			var uct_at: String = String(uct_card.def.action_type) if "action_type" in uct_card.def else ""
			return uct_at == uct_type

		&"USED_COUNTER_CARD":
			# 当前 use_action_card 打出的是迎击牌（action_type=="迎击"）才触发。
			# 推进 effect2：持有者使用迎击牌时弹多选窗。推进自身是辅助->false，不自触发。
			var ucc_card_id: StringName = payload.get("card_instance_id", payload.get("card_id", &""))
			if ucc_card_id == &"":
				return false
			var ucc_ctx = binding.context if binding != null else null
			if ucc_ctx == null or ucc_ctx.get("game_state") == null:
				return false
			var ucc_card = ucc_ctx.game_state.get_card(ucc_card_id)
			if ucc_card == null or ucc_card.def == null:
				return false
			var ucc_at: String = String(ucc_card.def.action_type) if "action_type" in ucc_card.def else ""
			return ucc_at == "迎击"

		&"USED_CARD_OWNER_IS_SELF":
			# use_action_card 打出的牌的持有者 == 本装备牌持有者（狙击腿：只有持有者本人打牌才触发）
			# 打出的牌从 payload.card_instance_id 取（fire USE_ACTION_AT 时牌已进 temp_zone，
			# 但 card.mech_id/owner_player_id 仍保留），与本装备牌的持有者比较。
			var uco_card_id: StringName = payload.get("card_instance_id", payload.get("card_id", &""))
			if uco_card_id == &"":
				return false
			var uco_ctx = binding.context if binding != null else null
			if uco_ctx == null or uco_ctx.get("game_state") == null:
				return false
			var uco_card = uco_ctx.game_state.get_card(uco_card_id)
			if uco_card == null:
				return false
			var uco_self_mech: StringName = _equip_mech_id(binding, payload)
			var uco_self_player: StringName = _equip_player_id(binding, payload)
			# 优先比 player_id（最稳定）；player_id 取不到时退回比 mech_id
			if uco_self_player != &"":
				return uco_card.owner_player_id == uco_self_player
			if uco_self_mech != &"":
				return uco_card.mech_id == uco_self_mech
			return false

		&"USED_ACTION_HAS_LINKED_ATTACK":
			# use_action_card（迎击牌响应攻击）绑定的原攻击仍有效：record.attack_action_id 非空
			# （TimingEngine.handle_response_selection 发起 use_action_card 时注入）。
			# effect_035 用：确保迎击牌确实绑定了原 attack 才触发"置损伤减威力"。
			return payload.get("attack_action_id", &"") != &""

		&"TARGET_IN_COVER_RANGE":
			# 掩护 effect1：文档"以机甲1与机甲1最大攻击范围内的其他机甲为攻击目标"--
			# 即攻击目标可以是 holder(机甲1)自身 或 holder范围内的其他机甲。
			# 机甲1 = payload.binding_context.mech_id（permanent_while_in_hand 监听器注入）；
			# 攻击目标 = payload.target_id。
			var tcr_target: StringName = payload.get("target_id", &"")
			if tcr_target == &"":
				return false
			var tcr_bind: Dictionary = payload.get("binding_context", {})
			var tcr_holder_mech_id: StringName = tcr_bind.get("mech_id", &"")
			if tcr_holder_mech_id == &"":
				return false
			# 排除攻击者自己持有掩护：攻击者不会用掩护减自己攻击威力。
			var tcr_attacker: StringName = payload.get("attacker_id", &"")
			if tcr_attacker != &"" and tcr_attacker == tcr_holder_mech_id:
				return false
			# holder 自身被攻击（target==holder）：触发（掩护可保护自己，自身不需范围检查）。
			if tcr_target == tcr_holder_mech_id:
				return true
			# 其他机甲被攻击：target 须在 holder 最大武器范围内。
			var tcr_ctx = binding.context if binding != null else null
			if tcr_ctx == null or tcr_ctx.get("game_state") == null:
				return false
			var tcr_gs = tcr_ctx.game_state
			var tcr_holder = tcr_gs.mechs.get(tcr_holder_mech_id)
			var tcr_target_mech = tcr_gs.mechs.get(tcr_target)
			if tcr_holder == null or tcr_target_mech == null:
				return false
			# 持有者最大武器范围：get_weapon_ids 返回 frame_base_weapon_X（基础武器虚拟ID）
			# 或装备卡 instance_id。前者须走 get_base_weapon 取 range_value（仿 attack_action._get_weapon_stats），
			# 否则 get_card(虚拟ID) 返回 null，range_value 永远取不到（max_range 恒为1的旧 bug）。
			var tcr_max_range: int = 1
			for wid in tcr_holder.get_weapon_ids():
				var tcr_rv: int = 1
				var tcr_wid_str := String(wid)
				if tcr_wid_str.begins_with("frame_base_weapon_"):
					var tcr_si: int = tcr_wid_str.trim_prefix("frame_base_weapon_").to_int() - 1
					var tcr_bw: Dictionary = tcr_holder.get_base_weapon(tcr_si)
					if not tcr_bw.is_empty():
						tcr_rv = int(tcr_bw.get("range_value", 1))
				else:
					var tcr_wc = tcr_gs.get_card(wid)
					if tcr_wc != null and tcr_wc.def != null and "range_value" in tcr_wc.def:
						tcr_rv = int(tcr_wc.def.range_value)
				tcr_max_range = max(tcr_max_range, tcr_rv)
			var tcr_map_cells: Dictionary = tcr_gs.map_state.cells if tcr_gs.map_state != null else {}
			return _RangeCalculator.is_in_weapon_range(tcr_holder.position, tcr_target_mech.position, tcr_max_range, tcr_map_cells)


		_:
			push_warning("ConditionChecker: 未知条件操作符 %s，默认返回 true" % op)
			return true


# ════════════════════════════════════════════════════════════
# 装备牌效果专用 helper：从 binding/payload 取装备牌来源信息
# ════════════════════════════════════════════════════════════

## 取装备牌来源的 card_instance_id（优先 payload.binding_context，退回 binding.source_card）
static func _equip_card_instance_id(binding, payload: Dictionary) -> StringName:
	var bind_ctx: Dictionary = payload.get("binding_context", {}) if payload != null else {}
	if not bind_ctx.is_empty():
		var cid: StringName = bind_ctx.get("card_instance_id", &"")
		if cid != &"":
			return cid
	if binding != null:
		return binding.get_source_instance_id()
	return &""


## 取装备牌来源所属机甲 ID
static func _equip_mech_id(binding, payload: Dictionary) -> StringName:
	var bind_ctx: Dictionary = payload.get("binding_context", {}) if payload != null else {}
	if not bind_ctx.is_empty():
		var mid: StringName = bind_ctx.get("mech_id", &"")
		if mid != &"":
			return mid
	if binding != null:
		return binding.get_source_mech_id()
	return &""


## 取装备牌来源所属玩家 ID
static func _equip_player_id(binding, payload: Dictionary) -> StringName:
	var bind_ctx: Dictionary = payload.get("binding_context", {}) if payload != null else {}
	if not bind_ctx.is_empty():
		var pid: StringName = bind_ctx.get("player_id", &"")
		if pid != &"":
			return pid
	if binding != null:
		return binding.get_owner_player_id()
	return &""


## 取装备牌来源机甲的本回合累计移动格数
## DIRECT 主动效果触发时 payload 无 move 数据，从机甲状态 cells_moved_this_turn 查
static func _mech_cells_moved(binding, payload: Dictionary) -> int:
	var mid: StringName = _equip_mech_id(binding, payload)
	if mid == &"" or binding == null or binding.context == null:
		return 0
	var gs = binding.context.get("game_state")
	if gs == null or not gs.mechs.has(mid):
		return 0
	return int(gs.mechs[mid].cells_moved_this_turn)


## 取装备牌来源机甲的本回合累计消耗动力（DIRECT 主动效果触发时用）
static func _mech_power_spent(binding, payload: Dictionary) -> int:
	var mid: StringName = _equip_mech_id(binding, payload)
	if mid == &"" or binding == null or binding.context == null:
		return 0
	var gs = binding.context.get("game_state")
	if gs == null or not gs.mechs.has(mid):
		return 0
	return int(gs.mechs[mid].power_spent_this_turn)


## 取源卡(装备牌)上设置的损伤数（用于 SELF_DAMAGE_TOKENS_ABOVE/BELOW/EQUALS 条件）
## 优先用 payload.source_card_damage_tokens（若调用方预填）；否则从 binding_context 反查
## 源卡 instance_id -> game_state.get_card -> card.damage_tokens（装备牌损伤挂在卡实例上）。
## 装备设置在区域中时损伤在 equipped_card.damage_tokens；离场 DISCARD_AFTER 时牌在 tmp_zone
## 仍保留 damage_tokens，故两类时点均可正确读取。
static func _source_card_damage_tokens(binding, payload: Dictionary) -> int:
	if payload != null and payload.has("source_card_damage_tokens"):
		return int(payload.get("source_card_damage_tokens", 0))
	var card_id: StringName = _equip_card_instance_id(binding, payload)
	if card_id == &"" or binding == null or binding.context == null:
		return 0
	var gs = binding.context.get("game_state")
	if gs == null:
		return 0
	var card = gs.get_card(card_id)
	if card == null:
		return 0
	return int(card.damage_tokens) if card.get("damage_tokens") else 0
