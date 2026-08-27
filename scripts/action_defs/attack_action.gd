## attack_action.gd — 攻击动作
##
## 按新规则文档定义的攻击动作生命周期：
##   ① 提取攻击信息
##   ② 选择武器 → 发出 ATTACK_BEFORE
##   ③ 选择攻击目标 → 发出 ATTACK_PRE
##   ④ 发动攻击 → 发出 ATTACK_AT（响应窗口）
##   ⑤ 判断攻击是否命中
##   ⑥ 计算伤害与损伤 → 发出 ATTACK_AFTER
##   ⑦ 造成伤害与设置损伤
##   ⑧ 攻击结算 → 发出 ATTACK_SETTLE（清理动作信息）
##
## 参考：new_logic/各动作的生命周期与时点.docx "攻击动作"
extends Action
class_name AttackAction

const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _RangeCalculator = preload("res://scripts/battle/RangeCalculator.gd")
const _GenEquipEffects = preload("res://scripts/generated_database/GeneratedEquipmentEffects.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const SLog = preload("res://scripts/services/slog.gd")

## 诊断开关（bug3b 二次结算）。默认关闭：二次驱动哨兵若被反复触发会写爆日志。
# 复现二次结算时再置 true。
const _DIAG_BUG3B := false


func _init() -> void:
	action_type = &"attack"


func setup_steps() -> void:
	steps = [
		{step_name = &"extract_attack_info",  timing_point = &"",              handler = _step_extract_attack_info},
		{step_name = &"select_weapon",        timing_point = _TimingConst.ATTACK_BEFORE, handler = _step_select_weapon},
		{step_name = &"select_target",        timing_point = _TimingConst.ATTACK_PRE,    handler = _step_select_target},
		{step_name = &"execute_attack",       timing_point = _TimingConst.ATTACK_AT,     handler = _step_execute_attack},
		{step_name = &"check_hit",            timing_point = &"",              handler = _step_check_hit},
		{step_name = &"calculate_damage",     timing_point = _TimingConst.ATTACK_AFTER,  handler = _step_calculate_damage},
		{step_name = &"apply_damage",         timing_point = &"",              handler = _step_apply_damage},
		{step_name = &"settle",               timing_point = _TimingConst.ATTACK_SETTLE,  handler = _step_settle},
		{step_name = &"cleanup",             timing_point = &"",              handler = _step_cleanup},
	]


func get_display_name() -> String:
	return "攻击动作"


## ① 提取攻击信息
## record 输入：attacker_id, target_id(可选), weapon_id(可选), attack_card_id, target_count
## record 输出：attacker_mechs, attack_source_cards, attack_action_cards, target_count
func _step_extract_attack_info(action: Action) -> Dictionary:
	var gs = context.game_state
	var result: Dictionary = {}

	# 记录发动攻击的机甲（可能有多个，但当前为1个）
	var attacker_id: StringName = action.record.get("attacker_id", &"")
	result["attacker_mechs"] = [attacker_id]

	# 影刹 pilot_069：任何攻击动作启动即置位「本回合已发动攻击」标记
	# （含铠威攻击窗口/联合攻击/迎击等不计 attack_count 的攻击；fork 子动作从 step4 起步不经此步）。
	var atk_mech = gs.mechs.get(attacker_id) if attacker_id != &"" else null
	if atk_mech != null:
		atk_mech.has_attacked_this_turn = true

	# 记录攻击的来源行动牌
	var attack_card_id: StringName = action.record.get("attack_card_id", &"")
	result["attack_action_cards"] = [attack_card_id] if attack_card_id != &"" else []

	# 可选择的攻击目标数
	var target_count: int = action.record.get("target_count", 1)
	result["target_count"] = target_count

	# 记录来源效果/动作信息
	var source_info: Dictionary = action.source.duplicate()
	result["attack_source"] = source_info

	return result


## ② 选择武器
## 如果 record 中已有 weapon_id，直接使用；否则需要玩家选择
## 记录 effective_weapon_type（默认=实体武器kind，可被近战装·头部效果改写）
func _step_select_weapon(action: Action) -> Dictionary:
	var result: Dictionary = {}

	# 如果已指定武器，直接记录
	var weapon_id: StringName = action.record.get("weapon_id", &"")
	if weapon_id != &"":
		var attacker_id: StringName = action.record.get("attacker_id", &"")
		var attacker = context.game_state.mechs.get(attacker_id)
		if attacker != null:
			var weapon_stats: Dictionary = _get_weapon_stats(attacker, weapon_id)
			result["weapon_id"] = weapon_id
			# 虚拟武器（帝国的神莺·躯干）：标记攻击武器来源为本牌，使 effect_088 的
			# ATTACK_SOURCE_IS_SELF(source_instance_id == payload.attack_weapon_instance_id) 命中，
			# 触发"消耗全部动力+禁回"。仅虚拟武器写此键--全工程此前从无写入， ATTACK_SOURCE_IS_SELF
			# 对 legacy 实体武器/部件效果恒为 false，此处不破坏既有行为。
			if weapon_stats.get("is_virtual", false):
				result["attack_weapon_instance_id"] = weapon_id
			result["weapon_might"] = weapon_stats.get("might", 0)
			# 瓦恩 pilot_083 威力加成快照：诺拉纯进攻还原（_step_calculate_damage）时从威力一并清，
			# 还原为武器牌面记述威力（瓦恩+3属武器派生修正，非 extra_might）。
			result["weapon_083_might_bonus"] = int(weapon_stats.get("pilot_083_might_bonus", 0))
			# 武器射程 = 基础射程 + 狙击装·头部被动远程范围加成（effect_022/055，派生值实时重算）
			# 存入 record 后，命中检查(L213)/选目标校验(L117)读 weapon_range+extra_range 自动含之。
			var w_kind: StringName = weapon_stats.get("weapon_kind", &"")
			result["weapon_range"] = weapon_stats.get("range_value", 1) + _GenEquipEffects.get_passive_weapon_range_bonus(attacker, w_kind)
			# effective_weapon_type 默认 = 实体武器 kind（近战/远程/特殊）
			# 近战装·头部效果（ATTACK_BEFORE priority 20）可改写为"近战"
			result["effective_weapon_type"] = weapon_stats.get("weapon_kind", &"")
			# 武器名写入 record：ATTACK_BEFORE 起所有攻击时点的 payload = record.duplicate()，
			# WEAPON_NAME_CONTAINS 条件读 payload.weapon_name（白马/赤枭/圣牛/雄鹰臂 +3 威力）。
			result["weapon_name"] = weapon_stats.get("weapon_name", &"")
		return result

	# 否则需要玩家选择武器
	return {
		"need_input": true,
		"input_type": &"select_weapon",
		"input_params": {
			"attacker_id": action.record.get("attacker_id", &""),
		},
	}


## ③ 选择攻击目标
## 如果 record 中已有 target_id，验证范围后直接使用；否则需要玩家选择
func _step_select_target(action: Action) -> Dictionary:
	var result: Dictionary = {}
	# 攻击射程受光环影响（光环格视为绿格、耗2射程预算，全场无折扣）。见 RangeCalculator。
	var _attack_aura: Dictionary = context.map_service.get_attack_aura_cells()
	# 攻击路径障碍：其他机甲所在格不可穿过（打后面的目标须绕路）；
	# 陷落等"不能被选为目标"的机甲不能被指定为目标，但依然作为障碍阻挡路径。
	var _attack_blocked: Dictionary = context.map_service.get_attack_blocked_keys(action.record.get("attacker_id", &""))
	# 多目标已选（双连等，input resume 提交 target_ids）：逐个校验在攻击范围内后回填。
	# 单目标走下方 target_id 路径；陷阱目标提交 target_id+target_is_trap（非 target_ids）。
	var target_ids: Array = action.record.get("target_ids", [])
	if not target_ids.is_empty() and not bool(action.record.get("target_is_trap", false)):
		var attacker_id_mt: StringName = action.record.get("attacker_id", &"")
		var attacker_mt = context.game_state.mechs.get(attacker_id_mt)
		var range_mt: int = max(1, action.record.get("weapon_range", 1) + int(action.record.get("extra_range", 0)))
		var cells_mt: Dictionary = context.game_state.map_state.cells if context.game_state.map_state else {}
		for tid in target_ids:
			var t_mt = context.game_state.mechs.get(tid)
			if t_mt == null or t_mt.has_status(&"cannot_be_targeted") or attacker_mt == null or not _RangeCalculator.is_in_weapon_range(attacker_mt.position, t_mt.position, range_mt, cells_mt, _attack_aura, _attack_blocked):
				return {"cancelled": true, "cancel_reason": "multi_target_out_of_range"}
		result["target_ids"] = target_ids
		result["target_id"] = target_ids[0]
		result["target_count"] = target_ids.size()
		return result

	var target_id: StringName = action.record.get("target_id", &"")

	if target_id != &"":
		# 验证目标在攻击范围内
		var attacker_id: StringName = action.record.get("attacker_id", &"")
		var attacker = context.game_state.mechs.get(attacker_id)
		var target = context.game_state.mechs.get(target_id)
		# 有效范围 = 基础范围 + extra_range（狙击头部+1 / 近战头部-2 等经 ATTACK_BEFORE 写入）
		var weapon_range: int = action.record.get("weapon_range", 1) + int(action.record.get("extra_range", 0))
		weapon_range = max(1, weapon_range)  # 范围最低1
		var _map_cells: Dictionary = context.game_state.map_state.cells if context.game_state.map_state else {}

		# 陷阱作为攻击目标（无响应窗口，攻击即引爆）：校验陷阱格在范围内
		if bool(action.record.get("target_is_trap", false)):
			var trap_q: int = int(action.record.get("target_trap_q", 0))
			var trap_r: int = int(action.record.get("target_trap_r", 0))
			if attacker != null and _RangeCalculator.is_in_weapon_range(attacker.position, {"q": trap_q, "r": trap_r}, weapon_range, _map_cells, _attack_aura, _attack_blocked):
				result["target_id"] = target_id
				result["target_ids"] = [target_id]  # 单目标回填 target_ids（泰格 pilot_040 近战锁定 FOR_EACH_TARGET 读 $payload.target_ids）
				return result
			return {"cancelled": true, "cancel_reason": "preset_target_out_of_range"}

		if attacker != null and target != null:
			# 陷落等"不能被选为攻击目标"的机甲：如同消失，不能被指定为攻击目标
			if target.has_status(&"cannot_be_targeted"):
				return {"cancelled": true, "cancel_reason": "target_not_targetable"}
			if _RangeCalculator.is_in_weapon_range(attacker.position, target.position, weapon_range, _map_cells, _attack_aura, _attack_blocked):
				result["target_id"] = target_id
				result["target_ids"] = [target_id]  # 单目标回填 target_ids（泰格 pilot_040 近战锁定 FOR_EACH_TARGET 读 $payload.target_ids）
				return result
			# target_id 已 preset 但目标不在攻击范围内（如反击 effect2 的 counter_strike 锁定
			# 原攻击者A，但 A 经强袭2追击/移动跳出 B 武器范围）。按规则"范围内无目标则攻击无法
			# 发动"，且反击锁定不能改打范围内其他目标，故直接 cancel 本攻击动作，避免卡在
			# select_attack_target 反复请求无效目标。
			return {"cancelled": true, "cancel_reason": "preset_target_out_of_range"}

	# 需要玩家选择攻击目标
	# 预检（仅在从未指定目标时）：若攻击范围内没有任何机甲可选
	# （如强袭2追击后 A 跳出 B 武器范围，B 反击2发动的攻击B 选不到目标），
	# 按规则"范围内无目标则攻击无法发动"——不产生攻击动作，直接 cancel 本攻击动作。
	# 注意：若 target_id 已 preset（玩家/效果已选过目标）但目标移动后跳出范围，
	# 不在此 cancel——交由 _step_check_hit 按规则判"未命中"。
	if target_id == &"":
		var attacker_id_pre: StringName = action.record.get("attacker_id", &"")
		var attacker_pre = context.game_state.mechs.get(attacker_id_pre)
		if attacker_pre != null:
			var range_pre: int = max(1, action.record.get("weapon_range", 1) + int(action.record.get("extra_range", 0)))
			var cells_pre: Dictionary = context.game_state.map_state.cells if context.game_state.map_state else {}
			var has_any_target := false
			for mech_id_pre: StringName in context.game_state.mechs:
				if mech_id_pre == attacker_id_pre:
					continue
				var m_pre = context.game_state.mechs[mech_id_pre]
				if m_pre == null or m_pre.has_status(&"cannot_be_targeted"):
					continue
				if _RangeCalculator.is_in_weapon_range(attacker_pre.position, m_pre.position, range_pre, cells_pre, _attack_aura, _attack_blocked):
					has_any_target = true
					break
			if not has_any_target:
				# 也检查范围内是否有陷阱标记（陷阱可选为攻击目标）
				for marker in context.game_state.map_state.markers:
					if marker.get("type", &"") != &"TRAP":
						continue
					var trap_pos := {"q": int(marker.get("q", 0)), "r": int(marker.get("r", 0))}
					if _RangeCalculator.is_in_weapon_range(attacker_pre.position, trap_pos, range_pre, cells_pre, _attack_aura, _attack_blocked):
						has_any_target = true
						break
			if not has_any_target:
				return {"cancelled": true, "cancel_reason": "no_target_in_range"}
	# pilot_006 里昂狩猎标签豁免：攻击数=0 豁免使用时，选目标只能选标记机甲（约束目标选择）。
	# 传 forced_target 到 UI，app_root 点击非标记机甲时拒绝。
	var _p006_forced: StringName = action.record.get("pilot_006_forced_target", &"") if bool(action.record.get("pilot_006_zero_exemption", false)) else &""
	return {
		"need_input": true,
		"input_type": &"select_attack_target",
		"input_params": {
			"attacker_id": action.record.get("attacker_id", &""),
			# 高亮范围 = record.weapon_range（含狙击头部被动加成）+ extra_range（近战头-2等
			# ATTACK_BEFORE 修正），与 _step_select_target 目标校验 / _step_check_hit 命中判定一致。
			"weapon_range": max(1, action.record.get("weapon_range", 1) + int(action.record.get("extra_range", 0))),
			"target_count": action.record.get("target_count", 1),
			"pilot_006_forced_target": _p006_forced,
		},
	}


## ④ 发动攻击（响应窗口在此步骤的时点 ATTACK_AT 触发）
## 记录：本次攻击是否被响应以及响应的来源
func _step_execute_attack(action: Action) -> Dictionary:
	# 诊断：本 step 只应执行一次。若已执行过却再次进入，说明该攻击动作被重复驱动
	# （二次结算 bug3b），记录调用栈供定位。
	if _DIAG_BUG3B and action._execute_attack_ran:
		var st: Array = get_stack()
		var trace := ""
		for i in range(2, min(st.size(), 8)):
			var f = st[i]
			trace += "%s:%d@%s " % [String(f.get("source", "").get_file()), int(f.get("line", 0)), String(f.get("function", ""))]
		SLog.log_raw("[DIAG execute_attack RE-RUN] action=%s csi=%d state=%s trace=%s" % [String(action.action_id), action.current_step_index, String(action.state), trace])
	action._execute_attack_ran = true
	# 幂等：仅在尚未初始化时写入默认值。
	# 本 step 带 ATTACK_AT 时点，迎击响应窗口关闭后父动作会被 continue_action 恢复；
	# 若该步骤因任何路径被重跑，无条件重置 responded/counter_attacked=false 会抹掉
	# 迎击窗口写入的真实响应状态，导致命中/结算误判、攻击被"结算两次"。
	var result: Dictionary = {}
	# cardless 直攻免牌（effect_128）：消耗本回合攻击次数（普通攻击牌在 use_action_card 已扣）。
	# 仅在首次进入 ATTACK_AT 时扣（_execute_attack_ran 守卫已防重跑）。
	# 铠威攻击窗口豁免：窗口归属机甲的攻击不消耗回合攻击次数（窗口此时尚未关闭，直接查窗口状态）。
	if bool(action.record.get("cardless_weapon_attack", false)) and bool(action.record.get("consume_turn_attack_count", true)):
		var ct_attacker_id: StringName = action.record.get("attacker_id", &"")
		if ct_attacker_id != &"" and not _ActionPilotEffects.attack_window_active_for_mech(context.game_state, ct_attacker_id):
			var ct_mech = context.game_state.mechs.get(ct_attacker_id) if ct_attacker_id != &"" else null
			if ct_mech != null:
				ct_mech.attack_count_this_turn += 1
	if not action.record.has("responded"):
		result["responded"] = false
	if not action.record.has("response_source"):
		result["response_source"] = &""
	if not action.record.has("response_card_id"):
		result["response_card_id"] = &""
	if not action.record.has("counter_attacked"):
		result["counter_attacked"] = false
	# pilot_007 effect_01 反夺攻击牌：监听父 use_action_card 的 USE_ACTION_SETTLE，需知道本攻击
	# 选定的目标。攻击子动作完成后会从父 pending_effect_action_ids 移除，故在此（ATTACK_AT 步、
	# 目标已锁定）把 target_id 显式回写到父 use_action_card record，使后续 USE_ACTION_SETTLE 的
	# payload（=use_action_card.record）仍可读到 attack_target_id。
	_propagate_targets_to_parent_use_action(action)

	# ── 多目标攻击 fork（双连等）：主攻击不发 ATTACK_AT，改为逐个派生"复制攻击"子动作。
	# 复制攻击深拷贝主攻击 record 快照（含武器威力/聚能/射程等发动前状态），从 step 3（ATTACK_AT）
	# 开始各自走完整 AT→AFTER→SETTLE 流程。主攻击只发 ATTACK_BEFORE/PRE，最后 1 个复制结算后整体结束。
	# 陷阱目标不 fork（攻击即引爆，单目标），故 target_count>=2 选了陷阱时按单目标走（target_ids 为空）。
	var mt_target_ids: Array = action.record.get("target_ids", [])
	if mt_target_ids.size() >= 2 and not bool(action.record.get("target_is_trap", false)):
		if not _weapon_still_held(action):
			# 武器已不持有：跳过所有 fork，主攻击直接完成（无 ATTACK_AT/AFTER/SETTLE）
			action.record.erase("_multi_target_fork_queue")
			result["multi_target_complete"] = true
			return result
		# 复制攻击队列（含全部目标，_create_next_fork 逐个 pop）
		action.record["_multi_target_fork_queue"] = mt_target_ids.duplicate()
		if _create_next_fork(action):
			# 第 1 个复制攻击已挂起（等待响应窗口/损伤放置等），主攻击等待其完成
			result["effect_action_created"] = true
			return result
		# 队列内所有目标同步完成（如均无响应窗口且无损伤放置 UI）：主攻击直接完成
		action.record.erase("_multi_target_fork_queue")
		result["multi_target_complete"] = true
		return result

	return result


## 把本 attack 选定的目标回传到父 use_action_card record（供 USE_ACTION_SETTLE 时点监听效果判定
## "使用攻击牌的目标"，如 pilot_007 effect_01）。仅当父动作是 use_action_card 时回写。
func _propagate_targets_to_parent_use_action(action: Action) -> void:
	var target_id: StringName = action.record.get("target_id", &"")
	if target_id == &"":
		return
	if context == null or context.action_registry == null:
		return
	var parent_id: StringName = action.parent_action_id
	if parent_id == &"":
		return
	var parent_action = context.action_registry.get_action(parent_id)
	if parent_action == null or parent_action.action_type != &"use_action_card":
		return
	parent_action.record["attack_target_id"] = target_id


## 多目标攻击：检查主攻击所选武器是否仍被机甲持有。
## 通用规则（所有攻击动作）：选定武器若已不再被机甲持有（被反击破坏/弃置等），
## 即使保存了快照也不得继续攻击--立即结算此攻击。
func _weapon_still_held(action: Action) -> bool:
	var weapon_id: StringName = action.record.get("weapon_id", &"")
	if weapon_id == &"":
		return true  # 无武器（理论不会发生）
	var wid_str := String(weapon_id)
	if wid_str.begins_with("frame_base_weapon"):
		return true  # 基础武器恒持有（框架固有）
	var attacker_id: StringName = action.record.get("attacker_id", &"")
	var attacker = context.game_state.mechs.get(attacker_id) if attacker_id != &"" else null
	if attacker == null:
		return false
	# 实体武器（weapon 槽）或虚拟武器（part 槽提供，如神莺·躯干）：检查卡牌仍装备在任一槽位。
	# get_weapon_ids() 仅含 weapon 槽，虚拟武器在 part 槽，故扫描所有槽位按 instance_id 匹配。
	for slot_id in attacker.slots:
		var slot = attacker.slots[slot_id]
		if slot != null and slot.equipped_card != null and slot.equipped_card.instance_id == weapon_id:
			return true
	return false


## 多目标攻击：派生 1 个"复制攻击"子动作（深拷贝主攻击 record 快照）。
## fork 从 step 3（execute_attack / ATTACK_AT）开始，跳过 extract/weapon/target 选择。
func _create_fork_sub_action(parent_action: Action, target_id: StringName) -> void:
	# 深拷贝主攻击 record：快照含武器威力 weapon_might / 聚能 extra_might / 射程 extra_range /
	# weapon_id / attacker / source 等发动前状态，故聚能加成与超米伽荣光炮（冷却在选武器时检查）
	# 对所有复制攻击均生效。
	var fork_record: Dictionary = parent_action.record.duplicate(true)
	fork_record["target_id"] = target_id
	fork_record["target_ids"] = [target_id]
	fork_record["target_count"] = 1
	# 标记为复制攻击（fork）：供 pilot_006 effect_02 去重判断--
	# fork 被 pilot_011 挡攻转移 rewind 重发 ATTACK_PRE 时，里昂 effect_02 应跳过
	# （主攻击 PRE 已抽1张）。闪击再攻等独立 attack 无此标记，正常抽。
	fork_record["_is_fork"] = true
	# fork 独立响应/命中/伤害：清除主攻击的响应与伤害记录（避免继承主攻击假数据）
	fork_record.erase("_multi_target_fork_queue")
	fork_record.erase("responded")
	fork_record.erase("counter_attacked")
	fork_record.erase("response_source")
	fork_record.erase("response_card_id")
	fork_record.erase("hit")
	fork_record.erase("miss")
	fork_record.erase("damage")
	fork_record.erase("markers")
	fork_record.erase("extra_markers")
	fork_record.erase("shield_hp_reduction")
	fork_record.erase("damage_reduction")
	fork_record.erase("temporary_armor_bonus")
	fork_record.erase("temp_armor_grants")
	fork_record.erase("negated")
	fork_record.erase("_redirect_rewind")
	fork_record.erase("_redirect_from")
	# fork 不再消耗攻击次数（双连的攻击次数由 use_action_card 已扣）
	fork_record["cardless_weapon_attack"] = false
	fork_record["consume_turn_attack_count"] = false
	var fork: Action = context.action_service.create_fork_attack(parent_action, fork_record, 2)
	if fork != null:
		context.action_engine.execute_action(fork)


## 多目标攻击：从队列取下一个目标派生复制攻击。
## 返回 true=有 fork 挂起（主攻击等待）；false=队列空或武器没了（主攻击应直接完成）。
## 同步循环：若 fork 同步完成（无响应窗口/无损伤放置），继续取下一个，直到挂起或队列空。
func _create_next_fork(action: Action) -> bool:
	var queue: Array = action.record.get("_multi_target_fork_queue", [])
	# pilot_015 诺拉 effect_01：强制纯进攻时双连仅完成首个 fork（trigger A 在主攻击 ATTACK_PRE 设 flag，
	# trigger B 在 fork ATTACK_AT 设 flag 并沿 parent 链标根 attack）。flag 设置后清空队列，不再派生后续 fork。
	var _p015_flags: Dictionary = action.record.get("_effect_flags", {})
	if _p015_flags.has(&"pilot_015_force_pure_assault") and not queue.is_empty():
		SLog.log_raw("[pilot_015] 双连仅完成首个 fork，取消剩余 %d 个目标" % queue.size())
		queue.clear()
		action.record["_multi_target_fork_queue"] = queue
	while not queue.is_empty():
		var target_id: StringName = queue[0]
		queue.remove_at(0)
		action.record["_multi_target_fork_queue"] = queue
		if not _weapon_still_held(action):
			break  # 武器已不持有：停止派生，主攻击完成
		_create_fork_sub_action(action, target_id)
		# 检查刚创建的 fork 是否已挂起（未完成）
		if not action.pending_effect_action_ids.is_empty():
			var last_id: StringName = action.pending_effect_action_ids[-1]
			var fork = context.action_registry.get_action(last_id)
			if fork != null and fork.state != &"completed" and fork.state != &"cancelled":
				return true  # fork 挂起，主攻击等待其完成
		# fork 同步完成（或已取消），继续取下一个
	return false


## 多目标攻击续跑钩子（由 ActionEngine._after_sub_action_finished 调用）。
## 上一个复制攻击完成后，派生下一个或结束整个多目标攻击。
## 返回 true=已处理（主攻击等待/完成）；返回 false=非多目标攻击，走正常 continue_action。
func _continue_fork_attacks() -> bool:
	if not record.has("_multi_target_fork_queue"):
		return false  # 非多目标攻击
	if _create_next_fork(self):
		return true  # 下一个 fork 已挂起，主攻击继续等待
	# 队列空（所有目标复制攻击完成）或武器没了：主攻击整体结束
	# （不发 ATTACK_AT/AFTER/SETTLE--这些时点由各复制攻击各自发出）
	record.erase("_multi_target_fork_queue")
	context.action_engine._complete_action(self)
	return true


## ⑤ 判断攻击是否命中
## 检查：目标机甲是否在攻击范围内
## 记录：本次攻击是否命中、是否被迎击牌响应
## 如果攻击被否定（识破），跳过此步骤及后续伤害步骤
func _step_check_hit(action: Action) -> Dictionary:
	# 被否定则跳过（按 effect_103 拆解歧义1 智能体选择：无效攻击 attack_hit=false 算未命中，
	# payload.miss=true 使重型锤矛 effect_103 等未命中监听能触发）
	if action.negated:
		return {"hit": false, "miss": true, "negated": true}

	# 通用规则：选定武器已不再被机甲持有（被反击破坏/弃置等）-> 立即结算（未命中，不造成伤害）。
	# 对多目标复制攻击同样适用：fork 执行中武器被破坏，该 fork 未命中。
	if not _weapon_still_held(action):
		return {"hit": false, "miss": true, "weapon_lost": true}

	var result: Dictionary = {}
	var attacker_id: StringName = action.record.get("attacker_id", &"")
	var target_id: StringName = action.record.get("target_id", &"")
	var attacker = context.game_state.mechs.get(attacker_id)
	var target = context.game_state.mechs.get(target_id)

	var hit: bool = false
	# 陷阱目标：攻击即引爆，必命中（陷阱无回避）
	if bool(action.record.get("target_is_trap", false)):
		hit = true
		result["hit"] = hit
		result["miss"] = false
		return result
	if attacker != null and target != null and not target.destroyed:
		# 有效范围 = 基础范围 + extra_range（命中检查同样读取修正后范围）
		var weapon_range: int = action.record.get("weapon_range", 1) + int(action.record.get("extra_range", 0))
		weapon_range = max(1, weapon_range)
		var map_cells: Dictionary = context.game_state.map_state.cells if context.game_state.map_state else {}
		var _attack_aura: Dictionary = context.map_service.get_attack_aura_cells()
		# 命中判定同样受机甲障碍影响（不能穿过机甲判定可达，打后面的须绕路）。
		# 攻击中途目标被施加"不能被选为目标"（陷落等）不改变已发动的攻击结算。
		var _attack_blocked: Dictionary = context.map_service.get_attack_blocked_keys(attacker_id)
		hit = _RangeCalculator.is_in_weapon_range(attacker.position, target.position, weapon_range, map_cells, _attack_aura, _attack_blocked)

	result["hit"] = hit
	# 未命中标志（effect_103 重型锤矛「没命中则自损2」等监听 PAYLOAD_ATTACK_MISS 读 payload.miss）
	result["miss"] = not hit
	return result


## ⑥ 计算此次攻击造成的伤害与损伤
## 伤害 = max(0, 攻击威力 - 目标护甲)，损伤 = floor(攻击威力 / 5)
## 记录：此次攻击造成的伤害与损伤的数值
func _step_calculate_damage(action: Action) -> Dictionary:
	var result: Dictionary = {}
	var hit: bool = action.record.get("hit", false)

	if not hit:
		result["damage"] = 0
		result["markers"] = 0
		result["base_damage"] = 0
		return result

	# 陷阱目标：无HP/护甲，攻击伤害 irrelevant（引爆在 _step_apply_damage 处理）
	if bool(action.record.get("target_is_trap", false)):
		result["damage"] = 0
		result["markers"] = 0
		result["base_damage"] = 0
		return result

	var attack_power: int = action.record.get("weapon_might", 0)
	# 加上额外威力（猛击+4 / 掩护-5 等，经 MODIFY_ATTACK_MIGHT 写入 extra_might）
	var extra_might: int = int(action.record.get("extra_might", 0))
	# pilot_015 诺拉 effect_01：强制纯进攻还原威力（flag 设置时 extra_might 归零，
	# 无论之前被猛击+4 增加或掩护-5 衰减，均还原为武器牌面记述的原本威力）。
	# 瓦恩 pilot_083 武器修改属武器派生修正（并入 weapon_might），纯进攻时一并清（从威力减去
	# weapon_083_might_bonus 快照），使攻击真正还原为武器牌面威力；不永久移除瓦恩施加。
	var _p015_flags: Dictionary = action.record.get("_effect_flags", {})
	if _p015_flags.has(&"pilot_015_force_pure_assault"):
		extra_might = 0
		attack_power = max(0, attack_power - int(action.record.get("weapon_083_might_bonus", 0)))
	attack_power += extra_might
	var target_id: StringName = action.record.get("target_id", &"")
	var target = context.game_state.mechs.get(target_id)

	var target_armor: int = 0
	if target != null:
		target_armor = target.get_armor()
		# pilot_004 玛沙 effect_02：防御值来源替换为 current_power（动力代护甲）。
		# 攻击/被攻击合并为单效果，经 SET_ATTACK_DEFENSE_STAT_SOURCE 写入。
		var _defense_override: Dictionary = action.record.get("defense_stat_override", {})
		if String(_defense_override.get(target_id, &"")) == "current_power":
			target_armor = target.power

	# 加上临时护甲加成（防御牌等）
	var temp_armor: int = action.record.get("temporary_armor_bonus", 0)

	var damage: int = max(0, attack_power - (target_armor + temp_armor))
	var markers: int = attack_power / 5
	# 注：extra_markers（破甲等 ATTACK_AFTER 时点效果写入）不在此读取。
	# 时点翻转后步骤为「handler 先执行 -> 再 fire timing」，本步 timing=ATTACK_AFTER，
	# handler 先于 fire 执行：若在此读 extra_markers，破甲 effect2 尚未在 ATTACK_AFTER fire
	# 写入（仍为0），+2 会丢失。extra_markers 改在 _step_apply_damage（fire 之后）应用，
	# 符合文档语义：step6 计算 base -> ATTACK_AFTER fire 改 -> step7 应用最终值。

	# 防御牌等效果减伤
	var damage_reduction: int = action.record.get("damage_reduction", 0)
	damage = max(0, damage - damage_reduction)

	result["damage"] = damage
	result["markers"] = max(0, markers)
	# 塞万提斯 pilot_034 effect_01：记录"攻击本身造成的伤害"（本步计算最终值，不含 ATTACK_AFTER
	# 效果追加/衰减，如巴托洛夫+3 等）。条件 ATTACK_BASE_DAMAGE_BELOW 读 base_damage 判定
	# "未对我方造成伤害的攻击"；若在此读 record.damage 会被同窗口其他 ATTACK_AFTER 监听器
	# （按优先级先 fire）改写，故需快照到独立字段。
	result["base_damage"] = damage
	return result


## ⑦ 造成伤害与设置损伤
## 执行：如果伤害和损伤≤0则不执行
## 产生效果动作：生命变动动作、损伤变动动作
## 这两个效果动作通过 execute_sub_action 显式登记父子关系：attack 暂停等待它们完成后再进 settle。
## 关键：损伤变动动作会弹 place_damage_tokens UI 让玩家逐个设置损伤，必须等所有损伤设置完毕
## （damage_change 完成、DAMAGE_CHANGE_SETTLE fire 后）才进入 ATTACK_SETTLE，
## 否则闪击 effect2 等 LISTEN(ATTACK_SETTLE) 的弹窗会与损伤设置 UI 重叠。
func _step_apply_damage(action: Action) -> Dictionary:
	var result: Dictionary = {}
	var hit: bool = action.record.get("hit", false)
	if not hit:
		return result

	# 陷阱目标：攻击即引爆--移除陷阱标记并触发陷阱爆炸（无HP/护甲，不走HP/损伤变动）。
	# 爆炸经 MarkerService.trigger_marker -> trap_explosion 动作（洪水扩散+逐机甲结算，
	# 攻击者在范围内亦受爆炸伤害）。爆炸为顶层动作，与本攻击的 ATTACK_SETTLE 并行结算。
	if bool(action.record.get("target_is_trap", false)):
		var trap_q: int = int(action.record.get("target_trap_q", 0))
		var trap_r: int = int(action.record.get("target_trap_r", 0))
		var attacker_id_t: StringName = action.record.get("attacker_id", &"")
		var gs = context.game_state
		var trap_marker: Dictionary = {}
		for m in gs.map_state.get_markers_at(trap_q, trap_r):
			if m.get("type", &"") == &"TRAP":
				trap_marker = m
				break
		if not trap_marker.is_empty():
			gs.map_state.remove_marker(trap_marker.get("marker_id", &""))
			if context.marker_service:
				context.marker_service.trigger_marker(attacker_id_t, trap_marker)
		return result

	# 拘束钩爪 effect_104 的锁定解除现由 LOCKED 状态机制处理：lock_status_clear_on_hit 在
	# 持有者下次命中该目标时移除 LOCKED 状态，GameActions.remove_status 同步清 lock_target_mech_id。
	# 此处不再按"任意攻击命中"清除（旧逻辑会误清他人命中导致的锁定）。

	var damage: int = action.record.get("damage", 0)
	# 盾牌在 ATTACK_AFTER 写入的HP伤害减量（太空合金盾牌 effect_136：造成的伤害-2）。
	# ATTACK_AFTER 时点在造成HP伤害前 fire，故此处读取时盾牌的减量已生效。
	var shield_hp_red: int = int(action.record.get("shield_hp_reduction", 0))
	if shield_hp_red > 0:
		damage = max(0, damage - shield_hp_red)
		action.record["damage"] = damage
	var markers: int = action.record.get("markers", 0)
	# 应用 extra_markers（破甲 +2 / 联邦左腿 -最多2 等 ATTACK_AFTER 时点效果写入）。
	# 时点翻转后 ATTACK_AFTER fire 在 _step_calculate_damage handler 之后，extra_markers
	# 在本 step7（fire 之后）才读取应用，避免 +2 丢失。写回 record 供 settle 日志/后续读取。
	# fork_extra_markers：洛尔恩效果2「掩护后损伤-1」写入（fork 深拷贝不清除此字段），
	# 使双连的每个复制攻击都继承减损。与 extra_markers 合并应用。
	markers = max(0, markers + int(action.record.get("extra_markers", 0)) + int(action.record.get("fork_extra_markers", 0)))
	action.record["markers"] = markers
	var target_id: StringName = action.record.get("target_id", &"")
	var attacker_id: StringName = action.record.get("attacker_id", &"")

	# 造成伤害（生命变动动作）—— 作为效果动作发起，attack 等其完成
	if damage > 0 and context.action_service != null:
		context.action_service.execute_sub_action(
			{"type": &"EXECUTE_HP_CHANGE", "params": {
				"mech_ids": [target_id],
				"value": damage,
				"method": &"decrease",
				"reason": &"attack_damage",
				# pilot_013 effect_01 权威标记：本次 hp_change 来自攻击步骤7的攻击伤害，
				# 不被巴托洛夫非攻击伤害免疫取消（ConditionChecker.HP_CHANGE_REASON_IS_NOT_ATTACK_DAMAGE
				# 优先看此标记，防伪造 reason=attack_damage 的非攻击伤害误判）。
				"created_by_attack_damage_step": true,
			}},
			{}, action)
		# hp_change 当前同步完成（不弹窗），_handle_effect_action_created 检测末尾效果动作
		# 已完成会 erase 并返回 false（不等待）。声明 effect_action_created 以走标准父子等待路径。
		result["effect_action_created"] = true

	# 设置损伤（损伤变动动作）—— 作为效果动作发起，attack 等其完成
	if markers > 0 and context.action_service != null:
		# 损伤位置由谁设置：攻击目标响应了攻击（迎击牌/装备效果/机师牌任意响应）时由被攻击目标设置，
		# 否则（未响应）由攻击方设置。
		# 注意用 responded（任何响应均算）而非 counter_attacked：装备牌响应（如光束步枪-5威力）
		# 不写 counter_attacked，但既然攻击目标响应了，命中后损伤就由攻击目标设置，不再区分响应类型。
		# 通用flag：效果（如赤牙 pilot_048）设置 attacker_always_places_damage_tokens=true 后，
		# 即使本次攻击被目标响应，损伤设置位置也仍由攻击方决定——该flag是通用机制，任何效果设置即生效。
		var chooser_player_id: StringName = &""
		var responded: bool = action.record.get("responded", false)
		var _placement_flags: Dictionary = action.record.get("_effect_flags", {})
		var _apd_entry: Dictionary = _placement_flags.get(&"attacker_always_places_damage_tokens", {})
		var attacker_always_places: bool = bool(_apd_entry.get("value", false))
		if responded and not attacker_always_places:
			var target_player = context.game_state.get_player_for_mech(target_id)
			chooser_player_id = target_player.player_id if target_player else &""
		else:
			var attacker_player = context.game_state.get_player_for_mech(attacker_id)
			chooser_player_id = attacker_player.player_id if attacker_player else &""

		context.action_service.execute_sub_action(
			{"type": &"EXECUTE_DAMAGE_CHANGE", "params": {
				"mech_ids": [target_id],
				"value": markers,
				"method": &"increase",
				"executor": chooser_player_id,
				"reason": &"attack_damage_tokens",
			}},
			{}, action)
		# damage_change 可能暂停在 place_damage_tokens UI（逐个设置损伤）。
		# 声明效果动作已创建，让 ActionEngine 把 attack 挂起等待 damage_change 完成
		# （_handle_effect_action_created 会检测末尾效果动作是否完成，未完成则 waiting_sub_action）。
		# 这样 ATTACK_SETTLE 必然在所有损伤设置完毕后才 fire。
		result["effect_action_created"] = true

	return result


## ⑧ 攻击结算
## 清理本动作信息，弃置攻击牌/迎击牌
func _step_settle(action: Action) -> Dictionary:
	var result: Dictionary = {}

	# 写日志（弃置攻击/迎击牌挪到 ATTACK_SETTLE fire 之后的 cleanup 步：
	# 翻转后 handler 在 fire 前执行，若在此弃牌会触发 unregister_listeners_for_card
	# 清掉仍监听 ATTACK_SETTLE 的效果（如闪击 effect2），导致 fire 时监听器已消失。
	# 设计文档：⑧攻击结算发出 ATTACK_SETTLE，本时点结束后才清理本动作信息。）
	if context.game_state != null:
		var negated: bool = action.record.get("negated", false)
		if negated:
			context.game_state.write_log(&"attack_negated", {
				"action_id": String(action.action_id),
			})
		else:
			var hit: bool = action.record.get("hit", false)
			var damage: int = action.record.get("damage", 0)
			var markers: int = action.record.get("markers", 0)
			if hit:
				context.game_state.write_log(&"attack_resolved", {
					"action_id": String(action.action_id),
					"hit": true,
					"damage": damage,
					"markers": markers,
				})
			else:
				context.game_state.write_log(&"attack_miss", {
					"action_id": String(action.action_id),
				})

	return result


## 把本 attack 的 responded/response_card_id 回写到父 use_action_card.record（通用增强）。
## 供监听父 USE_ACTION_SETTLE 的”获响应牌”效果（如疾风 pilot_076 获攻击牌）读取父 payload。
## 调用点：_step_cleanup（ATTACK_SETTLE fire 之后，responded/response_card_id 已最终确定）。
## 仅当父是 use_action_card 时回写（玩家主动使用攻击牌触发的 attack）；反击 attack 的父是
## 迎击牌 use_action_card，回写字段对其无害（迎击牌获牌分支不读 responded/response_card_id）。
func _propagate_response_info_to_parent(action: Action) -> void:
	if context == null or context.action_registry == null:
		return
	var parent_id: StringName = action.parent_action_id
	if parent_id == &"":
		return
	var parent = context.action_registry.get_action(parent_id)
	if parent == null:
		return
	# 把本 attack 的 responded/response_card_id 原样向上回写父 action.record。
	if bool(action.record.get("responded", false)):
		parent.record["responded"] = true
	var rcid: StringName = action.record.get("response_card_id", &"")
	if rcid != &"":
		parent.record["response_card_id"] = rcid
	# 回写响应方玩家 id（迎击方=被攻击方=target 所属玩家），供「获响应牌」效果判定我方是否
	# 为响应方。不能读 response_card_id 的当前 owner——迎击牌被 CLAIM 后 owner 已改，会误判
	# （疾风获迎击牌后，攻击牌 settle 时误把迎击牌新 owner 当响应方，再误获攻击牌）。
	# 本 attack 的 responder_player_id 若已由 fork 子动作回写则沿用，避免用主攻击 target
	# 覆盖 fork 的响应方（双连获牌B 需 fork 的响应方）。父已有（先前 fork 已写）也不覆盖。
	if not action.record.has("responder_player_id"):
		var resp_target_mid: StringName = action.record.get("target_id", &"")
		if resp_target_mid != &"" and context.game_state != null:
			var resp_player = context.game_state.get_player_for_mech(resp_target_mid)
			if resp_player != null:
				action.record["responder_player_id"] = resp_player.player_id
	if action.record.has("responder_player_id") and not parent.record.has("responder_player_id"):
		parent.record["responder_player_id"] = action.record["responder_player_id"]
	# 级联：父若是 attack（双连 fork 的主攻击/递归串行链），继续向上回写，使响应信息最终
	# 到达顶层 use_action_card（「获响应牌」效果监听父 USE_ACTION_SETTLE 读取 payload）。
	# 单层攻击的父为 use_action_card 时到此即止。
	if parent.action_type == &"attack":
		_propagate_response_info_to_parent(parent)


## ⑧+ 清理本动作的临时信息。行动牌由各自的”使用行动牌”动作结算弃置，
## 攻击动作不能越权重复弃置攻击牌或响应牌。
func _step_cleanup(action: Action) -> Dictionary:
	# 铠威攻击窗口「发动攻击即关闭」：攻击动作发起后（ATTACK_SETTLE fire 之后、动作完成之前）
	# 关闭窗口。攻击方为该窗口 owner_mech_id 时关闭；否则无窗口/非归属机甲则安全跳过。
	# 关闭后 action_completed 派发的铠威钩子 process_next 才会处理队列中后续触发（双连/递归串行）。
	var _aw_attacker: StringName = action.record.get("attacker_id", &"")
	if _aw_attacker != &"":
		_ActionPilotEffects.attack_window_close(context, _aw_attacker)
	# 通用增强：把本 attack 的 responded/response_card_id 回写到父 use_action_card.record，
	# 供监听父 USE_ACTION_SETTLE 的"获响应牌"效果（如疾风 pilot_076 获攻击牌）读取父 payload。
	# 本步在 ATTACK_SETTLE fire 之后、动作完成之前，responded/response_card_id 已最终确定。
	_propagate_response_info_to_parent(action)
	# 恢复防御等效果给机甲加的临时护甲（ADD_MECH_TEMP_ARMOR 登记的 temp_armor_grants）。
	# 防御结算后恢复护甲数值：本步在 ATTACK_SETTLE fire 之后执行，+5 已参与伤害计算，
	# 此处还原。清空列表防重复结算（bug3b 二次驱动）。
	var grants: Array = action.record.get("temp_armor_grants", [])
	if not grants.is_empty() and context.game_state != null:
		for g in grants:
			if g is Dictionary:
				var grant_mech = context.game_state.mechs.get(g.get("mech_id", &""))
				if grant_mech != null:
					grant_mech.temp_armor_bonus -= int(g.get("delta", 0))
		action.record["temp_armor_grants"] = []
	# 弃置绑定到本攻击的响应牌（反击牌）：其 use_action_card._step_settle 已跳过弃置
	# （反击 effect2 须在本攻击 ATTACK_SETTLE 触发，故牌须留临时区到此时点之后才弃置）。
	# 仅弃仍在临时区的响应牌（非迎击响应牌/装备已由各自路径处理）；同步移牌，避免在 cleanup
	# 步创建异步 discard_card 子动作。反击牌弃置无效果监听 DISCARD 时点，不发育时点无副作用。
	var response_card_id: StringName = action.record.get("response_card_id", &"")
	if response_card_id != &"" and context.game_state != null:
		var rcard = context.game_state.get_card(response_card_id)
		if rcard != null and rcard.zone == &"temp_zone" and context.game_state.deck_state != null:
			context.game_state.remove_card_from_all_zones(response_card_id)
			rcard.zone = &"discard"
			context.game_state.deck_state.action_discard_pile.append(response_card_id)
			if context.has_method("unregister_hand_card_availability"):
				context.unregister_hand_card_availability(response_card_id)
			context.game_state.write_log(&"card_discarded", {
				"card_id": String(response_card_id),
				"reason": "ACTION_CARD_PLAYED",
			})
	return {}


## ── 辅助方法 ──


## 获取武器威力、射程与类型
func _get_weapon_stats(attacker, weapon_id: StringName) -> Dictionary:
	var wid_str = String(weapon_id)
	# 基础武器虚拟ID
	if wid_str.begins_with("frame_base_weapon"):
		var slot_index: int = 0
		if wid_str.begins_with("frame_base_weapon_"):
			# "frame_base_weapon_" 后的数字（1-based）→ 0-based 索引
			slot_index = wid_str.trim_prefix("frame_base_weapon_").to_int() - 1
		var base_weapon = attacker.get_base_weapon(slot_index)
		if not base_weapon.is_empty():
			# 基础武器走派生统计（含瓦恩 pilot_083 基础武器威力/范围加成，施加存机甲 pilot_083_base_apps）
			var _bws: Dictionary = _ActionPilotEffects.get_base_weapon_effective_stats(attacker, slot_index)
			return {
				"might": int(_bws.get("might", base_weapon.get("might", 0))),
				"range_value": int(_bws.get("range_value", base_weapon.get("range_value", 1))),
				"weapon_kind": _bws.get("weapon_kind", base_weapon.get("weapon_kind", &"")),
				"weapon_name": _bws.get("weapon_name", base_weapon.get("name", &"")),
			}
	# 从卡牌实例获取（实体武器 / 虚拟武器）
	# 统一经 _GenEquipEffects.get_effective_weapon_stats 查询：含持久/临时修正、派生值
	# （26/27 每损伤-2、40 护甲×2/动力）、流星钢锤形态。避免各处直读 def.might 双计。
	var weapon_card = context.game_state.get_card(weapon_id)
	if weapon_card and weapon_card.def:
		var eff_stats: Dictionary = _GenEquipEffects.get_effective_weapon_stats(weapon_card)
		return {
			"might": int(eff_stats.get("might", 0)),
			"range_value": int(eff_stats.get("range_value", 1)),
			"weapon_kind": eff_stats.get("weapon_kind", &""),
			"weapon_name": eff_stats.get("weapon_name", &""),
			"is_virtual": bool(eff_stats.get("is_virtual", false)),
			# 瓦恩 pilot_083 威力加成（武器派生修正）：诺拉纯进攻还原时一并清（_step_calculate_damage）
			"pilot_083_might_bonus": int(eff_stats.get("pilot_083_might_bonus", 0)),
		}
	return {"might": 0, "range_value": 1, "weapon_kind": &"", "weapon_name": &""}
