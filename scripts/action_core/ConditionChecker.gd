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

		&"HAS_EQUIPMENT_CARD":
			# 通用件：持有者拥有至少1张可弃置的装备牌（装备手牌 + 其所有机甲已设置槽位含备用区）。
			# 供"弃装备抽牌"类主动效果按钮置灰判定（无装备可弃则按钮不可点）。
			var he_player: StringName = _equip_player_id(binding, payload)
			var he_ctx = binding.context if binding != null else null
			if he_player == &"" or he_ctx == null or he_ctx.get("game_state") == null:
				return false
			return not _equipment_card_ids(he_ctx.game_state, he_player).is_empty()

		&"HAS_UNEQUIPPED_EQUIPMENT_CARD":
			# 通用件：持有者装备手牌中至少1张"未设置的装备牌"（仅装备手牌，不含已设置槽位）。
			# 供"弃置未设置的装备牌"类主动效果按钮置灰判定（柏格 pilot_064 等）。
			var hue_player: StringName = _equip_player_id(binding, payload)
			var hue_ctx = binding.context if binding != null else null
			if hue_player == &"" or hue_ctx == null or hue_ctx.get("game_state") == null:
				return false
			return not _unequipped_equipment_card_ids(hue_ctx.game_state, hue_player).is_empty()

		&"HAS_CARD_DEF_ID_IN_HAND":
			# 通用件：持有者手牌中是否有指定 card_def_id 的行动牌（如实体防御牌选择分支条件）。
			# params: {card_def_id}
			var hcdh_params: Dictionary = condition.get("params", condition)
			var hcdh_def: StringName = hcdh_params.get("card_def_id", &"")
			if hcdh_def == &"":
				return false
			var hcdh_owner: StringName = binding.get_owner_player_id()
			var hcdh_ctx = binding.context if binding != null else null
			if hcdh_owner == &"" or hcdh_ctx == null or hcdh_ctx.get("game_state") == null:
				return false
			var hcdh_player = hcdh_ctx.game_state.players.get(hcdh_owner)
			if hcdh_player == null:
				return false
			for hcdh_cid: StringName in hcdh_player.action_hand:
				var hcdh_card = hcdh_ctx.game_state.get_card(hcdh_cid)
				if hcdh_card != null and hcdh_card.def != null and String(hcdh_card.def.card_id) == String(hcdh_def):
					return true
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

		&"ATTACK_BASE_DAMAGE_BELOW":
			# 塞万提斯 pilot_034 effect_01：攻击本身造成的伤害 < threshold（默认1，即0伤害）。
			# 读 attack._step_calculate_damage 快照的 base_damage 独立字段（不含 ATTACK_AFTER
			# 追加/衰减，如巴托洛夫+3），判定「未对我方造成伤害的攻击」。
			var abd_params: Dictionary = condition.get("params", condition)
			var abd_thresh: int = int(abd_params.get("threshold", 1))
			return int(payload.get("base_damage", 0)) < abd_thresh

		&"ATTACK_TARGET_IN_PILOT_034_RECORDED":
			# 塞万提斯 pilot_034 effect_02b：攻击目标在本机师静态记录集内（曾对我方造成伤害）。
			# 按绑定机师牌实例（payload.binding_context.card_instance_id）各自独立记录。
			var p034_atk_target: StringName = payload.get("attack_target_id", payload.get("target_id", &""))
			if p034_atk_target == &"":
				return false
			var p034_bc: Dictionary = payload.get("binding_context", {}) if payload != null else {}
			var p034_src_pilot: StringName = p034_bc.get("card_instance_id", &"")
			if p034_src_pilot == &"":
				return false
			return _ActionPilotEffects.pilot_034_is_recorded(p034_src_pilot, p034_atk_target)

		&"ATTACK_WAS_RESPONDED":
			# 本次攻击被响应（迎击牌 RESPOND_ATTACK 写回 attack record.responded）。
			# 强袭在 ATTACK_AT 响应效果全部结算后补跑监听器，此时读取最新 responded。
			return payload.get("responded", false) == true

		&"COUNTER_HAS_ATTACK_ACTION_ID":
			# 疾风 pilot_076 effect_01：本次 use_action_card 是迎击牌且响应了一个攻击
			# （handle_response_selection 发起时注入 attack_action_id 到 use_action_card.record）。
			# 配合 ATTACK_SOURCE_ACTION_CARD_TYPE_IS(迎击) 已排除转化迎击（def.action_type≠迎击）。
			return payload.get("attack_action_id", &"") != &""

		&"COUNTER_CLAIM_TRIGGERED":
			# 疾风 pilot_076 effect_02 获牌触发（获牌A OR 获牌B，自动 CLAIM 无弹窗）：
			# 获牌A：本次 use_action_card 打出实体迎击牌，且其响应的攻击的攻击方==本机师
			#        （我方发动的攻击被迎击响应 -> 获该迎击牌）。
			# 获牌B：本次 use_action_card 打出实体攻击牌，且该攻击被迎击响应、响应方==本玩家
			#        （我方迎击响应攻击牌 -> 获该攻击牌；responded/responder_player_id 由
			#        attack_action._propagate_response_info_to_parent 在 _step_cleanup 回写到父 record）。
			# 转化牌 def.action_type 为原牌类型，天然不匹配"迎击"/"攻击"，故转化不触发。
			var cct_ctx = binding.context if binding != null else null
			if cct_ctx == null or cct_ctx.get("game_state") == null:
				return false
			var cct_card_id: StringName = payload.get("attack_card_id", payload.get("card_instance_id", &""))
			if cct_card_id == &"":
				return false
			var cct_card = cct_ctx.game_state.get_card(cct_card_id)
			if cct_card == null or cct_card.def == null:
				return false
			var cct_atype := String(cct_card.def.action_type)
			var cct_self_mech: StringName = _equip_mech_id(binding, payload)
			var cct_self_player: StringName = _equip_player_id(binding, payload)
			if cct_atype == "迎击":
				# 获牌A：attack_action_id 反查攻击方==self
				var cct_aaid: StringName = payload.get("attack_action_id", &"")
				if cct_aaid == &"" or cct_ctx.get("action_registry") == null:
					return false
				var cct_atk = cct_ctx.action_registry.get_action(cct_aaid)
				if cct_atk == null:
					return false
				var cct_attacker: StringName = cct_atk.record.get("attacker_id", &"")
				return cct_self_mech != &"" and cct_attacker != &"" and cct_self_mech == cct_attacker
			if cct_atype == "攻击":
				# 获牌B：被迎击响应 + 响应方==self。
				# 响应方读 responder_player_id（attack_action._propagate_response_info_to_parent 回写，
				# = 被攻击方=target 所属玩家，稳定）。不读 response_card_id 当前 owner--迎击牌被
				# CLAIM 后 owner 已改，会误判（branch_a 获迎击牌后再误获攻击牌）。
				if not bool(payload.get("responded", false)):
					return false
				var cct_responder: StringName = payload.get("responder_player_id", &"")
				return cct_self_player != &"" and cct_responder != &"" and cct_self_player == cct_responder
			return false

		&"OWNER_ACTION_HAND_IS_EMPTY":
			# 诺拉 effect_01：效果所属玩家（binding_context.player_id）行动手牌 == 0（动态查 game_state）。
			# 与 OWNER_ACTION_HAND_EMPTY 区别：后者读 payload.owner_action_hand_count（ATTACK_PRE 等时点未注入），
			# 此 op 从 binding_context.player_id 实时查 game_state，适用于任何时点。
			var oahie_pid: StringName = _equip_player_id(binding, payload)
			var oahie_ctx = binding.context if binding != null else null
			if oahie_pid == &"" or oahie_ctx == null or oahie_ctx.get("game_state") == null:
				return false
			var oahie_player = oahie_ctx.game_state.players.get(oahie_pid)
			if oahie_player == null:
				return false
			return oahie_player.action_hand.is_empty()

		&"ATTACK_SOURCE_IS_PHYSICAL_ATTACK_CARD":
			# 诺拉 effect_01a/01b：本次攻击由物理攻击牌发起（attack_card_id 非空 + 非虚拟转化）。
			# 区分莱比尔/迪恩/诺拉自己的虚拟转化进攻（virtual_transform=true 不触发），
			# 以及无牌武器攻击（cardless_weapon_attack，attack_card_id 空）。
			var aspac_card_id: StringName = payload.get("attack_card_id", &"")
			if aspac_card_id == &"":
				return false
			if bool(payload.get("virtual_transform", false)) or bool(payload.get("is_virtual", false)):
				return false
			# 进一步确认该牌是攻击牌（action_type=="攻击"），排除辅助牌/迎击牌触发的攻击
			var aspac_ctx = binding.context if binding != null else null
			if aspac_ctx == null or aspac_ctx.get("game_state") == null:
				return true  # 无法查牌定义时仅按 attack_card_id 非空+非虚拟判定
			var aspac_card = aspac_ctx.game_state.get_card(aspac_card_id)
			if aspac_card == null or aspac_card.def == null:
				return true
			var aspac_at: String = String(aspac_card.def.action_type) if "action_type" in aspac_card.def else ""
			return aspac_at == "攻击"

		&"USED_CARD_RESPONDS_TO_OWN_ATTACK":
			# 诺拉 effect_01c：当前 use_action_card 是响应我方攻击的迎击牌。
			# use_action_card record 带 attack_action_id（被响应的攻击动作 id）；
			# 该攻击的发起方(attacker_id) == 诺拉所属机甲(binding_context.mech_id)。
			var ucroa_atk_id: StringName = payload.get("attack_action_id", &"")
			if ucroa_atk_id == &"":
				return false
			var ucroa_ctx = binding.context if binding != null else null
			if ucroa_ctx == null or ucroa_ctx.get("action_registry") == null:
				return false
			var ucroa_atk = ucroa_ctx.action_registry.get_action(ucroa_atk_id)
			if ucroa_atk == null:
				return false
			var ucroa_attacker: StringName = ucroa_atk.record.get("attacker_id", &"")
			if ucroa_attacker == &"":
				return false
			var ucroa_own_mech: StringName = _equip_mech_id(binding, payload)
			return ucroa_own_mech != &"" and ucroa_attacker == ucroa_own_mech

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
			var wt_aura: Dictionary = wt_ctx.map_service.get_attack_aura_cells()
			# 与 attack_action._step_select_target 口径一致：机甲格为路径障碍 + 陷落不可被指定
			var wt_blocked: Dictionary = wt_ctx.map_service.get_attack_blocked_keys(wt_attacker_id)
			for mech_id_wt: StringName in wt_ctx.game_state.mechs:
				if mech_id_wt == wt_attacker_id:
					continue
				var m_wt = wt_ctx.game_state.mechs[mech_id_wt]
				if m_wt == null or m_wt.destroyed:
					continue
				if m_wt.has_status(&"cannot_be_targeted"):
					continue
				if _RangeCalculator.is_in_weapon_range(wt_attacker.position, m_wt.position, wt_range, wt_cells, wt_aura, wt_blocked):
					return true
			# 陷阱标记也是可攻击目标（攻击即引爆，无响应窗口）
			if wt_ctx.game_state.map_state != null:
				for m_wt2 in wt_ctx.game_state.map_state.markers:
					if m_wt2.get("type", &"") == &"TRAP":
						var t_pos: Dictionary = {"q": int(m_wt2.get("q", 0)), "r": int(m_wt2.get("r", 0))}
						if _RangeCalculator.is_in_weapon_range(wt_attacker.position, t_pos, wt_range, wt_cells, wt_aura, wt_blocked):
							return true
			return false

		&"HAS_ATTACK_TARGET_IN_RANGE":
			# 转化攻击前置条件（诺拉全当进攻 / 伏特当强袭/猛击/破甲）：源机甲任一武器射程内存在
			# 可攻击目标（任意存活其他机甲或陷阱标记）。条件不足时 DIRECT 按钮置灰
			# （equipment_panel can_trigger_active_effect），避免点了才烧燃料牌。
			# 与 attack_action._step_select_target 的候选口径一致：遍历全部存活机甲（排除自己）+TRAP；
			# 有效范围=武器基础范围+狙击头被动加成（get_passive_weapon_range_bonus，与选武器时一致）。
			var hat_ctx = binding.context if binding != null else null
			if hat_ctx == null or hat_ctx.get("game_state") == null:
				return false
			var hat_mech_id: StringName = _equip_mech_id(binding, payload)
			if hat_mech_id == &"":
				hat_mech_id = payload.get("source_mech_id", payload.get("mech_id", &""))
			var hat_attacker = hat_ctx.game_state.mechs.get(hat_mech_id)
			if hat_attacker == null or hat_attacker.destroyed:
				return false
			var hat_cells: Dictionary = hat_ctx.game_state.map_state.cells if hat_ctx.game_state.map_state else {}
			var hat_aura: Dictionary = hat_ctx.map_service.get_attack_aura_cells()
			# 与 attack_action._step_select_target 口径一致：机甲格为路径障碍 + 陷落不可被指定
			var hat_blocked: Dictionary = hat_ctx.map_service.get_attack_blocked_keys(hat_mech_id)
			for hat_wid in hat_attacker.get_weapon_ids():
				var hat_wid_sn: StringName = StringName(hat_wid)
				var hat_wid_str: String = String(hat_wid_sn)
				var hat_range: int = 1
				var hat_wkind: StringName = &""
				if hat_wid_str.begins_with("frame_base_weapon"):
					var hat_slot: int = 0
					if hat_wid_str.begins_with("frame_base_weapon_"):
						hat_slot = hat_wid_str.trim_prefix("frame_base_weapon_").to_int() - 1
					var hat_bw = hat_attacker.get_base_weapon(hat_slot)
					if hat_bw.is_empty():
						continue
					hat_range = int(hat_bw.get("range_value", 1))
					hat_wkind = hat_bw.get("weapon_kind", &"")
				else:
					var hat_wcard = hat_ctx.game_state.get_card(hat_wid_sn)
					if hat_wcard == null:
						continue
					var hat_wstats: Dictionary = _GenEquipEffects.get_effective_weapon_stats(hat_wcard)
					hat_range = int(hat_wstats.get("range_value", 1))
					hat_wkind = hat_wstats.get("weapon_kind", &"")
				hat_range = max(1, hat_range + _GenEquipEffects.get_passive_weapon_range_bonus(hat_attacker, hat_wkind))
				for m_hat: StringName in hat_ctx.game_state.mechs:
					if m_hat == hat_mech_id:
						continue
					var m_hat2 = hat_ctx.game_state.mechs[m_hat]
					if m_hat2 == null or m_hat2.destroyed:
						continue
					if m_hat2.has_status(&"cannot_be_targeted"):
						continue
					if _RangeCalculator.is_in_weapon_range(hat_attacker.position, m_hat2.position, hat_range, hat_cells, hat_aura, hat_blocked):
						return true
				if hat_ctx.game_state.map_state != null:
					for m_hat3 in hat_ctx.game_state.map_state.markers:
						if m_hat3.get("type", &"") != &"TRAP":
							continue
						var t_hat: Dictionary = {"q": int(m_hat3.get("q", 0)), "r": int(m_hat3.get("r", 0))}
						if _RangeCalculator.is_in_weapon_range(hat_attacker.position, t_hat, hat_range, hat_cells, hat_aura, hat_blocked):
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

		&"PILOT_020_X_AT_LEAST":
			# 肯德弃置数 X >= threshold（读 binding_context 的肯德 pilot 卡实例 counter，按当前回合）。
			# 用于 effect_03(攻击加成 X≥3)/effect_04(回合末抽牌 X≥4) 的监听门槛。
			# X 存 counters["pilot_020_x_<turn_number>"]，按 turn_number 每回合自动重置。
			var p020_params: Dictionary = condition.get("params", condition)
			var p020_threshold: int = int(p020_params.get("threshold", 1))
			var p020_bind_ctx: Dictionary = payload.get("binding_context", {})
			var p020_ctx = binding.context if binding != null else null
			if p020_ctx == null or p020_ctx.get("game_state") == null:
				return false
			var p020_card = _ActionPilotEffects.get_pilot_020_pilot_card(p020_ctx.game_state, p020_bind_ctx)
			if p020_card == null:
				return false
			var p020_x: int = _ActionPilotEffects.get_pilot_020_x(p020_card, int(p020_ctx.game_state.turn_number))
			return p020_x >= p020_threshold

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

		&"MAP_MARKER_IN_RANGE":
			# 通用：源机甲（binding.get_source_mech_id）hex 距离 range 内存在至少 count 个
			# 指定类型地图标记（默认 TRAP）。params: {marker_type, range(默认4), count(默认1)}。
			# 供主动效果按钮可用性门槛（格雷厄姆 pilot_057「4格内可选陷阱」等）。
			var mmir_ctx = binding.context if binding != null else null
			if mmir_ctx == null or mmir_ctx.get("game_state") == null:
				return false
			var mmir_params: Dictionary = condition.get("params", {})
			var mmir_type: StringName = mmir_params.get("marker_type", &"TRAP")
			var mmir_range: int = int(mmir_params.get("range", 4))
			var mmir_need: int = int(mmir_params.get("count", 1))
			var mmir_min_dist: int = int(mmir_params.get("min_distance", 0))
			var mmir_mech_id: StringName = binding.get_source_mech_id()
			if payload.has("binding_context") and mmir_mech_id == &"":
				mmir_mech_id = payload.get("binding_context", {}).get("mech_id", &"")
			if mmir_mech_id == &"":
				return false
			var mmir_mech = mmir_ctx.game_state.mechs.get(mmir_mech_id)
			if mmir_mech == null:
				return false
			return get_marker_cells_in_range(
				mmir_ctx.game_state, mmir_mech.position, mmir_type, mmir_range, mmir_min_dist
			).size() >= mmir_need

		&"EVENT_DECK_HAS_CARDS":
			# 通用：事件牌堆剩余张数 >= minimum（默认1）。供「抽1张事件牌设置到区域」类
			# 主动效果按钮置灰（李 pilot_051 e1：事件牌堆耗尽不可点）。
			var edc_ctx = binding.context if binding != null else null
			if edc_ctx == null or edc_ctx.get("game_state") == null:
				return false
			var edc_min: int = int(condition.get("params", {}).get("minimum", 1))
			return edc_ctx.game_state.deck_state.event_deck.size() >= edc_min

		&"OWNER_IS_HUMAN":
			# 通用：效果绑定来源玩家 is_human（PvE 敌方 AI=false 跳过弹窗类被动；
			# PvP/PvP3 全人类恒真）。李 pilot_051 e2 拦截弹窗对 AI 拥有者不触发。
			var oh_bind_ctx: Dictionary = payload.get("binding_context", {})
			var oh_pid: StringName = oh_bind_ctx.get("player_id", &"")
			if oh_pid == &"":
				return false
			var oh_ctx = binding.context if binding != null else null
			if oh_ctx == null or oh_ctx.get("game_state") == null:
				return false
			var oh_player = oh_ctx.game_state.players.get(oh_pid)
			if oh_player == null:
				return false
			return bool(oh_player.is_human)

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

		&"SELF_MECH_IS_AMONG_ATTACK_TARGETS":
			# 青瞳 pilot_037：本牌所属机甲在本次攻击的机甲目标列表内（含双连多目标）。
			# 与 SELF_MECH_IS_ATTACK_TARGET 的区别：后者只匹配 target_id（单目标），双连主攻击
			# 的 record 只带主目标 target_id，青瞳须在 target_id + target_ids 合并集里查自身。
			var smat_self: StringName = _equip_mech_id(binding, payload)
			if smat_self == &"":
				return false
			var smat_targets: Array = _collect_attack_mech_targets(binding, payload, false)
			return smat_targets.has(smat_self)

		&"SELF_MECH_HAS_RESERVE_EQUIPMENT":
			# 约书亚 pilot_025 选项1b 可用性：本牌所属机甲的备用区是否有装备牌。
			# 备用区(reserve_1/reserve_2)有 equipped_card 即可（face_down 白板也算，可重新设置）。
			var shr_mech_id: StringName = _equip_mech_id(binding, payload)
			if shr_mech_id == &"" or binding == null or binding.context == null or binding.context.get("game_state") == null:
				return false
			var shr_mech = binding.context.game_state.mechs.get(shr_mech_id)
			if shr_mech == null:
				return false
			for shr_sid in [&"reserve_1", &"reserve_2"]:
				var shr_slot = shr_mech.slots.get(shr_sid)
				if shr_slot != null and shr_slot.equipped_card != null:
					return true
			return false

		&"STATUS_OWNER_IS_ATTACKER":
			# 状态监听器专用：本状态所属机甲（binding_context.target_id）= 攻击发起方。
			# 状态监听器的 binding_context 含 target_id(=持有状态的机甲)/status_id/status_type，
			# 但无 mech_id 字段（SELF_MECH_IS_ATTACKER 经 _equip_mech_id 读 mech_id 解析失败），
			# 故直接比较 binding_context.target_id 与攻击 record 的 attacker_id。
			var soia_ctx: Dictionary = payload.get("binding_context", {}) if payload != null else {}
			var soia_status_mech: StringName = soia_ctx.get("target_id", &"")
			var soia_attacker: StringName = payload.get("attacker_id", &"")
			return soia_status_mech != &"" and soia_status_mech == soia_attacker

		&"OWNER_HAS_WEAPON_EQUIPMENT_CARD":
			# 提比里安 pilot_022 effect_01 主动按钮可用性：持有者玩家是否持有任意武器装备牌
			# （装备手牌 + 机甲所有已设置槽位中 def.equipment_kind==WEAPON 的牌）。
			# 虚拟武器天然排除——虚拟武器 def.equipment_kind==PART（神莺躯干），枚举只看 WEAPON。
			var ohw_owner: StringName = _equip_player_id(binding, payload)
			var ohw_ctx = binding.context if binding != null else null
			if ohw_owner == &"" or ohw_ctx == null or ohw_ctx.get("game_state") == null:
				return false
			return not _weapon_equipment_card_ids(ohw_ctx.game_state, ohw_owner).is_empty()

		&"OWNER_MECH_HAS_CHARGEABLE_WEAPON":
			# 克劳德 pilot_029 effect_02 前置：持有者机甲至少有一把可聚能武器。
			# 口径与聚能武器选择一致（get_weapon_ids=武器槽装备牌+基础武器虚拟ID；
			# 虚拟武器如神莺躯干亦列入）。无武器时按钮置灰，防白丢行动牌。
			var cmw_mech_id: StringName = _equip_mech_id(binding, payload)
			if cmw_mech_id == &"":
				return false
			var cmw_ctx = binding.context if binding != null else null
			if cmw_ctx == null or cmw_ctx.get("game_state") == null:
				return false
			var cmw_mech = cmw_ctx.game_state.mechs.get(cmw_mech_id)
			if cmw_mech == null:
				return false
			if not cmw_mech.get_weapon_ids().is_empty():
				return true
			for cmw_sid in cmw_mech.slots:
				var cmw_slot = cmw_mech.slots[cmw_sid]
				if cmw_slot == null or cmw_slot.equipped_card == null:
					continue
				if not _GenEquipEffects.get_virtual_weapon_from_equipment(cmw_slot.equipped_card).is_empty():
					return true
			return false

		&"PILOT_022_NOT_USED_THIS_GAME":
			# 提比里安 pilot_022 effect_02 本局1次：来源机师牌实例 counters 无已用标记时方可触发。
			var p022_cid: StringName = _equip_card_instance_id(binding, payload)
			if p022_cid == &"" or binding == null or binding.context == null or binding.context.get("game_state") == null:
				return false
			var p022_card = binding.context.game_state.get_card(p022_cid)
			if p022_card == null:
				return false
			return not bool(p022_card.counters.get("pilot_022_effect_02_used", false))

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
			# 弃置原因 == condition.reason（近战右腿只接受 damage_durability）。
			# reason 支持 String（单值，兼容现有调用）或 Array（任一匹配，卖出×2 等需多 reason）。
			# 参数统一 params 优先回退顶层（历史不一致：近战右腿 reason 在顶层；霍克卖出翻倍用 params.reason）
			var dr_p: Dictionary = condition.get("params", condition)
			var dr_reason = dr_p.get("reason", condition.get("reason", &""))
			# 类型安全判空：reason 可能是 String/StringName（单值）或 Array（多值）。
			# 不可直接 `== &""`：Array 与 StringName 比较是运行时错误，会中断 check_single 误判 false。
			var dr_reason_empty: bool = false
			if typeof(dr_reason) == TYPE_ARRAY:
				dr_reason_empty = (dr_reason as Array).is_empty()
			else:
				dr_reason_empty = String(dr_reason) == ""
			if dr_reason_empty:
				return false
			var dr_reasons: Array = [dr_reason] if (typeof(dr_reason) == TYPE_STRING or typeof(dr_reason) == TYPE_STRING_NAME) else dr_reason
			var dr_reason_strs: Array = []
			for _dr_r in dr_reasons:
				dr_reason_strs.append(String(_dr_r))
			var dr_snapshots: Array = payload.get("discard_snapshots", [])
			var dis_card_id_dr: StringName = _equip_card_instance_id(binding, payload)
			# 仅当来源牌出现在本次弃置快照中才做单牌过滤：装备效果（近战右腿等）来源牌=被弃装备，
			# 过滤到本牌；事件级效果（霍克卖出翻倍）来源牌=机师牌不在快照，须匹配任意被弃装备。
			var dr_src_in_snap := false
			for _probe_dr: Dictionary in dr_snapshots:
				if dis_card_id_dr != &"" and String(_probe_dr.get("card_id", &"")) == String(dis_card_id_dr):
					dr_src_in_snap = true
					break
			for snap: Dictionary in dr_snapshots:
				if dis_card_id_dr != &"" and dr_src_in_snap and String(snap.get("card_id", &"")) != String(dis_card_id_dr):
					continue
				if String(snap.get("reason", &"")) in dr_reason_strs:
					return true
			return false

		&"DISCARD_INCLUDED_OWNER_ACTION_CARD":
			# 本次弃置的牌中至少1张是效果持有者自己的牌（德伦迪 pilot_042：每次弃置行动牌后抽1）。
			# discard_snapshots 含 from_mech_id/from_zone/card_kind/card_id；牌进手牌时 card.mech_id=抽取机甲，
			# 故 from_mech_id==效果持有者机甲 即可判定归属（他人弃自己的牌、自己弃他人牌均不误配）。
			# 可选 from_zone 参数限定弃置来源区（德伦迪用 action_hand=仅从手牌弃置触发）；
			# 可选 card_kind 参数限定牌类型（默认 action 保持德伦迪行为；霍克 pilot_055 卖出翻倍用
			#   equipment=本次卖出的是效果持有者自己的装备牌）；
			# 可选 action_type 参数限定行动牌类型（如 辅助：肯尼斯 pilot_075 判定本次弃置含辅助牌——
			#   按快照 card_id 查 gs.get_card().def.action_type，非行动牌/无 def 不命中）；
			# 可选 negate 参数取反（布尔，默认 false）：本次弃置【不】含满足上述条件的牌时命中
			#   （肯尼斯 effect_02 弹窗分支=不含辅助牌时弹 CHOOSE_ONE）。
			var d_mech_id: StringName = _equip_mech_id(binding, payload)
			if d_mech_id == &"":
				return false
			# 参数统一 params 优先回退顶层（历史不一致，见 VARIABLE_ABOVE 等）
			var d_params: Dictionary = condition.get("params", condition)
			var d_zone: StringName = d_params.get("from_zone", condition.get("from_zone", &""))
			var d_card_kind: StringName = d_params.get("card_kind", condition.get("card_kind", &"action"))
			var d_action_type: StringName = d_params.get("action_type", condition.get("action_type", &""))
			var d_negate: bool = bool(d_params.get("negate", condition.get("negate", false)))
			var d_snaps: Array = payload.get("discard_snapshots", [])
			var d_match := false
			for snap: Dictionary in d_snaps:
				if String(snap.get("card_kind", &"")) != String(d_card_kind):
					continue
				if String(snap.get("from_mech_id", &"")) != String(d_mech_id):
					continue
				if d_zone != &"" and String(snap.get("from_zone", &"")) != String(d_zone):
					continue
				if d_action_type != &"":
					var d_ctx = binding.context if binding != null else null
					if d_ctx == null or d_ctx.get("game_state") == null:
						continue
					var d_cid: StringName = snap.get("card_id", &"")
					if d_cid == &"":
						continue
					var d_card = d_ctx.game_state.get_card(d_cid)
					if d_card == null or d_card.def == null:
						continue
					# CardDef 子类无 .get()，需按类型属性访问（无类型动态访问，同 dea_card.def.rarity）：
					# 先判 card_kind 再读 action_type
					var d_def = d_card.def
					if d_def.card_kind != &"action":
						continue
					var d_act_type: StringName = d_def.action_type
					if d_act_type == &"":
						continue
					if String(d_act_type) != String(d_action_type):
						continue
				d_match = true
				break
			return not d_match if d_negate else d_match

		&"DISCARD_EQUIPMENT_IS_ADVANCED":
			# 本次弃置的装备牌中至少1张是高级装备（稀有度 SR/SSR；规则书：高级装备牌堆包含 SR、SSR）。
			# 供「按被弃装备稀有度给奖励」类效果用（霍克 pilot_055：卖出高级装备牌再获得3金币）。
			var dea_ctx = binding.context if binding != null else null
			if dea_ctx == null or dea_ctx.get("game_state") == null:
				return false
			var dea_gs = dea_ctx.game_state
			var dea_snaps: Array = payload.get("discard_snapshots", [])
			var dis_card_id_dea: StringName = _equip_card_instance_id(binding, payload)
			# 仅当来源牌出现在本次弃置快照中才做单牌过滤（同 DISCARD_REASON_IS：装备效果过滤到本牌，
			# 机师事件级效果匹配任意被弃装备）。
			var dea_src_in_snap := false
			for _probe_dea: Dictionary in dea_snaps:
				if dis_card_id_dea != &"" and String(_probe_dea.get("card_id", &"")) == String(dis_card_id_dea):
					dea_src_in_snap = true
					break
			for snap: Dictionary in dea_snaps:
				if dis_card_id_dea != &"" and dea_src_in_snap and String(snap.get("card_id", &"")) != String(dis_card_id_dea):
					continue
				if String(snap.get("card_kind", &"")) != &"equipment":
					continue
				var dea_cid: StringName = snap.get("card_id", &"")
				if dea_cid == &"":
					continue
				var dea_card = dea_gs.get_card(dea_cid)
				if dea_card != null and dea_card.def != null:
					var dea_rar: String = String(dea_card.def.rarity)
					if dea_rar == "SR" or dea_rar == "SSR":
						return true
			return false

		&"SET_EQUIP_INCLUDES_OWNER_FACE_UP":
			# 本次设置装备动作：目标机甲是效果持有者机甲 + 设置的装备牌（card_kind=equipment）
			# + 正面设置（槽位非 RESERVE）+ 非「设置即损坏弃置」（亚林 pilot_053：正面设置触发）。
			# SET_EQUIP_AT 时点 payload=record（card_id/mech_id/slot_id/equipment_broken_on_set）。
			var se_mech: StringName = _equip_mech_id(binding, payload)
			if se_mech == &"":
				return false
			if payload.get("equipment_broken_on_set", false) == true:
				return false
			if String(payload.get("mech_id", &"")) != String(se_mech):
				return false
			var se_slot_id: StringName = payload.get("slot_id", &"")
			if se_slot_id == &"":
				return false
			var se_ctx = binding.context if binding != null else null
			if se_ctx == null or se_ctx.get("game_state") == null:
				return false
			var se_mech_o = se_ctx.game_state.mechs.get(se_mech)
			if se_mech_o == null:
				return false
			var se_slot = se_mech_o.slots.get(se_slot_id)
			if se_slot == null:
				return false
			if String(se_slot.slot_kind) == &"RESERVE":
				return false
			var se_card_id: StringName = payload.get("card_id", &"")
			if se_card_id == &"":
				return false
			var se_card = se_ctx.game_state.get_card(se_card_id)
			if se_card == null or se_card.def == null:
				return false
			if String(se_card.def.card_kind) != &"equipment":
				return false
			return true

		&"DISCARD_INCLUDES_OWNER_FACE_UP_EQUIPMENT":
			# 本次弃置的牌中至少1张是效果持有者机甲上正面朝上的装备牌（亚林 pilot_053：弃置触发）。
			# discard_snapshots 含 from_mech_id/from_slot_id/from_zone/card_kind；
			# 正面=from_zone=equipment_slot（已设置在区域）且槽位非 RESERVE（备用区背面）。
			var de_mech: StringName = _equip_mech_id(binding, payload)
			if de_mech == &"":
				return false
			var de_ctx = binding.context if binding != null else null
			if de_ctx == null or de_ctx.get("game_state") == null:
				return false
			var de_snaps: Array = payload.get("discard_snapshots", [])
			for snap: Dictionary in de_snaps:
				if String(snap.get("card_kind", &"")) != &"equipment":
					continue
				if String(snap.get("from_mech_id", &"")) != String(de_mech):
					continue
				if String(snap.get("from_zone", &"")) != &"equipment_slot":
					continue
				var de_slot_id: StringName = snap.get("from_slot_id", &"")
				if de_slot_id == &"":
					continue
				var de_mech_o = de_ctx.game_state.mechs.get(de_mech)
				if de_mech_o == null:
					continue
				var de_slot = de_mech_o.slots.get(de_slot_id)
				if de_slot == null:
					continue
				if String(de_slot.slot_kind) == &"RESERVE":
					continue
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

		&"USED_CARD_HAS_TAG_FROM_ME":
			# 温斯顿 pilot_082：打出的牌带指定运行时标签（"联"）且 owner==本机师牌绑定玩家。
			# 标签 owner 是打标签时的持有者（温斯顿玩家），牌被转给他人后 owner 不变，
			# 故只要"该玩家名下的联标签"命中即触发（联牌被使用 -> 对温斯顿施加联合状态）。
			# tag 参数置于 condition.params（回退顶层）；统一读 CardInstance.has_tag。
			var ucht_params: Dictionary = condition.get("params", condition)
			var ucht_tag: StringName = ucht_params.get("tag", condition.get("tag", &""))
			var ucht_card_id: StringName = payload.get("card_instance_id", payload.get("card_id", &""))
			if ucht_card_id == &"" or ucht_tag == &"":
				return false
			var ucht_ctx = binding.context if binding != null else null
			if ucht_ctx == null or ucht_ctx.get("game_state") == null:
				return false
			var ucht_card = ucht_ctx.game_state.get_card(ucht_card_id)
			if ucht_card == null or not ucht_card.has_method(&"has_tag"):
				return false
			var ucht_self_player: StringName = _equip_player_id(binding, payload)
			if ucht_self_player == &"":
				return false
			return ucht_card.has_tag(ucht_tag, ucht_self_player)

		&"USE_ACTION_IS_UNITE_ORIGIN":
			# 莎菲雅 pilot_084：当前 use_action_card 是"因联合的效果使用攻击牌"（联合攻击 offer 选出，
			# TimingEngine unite_attack_offer resume 在 use_action_card record 注入 _unite_attack_origin）。
			# payload = action.record.duplicate()，下划线键随 record 携带，直接读取布尔标记。
			return bool(payload.get("_unite_attack_origin", false))

		&"USE_ACTION_BY_OTHER_MECH":
			# 当前使用行动牌的机甲不是本效果绑定机甲（莎菲雅被动机甲 ≠ 出牌者机甲即"其他机甲"，
			# 不管是不是我方阵营；同一机师牌绑定 1 台机甲，被动机甲即莎菲雅持有者）。
			var uabm_source: StringName = payload.get("source_mech_id", payload.get("mech_id", &""))
			if uabm_source == &"":
				return false
			return uabm_source != _equip_mech_id(binding, payload)

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

		&"USED_CARD_IS_COVER":
			# 当前 use_action_card 打出的牌是掩护（card_def_id == action_016_掩护）。
			# 转化掩护（PLAY_AS_NAMED as_card_def_id=action_016_掩护）record.card_def_id 以
			# as_card_def_id 优先，故转化与原版掩护均命中。洛尔恩 pilot_062 效果2 用：
			# 我方使用掩护（转化或原版，不含进攻）后二选一（损伤-1 / 不可响应）。
			return String(payload.get("card_def_id", &"")) == "action_016_掩护"

		&"PAYLOAD_ARRAY_NOT_EMPTY":
			# payload[key] 是数组且非空。通用条件 op（洛尔恩 pilot_062 效果1 转化掩护：
			# CHOOSE_MANY_CARDS store_result_key 选中行动牌后，CONDITIONAL_ACTIONS 据此判定
			# 无牌不发动不计次——无牌时 CHOOSE_MANY_CARDS 空候选跳过，payload 无此键，取空数组）。
			var pne_params: Dictionary = condition.get("params", {})
			var pne_key: String = String(pne_params.get("key", &""))
			if pne_key == "":
				return false
			var pne_val: Variant = payload.get(pne_key, [])
			return pne_val is Array and not (pne_val as Array).is_empty()

		&"PAYLOAD_CARD_IS_WEAPON":
			# 通用件：payload[key]（CHOOSE_MANY_CARDS store_result_key 存的卡 id 数组）中
			# 第一张牌是否为武器装备牌（def.equipment_kind == WEAPON）。弃置后牌实例仍在
			# game_state.cards（进弃牌堆），def 保留可查。供"弃置的是武器则追加效果"类
			# 条件分支（柏格 pilot_064 弃装获金抽装 等）。
			var pwi_params: Dictionary = condition.get("params", {})
			var pwi_key: String = String(pwi_params.get("key", &""))
			if pwi_key == "":
				return false
			var pwi_ids: Variant = payload.get(pwi_key, [])
			if not (pwi_ids is Array) or (pwi_ids as Array).is_empty():
				return false
			var pwi_ctx = binding.context if binding != null else null
			if pwi_ctx == null or pwi_ctx.get("game_state") == null:
				return false
			var pwi_card = pwi_ctx.game_state.get_card((pwi_ids as Array)[0])
			if pwi_card == null or pwi_card.def == null:
				return false
			return _is_weapon_equipment_def(pwi_card.def)

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
			var tcr_aura: Dictionary = tcr_ctx.map_service.get_attack_aura_cells()
			# 掩护射程同样受机甲障碍影响（与攻击判定口径一致：blocked 可作终点不可穿过）
			var tcr_blocked: Dictionary = tcr_ctx.map_service.get_attack_blocked_keys(tcr_holder_mech_id)
			return _RangeCalculator.is_in_weapon_range(tcr_holder.position, tcr_target_mech.position, tcr_max_range, tcr_map_cells, tcr_aura, tcr_blocked)


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

		&"CAN_ACTIVE_ATTACK":
			# 可主动发起进攻：本回合可攻击（攻击数>0），或我方攻击窗口激活期间（铠威窗口豁免攻击次数）。
			# 布彻尔 pilot_063「当作进攻」通用条件：主阶段用普通攻击次数，窗口内豁免（窗口攻击本身不耗次数）。
			var caa_mech_id: StringName = _equip_mech_id(binding, payload)
			var caa_ctx = binding.context if binding != null else null
			if caa_mech_id == &"" or caa_ctx == null or caa_ctx.get("game_state") == null:
				return false
			var caa_mech = caa_ctx.game_state.mechs.get(caa_mech_id)
			if caa_mech == null:
				return false
			if caa_mech.has_method(&"can_attack") and caa_mech.can_attack():
				return true
			return _ActionPilotEffects.attack_window_active_for_mech(caa_ctx.game_state, caa_mech_id)

		&"ATTACK_IS_ASSAULT_CLASS":
			# 本次攻击是否属于「进攻」类（进攻牌/转化进攻/视为进攻）。
			# 布彻尔 pilot_063「我方使用的进攻」通用条件：原版进攻牌、转化进攻（PLAY_AS_NAMED 等写入
			# virtual_as_def_id）、诺拉视为纯进攻（_effect_flags 的 pilot_015_force_pure_assault）都算；
			# 强袭/猛击/破甲/掩护/闪击/反击等非进攻效果不算。
			# params.card_def_id 可指定判定的进攻牌 def id（默认 action_001_进攻，可复用）。
			var aia_params: Dictionary = condition.get("params", condition)
			var aia_def_id: String = String(aia_params.get("card_def_id", &"action_001_进攻"))
			var aia_ctx = binding.context if binding != null else null
			if aia_ctx == null or aia_ctx.get("game_state") == null:
				return false
			var aia_gs = aia_ctx.game_state
			# 1) 诺拉视为纯进攻（_effect_flags 里 flag 值为 {"value": bool} 结构）
			var aia_flags: Dictionary = payload.get("_effect_flags", {})
			if aia_flags is Dictionary and aia_flags.has(&"pilot_015_force_pure_assault"):
				var aia_flag_entry: Dictionary = aia_flags.get(&"pilot_015_force_pure_assault", {})
				if bool(aia_flag_entry.get("value", false)):
					return true
			# 2/3) 来源行动牌为进攻牌 / 转化进攻（attack_action_cards 优先，缺省回退 attack_card_id）
			return _attack_source_is_card_class(payload, aia_gs, aia_def_id)

		&"ATTACK_IS_NAMED_CARD":
			# 本次攻击的来源行动牌是否为具名行动牌（原版 def.card_id 或转化 virtual_as_def_id）。
			# 通用条件（不绑机师）：params.card_def_id 指定判定的行动牌 id（默认 action_001_进攻）。
			# 丹 pilot_067「双连加成」判双连（card_def_id=action_005_双连）：原版双连 / 转化双连都算；
			# 强袭/猛击/破甲/掩护/闪击/反击等非双连效果不算。
			var anc_params: Dictionary = condition.get("params", condition)
			var anc_def_id: String = String(anc_params.get("card_def_id", &"action_001_进攻"))
			var anc_ctx = binding.context if binding != null else null
			if anc_ctx == null or anc_ctx.get("game_state") == null:
				return false
			return _attack_source_is_card_class(payload, anc_ctx.game_state, anc_def_id)

		&"ATTACK_TARGET_COUNT_AT_LEAST":
			# 本次攻击选定的机甲目标数 >= params.count（双连等多目标）。
			# 读 payload.target_ids 大小（缺省回退 target_count）。主攻击 ATTACK_PRE 时目标已选定
			# （select_target step handler 先执行写入 target_ids，再 fire ATTACK_PRE，故 PRE 可判定）。
			# 丹 pilot_067「双连加成」2目标判定：count=2。
			var atc_params: Dictionary = condition.get("params", condition)
			var atc_min: int = int(atc_params.get("count", 1))
			var atc_tids: Array = payload.get("target_ids", [])
			var atc_n: int = atc_tids.size()
			if atc_n == 0:
				atc_n = int(payload.get("target_count", 0))
			return atc_n >= atc_min

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

		&"PILOT_024_CAN_USE_EFFECT1":
			# 琳效果1「当作维修」按钮可用：自己主阶段+范围内有维修目标，或 维修窗口激活
			# （被其他机甲 RE 请求后窗口内按钮可用，按每玩家回合重置，窗口内可持续再按）。
			var p24_ctx = binding.context if binding != null else null
			if p24_ctx == null or p24_ctx.get("game_state") == null:
				return false
			var p24_gs = p24_ctx.game_state
			var p24_mech: StringName = _equip_mech_id(binding, payload)
			if p24_mech == &"" or not _ActionPilotEffects.pilot_024_is_lin(p24_gs, p24_mech):
				return false
			# 窗口激活：无论是否主阶段都可用
			if _ActionPilotEffects.pilot_024_window_active_for_mech(p24_gs, p24_mech):
				return true
			# 自己主阶段 + 存在维修目标
			var p24_phase: StringName = payload.get("phase", &"")
			if p24_phase != &"MAIN" and p24_gs.phase != &"MAIN":
				return false
			var p24_owner: StringName = _equip_player_id(binding, payload)
			if p24_owner == &"" or p24_gs.active_player_id != p24_owner:
				return false
			return _has_repair_target(p24_gs, p24_mech, _ActionPilotEffects.get_repair_range(p24_gs, p24_mech))

		&"PILOT_024_RE_AVAILABLE":
			# 请求方（装备此 RE 效果绑定的机甲）RE 可请求：非琳本人、己方回合、可维修（非满状态）、
			# 本回合未请求过、琳在场且存活、请求方在琳4格内。
			var p24r_ctx = binding.context if binding != null else null
			if p24r_ctx == null or p24r_ctx.get("game_state") == null:
				return false
			var p24r_gs = p24r_ctx.game_state
			var p24r_mech: StringName = _equip_mech_id(binding, payload)
			if p24r_mech == &"":
				return false
			# 己方回合
			var p24r_owner: StringName = _equip_player_id(binding, payload)
			if p24r_owner == &"" or p24r_gs.active_player_id != p24r_owner:
				return false
			# 非琳本人
			if _ActionPilotEffects.pilot_024_is_lin(p24r_gs, p24r_mech):
				return false
			# 琳在场且存活
			var p24r_lin: StringName = _ActionPilotEffects.pilot_024_find_lin_mech(p24r_gs)
			if p24r_lin == &"":
				return false
			var p24r_lin_m = p24r_gs.mechs.get(p24r_lin)
			if p24r_lin_m == null or p24r_lin_m.destroyed:
				return false
			# 可维修（满状态不可点）
			if not _ActionPilotEffects.pilot_024_mech_repairable(p24r_gs, p24r_mech):
				return false
			# 本回合未请求过（点击即消耗，琳拒绝也不刷新）
			if _ActionPilotEffects.pilot_024_re_used_this_round(p24r_gs, p24r_mech):
				return false
			# 4格内
			return _ActionPilotEffects.pilot_024_requester_in_range(p24r_gs, p24r_mech, p24r_lin, 4)

		&"PILOT_081_RE_AVAILABLE":
			# 请求方（点 RE 的机甲）可请求汀兰回复：己方回合、本回合未请求过、在光环格上
			# （有覆盖该机甲的存活汀兰持有者，含持有者自身可自我请求）。不卡满血：金币收益始终有效。
			var p81r_ctx = binding.context if binding != null else null
			if p81r_ctx == null or p81r_ctx.get("game_state") == null:
				return false
			var p81r_gs = p81r_ctx.game_state
			var p81r_mech: StringName = _equip_mech_id(binding, payload)
			if p81r_mech == &"":
				return false
			# 己方回合
			var p81r_owner: StringName = _equip_player_id(binding, payload)
			if p81r_owner == &"" or p81r_gs.active_player_id != p81r_owner:
				return false
			# 本回合未请求过（点击即消耗，持有者拒绝也不刷新）
			if _ActionPilotEffects.pilot_081_re_used_this_turn(p81r_gs, p81r_mech):
				return false
			# 在光环格上：有覆盖该机甲的存活汀兰持有者
			return not _ActionPilotEffects.pilot_081_find_covering_holders(p81r_gs, p81r_mech).is_empty()

		&"PILOT_083_RE_AVAILABLE":
			# 请求方（点 RE 的机甲）可请求瓦恩修改武器：己方回合、本回合未请求过、3格内有存活瓦恩持有者
			# （排除请求方自身--瓦恩持有者不能自己请求自己）。点击即消耗本回合次数（持有者拒绝也不刷新，同琳/汀兰）。
			var p83r_ctx = binding.context if binding != null else null
			if p83r_ctx == null or p83r_ctx.get("game_state") == null:
				return false
			var p83r_gs = p83r_ctx.game_state
			var p83r_mech: StringName = _equip_mech_id(binding, payload)
			if p83r_mech == &"":
				return false
			# 己方回合
			var p83r_owner: StringName = _equip_player_id(binding, payload)
			if p83r_owner == &"" or p83r_gs.active_player_id != p83r_owner:
				return false
			# 本回合未请求过
			if _ActionPilotEffects.pilot_083_re_used_this_turn(p83r_gs, p83r_mech):
				return false
			# 3格内有覆盖该机甲的存活瓦恩持有者
			return not _ActionPilotEffects.pilot_083_find_covering_holders(p83r_gs, p83r_mech).is_empty()

		&"HAS_FIELD_WEAPON":
			# 场上是否有至少1把武器（瓦恩效果1前置：无武器不可点）。判定经
			# _ActionPilotEffects.pilot_083_has_field_weapon（实体武器槽+虚拟武器，排除基础武器）。
			var hfw_ctx = binding.context if binding != null else null
			if hfw_ctx == null or hfw_ctx.get("game_state") == null:
				return false
			return _ActionPilotEffects.pilot_083_has_field_weapon(hfw_ctx.game_state)

		&"REPAIR_HAS_VALID_TARGET":
			# 场上自身或相邻 range 格存在非满状态机甲（effect_130 维修机械臂前置）。
			# 范围读机师牌 repair_boost（通用机制）：坎得 pilot_023 等维修增强机师 range=4。
			var rht_range: int = int(condition.get("range", 1))
			var rht_mech: StringName = _equip_mech_id(binding, payload)
			var rht_ctx = binding.context if binding != null else null
			if rht_mech == &"" or rht_ctx == null or rht_ctx.get("game_state") == null:
				return false
			var rht_boost_range: int = _ActionPilotEffects.get_repair_range(rht_ctx.game_state, rht_mech)
			if rht_boost_range > rht_range:
				rht_range = rht_boost_range
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
			if not _has_repair_target(rba_ctx.game_state, rba_mech, _ActionPilotEffects.get_repair_range(rba_ctx.game_state, rba_mech)):
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
			# 维修分支（范围读机师牌 repair_boost：坎得等 range=4）
			if _has_repair_target(mao_ctx.game_state, mao_mech, _ActionPilotEffects.get_repair_range(mao_ctx.game_state, mao_mech)):
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
			# 本牌所属机甲 hex 范围内存在存活机甲（pilot_002/004/006/009 用）
			# params.range 为六角距离上限；距离用 _HexGrid.distance（odd-q offset 校正）。
			# params.include_self（默认 false）：true 时自己也算候选（奥黛尔 pilot_038 等
			# 「含我方」效果用；自己距离0必在范围内，含自己通常使条件恒真）。
			var hmr_params: Dictionary = condition.get("params", condition)
			var hmr_range: int = int(hmr_params.get("range", condition.get("range", 1)))
			var hmr_include_self: bool = bool(hmr_params.get("include_self", false))
			var hmr_mech_id: StringName = _equip_mech_id(binding, payload)
			var hmr_ctx = binding.context if binding != null else null
			if hmr_mech_id == &"" or hmr_ctx == null or hmr_ctx.get("game_state") == null:
				return false
			var hmr_src = hmr_ctx.game_state.mechs.get(hmr_mech_id)
			if hmr_src == null:
				return false
			for hmr_mid in hmr_ctx.game_state.mechs:
				if hmr_mid == hmr_mech_id and not hmr_include_self:
					continue
				var hmr_m = hmr_ctx.game_state.mechs[hmr_mid]
				if hmr_m == null or hmr_m.destroyed:
					continue
				if _hex_distance(hmr_src.position, hmr_m.position) <= hmr_range:
					return true
			return false

		&"OTHER_MECH_WITH_ACTION_CARD_IN_HEX_RANGE":
			# 本牌所属机甲 hex 范围内存在其他存活机甲且其玩家持有行动牌（骇客 pilot_066 移动窥牌用）。
			# params.range 为六角距离上限；距离用 _hex_distance（odd-q offset 校正）。
			# 只统计「玩家手牌 action_hand 非空」的机甲（0张行动牌的机甲不算候选，即使可被查看空窗）。
			var omw_params: Dictionary = condition.get("params", condition)
			var omw_range: int = int(omw_params.get("range", condition.get("range", 3)))
			var omw_mech_id: StringName = _equip_mech_id(binding, payload)
			var omw_ctx = binding.context if binding != null else null
			if omw_mech_id == &"" or omw_ctx == null or omw_ctx.get("game_state") == null:
				return false
			var omw_gs = omw_ctx.game_state
			var omw_src = omw_gs.mechs.get(omw_mech_id)
			if omw_src == null or omw_src.destroyed:
				return false
			for omw_mid: StringName in omw_gs.mechs:
				if omw_mid == omw_mech_id:
					continue
				var omw_m = omw_gs.mechs[omw_mid]
				if omw_m == null or omw_m.destroyed:
					continue
				if _hex_distance(omw_src.position, omw_m.position) > omw_range:
					continue
				var omw_owner: StringName = omw_m.owner_player_id
				var omw_player = omw_gs.players.get(omw_owner) if omw_owner != &"" else null
				if omw_player != null and not omw_player.action_hand.is_empty():
					return true
			return false

		&"HAS_OTHER_MECH_IN_VARIABLE_RANGE":
			# pilot_027 维罗妮卡效果3：4+X格范围内存在其他存活机甲（X存机师牌实例counters，可变范围）。
			# params.base_range=4（固定基数），params.variable_name=&"pilot_027_x"（从 owner 机师牌实例读）。
			# 范围随效果2「给予金币X+1」动态增长；距离用 _HexGrid.distance。
			var hv_params: Dictionary = condition.get("params", condition)
			var hv_base: int = int(hv_params.get("base_range", 4))
			var hv_var_name: String = String(hv_params.get("variable_name", &""))
			var hv_mech_id: StringName = _equip_mech_id(binding, payload)
			var hv_ctx = binding.context if binding != null else null
			if hv_mech_id == &"" or hv_ctx == null or hv_ctx.get("game_state") == null:
				return false
			var hv_src = hv_ctx.game_state.mechs.get(hv_mech_id)
			if hv_src == null or hv_src.destroyed:
				return false
			var hv_x: int = 0
			if hv_var_name == "pilot_027_x":
				hv_x = _ActionPilotEffects.get_pilot_027_x(_ActionPilotEffects.pilot_027_pilot_card(hv_ctx.game_state))
			var hv_range: int = hv_base + hv_x
			for hv_mid in hv_ctx.game_state.mechs:
				if hv_mid == hv_mech_id:
					continue
				var hv_m = hv_ctx.game_state.mechs[hv_mid]
				if hv_m == null or hv_m.destroyed:
					continue
				if _hex_distance(hv_src.position, hv_m.position) <= hv_range:
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

		&"DISCARD_CONTAINS_FACEUP_EQUIPMENT":
			# 本次弃置动作中含「原先正面设置在机甲上」的装备牌（pilot_085 莽克弃装获金）。
			# 正面设置 = 快照 from_zone==equipment_slot 且非 face_down（备用区背面设置除外）；
			# 手上未设置(from_zone=equipment_hand)/临时区(temp_zone)天然排除。
			# 覆盖被新牌顶掉(equipment_replace)/损坏(damage_durability)/卖出(量产装 sell_set_equipment)等弃置路径。
			var dfp_snapshots: Array = payload.get("discard_snapshots", [])
			for dfp_snap in dfp_snapshots:
				if not (dfp_snap is Dictionary):
					continue
				if String(dfp_snap.get("card_kind", &"")) != "equipment":
					continue
				if String(dfp_snap.get("from_zone", &"")) != "equipment_slot":
					continue
				if String(dfp_snap.get("from_mech_id", &"")) == "":
					continue
				if bool(dfp_snap.get("face_down", false)):
					continue
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
		# 生命变动（hp_change）通用条件（杰狞 pilot_049 等复用）
		# ════════════════════════════════════════════════════════════

		&"HP_CHANGE_LIVE_METHOD_IS":
			# 读被监听 hp_change 动作的「活 record」method（而非 fire 时快照 payload）。
			# 低优先级监听器（如杰狞优先级-1）需要看到高优先级效果（安德洛美达反转 priority30）
			# 改写过的 record.method（restore→decrease），payload 快照看不到，须查活 record。
			var hclm_params: Dictionary = condition.get("params", condition)
			var hclm_method: StringName = hclm_params.get("method", condition.get("method", &""))
			var hclm_live = _live_action_record(binding, payload)
			if hclm_live == null or hclm_live.is_empty():
				return false
			return String(hclm_live.get("method", &"")) == String(hclm_method)

		&"HP_CHANGE_TARGET_IS_OTHER_WITHIN_RANGE":
			# 生命变动目标机甲 ≠ 效果所属机甲，且 hex 距离 ≤ base_range（杰狞伤害转移等通用条件）。
			var hcow_params: Dictionary = condition.get("params", condition)
			var hcow_range: int = int(hcow_params.get("base_range", condition.get("base_range", 4)))
			var hcow_self: StringName = _equip_mech_id(binding, payload)
			if hcow_self == &"":
				return false
			var hcow_target: StringName = _hp_change_target(payload)
			if hcow_target == &"" or hcow_target == hcow_self:
				return false
			var hcow_ctx = binding.context if binding != null else null
			if hcow_ctx == null or hcow_ctx.get("game_state") == null:
				return false
			var hcow_src = hcow_ctx.game_state.mechs.get(hcow_self)
			var hcow_tgt = hcow_ctx.game_state.mechs.get(hcow_target)
			if hcow_src == null or hcow_tgt == null:
				return false
			return _hex_distance(hcow_src.position, hcow_tgt.position) <= hcow_range

		&"HP_CHANGE_TARGET_WITHIN_RANGE_INCLUDING_SELF":
			# 生命变动目标机甲 == 效果所属机甲，或 hex 距离 ≤ base_range（含自身的"范围内受伤"通用条件，
			# 芮贝卡 pilot_078 等用；与 HP_CHANGE_TARGET_IS_OTHER_WITHIN_RANGE 的区别是允许目标=自身）。
			# 目标已毁灭（HP≤0 在本动作 step 已 destroy）不可回复，直接排除。
			var hcw_params: Dictionary = condition.get("params", condition)
			var hcw_range: int = int(hcw_params.get("base_range", condition.get("base_range", 3)))
			var hcw_self: StringName = _equip_mech_id(binding, payload)
			if hcw_self == &"":
				return false
			var hcw_target: StringName = _hp_change_target(payload)
			if hcw_target == &"":
				return false
			var hcw_ctx = binding.context if binding != null else null
			if hcw_ctx == null or hcw_ctx.get("game_state") == null:
				return false
			var hcw_src = hcw_ctx.game_state.mechs.get(hcw_self)
			var hcw_tgt = hcw_ctx.game_state.mechs.get(hcw_target)
			if hcw_src == null or hcw_tgt == null or hcw_tgt.destroyed:
				return false
			if String(hcw_target) == String(hcw_self):
				return true
			return _hex_distance(hcw_src.position, hcw_tgt.position) <= hcw_range

		&"ATTACK_ATTACKER_WITHIN_RANGE_INCLUDING_SELF":
			# 攻击方机甲在 base_range 内（含自身=效果所属机甲）的通用条件（维奥拉 pilot_077 等）。
			# 与 HP_CHANGE_TARGET_WITHIN_RANGE_INCLUDING_SELF 同构：允许攻击方==效果所属机甲，
			# 与 HP_CHANGE_TARGET_IS_OTHER_WITHIN_RANGE 的区别是允许攻击方=自身。
			var aaws_params: Dictionary = condition.get("params", condition)
			var aaws_range: int = int(aaws_params.get("base_range", condition.get("base_range", 3)))
			var aaws_self: StringName = _equip_mech_id(binding, payload)
			if aaws_self == &"":
				return false
			var aaws_attacker: StringName = payload.get("attacker_id", &"")
			if aaws_attacker == &"":
				return false
			if String(aaws_attacker) == String(aaws_self):
				return true
			var aaws_ctx = binding.context if binding != null else null
			if aaws_ctx == null or aaws_ctx.get("game_state") == null:
				return false
			var aaws_src = aaws_ctx.game_state.mechs.get(aaws_self)
			var aaws_atk = aaws_ctx.game_state.mechs.get(aaws_attacker)
			if aaws_src == null or aaws_atk == null or aaws_atk.destroyed:
				return false
			return _hex_distance(aaws_src.position, aaws_atk.position) <= aaws_range

		&"HP_CHANGE_SOURCE_MECH_IS_BINDING":
			# 造成本次生命变动的来源机甲 == 效果所属机甲（negate=true 取反）。
			# 读活 record 的 source.mech_id：安德洛美达反转在优先级30已清 source（无源伤害），
			# 杰狞在-1 读到空 → 不匹配绑定（杰狞排除"自己造成的伤害"的转移询问）。
			# 陷阱无来源（source 空）→ 不匹配绑定（效果2不加伤；效果1排除自伤后仍可转移）。
			var hcsb_params: Dictionary = condition.get("params", condition)
			var hcsb_negate: bool = bool(hcsb_params.get("negate", condition.get("negate", false)))
			var hcsb_self: StringName = _equip_mech_id(binding, payload)
			if hcsb_self == &"":
				return false
			var hcsb_src: StringName = &""
			var hcsb_live = _live_action_record(binding, payload)
			if hcsb_live != null and not hcsb_live.is_empty():
				var hcsb_src_dict: Dictionary = hcsb_live.get("source", {})
				if hcsb_src_dict is Dictionary:
					hcsb_src = hcsb_src_dict.get("mech_id", &"")
					# 攻击伤害：hp_change 的 source.mech_id 为空（只在 source_action_id 指向 attack），
					# 退回 source_action_id -> attack 动作的 attacker_id（同 pilot_034 来源解析）。
					# 仅来源是攻击动作才回溯；效果/陷阱来源 action 非 attack 则保持空（不匹配绑定）。
					if hcsb_src == &"":
						var hcsb_src_aid: StringName = hcsb_src_dict.get("source_action_id", &"")
						if hcsb_src_aid != &"" and binding != null and binding.context != null and binding.context.get("action_registry") != null:
							var hcsb_src_action = binding.context.action_registry.get_action(hcsb_src_aid)
							if hcsb_src_action != null and hcsb_src_action.action_type == &"attack":
								hcsb_src = hcsb_src_action.record.get("attacker_id", &"")
			var hcsb_match: bool = (hcsb_src != &"" and String(hcsb_src) == String(hcsb_self))
			return not hcsb_match if hcsb_negate else hcsb_match

		&"BINDING_CARD_COUNTER_ABOVE":
			# 效果所属卡实例（binding_context.card_instance_id）counters["var_<counter_key>"] > threshold。
			# 杰狞效果2 X 计数：INCREMENT_VARIABLE 写 card.counters["var_<name>"]，此处读。
			var bcca_params: Dictionary = condition.get("params", condition)
			var bcca_key: StringName = bcca_params.get("counter_key", condition.get("counter_key", &""))
			var bcca_threshold: int = int(bcca_params.get("threshold", condition.get("threshold", 0)))
			var bcca_bind: Dictionary = payload.get("binding_context", {})
			var bcca_cid: StringName = bcca_bind.get("card_instance_id", &"")
			var bcca_ctx = binding.context if binding != null else null
			if bcca_cid == &"" or bcca_ctx == null or bcca_ctx.get("game_state") == null:
				return false
			var bcca_card = bcca_ctx.game_state.get_card(bcca_cid)
			if bcca_card == null:
				return false
			var bcca_counters: Dictionary = bcca_card.counters if bcca_card.counters != null else {}
			var bcca_val: int = int(bcca_counters.get("var_%s" % String(bcca_key), 0))
			return bcca_val > bcca_threshold

		&"MECH_IS_OTHER_THAN_BINDING":
			# 通用：payload 携带的机甲（payload.mech_id / source_mech_id）是"其他机甲"——
			# 存活且 != 效果绑定机甲（动力税等监听其他机甲行为的效果用）。
			var miob_mech: StringName = payload.get("mech_id", payload.get("source_mech_id", &""))
			var miob_self: StringName = _equip_mech_id(binding, payload)
			if miob_mech == &"" or miob_self == &"" or String(miob_mech) == String(miob_self):
				return false
			var miob_ctx = binding.context if binding != null else null
			if miob_ctx == null or miob_ctx.get("game_state") == null:
				return false
			var miob_m = miob_ctx.game_state.mechs.get(miob_mech)
			return miob_m != null and not miob_m.destroyed

		&"PAYLOAD_MECH_IN_COUNTER_VARIABLE_RANGE":
			# 通用：payload 携带的机甲在绑定机甲 (base_range + 绑定牌counter X) 格范围内
			# （hex 距离）。X 存绑定卡实例 counters["var_<counter_key>"]
			# （INCREMENT_VARIABLE 写入，杰西卡 pilot_050 的 4+X 可变范围用；不绑机师ID）。
			# 位置用消耗时快照：动力税在 BASIC_MOVE_AT（先消耗后移动）触发时 payload.mech_id
			# 的位置仍是移动前位置。
			var pmcv_params: Dictionary = condition.get("params", condition)
			var pmcv_base: int = int(pmcv_params.get("base_range", 4))
			var pmcv_key: StringName = pmcv_params.get("counter_key", &"")
			var pmcv_mech: StringName = payload.get("mech_id", payload.get("source_mech_id", &""))
			var pmcv_self: StringName = _equip_mech_id(binding, payload)
			var pmcv_ctx = binding.context if binding != null else null
			if pmcv_mech == &"" or pmcv_self == &"" or pmcv_ctx == null or pmcv_ctx.get("game_state") == null:
				return false
			var pmcv_src = pmcv_ctx.game_state.mechs.get(pmcv_self)
			var pmcv_tgt = pmcv_ctx.game_state.mechs.get(pmcv_mech)
			if pmcv_src == null or pmcv_tgt == null or pmcv_src.destroyed or pmcv_tgt.destroyed:
				return false
			var pmcv_extra: int = 0
			if pmcv_key != &"":
				var pmcv_bind: Dictionary = payload.get("binding_context", {})
				var pmcv_cid: StringName = pmcv_bind.get("card_instance_id", &"")
				if pmcv_cid != &"":
					var pmcv_card = pmcv_ctx.game_state.get_card(pmcv_cid)
					if pmcv_card != null:
						var pmcv_counters: Dictionary = pmcv_card.counters if pmcv_card.counters != null else {}
						pmcv_extra = int(pmcv_counters.get("var_%s" % String(pmcv_key), 0))
			return _hex_distance(pmcv_src.position, pmcv_tgt.position) <= pmcv_base + pmcv_extra

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
		# pilot_035 库马斯 条件
		# ════════════════════════════════════════════════════════════

		&"PILOT_035_MARK_ACTIVE":
			# 本库马斯实例已设置本轮标记机甲（effect_02 选择过且未被取消/未在轮始被 reset 清掉）
			var p035_bind: Dictionary = payload.get("binding_context", {})
			var p035_source: StringName = p035_bind.get("card_instance_id", &"")
			if p035_source == &"":
				return false
			return _ActionPilotEffects.get_pilot_035_mark(p035_source) != &""

		&"GAIN_CARD_IS_DRAW":
			# 本次 gain_card 是"抽取"（统一 draw 标：card_ids 空 + 系统从牌堆/弃牌堆自动取牌）。
			# 觉醒（选牌获取）、回收维修（明确 card_ids）、识破偷牌（steal 不走 gain_card）、
			# 给予转移（transfer 不走 gain_card）均无此标。
			return bool(payload.get("draw", false))

		&"GAIN_CARD_IS_ACTION_DRAW":
			# 抽取的是行动牌（装备抽取/商店购买等自动排除）
			return payload.get("draw_card_kind", &"") == &"action"

		&"GAIN_CARD_DRAW_OWNER_IS_BINDING":
			# 抽取方（玩家/机甲）== 效果拥有者（binding_context.player_id/mech_id）。
			# 通用条件（格温 pilot_043 宣言抽取等）：只对效果拥有者自己的抽取生效。
			var gdob: Dictionary = payload.get("binding_context", {})
			var gdob_pid: StringName = gdob.get("player_id", &"")
			var gdob_mid: StringName = gdob.get("mech_id", &"")
			if gdob_pid == &"" and gdob_mid == &"":
				return false
			var gdob_dpid: StringName = payload.get("draw_player_id", &"")
			if gdob_pid != &"" and gdob_dpid == gdob_pid:
				return true
			var gdob_dmids: Array = payload.get("draw_mech_ids", [])
			for gdob_m in gdob_dmids:
				if StringName(gdob_m) == gdob_mid:
					return true
			return false

		&"CARD_COUNTER_IS":
			# 通用：来源牌实例 counters[key] == value。键不存在时按 default_when_absent（默认 true）。
			# 开关型效果：DIRECT 按钮翻转 flag（SET_CARD_COUNTER），LISTEN 效果读 flag 决定是否发动。
			# 银雪 pilot_065 窥牌拦截默认启用（absent->true==true 通过）；禁用后 false!=true 不发动。
			var cci_p: Dictionary = condition.get("params", condition)
			var cci_key: String = String(cci_p.get("key", &""))
			if cci_key == "":
				return false
			var cci_value: Variant = cci_p.get("value", true)
			var cci_default: Variant = cci_p.get("default_when_absent", true)
			var cci_bind: Dictionary = payload.get("binding_context", {})
			var cci_cid: StringName = cci_p.get("card_instance_id", cci_bind.get("card_instance_id", &""))
			var cci_ctx = binding.context if binding != null else null
			if cci_cid == &"" or cci_ctx == null or cci_ctx.get("game_state") == null:
				return false
			var cci_card = cci_ctx.game_state.get_card(cci_cid)
			if cci_card == null:
				return false
			var cci_cur: Variant = cci_card.counters.get(cci_key, cci_default) if "counters" in cci_card else cci_default
			return cci_cur == cci_value

		&"GAIN_CARD_DRAW_MECH_WITHIN_HEX_RANGE":
			# 通用：抽取方机甲（payload.draw_mech_ids，空则回退 draw_player_id 的全部机甲）
			# 在效果拥有者机甲 hex 范围内（含自身，距离0）。银雪 pilot_065：3格内机甲（含我方）抽牌前触发。
			var gdmwr_p: Dictionary = condition.get("params", condition)
			var gdmwr_range: int = int(gdmwr_p.get("range", condition.get("range", 3)))
			var gdmwr_bind_mech: StringName = _equip_mech_id(binding, payload)
			var gdmwr_ctx = binding.context if binding != null else null
			if gdmwr_bind_mech == &"" or gdmwr_ctx == null or gdmwr_ctx.get("game_state") == null:
				return false
			var gdmwr_src = gdmwr_ctx.game_state.mechs.get(gdmwr_bind_mech)
			if gdmwr_src == null:
				return false
			var gdmwr_candidates: Array = payload.get("draw_mech_ids", [])
			if gdmwr_candidates.is_empty():
				var gdmwr_dpid: StringName = payload.get("draw_player_id", &"")
				if gdmwr_dpid != &"":
					var gdmwr_fallback: Array = []
					for gdmwr_mid in gdmwr_ctx.game_state.mechs:
						var gdmwr_m0 = gdmwr_ctx.game_state.mechs[gdmwr_mid]
						if gdmwr_m0 != null and gdmwr_m0.owner_player_id == gdmwr_dpid:
							gdmwr_fallback.append(gdmwr_mid)
					gdmwr_candidates = gdmwr_fallback
			for gdmwr_mid in gdmwr_candidates:
				var gdmwr_m = gdmwr_ctx.game_state.mechs.get(StringName(gdmwr_mid))
				if gdmwr_m == null:
					continue
				if _hex_distance(gdmwr_src.position, gdmwr_m.position) <= gdmwr_range:
					return true
			return false

		&"SHOP_BUYER_IS_SELF":
			# 商店购买者（buyer_player_id/buyer_mech_id）== 效果拥有者（binding_context.player_id/mech_id）。
			# 通用条件（莉卡尔 pilot_054 等"购买后触发"效果）：只对效果拥有者自己的购买生效。
			var sbis: Dictionary = payload.get("binding_context", {})
			var sbis_pid: StringName = sbis.get("player_id", &"")
			var sbis_mid: StringName = sbis.get("mech_id", &"")
			if sbis_pid == &"" and sbis_mid == &"":
				return false
			var sbis_bpid: StringName = payload.get("buyer_player_id", &"")
			if sbis_pid != &"" and sbis_bpid == sbis_pid:
				return true
			var sbis_bmid: StringName = payload.get("buyer_mech_id", &"")
			if sbis_mid != &"" and StringName(sbis_bmid) == sbis_mid:
				return true
			return false

		&"PAYLOAD_BOOL_IS_TRUE":
			# 读 payload 布尔标志（通用：params.key 指定的 payload 键为真）。
			# 莉卡尔 pilot_054 判断本次购买的是否高级装备（payload.is_advanced）。
			var pbt_params: Dictionary = condition.get("params", {})
			var pbt_key: String = String(pbt_params.get("key", &""))
			if pbt_key == "":
				return false
			return bool(payload.get(pbt_key, false))

		&"GAIN_CARD_DRAWN_INCLUDE_RECORD_ACTION_TYPE":
			# 本次抽到的牌（drawn_card_ids）中含 record[record_key] 宣言的行动牌类型。
			# 通用条件（格温 pilot_043：BEFORE 宣言写入 record，AFTER 检查抽牌含该类型）。
			var gdir_params: Dictionary = condition.get("params", {})
			var gdir_key: StringName = StringName(gdir_params.get("record_key", &""))
			if gdir_key == &"":
				return false
			var gdir_declared: String = String(payload.get(gdir_key, &""))
			if gdir_declared == "":
				return false
			var gdir_drawn: Array = payload.get("drawn_card_ids", [])
			if gdir_drawn.is_empty():
				return false
			var gdir_ctx = binding.context if binding != null else null
			if gdir_ctx == null or gdir_ctx.get("game_state") == null:
				return false
			for gdir_cid in gdir_drawn:
				var gdir_card = gdir_ctx.game_state.get_card(StringName(gdir_cid))
				if gdir_card != null and gdir_card.def != null \
						and gdir_card.def.card_kind == &"action" \
						and String(gdir_card.def.action_type) == gdir_declared:
					return true
			return false

		&"PILOT_035_DRAW_MECH_IS_MARKED":
			# 抽取方机甲 == 本库马斯本轮标记机甲
			var p035b2: Dictionary = payload.get("binding_context", {})
			var p035_src2: StringName = p035b2.get("card_instance_id", &"")
			var p035_marked: StringName = _ActionPilotEffects.get_pilot_035_mark(p035_src2) if p035_src2 != &"" else &""
			if p035_marked == &"":
				return false
			var p035_draw_mids: Array = payload.get("draw_mech_ids", [])
			for p035_dmid in p035_draw_mids:
				if StringName(p035_dmid) == p035_marked:
					return true
			return false

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

		&"ATTACK_SOURCE_CARD_IS":
			# 伏特 effect_02：本次攻击源牌的"有效 def_id"（实体牌 def.card_id，或虚拟转化牌 counters.virtual_as_def_id）
			# 在指定列表中。识别强袭/猛击/破甲（伏特效果1转化虚拟牌 + 原版实体牌均命中）。
			var asc_params: Dictionary = condition.get("params", condition)
			var asc_ids: Array = asc_params.get("card_def_ids", condition.get("card_def_ids", []))
			var asc_card_id: StringName = payload.get("attack_card_id", payload.get("card_instance_id", &""))
			if asc_card_id == &"":
				return false
			var asc_ctx = binding.context if binding != null else null
			if asc_ctx == null or asc_ctx.get("game_state") == null:
				return false
			var asc_card = asc_ctx.game_state.get_card(asc_card_id)
			if asc_card == null or asc_card.def == null:
				return false
			# 有效 def_id：虚拟转化牌读 counters.virtual_as_def_id，否则读 def.card_id
			var asc_eff_id: StringName = asc_card.counters.get("virtual_as_def_id", &"")
			if asc_eff_id == &"":
				asc_eff_id = asc_card.def.card_id
			return asc_ids.has(String(asc_eff_id))

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
			var pcu_aura: Dictionary = pcu_ctx.map_service.get_attack_aura_cells()
			# 与 attack_action._step_select_target 口径一致：机甲格为路径障碍 + 陷落不可被指定
			var pcu_blocked: Dictionary = pcu_ctx.map_service.get_attack_blocked_keys(pcu_mech_id)
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
					if pcu_m.has_status(&"cannot_be_targeted"):
						continue
					if _RangeCalculator.is_in_weapon_range(pcu_mech.position, pcu_m.position, pcu_rv, pcu_cells, pcu_aura, pcu_blocked):
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
			var muac_aura: Dictionary = muac_ctx.map_service.get_attack_aura_cells()
			# 与 attack_action._step_select_target 口径一致：机甲格为路径障碍 + 陷落不可被指定
			var muac_blocked: Dictionary = muac_ctx.map_service.get_attack_blocked_keys(muac_target)
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
					if muac_m.has_status(&"cannot_be_targeted"):
						continue
					if _RangeCalculator.is_in_weapon_range(muac_mech.position, muac_m.position, muac_rv, muac_cells, muac_aura, muac_blocked):
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

		&"EFFECT_ONCE_PER_TURN_AVAILABLE":
			# 通用件：某来源牌实例的每回合N次额度本回合是否未用满（跨效果共享额度）。
			# 用于效果分支复用另一个效果的额度（如布鲁克 effect_02 的转化防御分支消耗
			# effect_01 的每回合1次：分支 condition 检查，动作 MARK_EFFECT_ONCE_PER_TURN_USED 标记）。
			# params: {once_per_turn_key, once_per_turn_max(默认1)}；来源实例取 binding_context.card_instance_id。
			var eoa_params: Dictionary = condition.get("params", condition)
			var eoa_key: StringName = eoa_params.get("once_per_turn_key", &"")
			if eoa_key == &"":
				return true
			var eoa_max: int = int(eoa_params.get("once_per_turn_max", 1))
			var eoa_cid: StringName = _equip_card_instance_id(binding, payload)
			var eoa_ctx = binding.context if binding != null else null
			if eoa_ctx == null or eoa_ctx.get("timing_engine") == null:
				return false
			return eoa_ctx.timing_engine.is_once_per_turn_key_available(eoa_key, eoa_cid, eoa_max)

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
			var smr_aura: Dictionary = smr_ctx.map_service.get_attack_aura_cells()
			# 与 _step_check_hit 命中判定口径一致（机甲格为攻击路径障碍）
			var smr_blocked: Dictionary = smr_ctx.map_service.get_attack_blocked_keys(smr_attacker_id)
			return _RangeCalculator.is_in_weapon_range(smr_attacker.position, smr_self_mech.position, smr_range, smr_map, smr_aura, smr_blocked)

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

		&"OWNER_ACTION_HAND_GREATER_THAN_MECH":
			# 青瞳 pilot_037：效果拥有方玩家的行动手牌数 > 指定机甲玩家(如攻击方)的行动手牌数。
			# mech_id 可为 $payload.attacker_id / $current_target.mech_id 等动态表达式（_resolve_checker_expr）。
			# 语义：偷牌结算后我方手牌数大于攻击方手牌数（等于不算）才满足。
			var oah_p: Dictionary = condition.get("params", condition)
			var oah_mech_expr = oah_p.get("mech_id", condition.get("mech_id", &""))
			var oah_mech: StringName = _resolve_checker_expr(oah_mech_expr, binding, payload)
			var oah_owner: StringName = _equip_mech_id(binding, payload)
			if oah_mech == &"" or oah_owner == &"":
				return false
			var oah_ctx = binding.context if binding != null else null
			if oah_ctx == null or oah_ctx.get("game_state") == null:
				return false
			var oah_owner_player = oah_ctx.game_state.get_player_for_mech(oah_owner)
			var oah_mech_player = oah_ctx.game_state.get_player_for_mech(oah_mech)
			if oah_owner_player == null or oah_mech_player == null:
				return false
			return oah_owner_player.action_hand.size() > oah_mech_player.action_hand.size()

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

		&"ATTACK_RECORD_FLAG_NOT_SET":
			# 伏特 effect_02：attack.record._effect_flags 中无指定 flag。
			# 诺拉 pilot_015_force_pure_assault 把攻击变纯进攻后，猛击+3威/破甲+2损/强袭回4动不生效。
			var rnfs_params: Dictionary = condition.get("params", condition)
			var rnfs_flag: StringName = rnfs_params.get("flag", condition.get("flag", &""))
			if rnfs_flag == &"":
				return false
			var rnfs_flags: Dictionary = payload.get("_effect_flags", {})
			var rnfs_entry: Dictionary = rnfs_flags.get(rnfs_flag, {})
			return not bool(rnfs_entry.get("value", false))

		&"ATTACK_RECORD_FLAG_IS_SET":
			# pilot_018 苔丝 effect_01b：attack.record._effect_flags 中指定 flag 已设（01a 发动过）。
			# flag 由 01a SET_ACTION_RECORD_FLAG 写入 attack.record["_effect_flags"][flag]；
			# fork 深拷贝 record 故 flag 继承到各复制攻击，使双连打苔丝的 fork 也能触发 01b。
			var rfs_params: Dictionary = condition.get("params", condition)
			var rfs_flag: StringName = rfs_params.get("flag", condition.get("flag", &""))
			if rfs_flag == &"":
				return false
			var rfs_flags: Dictionary = payload.get("_effect_flags", {})
			var rfs_entry: Dictionary = rfs_flags.get(rfs_flag, {})
			return bool(rfs_entry.get("value", false))

		&"ATTACK_RESPONDED_BY_OWNER_REAL_COUNTER":
			# pilot_018 苔丝 effect_01b：本攻击被「苔丝拥有方用真实迎击牌」响应（非虚拟转化牌）。
			# 判定：responded=true + response_source.player_id == 苔丝 owner_player_id
			#       + 响应牌 action_type=="迎击" 且非虚拟转化（无 virtual_as_def_id 标记）。
			# 「真实迎击牌」排除：莱比尔/迪恩/诺拉等 virtual_transform 转化出的虚拟迎击牌、
			# 装备牌响应（counter_attacked=false 的非迎击响应）、非苔丝方的响应。
			# 时点天然保证：01b 挂 ATTACK_AT priority 0（响应窗口关闭后补跑），此时反击 effect2
			# 的额外攻击尚未执行（在 ATTACK_SETTLE），故只算「第一个光响应」，后续额外攻击不计。
			if not bool(payload.get("responded", false)):
				return false
			var rs_source: Dictionary = payload.get("response_source", {})
			var rs_card_id: StringName = rs_source.get("card_instance_id", payload.get("response_card_id", &""))
			if rs_card_id == &"":
				return false
			# 响应方 == 苔丝拥有者（binding_context.player_id）
			var rbrc_owner_pid: StringName = _equip_player_id(binding, payload)
			var rs_responder_pid: StringName = rs_source.get("player_id", &"")
			if rbrc_owner_pid == &"" or rs_responder_pid == &"" or rbrc_owner_pid != rs_responder_pid:
				return false
			# 响应牌须为真实迎击牌：查 CardInstance
			var rbrc_ctx = binding.context if binding != null else null
			if rbrc_ctx == null or rbrc_ctx.get("game_state") == null:
				return false
			var rbrc_card = rbrc_ctx.game_state.get_card(rs_card_id)
			if rbrc_card == null or rbrc_card.def == null:
				return false
			# 虚拟转化牌（virtual_transform）：counters.virtual_as_def_id 标记由 use_action_card 写入
			if rbrc_card.counters.has("virtual_as_def_id"):
				return false
			# 必须是迎击牌（action_type=="迎击"）
			var rbrc_at: String = String(rbrc_card.def.action_type) if "action_type" in rbrc_card.def else ""
			return rbrc_at == "迎击"

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

		# ════════════════════════════════════════════════════════════
		# 事件牌系统通用条件（GeneratedEventEffects 使用，不绑具体牌）
		# ════════════════════════════════════════════════════════════

		&"OWNER_PILOT_OR_FRAME_HAS_FACTION":
			# 遭遇事件：效果绑定机甲的机师牌 或 机甲框架 任一阵营 == faction。
			return _owner_pilot_or_frame_faction_matches(binding, payload, condition, true)

		&"OWNER_PILOT_OR_FRAME_LACKS_FACTION":
			# 遭遇事件：效果绑定机甲的机师牌与机甲框架阵营均 != faction。
			return _owner_pilot_or_frame_faction_matches(binding, payload, condition, false)

		&"PAYLOAD_EVENT_CARD_IS_SELF":
			# EVENT_TIMER_EXPIRE / EVENT_RESOLVE 等时点 payload 的事件牌 == 本牌
			# （payload.event_card_id == binding_context.card_instance_id，任务奖励只对到期牌触发）。
			var pecis_bind: Dictionary = payload.get("binding_context", {})
			var pecis_self: StringName = pecis_bind.get("card_instance_id", &"")
			if pecis_self == &"":
				pecis_self = _equip_card_instance_id(binding, payload)
			var pecis_payload_card: StringName = payload.get("event_card_id", &"")
			return pecis_self != &"" and pecis_payload_card != &"" and String(pecis_self) == String(pecis_payload_card)

		&"PAYLOAD_PLAYER_IS_OWNER":
			# 通用：payload[key] 的玩家 id == 效果绑定玩家（金币任务：GAIN_GOLD_AFTER 的
			# gainer_player_id == 绑定玩家 -> 我方获金才累积进度）。key 参数默认 gainer_player_id。
			var ppio_params: Dictionary = condition.get("params", condition)
			var ppio_key: String = String(ppio_params.get("key", "gainer_player_id"))
			var ppio_owner: StringName = _equip_player_id(binding, payload)
			var ppio_payload_pid: StringName = payload.get(ppio_key, &"")
			return ppio_owner != &"" and ppio_payload_pid != &"" and String(ppio_owner) == String(ppio_payload_pid)

		&"PAYLOAD_MECH_IS_BINDING":
			# 通用：payload 携带的机甲（payload.mech_id）== 效果绑定机甲
			# （设置任务：SET_EQUIP_AFTER 的 mech_id == 绑定机甲 -> 只算我方机甲的设置）。
			var pmib_mech: StringName = payload.get("mech_id", payload.get("source_mech_id", &""))
			var pmib_self: StringName = _equip_mech_id(binding, payload)
			return pmib_mech != &"" and pmib_self != &"" and String(pmib_mech) == String(pmib_self)

		&"PAYLOAD_SLOT_NOT_RESERVE":
			# 通用：payload.slot_id 对应槽位非备用区（正面设置判定，事件牌设置任务用；
			# 备用区背面放置不算"正面设置"）。
			var psnr_ctx = binding.context if binding != null else null
			if psnr_ctx == null or psnr_ctx.get("game_state") == null:
				return false
			var psnr_bind: Dictionary = payload.get("binding_context", {})
			var psnr_mech_id: StringName = payload.get("mech_id", psnr_bind.get("mech_id", &""))
			if psnr_mech_id == &"":
				psnr_mech_id = _equip_mech_id(binding, payload)
			var psnr_slot_id: StringName = payload.get("slot_id", &"")
			if psnr_mech_id == &"" or psnr_slot_id == &"":
				return false
			var psnr_mech = psnr_ctx.game_state.mechs.get(psnr_mech_id)
			if psnr_mech == null:
				return false
			var psnr_slot = psnr_mech.slots.get(psnr_slot_id)
			if psnr_slot == null:
				return false
			return String(psnr_slot.slot_kind) != &"RESERVE"

		&"MOVED_DISTANCE_THIS_TURN_BELOW":
			# 通用：本回合累积移动距离 < threshold（事件牌修整 e012「本回合没有移动」threshold=1）。
			# 被动监听从 payload 取；无预填字段时从机甲状态 cells_moved_this_turn 查。
			var mdb_threshold: int = int(condition.get("params", condition).get("threshold", condition.get("threshold", 1)))
			var mdb_cells: int = 0
			if payload != null and payload.has("moved_cells_this_turn"):
				mdb_cells = int(payload.get("moved_cells_this_turn"))
			else:
				mdb_cells = _mech_cells_moved(binding, payload)
			return mdb_cells < mdb_threshold

		&"BINDING_CARD_COUNTER_AT_LEAST":
			# 通用：效果所属卡实例 counters["var_<counter_key>"] >= threshold
			# （事件牌任务达标判定：task_progress >= 10。TRACK_EVENT_PROGRESS 写 var_ 前缀键）。
			var bcat_params: Dictionary = condition.get("params", condition)
			var bcat_key: StringName = bcat_params.get("counter_key", condition.get("counter_key", &""))
			var bcat_threshold: int = int(bcat_params.get("threshold", condition.get("threshold", 0)))
			var bcat_bind: Dictionary = payload.get("binding_context", {})
			var bcat_cid: StringName = bcat_bind.get("card_instance_id", &"")
			var bcat_ctx = binding.context if binding != null else null
			if bcat_cid == &"" or bcat_ctx == null or bcat_ctx.get("game_state") == null:
				return false
			var bcat_card = bcat_ctx.game_state.get_card(bcat_cid)
			if bcat_card == null:
				return false
			var bcat_counters: Dictionary = bcat_card.counters if bcat_card.counters != null else {}
			var bcat_val: int = int(bcat_counters.get("var_%s" % String(bcat_key), 0))
			return bcat_val >= bcat_threshold

		&"BINDING_CARD_COUNTER_BELOW":
			# 通用：效果所属卡实例 counters["var_<counter_key>"] < threshold
			# （任务奖励"未领取"判定：var_task_claimed < 1。INCREMENT_VARIABLE 写 var_ 前缀键）。
			var bcbt_params: Dictionary = condition.get("params", condition)
			var bcbt_key: StringName = bcbt_params.get("counter_key", condition.get("counter_key", &""))
			var bcbt_threshold: int = int(bcbt_params.get("threshold", condition.get("threshold", 0)))
			var bcbt_bind: Dictionary = payload.get("binding_context", {})
			var bcbt_cid: StringName = bcbt_bind.get("card_instance_id", &"")
			var bcbt_ctx = binding.context if binding != null else null
			if bcbt_cid == &"" or bcbt_ctx == null or bcbt_ctx.get("game_state") == null:
				return false
			var bcbt_card = bcbt_ctx.game_state.get_card(bcbt_cid)
			if bcbt_card == null:
				return false
			var bcbt_counters: Dictionary = bcbt_card.counters if bcbt_card.counters != null else {}
			var bcbt_val: int = int(bcbt_counters.get("var_%s" % String(bcbt_key), 0))
			return bcbt_val < bcbt_threshold

		_:
			push_warning("ConditionChecker: 未知条件操作符 %s，默认返回 true" % op)
			return true


# ════════════════════════════════════════════════════════════
# 攻击来源行动牌判定 helper（ATTACK_IS_ASSAULT_CLASS / ATTACK_IS_NAMED_CARD 共享）
# ════════════════════════════════════════════════════════════

## 攻击来源行动牌是否匹配具名卡 id（原版 def.card_id 或转化 counters.virtual_as_def_id）。
## 通用（不绑机师）：从 payload.attack_action_cards 取来源（缺省回退 attack_card_id），逐张判定。
## 布彻尔 pilot_063 进攻判定 / 丹 pilot_067 双连判定共用。
static func _attack_source_is_card_class(payload: Dictionary, gs, def_id: String) -> bool:
	var src: Array = payload.get("attack_action_cards", [])
	if src.is_empty():
		var cid0: StringName = payload.get("attack_card_id", &"")
		if cid0 != &"":
			src = [cid0]
	for scid in src:
		if scid == null or scid == &"":
			continue
		var card = gs.get_card(StringName(scid))
		if card == null:
			continue
		if card.def != null and String(card.def.card_id) == def_id:
			return true
		var counters: Dictionary = card.counters if card.counters is Dictionary else {}
		if String(counters.get("virtual_as_def_id", &"")) == def_id:
			return true
	return false


# 装备牌效果专用 helper：从 binding/payload 取装备牌来源信息
# ════════════════════════════════════════════════════════════

## 事件牌遭遇（通用）：效果绑定机甲的 机师牌阵营 / 机甲框架阵营 与 faction 的匹配。
## has_faction=true：任一 == faction 即命中；has_faction=false：两者均 != faction 才命中。
## faction 参数统一 params 优先回退顶层。
static func _owner_pilot_or_frame_faction_matches(binding, payload: Dictionary, condition: Dictionary, has_faction: bool) -> bool:
	var opf_params: Dictionary = condition.get("params", condition)
	var opf_faction: String = String(opf_params.get("faction", condition.get("faction", &"")))
	if opf_faction == "":
		return false
	var opf_ctx = binding.context if binding != null else null
	if opf_ctx == null or opf_ctx.get("game_state") == null:
		return false
	var opf_mech_id: StringName = _equip_mech_id(binding, payload)
	if opf_mech_id == &"":
		return false
	var opf_mech = opf_ctx.game_state.mechs.get(opf_mech_id)
	if opf_mech == null:
		return false
	# 机师牌阵营（pilot 槽）
	var opf_pilot_faction: String = ""
	var opf_pilot_slot = opf_mech.slots.get(&"pilot")
	if opf_pilot_slot != null and opf_pilot_slot.equipped_card != null and opf_pilot_slot.equipped_card.def != null:
		if "faction" in opf_pilot_slot.equipped_card.def:
			opf_pilot_faction = String(opf_pilot_slot.equipped_card.def.faction)
	# 机甲框架阵营
	var opf_frame_faction: String = ""
	if opf_mech.frame_def != null and "faction" in opf_mech.frame_def:
		opf_frame_faction = String(opf_mech.frame_def.faction)
	if has_faction:
		return opf_pilot_faction == opf_faction or opf_frame_faction == opf_faction
	return opf_pilot_faction != opf_faction and opf_frame_faction != opf_faction


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


## 枚举某玩家所有装备牌实例 id（供"弃装备抽牌"类效果选择/弃置与条件检查共用）。
## 范围：装备手牌 + 该玩家所有机甲已设置槽位（含备用区/事件区/机师区，只看 card_kind==equipment）。
## 遍历玩家所有机甲（PVP3 多机甲通用），非仅首台。事件牌/机师牌/行动牌天然排除（card_kind 过滤）。
static func _equipment_card_ids(game_state, player_id: StringName) -> Array:
	var result: Array = []
	if game_state == null or player_id == &"":
		return result
	var p = game_state.players.get(player_id)
	if p == null:
		return result
	var seen: Dictionary = {}
	# 装备手牌
	for cid: StringName in p.equipment_hand:
		var card = game_state.get_card(cid)
		if card != null and card.def != null and _is_equipment_card_def(card.def):
			seen[cid] = true
			result.append(cid)
	# 该玩家所有机甲的已设置槽位（含备用区）
	for mech in game_state.mechs.values():
		if mech == null or String(mech.owner_player_id) != String(player_id):
			continue
		for sid: StringName in mech.slots:
			var slot = mech.slots[sid]
			if slot == null:
				continue
			var ec = slot.get("equipped_card")
			if ec == null or ec.def == null:
				continue
			if not _is_equipment_card_def(ec.def):
				continue
			var eid: StringName = ec.instance_id
			if not seen.has(eid):
				seen[eid] = true
				result.append(eid)
	return result


## 枚举某玩家所有"未设置的装备牌"实例 id（仅装备手牌，不含任何已设置槽位）。
## 供"弃置未设置的装备牌"类效果弹窗候选与按钮条件检查共用（柏格 pilot_064 等）。
static func _unequipped_equipment_card_ids(game_state, player_id: StringName) -> Array:
	var result: Array = []
	if game_state == null or player_id == &"":
		return result
	var p = game_state.players.get(player_id)
	if p == null:
		return result
	for cid: StringName in p.equipment_hand:
		var card = game_state.get_card(cid)
		if card != null and card.def != null and _is_equipment_card_def(card.def):
			result.append(cid)
	return result


static func _is_equipment_card_def(def) -> bool:
	if def == null:
		return false
	if not ("card_kind" in def) or def.card_kind != &"equipment":
		return false
	return true


## 枚举某玩家所有武器装备牌实例 id（供提比里安 pilot_022 effect_01 弃置与条件检查共用）。
## 范围：装备手牌 + 该玩家机甲所有已设置槽位中 def.equipment_kind==WEAPON 的牌。
## 虚拟武器天然排除——虚拟武器 def.equipment_kind==PART（神莺躯干），此处只看 WEAPON。
static func _weapon_equipment_card_ids(game_state, player_id: StringName) -> Array:
	var result: Array = []
	if game_state == null or player_id == &"":
		return result
	var p = game_state.players.get(player_id)
	if p == null:
		return result
	var seen: Dictionary = {}
	# 装备手牌
	for cid: StringName in p.equipment_hand:
		var card = game_state.get_card(cid)
		if card != null and card.def != null and _is_weapon_equipment_def(card.def):
			seen[cid] = true
			result.append(cid)
	# 机甲所有槽位（武器槽/备用区/部件槽，只要装的是 WEAPON 牌）
	var mech = game_state.get_mech_for_player(player_id)
	if mech != null:
		for sid: StringName in mech.slots:
			var slot = mech.slots[sid]
			if slot == null:
				continue
			var ec = slot.get("equipped_card")
			if ec == null or ec.def == null:
				continue
			if not _is_weapon_equipment_def(ec.def):
				continue
			var eid: StringName = ec.instance_id
			if not seen.has(eid):
				seen[eid] = true
				result.append(eid)
	return result


static func _is_weapon_equipment_def(def) -> bool:
	if def == null:
		return false
	# def 是 CardDef 子类对象（EquipmentCardDef/PilotCardDef/ActionCardDef 等，RefCounted）
	# 或 Dictionary。不能 .get(key, default)（RefCounted 无 2 参 get），改用
	# "prop" in def + 属性访问（对 Dictionary 与对象都成立）。
	if not ("card_kind" in def) or def.card_kind != &"equipment":
		return false
	if not ("equipment_kind" in def):
		return false
	return def.equipment_kind == &"WEAPON"


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


## 读被监听动作的「活 record」：payload 是 fire 时快照副本，低优先级监听器（如杰狞优先级-1）
## 要看到高优先级效果（安德洛美达反转 priority30）改写过的 record，须经 action_id 查 action_registry
## 上的动作实例取其 record（record 随 step handler 改写实时更新）。
static func _live_action_record(binding, payload: Dictionary) -> Dictionary:
	if binding == null:
		return {}
	var ctx = binding.context
	if ctx == null or ctx.get("action_registry") == null:
		return {}
	var aid: StringName = payload.get("action_id", &"")
	if aid == &"":
		return {}
	var action = ctx.action_registry.get_action(aid)
	if action == null:
		return {}
	return action.record


## 生命变动（hp_change）动作的目标机甲：优先 mech_ids[0]，回退 target_id/target_mech_id。
## 杰狞效果1要"其他机甲即将受到伤害"，须定位被变动的目标机甲再比对距离与自身。
static func _hp_change_target(payload: Dictionary) -> StringName:
	var mids: Array = payload.get("mech_ids", [])
	if not mids.is_empty():
		return StringName(mids[0])
	return StringName(payload.get("target_id", payload.get("target_mech_id", &"")))


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
	return get_valid_trap_cells(ctc_ctx.game_state, ctc_card_id, ctc_mech_id, ctc_ctx.map_service.get_attack_aura_cells(), ctc_ctx.map_service.get_attack_blocked_keys(ctc_mech_id)).size()


## 返回武器有效范围内可放陷阱的格子列表（供 CHOOSE_MAP_CELL 选格 UI 高亮+点击）
## 每项: {q, r, cell_id}
## aura_green_cells：攻击光环集合（光环格视为绿格、耗2射程预算），由调用方从 context.map_service.get_attack_aura_cells() 传入；
##   默认 {} 保持无光环时行为不变。
## blocked_keys：攻击路径障碍格集合（context.map_service.get_attack_blocked_keys()，机甲格不可穿过）；
##   默认 {} 行为不变。
static func get_valid_trap_cells(gs, card_id: StringName, mech_id: StringName, aura_green_cells: Dictionary = {}, blocked_keys: Dictionary = {}) -> Array[Dictionary]:
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
		if _RangeCalculator.is_in_weapon_range(mech.position, cell_pos, range, gs.map_state.cells, aura_green_cells, blocked_keys):
			if _cell_can_hold_trap(gs, cell_id):
				result.append({"q": int(cell.q), "r": int(cell.r), "cell_id": String(cell_id)})
	return result


## 收集距 from_position hex 距离 range 内、含指定类型标记的格子列表（供 CHOOSE_MAP_CELL
## 通用 markers 候选源 + MAP_MARKER_IN_RANGE 条件共用）。每项: {q, r, cell_id}。
## marker_type 传 &"ANY"（或空）= 不限类型（事件/金币/陷阱都算，墨尘 pilot_080 相邻标记）。
## min_distance：最小格距（默认0=含自身格；传1=仅严格相邻6格不含自身，
## 墨尘「相邻格子上的标记」语义）。range_val 仍为上界（<=）。
static func get_marker_cells_in_range(gs, from_position: Dictionary, marker_type: StringName, range_val: int, min_distance: int = 0) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if gs == null or gs.map_state == null or from_position.is_empty():
		return result
	var any_type: bool = marker_type == &"ANY" or marker_type == &""
	var seen: Dictionary = {}
	for marker: Dictionary in gs.map_state.markers:
		if not any_type and marker.get("type", &"") != marker_type:
			continue
		var mq: int = int(marker.get("q", 0))
		var mr: int = int(marker.get("r", 0))
		var cell_id: String = "%d,%d" % [mq, mr]
		if seen.has(cell_id):
			continue
		var m_dist: int = _HexGrid.distance(from_position, {"q": mq, "r": mr})
		if m_dist > range_val or m_dist < min_distance:
			continue
		seen[cell_id] = true
		result.append({"q": mq, "r": mr, "cell_id": cell_id})
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
