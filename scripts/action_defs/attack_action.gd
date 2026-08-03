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
	var target_id: StringName = action.record.get("target_id", &"")

	if target_id != &"":
		# 验证目标在攻击范围内
		var attacker_id: StringName = action.record.get("attacker_id", &"")
		var attacker = context.game_state.mechs.get(attacker_id)
		var target = context.game_state.mechs.get(target_id)
		# 有效范围 = 基础范围 + extra_range（狙击头部+1 / 近战头部-2 等经 ATTACK_BEFORE 写入）
		var weapon_range: int = action.record.get("weapon_range", 1) + int(action.record.get("extra_range", 0))
		weapon_range = max(1, weapon_range)  # 范围最低1

		if attacker != null and target != null:
			var map_cells: Dictionary = context.game_state.map_state.cells if context.game_state.map_state else {}
			if _RangeCalculator.is_in_weapon_range(attacker.position, target.position, weapon_range, map_cells):
				result["target_id"] = target_id
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
				if m_pre == null:
					continue
				if _RangeCalculator.is_in_weapon_range(attacker_pre.position, m_pre.position, range_pre, cells_pre):
					has_any_target = true
					break
			if not has_any_target:
				return {"cancelled": true, "cancel_reason": "no_target_in_range"}
	return {
		"need_input": true,
		"input_type": &"select_attack_target",
		"input_params": {
			"attacker_id": action.record.get("attacker_id", &""),
			# 高亮范围 = record.weapon_range（含狙击头部被动加成）+ extra_range（近战头-2等
			# ATTACK_BEFORE 修正），与 _step_select_target 目标校验 / _step_check_hit 命中判定一致。
			"weapon_range": max(1, action.record.get("weapon_range", 1) + int(action.record.get("extra_range", 0))),
			"target_count": action.record.get("target_count", 1),
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
	if bool(action.record.get("cardless_weapon_attack", false)) and bool(action.record.get("consume_turn_attack_count", true)):
		var ct_attacker_id: StringName = action.record.get("attacker_id", &"")
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
	return result


## ⑤ 判断攻击是否命中
## 检查：目标机甲是否在攻击范围内
## 记录：本次攻击是否命中、是否被迎击牌响应
## 如果攻击被否定（识破），跳过此步骤及后续伤害步骤
func _step_check_hit(action: Action) -> Dictionary:
	# 被否定则跳过
	if action.negated:
		return {"hit": false, "negated": true}

	var result: Dictionary = {}
	var attacker_id: StringName = action.record.get("attacker_id", &"")
	var target_id: StringName = action.record.get("target_id", &"")
	var attacker = context.game_state.mechs.get(attacker_id)
	var target = context.game_state.mechs.get(target_id)

	var hit: bool = false
	if attacker != null and target != null and not target.destroyed:
		# 有效范围 = 基础范围 + extra_range（命中检查同样读取修正后范围）
		var weapon_range: int = action.record.get("weapon_range", 1) + int(action.record.get("extra_range", 0))
		weapon_range = max(1, weapon_range)
		var map_cells: Dictionary = context.game_state.map_state.cells if context.game_state.map_state else {}
		hit = _RangeCalculator.is_in_weapon_range(attacker.position, target.position, weapon_range, map_cells)

	result["hit"] = hit
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
		return result

	var attack_power: int = action.record.get("weapon_might", 0)
	# 加上额外威力（猛击+4 / 掩护-5 等，经 MODIFY_ATTACK_MIGHT 写入 extra_might）
	var extra_might: int = int(action.record.get("extra_might", 0))
	attack_power += extra_might
	var target_id: StringName = action.record.get("target_id", &"")
	var target = context.game_state.mechs.get(target_id)

	var target_armor: int = 0
	if target != null:
		target_armor = target.get_armor()

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

	# 拘束钩爪 effect_104：目标被任意攻击命中时，解除锁定此目标的所有武器（"下一次被攻击命中时结束"）
	# 跳过本攻击武器：effect_104 在 ATTACK_AFTER 刚设的锁不应被同一攻击的 _step_apply_damage 立即清除。
	var clear_lock_target: StringName = action.record.get("target_id", &"")
	var this_attack_weapon: StringName = action.record.get("weapon_id", action.record.get("attack_weapon_instance_id", &""))
	if clear_lock_target != &"" and context.game_state != null:
		for m_id in context.game_state.mechs:
			var m = context.game_state.mechs[m_id]
			if m == null:
				continue
			for wid in m.get_weapon_ids():
				if String(wid).begins_with("frame_base_weapon"):
					continue
				if wid == this_attack_weapon:
					continue  # 跳过本攻击武器（刚设锁的）
				var wcard = context.game_state.get_card(wid)
				if wcard != null:
					var wlt: StringName = wcard.lock_target_mech_id if "lock_target_mech_id" in wcard else &""
					if wlt == clear_lock_target:
						wcard.lock_target_mech_id = &""

	var damage: int = action.record.get("damage", 0)
	var markers: int = action.record.get("markers", 0)
	# 应用 extra_markers（破甲 +2 / 联邦左腿 -最多2 等 ATTACK_AFTER 时点效果写入）。
	# 时点翻转后 ATTACK_AFTER fire 在 _step_calculate_damage handler 之后，extra_markers
	# 在本 step7（fire 之后）才读取应用，避免 +2 丢失。写回 record 供 settle 日志/后续读取。
	markers = max(0, markers + int(action.record.get("extra_markers", 0)))
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
			}},
			{}, action)
		# hp_change 当前同步完成（不弹窗），_handle_effect_action_created 检测末尾效果动作
		# 已完成会 erase 并返回 false（不等待）。声明 effect_action_created 以走标准父子等待路径。
		result["effect_action_created"] = true

	# 设置损伤（损伤变动动作）—— 作为效果动作发起，attack 等其完成
	if markers > 0 and context.action_service != null:
		# 损伤位置由谁设置：迎击牌响应(counter_attacked=true)时由被攻击目标设置，
		# 否则（未响应或非迎击牌响应）由攻击方设置。
		# 注意用 counter_attacked 而非 responded：responded 含非迎击牌响应（装备牌/机师牌），
		# 非迎击牌响应不算迎击，损伤仍由攻击方设置。
		var chooser_player_id: StringName = &""
		var counter_attacked: bool = action.record.get("counter_attacked", false)
		if counter_attacked:
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


## ⑧+ 清理本动作的临时信息。行动牌由各自的“使用行动牌”动作结算弃置，
## 攻击动作不能越权重复弃置攻击牌或响应牌。
func _step_cleanup(action: Action) -> Dictionary:
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
			return {
				"might": base_weapon.get("might", 0),
				"range_value": base_weapon.get("range_value", 1),
				"weapon_kind": base_weapon.get("weapon_kind", &""),
				"weapon_name": base_weapon.get("name", &""),
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
		}
	return {"might": 0, "range_value": 1, "weapon_kind": &"", "weapon_name": &""}
