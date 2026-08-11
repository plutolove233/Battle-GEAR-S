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
const _HexGrid = preload("res://scripts/battle/hex_grid.gd")
const _GenEquipEffects = preload("res://scripts/generated_database/GeneratedEquipmentEffects.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")


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
			# payload.phase 优先（时点 fire 时携带）；DIRECT 主动效果 payload 无 phase 时
			# 回退查 game_state.phase == MAIN 且当前回合 == 持有者。
			var iomp_phase: StringName = payload.get("phase", &"")
			if iomp_phase == &"MAIN":
				return true
			var iomp_ctx = binding.context if binding != null else null
			if iomp_ctx == null or iomp_ctx.get("game_state") == null:
				return false
			var iomp_gs = iomp_ctx.game_state
			if iomp_gs.phase != &"MAIN":
				return false
			var iomp_owner: StringName = _equip_player_id(binding, payload)
			return iomp_owner != &"" and iomp_gs.active_player_id == iomp_owner

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
			# 持有至少 N 张行动牌（默认1）。params.count 或 params.minimum 指定阈值。
			# 优先用 payload 预填字段；否则从 binding.context.game_state 查实际手牌
			# （fire_timing 的 payload 不自动带 hand 信息，需经 context 查询）。
			var ha_params: Dictionary = condition.get("params", {})
			var ha_need: int = int(ha_params.get("count", ha_params.get("minimum", 1)))
			if ha_need < 1:
				ha_need = 1
			var owner_id: StringName = binding.get_owner_player_id()
			var hand_count: int = payload.get("owner_action_hand_count", -1)
			if hand_count >= 0:
				return hand_count >= ha_need
			var hand: Array = payload.get("action_hand", [])
			if not hand.is_empty():
				return hand.size() >= ha_need
			var hh_ctx = binding.context if binding != null else null
			if owner_id != &"" and hh_ctx != null and hh_ctx.get("game_state") != null:
				var hh_player = hh_ctx.game_state.players.get(owner_id)
				if hh_player != null:
					return hh_player.action_hand.size() >= ha_need
			return false

		&"PAYLOAD_CARD_HAS_TAG":
			var card_id: StringName = payload.get("card_id", &"")
			var tag: StringName = condition.get("tag", &"")
			if card_id == &"" or tag == &"":
				return false
			var card_tags: Array = payload.get("card_tags", [])
			return tag in card_tags

		&"PAYLOAD_CARD_HAS_RUNTIME_TAG":
			# pilot_003 effect_02：检查 payload.card_instance_id 对应卡实例的运行时标签（face_up_bury 等）。
			# tag 参数置于 condition.params（回退顶层）；统一读 CardInstance.has_tag。
			var rt_card_id: StringName = payload.get("card_instance_id", payload.get("card_id", &""))
			var rt_params: Dictionary = condition.get("params", condition)
			var rt_tag: StringName = rt_params.get("tag", condition.get("tag", &""))
			if rt_card_id == &"" or rt_tag == &"" or binding == null or binding.context == null:
				return false
			var rt_card = binding.context.game_state.get_card(rt_card_id)
			if rt_card == null:
				return false
			return rt_card.has_tag(rt_tag)

		&"PAYLOAD_FROM_ZONE_IS":
			# pilot_003 effect_02：检查离堆时点的来源区域（from_zone）。
			# zone 参数置于 condition.params（回退顶层）。
			var z_params: Dictionary = condition.get("params", condition)
			var zone_expect: StringName = z_params.get("zone", condition.get("zone", &""))
			var zone_actual: StringName = payload.get("from_zone", &"")
			return zone_expect != &"" and zone_expect == zone_actual

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
			# DIRECT 直攻免牌（effect_128）payload 无 attacker_id/weapon_id，从 binding_context 取
			if wc_attacker_id == &"" or wc_weapon_id == &"":
				wc_attacker_id = _equip_mech_id(binding, payload)
				wc_weapon_id = _equip_card_instance_id(binding, payload)
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
			if not weapon_still_equipped:
				return false
			# 冷却/锁定拦截（effect_125/104）
			var wc_card = wc_ctx.game_state.get_card(wc_weapon_id)
			if wc_card != null:
				if _is_weapon_on_cooldown(wc_card):
					return false
				if _weapon_lock_active(wc_card, wc_ctx.game_state, wc_weapon_id):
					return false
			return true

		&"WEAPON_HAS_ATTACKABLE_TARGET_IN_RANGE":
			# 闪击再攻：攻击A的武器攻击范围内存在可攻击的机甲（存活且在范围内）。
			# 再攻不锁定攻击A的目标，玩家可在武器范围内任选，故只须保证范围内有任意可攻击目标。
			# 有效范围 = 武器基础范围 + extra_range（与 attack_action._step_select_target 一致）。
			# payload = 攻击A 的 record（含 attacker_id / weapon_id / weapon_range / extra_range）。
			var wt_attacker_id: StringName = payload.get("attacker_id", &"")
			var wt_weapon_id: StringName = payload.get("weapon_id", &"")
			# DIRECT 直攻免牌（effect_128）从 binding_context 取
			if wt_attacker_id == &"" or wt_weapon_id == &"":
				wt_attacker_id = _equip_mech_id(binding, payload)
				wt_weapon_id = _equip_card_instance_id(binding, payload)
			if wt_attacker_id == &"" or wt_weapon_id == &"":
				return false
			var wt_ctx = binding.context if binding != null else null
			if wt_ctx == null or wt_ctx.get("game_state") == null:
				return false
			var wt_attacker = wt_ctx.game_state.mechs.get(wt_attacker_id)
			if wt_attacker == null or wt_attacker.destroyed:
				return false
			# 有效范围：优先 payload.weapon_range（attack record，含狙击头加成）+ extra_range；
			# DIRECT 直攻免牌 payload 无 weapon_range，用 get_effective_weapon_stats 派生重算。
			var wt_range: int = 1
			if payload.has("weapon_range"):
				wt_range = max(1, int(payload.get("weapon_range", 1)) + int(payload.get("extra_range", 0)))
			else:
				var wt_card = wt_ctx.game_state.get_card(wt_weapon_id)
				if wt_card != null:
					wt_range = max(1, int(_GenEquipEffects.get_effective_weapon_stats(wt_card).get("range_value", 1)))
				wt_range = max(1, wt_range + int(payload.get("extra_range", 0)))
			var wt_cells: Dictionary = wt_ctx.game_state.map_state.cells if wt_ctx.game_state.map_state else {}
			for mech_id_wt: StringName in wt_ctx.game_state.mechs:
				if mech_id_wt == wt_attacker_id:
					continue
				var m_wt = wt_ctx.game_state.mechs[mech_id_wt]
				if m_wt == null or m_wt.destroyed:
					continue
				if _RangeCalculator.is_in_weapon_range(wt_attacker.position, m_wt.position, wt_range, wt_cells):
					return true
			# 陷阱标记也是可攻击目标（攻击即引爆，无响应窗口）
			if wt_ctx.game_state.map_state != null:
				for m_wt2 in wt_ctx.game_state.map_state.markers:
					if m_wt2.get("type", &"") == &"TRAP":
						var t_pos: Dictionary = {"q": int(m_wt2.get("q", 0)), "r": int(m_wt2.get("r", 0))}
						if _RangeCalculator.is_in_weapon_range(wt_attacker.position, t_pos, wt_range, wt_cells):
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
			if source_instance_id == &"":
				return false
			# 虚拟武器(神莺躯干 effect_087)攻击时 record.attack_weapon_instance_id=躯干instance；
			# 实体武器攻击时 record.weapon_id=武器卡instance。两者皆与 source_instance_id 比较。
			# effect_088 source=躯干instance，仅虚拟攻击(weapon_id==躯干)时命中，实体武器不误触。
			var attack_weapon_id: StringName = payload.get("attack_weapon_instance_id", &"")
			if attack_weapon_id != &"" and source_instance_id == attack_weapon_id:
				return true
			var asw_weapon_id: StringName = payload.get("weapon_id", &"")
			return asw_weapon_id != &"" and source_instance_id == asw_weapon_id

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
			# 本次攻击产生的损伤全部放置于同一区域（effect_101）。基于 attack.damage_placement_log 判定。
			var dtas_log: Array = payload.get("damage_placement_log", [])
			if dtas_log.size() < 1:
				return false
			var dtas_first = dtas_log[0]
			for s in dtas_log:
				if s != dtas_first:
					return false
			return true

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
			# 字段可置于 condition 顶层或 condition.params 下（历史不一致：w107/109/118/124 用 params，
			# effect_081 等用顶层）。统一两者都支持：params 优先，回退顶层。
			var _va_params: Dictionary = condition.get("params", condition)
			var variable_name: StringName = _va_params.get("variable_name", condition.get("variable_name", &""))
			var threshold: int = int(_va_params.get("threshold", condition.get("threshold", 0)))
			if variable_name == &"":
				return false
			# attack 作用域变量：存于 attack.record["variables"][name]（INCREMENT_VARIABLE scope=attack 写入），
			# attack 各时点 payload = record.duplicate()，故 payload.variables 可读。
			var va_scope: StringName = _va_params.get("scope", condition.get("scope", &""))
			if va_scope == &"attack":
				var atk_vars: Dictionary = payload.get("variables", {}) if payload != null else {}
				return int(atk_vars.get(variable_name, 0)) > threshold
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

		&"HAS_SET_TRAP_STATUS":
			# 机甲拥有设陷状态（回合末清除监听器用：binding_context.target_id = 持有设陷状态的机甲）
			var st_ctx: Dictionary = payload.get("binding_context", {})
			var st_mech_id: StringName = st_ctx.get("target_id", &"")
			if st_mech_id == &"":
				st_mech_id = binding.get_source_mech_id()
			if st_mech_id == &"" or binding.context == null or binding.context.get("game_state") == null:
				return false
			var st_mech = binding.context.game_state.mechs.get(st_mech_id)
			if st_mech == null:
				return false
			return st_mech.has_status(&"SET_TRAP")

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
			# 攻击目标优先读 attack_target_id（响应窗口注入，不被 resume 选牌目标 target_id 覆盖）
			var smi_target: StringName = payload.get("attack_target_id", payload.get("target_id", &""))
			return smi_mech_id != &"" and smi_mech_id == smi_target

		&"SELF_MECH_IS_ATTACKER":
			# 本牌所属机甲 = 攻击发起方
			var sma_mech_id: StringName = _equip_mech_id(binding, payload)
			var sma_attacker: StringName = payload.get("attacker_id", &"")
			return sma_mech_id != &"" and sma_mech_id == sma_attacker

		&"SELF_MECH_NOT_ATTACK_TARGET":
			# 本牌所属机甲 != 攻击目标（pilot_002 防御分支：被授予机师非被攻击目标）
			var snat_mech_id: StringName = _equip_mech_id(binding, payload)
			var snat_target: StringName = payload.get("attack_target_id", payload.get("target_id", &""))
			return snat_mech_id != &"" and snat_mech_id != snat_target

		&"ATTACK_NOT_RESPONDED":
			# 本次攻击尚未被任何迎击牌/装备牌/机师效果响应。
			# gather 阶段 action.record.responded 尚未写(为 false)->放行；玩家选中任一响应后
			# responded=true->后续不再列本效果(每攻击仅一次响应竞态,先响应者关闭他人窗口)。
			# 注:本条件仅用于 availability gather(set_conditions 在 _check_availability 末尾评估)；
			# 迪恩转化效果带弃牌 cost,走 response_discard 路径直跑 _execute_actions,不经 _execute_effect 复查。
			return not bool(payload.get("responded", false))

		&"ATTACK_TARGET_IN_HEX_RANGE":
			# 攻击目标在 本牌所属机甲 hex 范围内（pilot_002 防御分支：被攻击目标5格内）
			var atir_params: Dictionary = condition.get("params", condition)
			var atir_range: int = int(atir_params.get("range", condition.get("range", 5)))
			var atir_mech_id: StringName = _equip_mech_id(binding, payload)
			var atir_target: StringName = payload.get("attack_target_id", payload.get("target_id", &""))
			var atir_ctx = binding.context if binding != null else null
			if atir_mech_id == &"" or atir_target == &"" or atir_ctx == null or atir_ctx.get("game_state") == null:
				return false
			var atir_src = atir_ctx.game_state.mechs.get(atir_mech_id)
			var atir_tgt = atir_ctx.game_state.mechs.get(atir_target)
			if atir_src == null or atir_tgt == null:
				return false
			return _hex_distance(atir_src.position, atir_tgt.position) <= atir_range

		&"SELF_MECH_IS_MOVE_SUBJECT":
			# 本牌所属机甲 = 基础移动的主体（basic_move record.mech_id）
			var sms_mech_id: StringName = _equip_mech_id(binding, payload)
			var sms_subject: StringName = payload.get("mech_id", payload.get("source_mech_id", &""))
			return sms_mech_id != &"" and sms_mech_id == sms_subject

		&"ATTACK_MARKERS_ABOVE":
			# 本次攻击产生的损伤标记数 > threshold
			# threshold 可置于 condition 顶层或 condition.params 下（历史不一致），params 优先回退顶层。
			var ama_params: Dictionary = condition.get("params", condition)
			var am_threshold: int = int(ama_params.get("threshold", condition.get("threshold", 0)))
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
			# 装备牌所属机甲当前动力 >= threshold（闪回激光剑 effect_110/111 动力前置）
			# threshold 可置于 condition 顶层或 condition.params 下，params 优先回退顶层。
			var op_params: Dictionary = condition.get("params", condition)
			var op_threshold: int = int(op_params.get("threshold", condition.get("threshold", 0)))
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
			# 兼容 value / threshold 两种参数名；params 优先回退顶层。BASIC_MOVE_AFTER fire 时动力已扣除，读 mech.power。
			var ope_params: Dictionary = condition.get("params", condition)
			var ope_value: int = int(ope_params.get("value", ope_params.get("threshold", condition.get("value", condition.get("threshold", 0)))))
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

		&"ACTION_CARD_IS_NOT_COUNTER":
			# 当前 use_action_card 打出的不是迎击牌（action_type != "迎击"）。
			# pilot_001 阿克罗姆：迎击牌不可双重生效（一次攻击只能被响应一次），01a/01b 据此排除迎击。
			var nac_card_id: StringName = payload.get("card_instance_id", payload.get("card_id", &""))
			if nac_card_id == &"":
				return false
			var nac_ctx = binding.context if binding != null else null
			if nac_ctx == null or nac_ctx.get("game_state") == null:
				return false
			var nac_card = nac_ctx.game_state.get_card(nac_card_id)
			if nac_card == null or nac_card.def == null:
				return false
			var nac_at: String = String(nac_card.def.action_type) if "action_type" in nac_card.def else ""
			return nac_at != "迎击"

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


		# ════════════════════════════════════════════════════════════
		# 武器装备牌效果专用条件（effect_093+）
		# ════════════════════════════════════════════════════════════

		&"ENERGY_TARGET_IS_SELF":
			# 聚能 effect_fire 的目标武器 == 本牌（effect_093/095/114/126 聚能联动）
			# effect_fire record 由 ActionService._execute_atomic_action(APPLY_ENERGY_TO_WEAPON) 写入
			# energy_target_weapon_instance_id；EFFECT_FIRE_AFTER payload = effect_fire record.duplicate()。
			var ets_self: StringName = _equip_card_instance_id(binding, payload)
			var ets_target: StringName = payload.get("energy_target_weapon_instance_id", &"")
			return ets_self != &"" and ets_self == ets_target

		&"WEAPON_MODE_EQUALS":
			# 本武器形态 == mode（流星钢锤 effect_098/099）
			var wme_mode: StringName = condition.get("mode", &"")
			var wme_card_id: StringName = _equip_card_instance_id(binding, payload)
			var wme_card = _get_card(binding, wme_card_id)
			if wme_card == null:
				return false
			var cur_mode: StringName = wme_card.weapon_mode if "weapon_mode" in wme_card else &""
			if cur_mode == &"":
				cur_mode = &"normal"
			return cur_mode == wme_mode

		&"WEAPON_MODE_NOT_EQUALS":
			var wmn_mode: StringName = condition.get("mode", &"")
			var wmn_card_id: StringName = _equip_card_instance_id(binding, payload)
			var wmn_card = _get_card(binding, wmn_card_id)
			if wmn_card == null:
				return false
			var cur_mode_n: StringName = wmn_card.weapon_mode if "weapon_mode" in wmn_card else &""
			if cur_mode_n == &"":
				cur_mode_n = &"normal"
			return cur_mode_n != wmn_mode

		&"WEAPON_IS_ON_COOLDOWN":
			# 武器冷却中（effect_128 直攻/武器选择过滤用；effect_126 聚能清除前置）
			var wic_card_id: StringName = _equip_card_instance_id(binding, payload)
			var wic_card = _get_card(binding, wic_card_id)
			if wic_card == null:
				return false
			return _is_weapon_on_cooldown(wic_card)

		&"WEAPON_IS_LOCKED_OUT":
			# 拘束钩爪 effect_104 锁定期间本牌不能攻击（校验 LOCKED 状态存活）
			var wil_card_id: StringName = _equip_card_instance_id(binding, payload)
			var wil_card = _get_card(binding, wil_card_id)
			if wil_card == null:
				return false
			var wil_ctx = binding.context if binding != null else null
			var wil_gs = wil_ctx.game_state if wil_ctx != null else null
			return _weapon_lock_active(wil_card, wil_gs, wil_card_id)

		&"WEAPON_STATUS_ABSENT":
			# 武器无某状态（effect_113：未用 weapon_used_this_turn 才回复威力）。状态存 card.counters。
			var wsa_status: StringName = condition.get("status_type", &"")
			if wsa_status == &"":
				return false
			var wsa_card_id: StringName = _equip_card_instance_id(binding, payload)
			var wsa_card = _get_card(binding, wsa_card_id)
			if wsa_card == null:
				return true
			return not bool(wsa_card.counters.get(wsa_status, false)) if "counters" in wsa_card else true

		&"SOURCE_OWNER_IS_TURN_PLAYER":
			# 来源玩家 == 当前回合玩家（effect_113/114 回复判定）。与 IS_OWNER_TURN 同义。
			var sotp_owner: StringName = _equip_player_id(binding, payload)
			var sotp_ctx = binding.context if binding != null else null
			if sotp_owner == &"" or sotp_ctx == null or sotp_ctx.get("game_state") == null:
				return false
			return sotp_ctx.game_state.active_player_id == sotp_owner

		&"TARGET_POWER_EQUALS":
			# 目标当前动力 == value（effect_118：减动力后目标动力为0）
			# 兼容 value / threshold 两种参数名；params 优先回退顶层。
			var tpe_params: Dictionary = condition.get("params", condition)
			var tpe_value: int = int(tpe_params.get("value", tpe_params.get("threshold", condition.get("value", condition.get("threshold", 0)))))
			var tpe_target: StringName = payload.get("target_id", &"")
			var tpe_ctx = binding.context if binding != null else null
			if tpe_target == &"" or tpe_ctx == null or tpe_ctx.get("game_state") == null:
				return false
			var tpe_mech = tpe_ctx.game_state.mechs.get(tpe_target)
			if tpe_mech == null:
				return false
			return tpe_mech.power == tpe_value

		&"DAMAGE_TOKENS_NOT_ALL_IN_SAME_SLOT":
			# 本次攻击损伤未全在同一区域（effect_119：至少2枚分布≥2区）
			var dtnas_log: Array = payload.get("damage_placement_log", [])
			if dtnas_log.size() < 2:
				return false
			var distinct: Dictionary = {}
			for s in dtnas_log:
				distinct[s] = true
			return distinct.size() >= 2

		&"SELF_MECH_IS_DAMAGE_TARGET":
			# 本牌所属机甲 = 损伤目标（盾牌 effect_127/133/136）
			var smd_mech: StringName = _equip_mech_id(binding, payload)
			var smd_target: StringName = payload.get("target_mech_id", payload.get("target_id", &""))
			if smd_target == &"":
				# damage_change payload 用 mech_ids 列表
				var smd_ids: Array = payload.get("mech_ids", [])
				for mid in smd_ids:
					if String(mid) == String(smd_mech):
						return true
				return false
			return smd_mech != &"" and smd_mech == smd_target

		&"DAMAGE_SOURCE_IS_ATTACK_OR_TRAP":
			# 损伤来源是攻击或陷阱（盾牌覆盖陷阱）
			var dsr_reason: String = String(payload.get("reason", &""))
			if dsr_reason.find("attack") >= 0 or dsr_reason.find("trap") >= 0:
				return true
			# damage_change 由 attack 子动作发起时无 reason，检查 payload 是否来自 attack（有 attack_action_id）
			return payload.has("attack_action_id") or payload.get("source", {}).has("attack_action_id")

		&"DAMAGE_SOURCE_IS_TRAP":
			# 损伤来源仅为陷阱（effect_136b 陷阱专用，避免与 effect_136 攻击用双触发）
			var dst_reason: String = String(payload.get("reason", &""))
			return dst_reason.find("trap") >= 0

		&"PAYLOAD_DAMAGE_TOKENS_ABOVE":
			# 待放损伤 > threshold（盾牌：损伤>0 才弹转移）
			var pdt_threshold: int = int(condition.get("threshold", 0))
			var pdt_total: int = int(payload.get("total_points", payload.get("value", 0)))
			return pdt_total > pdt_threshold

		&"TARGET_HAS_ACTION_CARDS":
			# 目标有 ≥ minimum 张行动牌（effect_100 弃目标牌前置）
			var tac_min: int = int(condition.get("minimum", 1))
			var tac_target: StringName = payload.get("target_id", &"")
			var tac_ctx = binding.context if binding != null else null
			if tac_target == &"" or tac_ctx == null or tac_ctx.get("game_state") == null:
				return false
			var tac_player = tac_ctx.game_state.get_player_for_mech(tac_target)
			if tac_player == null:
				return false
			return tac_player.action_hand.size() >= tac_min

		&"ATTACK_COUNT_ABOVE":
			# 剩余攻击次数 > threshold（effect_128 直攻免牌：剩余>0 才可用）。
			# 剩余 = max_attacks_per_turn - attack_count_this_turn。threshold=0 即 can_attack()。
			var aca_threshold: int = int(condition.get("threshold", 0))
			var aca_mech_id: StringName = _equip_mech_id(binding, payload)
			var aca_ctx = binding.context if binding != null else null
			if aca_mech_id == &"" or aca_ctx == null or aca_ctx.get("game_state") == null:
				return false
			var aca_mech = aca_ctx.game_state.mechs.get(aca_mech_id)
			if aca_mech == null:
				return false
			if aca_threshold == 0 and aca_mech.has_method(&"can_attack"):
				return aca_mech.can_attack()
			var aca_used: int = int(aca_mech.attack_count_this_turn) if "attack_count_this_turn" in aca_mech else 0
			var aca_max: int = int(aca_mech.get("max_attacks_per_turn", 1)) if aca_mech.get("max_attacks_per_turn") != null else 1
			return (aca_max - aca_used) > aca_threshold

		&"TARGET_IS_ADJACENT":
			# 攻击目标与攻击方当前位置六边形相邻（距离1，effect_115 霰弹/爆弹/轨道炮）
			var tadj_attacker: StringName = payload.get("attacker_id", &"")
			var tadj_target: StringName = payload.get("target_id", &"")
			var tadj_ctx = binding.context if binding != null else null
			if tadj_attacker == &"" or tadj_target == &"" or tadj_ctx == null or tadj_ctx.get("game_state") == null:
				return false
			var tadj_a = tadj_ctx.game_state.mechs.get(tadj_attacker)
			var tadj_t = tadj_ctx.game_state.mechs.get(tadj_target)
			if tadj_a == null or tadj_t == null:
				return false
			return _hex_distance(tadj_a.position, tadj_t.position) == 1

		&"REPAIR_HAS_VALID_TARGET":
			# 场上自身或相邻1格存在非满状态机甲（effect_130 维修机械臂前置）
			var rht_range: int = int(condition.get("range", 1))
			var rht_mech: StringName = _equip_mech_id(binding, payload)
			var rht_ctx = binding.context if binding != null else null
			if rht_mech == &"" or rht_ctx == null or rht_ctx.get("game_state") == null:
				return false
			return _has_repair_target(rht_ctx.game_state, rht_mech, rht_range)

		&"REPAIR_BRANCH_AVAILABLE":
			# 多功能机械臂 effect_135：维修分支可用（有维修目标 + ≥1行动牌）
			var rba_ctx = binding.context if binding != null else null
			if rba_ctx == null or rba_ctx.get("game_state") == null:
				return false
			var rba_mech: StringName = _equip_mech_id(binding, payload)
			var rba_player: StringName = _equip_player_id(binding, payload)
			if rba_mech == &"":
				return false
			if not _has_repair_target(rba_ctx.game_state, rba_mech, 1):
				return false
			if rba_player != &"":
				var rba_pl = rba_ctx.game_state.players.get(rba_player)
				if rba_pl == null or rba_pl.action_hand.is_empty():
					return false
			return true

		&"MULTI_ARM_HAS_AVAILABLE_OPTION":
			# effect_135：维修分支 或 弃2抽2分支 至少一个可用
			var mao_ctx = binding.context if binding != null else null
			if mao_ctx == null or mao_ctx.get("game_state") == null:
				return false
			var mao_mech: StringName = _equip_mech_id(binding, payload)
			var mao_player: StringName = _equip_player_id(binding, payload)
			if mao_mech == &"":
				return false
			# 维修分支
			if _has_repair_target(mao_ctx.game_state, mao_mech, 1):
				if mao_player != &"":
					var mao_pl_a = mao_ctx.game_state.players.get(mao_player)
					if mao_pl_a != null and not mao_pl_a.action_hand.is_empty():
						return true
			# 弃2抽2分支
			if mao_player != &"":
				var mao_pl_b = mao_ctx.game_state.players.get(mao_player)
				if mao_pl_b != null and mao_pl_b.action_hand.size() >= 2:
					return true
			return false

		&"WEAPON_HAS_VALID_TRAP_CELL":
			# effect_134：武器范围内有可放陷阱格
			return _count_valid_trap_cells(binding, payload) >= 1

		&"WEAPON_HAS_VALID_TRAP_CELLS":
			# effect_137：武器范围内有 ≥ count 个可放陷阱格
			var wvc_count: int = int(condition.get("count", 1))
			return _count_valid_trap_cells(binding, payload) >= wvc_count

		&"WEAPON_HAS_ATTACK_OR_TRAP_OPTION":
			# 机雷 CHOOSE_ONE(攻击|设陷) 前置：攻击可用 或 可放陷阱 至少一项，否则按钮置灰
			# （避免0可选项时点了无效却标记 once_per_turn 致按钮错误禁用）
			if check_all(binding, payload, [
				{"op": &"ATTACK_COUNT_ABOVE", "params": {"threshold": 0}},
				{"op": &"WEAPON_CAN_ATTACK_AGAIN"},
				{"op": &"WEAPON_HAS_ATTACKABLE_TARGET_IN_RANGE"},
			]):
				return true
			return check_all(binding, payload, [{"op": &"WEAPON_HAS_VALID_TRAP_CELL"}])

		&"TARGET_CELL_CAN_HOLD_TRAP":
			# 选格规则：所选格子可放陷阱（无既有陷阱）
			var tct_cell: StringName = payload.get("selected_cell_id", payload.get("cell_id", &""))
			var tct_ctx = binding.context if binding != null else null
			if tct_cell == &"" or tct_ctx == null or tct_ctx.get("game_state") == null:
				return false
			return _cell_can_hold_trap(tct_ctx.game_state, tct_cell)

		&"DISCARD_PARENT_ATTACK_WEAPON_IS_SELF":
			# effect_124：随机弃牌的父攻击武器 == 本牌。payload.parent_attack_id 指向 attack，
			# 读 attack.weapon_id 与本牌比较。
			var dpas_self: StringName = _equip_card_instance_id(binding, payload)
			if dpas_self == &"":
				return false
			var dpas_ctx = binding.context if binding != null else null
			if dpas_ctx == null or dpas_ctx.get("action_registry") == null:
				return false
			var dpas_atk_id: StringName = payload.get("parent_attack_id", payload.get("attack_action_id", &""))
			if dpas_atk_id == &"":
				return false
			var dpas_atk = dpas_ctx.action_registry.get_action(dpas_atk_id)
			if dpas_atk == null:
				return false
			var dpas_wid: StringName = dpas_atk.record.get("weapon_id", &"")
			return dpas_wid == dpas_self

		# ════════════════════════════════════════════════════════════
		# 机师牌效果通用条件（SSR pilot_001-010 起多张共用）
		# ════════════════════════════════════════════════════════════

		&"SELF_MECH_ALIVE":
			# 本牌所属机甲存活（pilot_004 玛沙 / pilot_010 刻托 前置）
			var smal_mech_id: StringName = _equip_mech_id(binding, payload)
			var smal_ctx = binding.context if binding != null else null
			if smal_mech_id == &"" or smal_ctx == null or smal_ctx.get("game_state") == null:
				return false
			var smal_mech = smal_ctx.game_state.mechs.get(smal_mech_id)
			return smal_mech != null and not smal_mech.destroyed

		&"ATTACKER_ALIVE":
			# 攻击发起方机甲存活（pilot_006 里昂 悬赏抽牌前置）
			var atkalive_attacker_id: StringName = payload.get("attacker_id", &"")
			if atkalive_attacker_id == &"":
				return false
			var atkalive_ctx = binding.context if binding != null else null
			if atkalive_ctx == null or atkalive_ctx.get("game_state") == null:
				return false
			var atkalive_mech = atkalive_ctx.game_state.mechs.get(atkalive_attacker_id)
			return atkalive_mech != null and not atkalive_mech.destroyed

		&"ATTACK_HAS_TARGET":
			# 当前攻击已选定目标（pilot_007 珀修斯 effect_02 前置）
			return payload.get("target_id", &"") != &""

		&"HAS_OTHER_MECH_IN_HEX_RANGE":
			# 本牌所属机甲 hex 范围内存在其他存活机甲（pilot_002/004/006/009 用）
			# params.range 为六角距离上限；距离用 _HexGrid.distance（odd-q offset 校正）。
			var hmr_params: Dictionary = condition.get("params", condition)
			var hmr_range: int = int(hmr_params.get("range", condition.get("range", 1)))
			var hmr_mech_id: StringName = _equip_mech_id(binding, payload)
			var hmr_ctx = binding.context if binding != null else null
			if hmr_mech_id == &"" or hmr_ctx == null or hmr_ctx.get("game_state") == null:
				return false
			var hmr_src = hmr_ctx.game_state.mechs.get(hmr_mech_id)
			if hmr_src == null:
				return false
			for hmr_mid in hmr_ctx.game_state.mechs:
				if hmr_mid == hmr_mech_id:
					continue
				var hmr_m = hmr_ctx.game_state.mechs[hmr_mid]
				if hmr_m == null or hmr_m.destroyed:
					continue
				if _hex_distance(hmr_src.position, hmr_m.position) <= hmr_range:
					return true
			return false

		&"HAS_OTHER_MECH_ON_FIELD":
			# 场上存在其他存活机甲（pilot_006 里昂 轮次悬赏前置）
			var hom_mech_id: StringName = _equip_mech_id(binding, payload)
			var hom_ctx = binding.context if binding != null else null
			if hom_ctx == null or hom_ctx.get("game_state") == null:
				return false
			for hom_mid in hom_ctx.game_state.mechs:
				if hom_mid == hom_mech_id:
					continue
				var hom_m = hom_ctx.game_state.mechs[hom_mid]
				if hom_m != null and not hom_m.destroyed:
					return true
			return false

		&"HAS_ANY_MECH_ON_FIELD":
			# 场上存在任意存活机甲（含自身；pilot_002/005 toggle 目标前置）
			var ham_ctx = binding.context if binding != null else null
			if ham_ctx == null or ham_ctx.get("game_state") == null:
				return false
			for ham_mid in ham_ctx.game_state.mechs:
				var ham_m = ham_ctx.game_state.mechs[ham_mid]
				if ham_m != null and not ham_m.destroyed:
					return true
			return false

		# ════════════════════════════════════════════════════════════
		# pilot_010 刻托 effect_02 视为序列 条件
		# ════════════════════════════════════════════════════════════

		&"USED_CARD_EXECUTOR_IS_SELF":
			# use_action_card 的真正执行者机甲 == 本机师所属机甲（区分受控牌：physical owner 可能他人，executor 是刻托机甲）
			var uces_bind: Dictionary = payload.get("binding_context", {})
			var uces_mech: StringName = uces_bind.get("mech_id", &"")
			if uces_mech == &"":
				return false
			var uces_executor: StringName = payload.get("mech_id", payload.get("source_mech_id", &""))
			return uces_executor != &"" and uces_executor == uces_mech

		&"PAYLOAD_IS_PHYSICAL_ACTION_CARD":
			# use_action_card 的牌是实体行动牌（非虚拟转化/当作）。虚拟当作不计数/不视为（pilot_010 裁定歧义3）。
			return not bool(payload.get("virtual_transform", false)) and not bool(payload.get("is_virtual", false))

		&"OWNER_ATTACK_CARD_USE_INDEX_THIS_TURN_BELOW":
			# 刻托本回合已用实体攻击牌数 < max_index（仅前3张：max_index=3，uses 0/1/2 通过）。
			# 第4张(uses=3)已在 use_action_card._step_validate_card 被 can_pilot_010_use_physical_attack_card
			# 拦截(返回 error->cancel，不 fire USE_ACTION_BEFORE)，不会到此条件。读 pilot_card.counters。
			var oau_params: Dictionary = condition.get("params", condition)
			var oau_max: int = int(oau_params.get("max_index", condition.get("max_index", 3)))
			var oau_bind: Dictionary = payload.get("binding_context", {})
			var oau_card_id: StringName = oau_bind.get("card_instance_id", &"")
			var oau_ctx = binding.context if binding != null else null
			if oau_card_id == &"" or oau_ctx == null or oau_ctx.get("game_state") == null:
				return false
			var oau_pcard = oau_ctx.game_state.get_card(oau_card_id)
			if oau_pcard == null or not "counters" in oau_pcard:
				return false
			var oau_turn: int = int(oau_ctx.game_state.turn_number)
			var oau_uses: int = int(oau_pcard.counters.get("pilot_010_uses_%d" % oau_turn, 0))
			return oau_uses < oau_max

		# ════════════════════════════════════════════════════════════
		# pilot_004 玛沙 条件
		# ════════════════════════════════════════════════════════════

		&"SELF_EFFECTIVE_ARMOR_ABOVE":
			# 本牌所属机甲当前有效护甲 > threshold（pilot_004 护甲转动力前置：至少1护甲可转化）
			var sea_params: Dictionary = condition.get("params", condition)
			var sea_threshold: int = int(sea_params.get("threshold", condition.get("threshold", 0)))
			var sea_mech_id: StringName = _equip_mech_id(binding, payload)
			var sea_ctx = binding.context if binding != null else null
			if sea_mech_id == &"" or sea_ctx == null or sea_ctx.get("game_state") == null:
				return false
			var sea_mech = sea_ctx.game_state.mechs.get(sea_mech_id)
			if sea_mech == null:
				return false
			return sea_mech.get_armor() > sea_threshold

		&"SOURCE_RUNTIME_MODIFIER_EXISTS":
			# 本机师实例建立的某 runtime_tag 的临时 modifier 存在（pilot_004 effect_02 清转换层前置）
			var srm_params: Dictionary = condition.get("params", condition)
			var srm_tag: StringName = srm_params.get("tag", condition.get("tag", &""))
			if srm_tag == &"":
				return false
			var srm_mech_id: StringName = _equip_mech_id(binding, payload)
			var srm_ctx = binding.context if binding != null else null
			if srm_mech_id == &"" or srm_ctx == null or srm_ctx.get("game_state") == null:
				return false
			var srm_mech = srm_ctx.game_state.mechs.get(srm_mech_id)
			if srm_mech == null:
				return false
			for s in srm_mech.statuses:
				if String(s.get("runtime_tag", &"")) == String(srm_tag):
					return true
			return false

		# ════════════════════════════════════════════════════════════
		# pilot_005 肯特 effect_01 授予能力 条件
		# ════════════════════════════════════════════════════════════

		&"SELF_MECH_IS_ATTACKER_OR_TARGET":
			# 本牌所属机甲是当前攻击的攻击方或目标（pilot_005 帝国压制：攻击/被攻击都触发）
			var smat_mech: StringName = _equip_mech_id(binding, payload)
			var smat_attacker: StringName = payload.get("attacker_id", &"")
			var smat_target: StringName = payload.get("target_id", &"")
			return smat_mech != &"" and (smat_mech == smat_attacker or smat_mech == smat_target)

		&"OPPOSING_ATTACK_PARTICIPANT_ACTION_HAND_ABOVE":
			# 对侧参与方（攻击方->目标 / 目标->攻击方）行动手牌数 > threshold。
			# 裁定（歧义1）：手牌不足2时可发动并弃全部剩余（触发效果非成本），故 threshold=1。
			var opa_params: Dictionary = condition.get("params", condition)
			var opa_threshold: int = int(opa_params.get("threshold", condition.get("threshold", 1)))
			var opa_mech: StringName = _equip_mech_id(binding, payload)
			var opa_attacker: StringName = payload.get("attacker_id", &"")
			var opa_target: StringName = payload.get("target_id", &"")
			var opa_opposing: StringName = &""
			if opa_mech == opa_attacker:
				opa_opposing = opa_target
			elif opa_mech == opa_target:
				opa_opposing = opa_attacker
			if opa_opposing == &"":
				return false
			var opa_ctx = binding.context if binding != null else null
			if opa_ctx == null or opa_ctx.get("game_state") == null:
				return false
			var opa_player = opa_ctx.game_state.get_player_for_mech(opa_opposing)
			if opa_player == null:
				return false
			return opa_player.action_hand.size() > opa_threshold

		&"PILOT_AURA_ACTIVE_FOR_MECH":
			# 本机甲有 pilot 光环 active（pilot_005/002，未被 toggle off）。granted effect conditions 用。
			var pam_mech: StringName = _equip_mech_id(binding, payload)
			var pam_ctx = binding.context if binding != null else null
			if pam_mech == &"" or pam_ctx == null or pam_ctx.get("game_state") == null:
				return false
			return _ActionPilotEffects.is_aura_active_for_mech(pam_ctx.game_state, pam_mech)

		# ════════════════════════════════════════════════════════════
		# pilot_008 安德洛美达 条件
		# ════════════════════════════════════════════════════════════

		&"PAYLOAD_PHYSICAL_CARD_DEF_ID_IS":
			# use_action_card 打出的实体牌 def_id == 指定（pilot_008 回收维修：action_012_维修）
			var pcd_params: Dictionary = condition.get("params", condition)
			var pcd_def_id: StringName = pcd_params.get("card_def_id", condition.get("card_def_id", &""))
			var pcd_card_id: StringName = payload.get("card_instance_id", payload.get("card_id", &""))
			var pcd_ctx = binding.context if binding != null else null
			if pcd_card_id == &"" or pcd_ctx == null or pcd_ctx.get("game_state") == null:
				return false
			var pcd_card = pcd_ctx.game_state.get_card(pcd_card_id)
			if pcd_card == null or pcd_card.def == null:
				return false
			return String(pcd_card.def.card_id) == String(pcd_def_id)

		&"DISCARD_CONTAINS_CARD_DEF_ID":
			# 本次弃置动作中含指定 def_id 的牌（pilot_008 回收弃置的维修）。
			# 查 payload.discard_snapshots（本次弃的牌快照，含 def_id），限定为本次弃置，
			# 避免弃牌堆里跨回合残留的维修被无关弃牌误触发回收。
			var dcd_params: Dictionary = condition.get("params", condition)
			var dcd_def_id: StringName = dcd_params.get("card_def_id", condition.get("card_def_id", &""))
			var dcd_snapshots: Array = payload.get("discard_snapshots", [])
			for snap in dcd_snapshots:
				if snap is Dictionary and String(snap.get("def_id", &"")) == String(dcd_def_id):
					return true
			return false

		&"SOURCE_CARD_INSTANCE_CAN_BE_GAINED":
			# 源牌可获得（简化：true，GAIN_SPECIFIC_CARD 内部验证）
			return true

		&"HP_CHANGE_METHOD_IS":
			var hcm_params: Dictionary = condition.get("params", condition)
			var hcm_method: StringName = hcm_params.get("method", condition.get("method", &""))
			return String(payload.get("method", &"")) == String(hcm_method)

		&"DAMAGE_CHANGE_METHOD_IS":
			var dcm_params: Dictionary = condition.get("params", condition)
			var dcm_method: StringName = dcm_params.get("method", condition.get("method", &""))
			return String(payload.get("method", &"")) == String(dcm_method)

		&"HP_CHANGE_AMOUNT_ABOVE":
			var ha_params: Dictionary = condition.get("params", condition)
			var ha_threshold: int = int(ha_params.get("threshold", condition.get("threshold", 0)))
			return int(payload.get("amount", payload.get("value", 0))) > ha_threshold

		&"DAMAGE_CHANGE_AMOUNT_ABOVE":
			var da_params: Dictionary = condition.get("params", condition)
			var da_threshold: int = int(da_params.get("threshold", condition.get("threshold", 0)))
			return int(payload.get("amount", payload.get("value", payload.get("total_points", 0)))) > da_threshold

		&"HP_CHANGE_ACTUAL_RESTORE_ABOVE":
			# 实际可回复量 = mini(value, max_hp - current_hp) > threshold（满血时回复0不触发逆转）
			var arh_params: Dictionary = condition.get("params", condition)
			var arh_threshold: int = int(arh_params.get("threshold", condition.get("threshold", 0)))
			var arh_value: int = int(payload.get("value", payload.get("amount", 0)))
			var arh_ctx = binding.context if binding != null else null
			if arh_ctx == null or arh_ctx.get("game_state") == null:
				return false
			var arh_target: StringName = StringName(payload.get("target_id", payload.get("target_mech_id", &"")))
			if arh_target == &"":
				var arh_mids: Array = payload.get("mech_ids", [])
				if not arh_mids.is_empty():
					arh_target = StringName(arh_mids[0])
			var arh_mech = arh_ctx.game_state.mechs.get(arh_target)
			if arh_mech == null:
				return false
			var arh_actual: int = mini(arh_value, maxi(0, arh_mech.max_hp - arh_mech.current_hp))
			return arh_actual > arh_threshold

		&"DAMAGE_CHANGE_ACTUAL_REMOVABLE_ABOVE":
			# 实际可移除损伤 = mini(value, 机甲现有损伤总数) > threshold（无损伤时不触发逆转）
			var ard_params: Dictionary = condition.get("params", condition)
			var ard_threshold: int = int(ard_params.get("threshold", condition.get("threshold", 0)))
			var ard_value: int = int(payload.get("value", payload.get("amount", payload.get("total_points", 0))))
			var ard_ctx = binding.context if binding != null else null
			if ard_ctx == null or ard_ctx.get("game_state") == null:
				return false
			var ard_target: StringName = StringName(payload.get("target_id", payload.get("target_mech_id", &"")))
			if ard_target == &"":
				var ard_mids: Array = payload.get("mech_ids", [])
				if not ard_mids.is_empty():
					ard_target = StringName(ard_mids[0])
			var ard_mech = ard_ctx.game_state.mechs.get(ard_target)
			if ard_mech == null:
				return false
			var ard_actual: int = mini(ard_value, ard_mech.get_damage_token_count())
			return ard_actual > ard_threshold

		&"PAYLOAD_TARGET_IN_VARIABLE_HEX_RANGE":
			# 目标在 base_range + X 格内（X = pilot_008 card.counters var_X）
			var ptv_params: Dictionary = condition.get("params", condition)
			var ptv_base: int = int(ptv_params.get("base_range", condition.get("base_range", 5)))
			var ptv_bind: Dictionary = payload.get("binding_context", {})
			var ptv_card_id: StringName = ptv_bind.get("card_instance_id", &"")
			var ptv_ctx = binding.context if binding != null else null
			var ptv_x: int = 0
			if ptv_card_id != &"" and ptv_ctx != null and ptv_ctx.get("game_state") != null:
				var ptv_card = ptv_ctx.game_state.get_card(ptv_card_id)
				ptv_x = _ActionPilotEffects.get_pilot_008_x(ptv_card)
			var ptv_range: int = ptv_base + ptv_x
			var ptv_source: StringName = ptv_bind.get("mech_id", &"")
			var ptv_target: StringName = StringName(payload.get("target_id", payload.get("target_mech_id", &"")))
			# hp_change/damage_change 用 mech_ids（无 target_id/target_mech_id），回退到 mech_ids[0]
			if ptv_target == &"":
				var ptv_mids: Array = payload.get("mech_ids", [])
				if not ptv_mids.is_empty():
					ptv_target = StringName(ptv_mids[0])
			if ptv_source == &"" or ptv_target == &"" or ptv_ctx == null or ptv_ctx.get("game_state") == null:
				return false
			var ptv_src = ptv_ctx.game_state.mechs.get(ptv_source)
			var ptv_tgt = ptv_ctx.game_state.mechs.get(ptv_target)
			if ptv_src == null or ptv_tgt == null:
				return false
			return _hex_distance(ptv_src.position, ptv_tgt.position) <= ptv_range

		# ════════════════════════════════════════════════════════════
		# pilot_006 里昂 条件
		# ════════════════════════════════════════════════════════════

		&"ATTACK_TARGET_HAS_SOURCE_MARK":
			# 当前攻击目标 == 本里昂实例的本轮悬赏标记目标
			var atsm_bind: Dictionary = payload.get("binding_context", {})
			var atsm_source: StringName = atsm_bind.get("card_instance_id", &"")
			var atsm_target: StringName = payload.get("target_id", &"")
			if atsm_source == &"" or atsm_target == &"":
				return false
			return _ActionPilotEffects.get_pilot_006_mark(atsm_source) == atsm_target

		# ════════════════════════════════════════════════════════════
		# pilot_007 珀修斯 条件
		# ════════════════════════════════════════════════════════════

		&"ATTACK_SOURCE_IS_PHYSICAL_ACTION_CARD":
			# 攻击来源是实体攻击行动牌（非虚拟当作/飞弹）。裁定：当作转化/飞弹不触发 effect_01。
			var asp_card_id: StringName = payload.get("attack_card_id", payload.get("card_instance_id", &""))
			if asp_card_id == &"":
				return false
			var asp_ctx = binding.context if binding != null else null
			if asp_ctx == null or asp_ctx.get("game_state") == null:
				return false
			var asp_card = asp_ctx.game_state.get_card(asp_card_id)
			if asp_card == null or asp_card.def == null:
				return false
			return asp_card.def.card_kind == &"action"

		&"ATTACK_SOURCE_ACTION_CARD_TYPE_IS":
			var ast_params: Dictionary = condition.get("params", condition)
			var ast_type: StringName = ast_params.get("card_type", condition.get("card_type", &""))
			var ast_card_id: StringName = payload.get("attack_card_id", payload.get("card_instance_id", &""))
			var ast_ctx = binding.context if binding != null else null
			if ast_card_id == &"" or ast_ctx == null or ast_ctx.get("game_state") == null:
				return false
			var ast_card = ast_ctx.game_state.get_card(ast_card_id)
			if ast_card == null or ast_card.def == null:
				return false
			return String(ast_card.def.action_type) == String(ast_type)

		&"ATTACK_SOURCE_CARD_CAN_BE_CLAIMED":
			# 攻击来源牌可获得（简化：true，CLAIM 内部验证）
			return true

		&"USED_ATTACK_TARGETED_SELF":
			# pilot_007 effect_01：使用攻击牌的目标 = 本机甲（珀修斯）。
			# payload 为父 use_action_card 的 USE_ACTION_SETTLE（=use_action_card.record），
			# attack_target_id 由 attack 子动作选定目标后回写到父 record（attack_action._propagate_targets_to_parent_use_action）。
			var uats_mech: StringName = _equip_mech_id(binding, payload)
			var uats_target: StringName = payload.get("attack_target_id", payload.get("target_id", &""))
			return uats_mech != &"" and uats_target != &"" and uats_mech == uats_target

		&"PILOT_007_CLAIMED_CARD_USABLE":
			# pilot_007 effect_01「立即使用此牌」选项条件：机甲可攻击 + 至少一把武器射程内有目标。
			# 此时回收牌仍在弃牌堆（CHOOSE_ONE 选定后 branch 内才 CLAIM），故不校验手牌；
			# 攻击牌属性已由 effect set_conditions（实体攻击牌+类型=攻击）保证。
			var pcu_ctx = binding.context if binding != null else null
			if pcu_ctx == null or pcu_ctx.get("game_state") == null:
				return false
			var pcu_mech_id: StringName = _equip_mech_id(binding, payload)
			if pcu_mech_id == &"":
				return false
			var pcu_mech = pcu_ctx.game_state.mechs.get(pcu_mech_id)
			if pcu_mech == null or pcu_mech.destroyed or pcu_mech.has_status(&"cannot_attack"):
				return false
			# 至少一把武器射程内有可攻击目标（与 MECH_HAS_USABLE_ATTACK_CARD 同口径）
			var pcu_cells: Dictionary = pcu_ctx.game_state.map_state.cells if pcu_ctx.game_state.map_state else {}
			for wid in pcu_mech.get_weapon_ids():
				var pcu_rv: int = 0
				var pcu_wid_str := String(wid)
				if pcu_wid_str.begins_with("frame_base_weapon_"):
					var pcu_si: int = pcu_wid_str.trim_prefix("frame_base_weapon_").to_int() - 1
					var pcu_bw: Dictionary = pcu_mech.get_base_weapon(pcu_si)
					if not pcu_bw.is_empty():
						pcu_rv = int(pcu_bw.get("range_value", 1))
				else:
					var pcu_wc = pcu_ctx.game_state.get_card(wid)
					if pcu_wc != null and pcu_wc.def != null and "range_value" in pcu_wc.def:
						pcu_rv = int(pcu_wc.def.range_value)
				if pcu_rv <= 0:
					continue
				for pcu_mid in pcu_ctx.game_state.mechs:
					if pcu_mid == pcu_mech_id:
						continue
					var pcu_m = pcu_ctx.game_state.mechs[pcu_mid]
					if pcu_m == null or pcu_m.destroyed:
						continue
					if _RangeCalculator.is_in_weapon_range(pcu_mech.position, pcu_m.position, pcu_rv, pcu_cells):
						return true
			return false

		# ════════════════════════════════════════════════════════════
		# pilot_009 美杜莎 条件
		# ════════════════════════════════════════════════════════════

		&"HAS_ACTION_CARD_TYPE_IN_HAND":
			# 持有者手牌有指定类型的行动牌（pilot_009 类型支付前置）
			var hath_params: Dictionary = condition.get("params", condition)
			var hath_type: StringName = hath_params.get("card_type", condition.get("card_type", &""))
			var hath_ctx = binding.context if binding != null else null
			var hath_pid: StringName = _equip_player_id(binding, payload)
			if hath_type == &"" or hath_ctx == null or hath_ctx.get("game_state") == null:
				return false
			var hath_player = hath_ctx.game_state.players.get(hath_pid)
			if hath_player == null:
				return false
			for cid in hath_player.action_hand:
				var c = hath_ctx.game_state.get_card(cid)
				if c != null and c.def != null and String(c.def.action_type) == String(hath_type):
					return true
			return false

		&"MECH_HAS_USABLE_ATTACK_CARD":
			# 被选机甲(payload.target_id)有可用攻击牌（pilot_006 e3 战后逼迫二选一置灰条件）。
			# 条件：手牌有真实攻击牌（虚拟转化不算）+ 不能攻击状态(destroyed/cannot_attack)为false +
			# 至少一把武器的射程内有可攻击目标（范围没目标则攻击牌不可用，置灰）。
			var muac_ctx = binding.context if binding != null else null
			if muac_ctx == null or muac_ctx.get("game_state") == null:
				return false
			var muac_target: StringName = payload.get("target_id", payload.get("target_mech_id", &""))
			if muac_target == &"":
				return false
			var muac_mech = muac_ctx.game_state.mechs.get(muac_target)
			if muac_mech == null or muac_mech.destroyed or muac_mech.has_status(&"cannot_attack"):
				return false
			var muac_player = muac_ctx.game_state.get_player_for_mech(muac_target)
			if muac_player == null:
				return false
			var muac_has_attack_card := false
			for cid in muac_player.action_hand:
				var muac_c = muac_ctx.game_state.get_card(cid)
				if muac_c != null and muac_c.def != null and String(muac_c.def.action_type) == "攻击":
					muac_has_attack_card = true
					break
			if not muac_has_attack_card:
				return false
			# 至少一把武器的射程内有可攻击目标（否则攻击牌不可用，置灰）
			var muac_cells: Dictionary = muac_ctx.game_state.map_state.cells if muac_ctx.game_state.map_state else {}
			for wid in muac_mech.get_weapon_ids():
				var muac_rv: int = 0
				var muac_wid_str := String(wid)
				if muac_wid_str.begins_with("frame_base_weapon_"):
					var muac_si: int = muac_wid_str.trim_prefix("frame_base_weapon_").to_int() - 1
					var muac_bw: Dictionary = muac_mech.get_base_weapon(muac_si)
					if not muac_bw.is_empty():
						muac_rv = int(muac_bw.get("range_value", 1))
				else:
					var muac_wc = muac_ctx.game_state.get_card(wid)
					if muac_wc != null and muac_wc.def != null and "range_value" in muac_wc.def:
						muac_rv = int(muac_wc.def.range_value)
				if muac_rv <= 0:
					continue
				for muac_mid in muac_ctx.game_state.mechs:
					if muac_mid == muac_target:
						continue
					var muac_m = muac_ctx.game_state.mechs[muac_mid]
					if muac_m == null or muac_m.destroyed:
						continue
					if _RangeCalculator.is_in_weapon_range(muac_mech.position, muac_m.position, muac_rv, muac_cells):
						return true
			return false

		&"PILOT_002_HAS_USABLE_BATCH":
			# binding_context.batch_id 对应批次未使用未破裂且 named_type 匹配（pilot_002 批次使用按钮条件）
			# 破裂检测：批次牌任一离开目标手牌则批次破裂（条件 false）
			var phub_params: Dictionary = condition.get("params", condition)
			var phub_named: StringName = phub_params.get("named_type", &"")
			var phub_bind: Dictionary = payload.get("binding_context", {}) if payload != null else {}
			var phub_batch_id: String = String(phub_bind.get("batch_id", ""))
			if phub_batch_id == "":
				# 也检查 payload 运行时（防御链内 GRANT_BATCH 后立即 USE_BATCH）
				phub_batch_id = String(payload.get("pilot_002_current_batch_id", "")) if payload != null else ""
			if phub_batch_id == "":
				return false
			var phub_batch: Dictionary = ActionPilotEffects.get_pilot_002_batch(phub_batch_id)
			if phub_batch.is_empty():
				return false
			if bool(phub_batch.get("used", false)) or bool(phub_batch.get("broken", false)):
				return false
			if phub_named != &"" and String(phub_batch.get("named_type", &"")) != String(phub_named):
				return false
			# 破裂检测：批次牌仍在目标手牌
			var phub_ctx = binding.context if binding != null else null
			if phub_ctx != null and phub_ctx.get("game_state") != null:
				var phub_tm: StringName = phub_batch.get("target_mech", &"")
				var phub_tp = phub_ctx.game_state.get_player_for_mech(phub_tm)
				if phub_tp != null:
					for phub_cid in phub_batch.get("card_ids", []):
						if not phub_tp.action_hand.has(phub_cid):
							return false
			return true

		# ════════════════════════════════════════════════════════════
		# pilot_001 阿克罗姆 条件
		# ════════════════════════════════════════════════════════════

		&"PAYLOAD_EFFECT_CHAIN_COMPLETED":
			# 第1次效果链已完成（取消/中断未生效则 false）
			return payload.get("effect_chain_completed", false) == true

		&"PAYLOAD_REPEAT_DEPTH_BELOW":
			# 防止复制链递归（repeat_depth < max_depth）
			var prd_params: Dictionary = condition.get("params", condition)
			var prd_max: int = int(prd_params.get("max_depth", condition.get("max_depth", 1)))
			return int(payload.get("repeat_depth", 0)) < prd_max

		# ════════════════════════════════════════════════════════════
		# SR 机师牌 011/012/013 通用条件
		# ════════════════════════════════════════════════════════════

		&"ATTACK_HAS_OTHER_MECH_TARGET":
			# pilot_012/013：当前攻击至少有1个非攻击者自身的机甲目标；陷阱标记不算机甲。
			# 收集 target_id + target_ids，过滤掉不存在于 mechs 的（陷阱标记/无效 id），排除攻击者。
			var ahot_params: Dictionary = condition.get("params", condition)
			var ahot_exclude_attacker: bool = bool(ahot_params.get("exclude_attacker", condition.get("exclude_attacker", true)))
			var ahot_targets: Array = _collect_attack_mech_targets(binding, payload, ahot_exclude_attacker)
			return not ahot_targets.is_empty()

		&"ATTACK_HAS_ADJACENT_OTHER_MECH_TARGET":
			# pilot_011 effect_02：当前攻击至少有1个机甲目标与迪恩相邻、非迪恩自身、
			# 且未被攻击者锁定（锁定转移封锁，见 Phase 0 锁定改动）。
			var haot_self: StringName = _equip_mech_id(binding, payload)
			var haot_ctx = binding.context if binding != null else null
			if haot_self == &"" or haot_ctx == null or haot_ctx.get("game_state") == null:
				return false
			var haot_gs = haot_ctx.game_state
			var haot_attacker_id: StringName = payload.get("attacker_id", &"")
			var haot_attacker_player = haot_gs.get_player_for_mech(haot_attacker_id) if haot_attacker_id != &"" else null
			var haot_attacker_pid: StringName = haot_attacker_player.player_id if haot_attacker_player != null else &""
			var haot_self_mech = haot_gs.mechs.get(haot_self)
			if haot_self_mech == null:
				return false
			var haot_targets: Array = _collect_attack_mech_targets(binding, payload, true)
			for haot_tid in haot_targets:
				if StringName(haot_tid) == haot_self:
					continue  # 排除迪恩自身
				var haot_tm = haot_gs.mechs.get(StringName(haot_tid))
				if haot_tm == null:
					continue
				if _hex_distance(haot_self_mech.position, haot_tm.position) != 1:
					continue  # 不相邻
				# 锁定转移封锁：被攻击者锁定的目标不可转移保护
				if haot_attacker_pid != &"" and haot_tm.is_locked_by(haot_attacker_pid):
					continue
				return true  # 找到1台可保护的相邻机甲目标
			return false

		&"SELF_MECH_IN_CURRENT_ATTACK_RANGE":
			# pilot_011 effect_02：迪恩处于本次攻击当前武器的有效范围内（武器的 BFS 攻击范围，非单纯六角距离）。
			var smr_self: StringName = _equip_mech_id(binding, payload)
			var smr_ctx = binding.context if binding != null else null
			if smr_self == &"" or smr_ctx == null or smr_ctx.get("game_state") == null:
				return false
			var smr_gs = smr_ctx.game_state
			var smr_attacker_id: StringName = payload.get("attacker_id", &"")
			var smr_attacker = smr_gs.mechs.get(smr_attacker_id)
			var smr_self_mech = smr_gs.mechs.get(smr_self)
			if smr_attacker == null or smr_self_mech == null:
				return false
			# 武器范围：优先从攻击动作 record 取（weapon_range + extra_range），回退 payload。
			# 响应窗口 nc_payload 不含 weapon_range，故须按 attack_action_id 查攻击动作 record。
			var smr_range: int = -1
			var smr_attack_id: StringName = payload.get("attack_action_id", payload.get("action_id", &""))
			if smr_attack_id != &"" and smr_ctx.get("action_registry") != null:
				var smr_attack = smr_ctx.action_registry.get_action(smr_attack_id)
				if smr_attack != null and smr_attack.record is Dictionary:
					smr_range = int(smr_attack.record.get("weapon_range", -1)) + int(smr_attack.record.get("extra_range", 0))
			if smr_range < 0:
				smr_range = int(payload.get("weapon_range", 1)) + int(payload.get("extra_range", 0))
			smr_range = max(1, smr_range)
			var smr_map: Dictionary = smr_gs.map_state.cells if smr_gs.map_state else {}
			return _RangeCalculator.is_in_weapon_range(smr_attacker.position, smr_self_mech.position, smr_range, smr_map)

		&"ATTACKER_IS_NOT_SELF_MECH":
			# pilot_011 effect_02：攻击来源不是迪恩自身（防止迪恩自己攻击友军时误触发转移给自己=自身攻击自身）。
			var ains_self: StringName = _equip_mech_id(binding, payload)
			var ains_attacker: StringName = payload.get("attacker_id", &"")
			return ains_self != &"" and ains_attacker != &"" and ains_self != ains_attacker

		&"TARGET_HAS_ACTION_CARD":
			# pilot_012：动态 target_id 路径（$current_target.mech_id）的机甲持有 >= count 张行动牌。
			var thac_p: Dictionary = condition.get("params", condition)
			var thac_count: int = int(thac_p.get("count", condition.get("count", 1)))
			var thac_target_expr = thac_p.get("target_id", condition.get("target_id", &""))
			var thac_target: StringName = _resolve_checker_expr(thac_target_expr, binding, payload)
			if thac_target == &"":
				return false
			var thac_ctx = binding.context if binding != null else null
			if thac_ctx == null or thac_ctx.get("game_state") == null:
				return false
			var thac_player = thac_ctx.game_state.get_player_for_mech(thac_target)
			if thac_player == null:
				return false
			return thac_player.action_hand.size() >= thac_count

		&"RECORDED_AFFECTED_ATTACK_TARGET_HAS_HIT":
			# pilot_012/013 effect_02：effect_01 已发动(flag) 且本次攻击命中目标中至少1台受影响。
			# flag 由 e01 SET_ACTION_RECORD_FLAG 写入 attack.record["_effect_flags"][flag]；
			# fork 深拷贝 record 故 flag 继承到各复制攻击，使双连每个 fork AFTER 都能判定。
			# 无 flag = e01 未发动（玩家选不发动 / 条件未满足）-> e02 跳过。
			# （旧 requires_effect 查同 action_id，fork 子动作 id 不同致双连 e02 失效，改靠 flag。）
			var rah_p: Dictionary = condition.get("params", condition)
			var rah_flag: StringName = rah_p.get("flag", &"")
			if rah_flag != &"":
				var rah_flags: Dictionary = payload.get("_effect_flags", {})
				var rah_entry: Dictionary = rah_flags.get(rah_flag, {})
				if not bool(rah_entry.get("value", false)):
					return false  # effect_01 未发动
			# e01 影响全部机甲目标（FOR_EACH_TARGET over ALL_CURRENT_ATTACK_MECH_TARGETS），
			# 故 affected == 全部机甲目标，命中目标即受影响目标。单目标读 payload.hit；双连读 hit_by_target。
			var rah_targets: Array = _collect_attack_mech_targets(binding, payload, true)
			if rah_targets.is_empty():
				return false
			var rah_hit_by: Dictionary = payload.get("hit_by_target", {})
			if not rah_hit_by.is_empty():
				for mid in rah_targets:
					if bool(rah_hit_by.get(mid, false)):
						return true
				return false
			# 单目标回退
			return payload.get("hit", false) == true

		&"HP_CHANGE_TARGET_IS_SELF":
			# pilot_013 effect_01：生命变动目标包含本机师所属机甲（支持多目标 hp_change 的 mech_ids）。
			var hcs_self: StringName = _equip_mech_id(binding, payload)
			if hcs_self == &"":
				return false
			var hcs_mech_ids: Array = payload.get("mech_ids", [])
			if hcs_mech_ids.is_empty():
				var hcs_single: StringName = payload.get("target_id", payload.get("target_mech_id", &""))
				return hcs_single == hcs_self
			for mid in hcs_mech_ids:
				if String(mid) == String(hcs_self):
					return true
			return false

		&"HP_CHANGE_REASON_IS_NOT_ATTACK_DAMAGE":
			# pilot_013 effect_01：生命减少来源不是攻击动作步骤7产生的伤害。
			# 权威：核对 root_attack_id + created_by_attack_damage_step，非只看 reason 文本（防伪造）。
			# 最小闭环：当前攻击步骤7发起的 hp_change reason=&"attack_damage"；effect 伤害/陷阱/事件用其他 reason。
			# created_by_attack_damage_step 标记由 attack._step_apply_damage 写入（若存在则权威判定为攻击伤害）。
			if bool(payload.get("created_by_attack_damage_step", false)):
				return false  # 来自攻击步骤7 -> 是攻击伤害 -> 不免疫
			var hcr_reason: String = String(payload.get("reason", &""))
			# attack_damage / attack_damage_tokens 是攻击产生的伤害/损伤变动 reason
			if hcr_reason == "attack_damage":
				return false
			return true

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
		var opid: StringName = binding.get_owner_player_id()
		if opid != &"":
			return opid
		# 退路：从来源机甲反查所属玩家（商店购买装备历史遗留未设 owner_player_id 的兜底，
		# 否则 MULTI_ARM 等条件因 player_id 空误判分支不可用，致触发按钮禁用）。
		var ep_ctx = binding.context
		if ep_ctx != null and ep_ctx.get("game_state") != null:
			var mid: StringName = _equip_mech_id(binding, payload)
			if mid != &"":
				var mech = ep_ctx.game_state.mechs.get(mid)
				if mech != null:
					return mech.owner_player_id
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


# ════════════════════════════════════════════════════════════
# 武器装备牌效果专用 helper（effect_093+）
# ════════════════════════════════════════════════════════════

## 取卡牌实例（从 game_state.get_card）
static func _get_card(binding, card_id: StringName):
	if card_id == &"" or binding == null or binding.context == null:
		return null
	var gs = binding.context.get("game_state")
	if gs == null:
		return null
	return gs.get_card(card_id)


## 武器是否处于冷却（effect_125/126）。冷却标记存 card.counters["cooldown_active"]。
static func _is_weapon_on_cooldown(card) -> bool:
	if card == null or not "counters" in card:
		return false
	return bool(card.counters.get("cooldown_active", false))


## 拘束钩爪 effect_104：武器是否处于锁定禁攻状态。
## 以目标身上 source_card_id=本武器 的 LOCKED 状态为权威；lock_target_mech_id 仅为缓存。
## 状态已被移除（命中解除/弃置解除）或目标离场时，清缓存并返回 false（恢复可攻击）。
static func _weapon_lock_active(card, gs, card_id: StringName) -> bool:
	if card == null:
		return false
	if gs == null:
		# 无 GameState 可查证，退回 cache 判断（保守认为仍锁）
		var cached: StringName = card.lock_target_mech_id if "lock_target_mech_id" in card else &""
		return cached != &""
	var card_id_str := String(card_id)
	# 扫描所有机甲：任意机甲上有 source=本武器的 LOCKED 状态即视为武器被锁定。
	# 双连等多锁场景：cache 只记最后1个目标，先清后者会误判解锁，故以全扫描为权威。
	var found_mech_id: StringName = &""
	for mech_id in gs.mechs:
		var m = gs.mechs[mech_id]
		if m == null:
			continue
		for s in m.statuses:
			if String(s.get("type", &"")) == "LOCKED" and String(s.get("source_card_id", &"")) == card_id_str:
				found_mech_id = mech_id
				break
		if found_mech_id != &"":
			break
	# 更新 cache（供 remove_locked_status_by_source_card 等用），无锁定则清空
	if "lock_target_mech_id" in card:
		card.lock_target_mech_id = found_mech_id
	return found_mech_id != &""


## 六边形轴向距离（pos = {q, r}）
## 六边形距离。本项目(q,r)实为 odd-q offset 伪装成 axial（见 hex_grid.gd），
## 故必须走 _HexGrid.distance（odd-q->cube），旧 axial 公式会对奇偶列给出错误距离。
static func _hex_distance(a: Dictionary, b: Dictionary) -> int:
	return _HexGrid.distance(a, b)


## 是否存在合法维修目标：自身或相邻 range 格内、非满状态机甲
static func _has_repair_target(gs, mech_id: StringName, range: int) -> bool:
	if gs == null or not gs.mechs.has(mech_id):
		return false
	var src = gs.mechs[mech_id]
	# 自身非满状态
	if src.current_hp < src.max_hp:
		return true
	# 检查是否有损伤（区域/装备牌）
	if _mech_has_damage(src):
		return true
	# 相邻机甲
	for mid in gs.mechs:
		if mid == mech_id:
			continue
		var m = gs.mechs[mid]
		if m == null or m.destroyed:
			continue
		if _hex_distance(src.position, m.position) <= range:
			if m.current_hp < m.max_hp or _mech_has_damage(m):
				return true
	return false


static func _mech_has_damage(mech) -> bool:
	if mech == null:
		return false
	for sid in mech.slots:
		var slot = mech.slots[sid]
		if slot == null:
			continue
		if int(slot.region_damage_tokens) > 0:
			return true
		if slot.equipped_card != null and int(slot.equipped_card.damage_tokens) > 0:
			return true
	return false


## 格子是否可放陷阱（非不可通行地形、无机甲占据、无既有陷阱标记）
static func _cell_can_hold_trap(gs, cell_id: StringName) -> bool:
	if gs == null or gs.map_state == null:
		return false
	if not gs.map_state.cells.has(cell_id):
		return false
	var cell = gs.map_state.cells[cell_id]
	if cell == null:
		return false
	# 不可通行地形(RED)不可放陷阱
	if String(cell.terrain) == &"RED":
		return false
	var parts := String(cell_id).split(",")
	var q := int(parts[0])
	var r := int(parts[1])
	# 有机甲占据的格子不可放陷阱（机甲与标记不能共存）
	for m_id in gs.mechs:
		var m = gs.mechs[m_id]
		if m == null or m.destroyed:
			continue
		if int(m.position.get("q", 0)) == q and int(m.position.get("r", 0)) == r:
			return false
	# 已有陷阱标记的格子不可叠加
	for m in gs.map_state.get_markers_at(q, r):
		if m.get("type", &"") == &"TRAP":
			return false
	return true


## 统计武器有效范围内可放陷阱的格子数（effect_134/137 前置）
static func _count_valid_trap_cells(binding, payload: Dictionary) -> int:
	var ctc_card_id: StringName = _equip_card_instance_id(binding, payload)
	var ctc_mech_id: StringName = _equip_mech_id(binding, payload)
	var ctc_ctx = binding.context if binding != null else null
	if ctc_card_id == &"" or ctc_mech_id == &"" or ctc_ctx == null or ctc_ctx.get("game_state") == null:
		return 0
	return get_valid_trap_cells(ctc_ctx.game_state, ctc_card_id, ctc_mech_id).size()


## 返回武器有效范围内可放陷阱的格子列表（供 CHOOSE_MAP_CELL 选格 UI 高亮+点击）
## 每项: {q, r, cell_id}
static func get_valid_trap_cells(gs, card_id: StringName, mech_id: StringName) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if gs == null or gs.map_state == null:
		return result
	var card = gs.get_card(card_id)
	if card == null:
		return result
	var mech = gs.mechs.get(mech_id)
	if mech == null:
		return result
	var stats: Dictionary = _GenEquipEffects.get_effective_weapon_stats(card)
	var range: int = max(1, int(stats.get("range_value", 1)))
	for cell_id in gs.map_state.cells:
		var cell = gs.map_state.cells[cell_id]
		if cell == null:
			continue
		var cell_pos: Dictionary = {"q": int(cell.q), "r": int(cell.r)}
		if _RangeCalculator.is_in_weapon_range(mech.position, cell_pos, range, gs.map_state.cells):
			if _cell_can_hold_trap(gs, cell_id):
				result.append({"q": int(cell.q), "r": int(cell.r), "cell_id": String(cell_id)})
	return result


# ════════════════════════════════════════════════════════════
# SR 机师牌 011/012/013 helper
# ════════════════════════════════════════════════════════════

## 收集当前攻击的机甲目标（排除陷阱标记/无效 id；可选排除攻击者自身）。
## target_id（单目标）+ target_ids（双连等多目标）合并去重；仅保留 game_state.mechs 中存活的机甲。
## 陷阱标记不在 mechs 字典中，自然被过滤。
static func _collect_attack_mech_targets(binding, payload: Dictionary, exclude_attacker: bool) -> Array:
	var ctx = binding.context if binding != null else null
	var gs = ctx.game_state if (ctx != null and ctx.get("game_state") != null) else null
	var attacker_id: StringName = payload.get("attacker_id", &"")
	var seen: Dictionary = {}
	var result: Array = []
	var _add := func(mid):
		var mid_sn: StringName = StringName(mid) if mid != null else &""
		if mid_sn == &"":
			return
		if seen.has(mid_sn):
			return
		seen[mid_sn] = true
		if gs != null:
			var m = gs.mechs.get(mid_sn)
			if m == null or m.destroyed:
				return  # 非存活机甲（陷阱标记/已毁）
		if exclude_attacker and mid_sn == attacker_id:
			return
		result.append(mid_sn)
	_add.call(payload.get("target_id", &""))
	for etid in payload.get("target_ids", []):
		_add.call(etid)
	return result


## 解析条件参数中的机甲 id 表达式（$current_target.mech_id / $payload.xxx / $binding_context.xxx / 字面值）。
## 供 TARGET_HAS_ACTION_CARD 等动态 target_id 条件用。
static func _resolve_checker_expr(expr, binding, payload: Dictionary) -> StringName:
	if expr == null:
		return &""
	if typeof(expr) == TYPE_STRING_NAME:
		return expr
	if typeof(expr) != TYPE_STRING:
		return StringName(str(expr))
	var s: String = String(expr)
	if s == "":
		return &""
	if s.begins_with("$current_target."):
		var ct: Dictionary = payload.get("current_target", {})
		return ct.get(s.substr(16), &"")
	if s.begins_with("$payload."):
		return payload.get(s.substr(9), &"")
	if s.begins_with("$binding_context."):
		var bc: Dictionary = payload.get("binding_context", {})
		return bc.get(s.substr(17), &"")
	return StringName(s)


## 取当前攻击的全部机甲目标（供 TargetChecker 自动收集目标规则复用）。
static func collect_attack_mech_targets(binding, payload: Dictionary, exclude_attacker: bool) -> Array:
	return _collect_attack_mech_targets(binding, payload, exclude_attacker)
