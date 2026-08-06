## use_action_card_action.gd — 使用行动牌动作
##
## 按新规则文档定义的使用行动牌动作生命周期：
##   ① 验证并记录 → 发出 USE_ACTION_BEFORE
##   ② 牌进入临时区 → 发出 USE_ACTION_AT
##   ③ 执行行动牌对应的效果/动作 → 发出 USE_ACTION_AFTER
##   ④ 非虚拟牌进弃牌堆 → 发出 USE_ACTION_SETTLE
##
## 参考：new_logic/各动作的生命周期与时点.docx "使用行动牌动作"
extends Action
class_name UseActionCardAction

const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const SLog = preload("res://scripts/services/slog.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")

## 诊断开关（双连卡临时区排查遗留）。默认关闭：复现时再置 true。
const _DIAG_USE_CARD := false


func _init() -> void:
	action_type = &"use_action_card"


## 取效果定义用的 card_def_id：as_card_def_id 优先（effect_130/135 维修臂把行动牌当维修打出），
## 否则用牌实例自身 card_id。
func _as_card_def_id(action, card) -> StringName:
	if action != null and action.record != null:
		var as_id: StringName = action.record.get("as_card_def_id", &"")
		if as_id != &"":
			return as_id
	if card != null and card.def != null:
		return card.def.card_id
	return &""


func setup_steps() -> void:
	# 文档 4 步结构（翻转后：handler 先跑再 fire timing，不再需要拆空步骤）：
	#   ①validate_card → USE_ACTION_BEFORE
	#   ②card_to_temp_zone（牌进临时区+注册效果）→ USE_ACTION_AT
	#   ③execute_effects → USE_ACTION_AFTER
	#   ④settle → USE_ACTION_SETTLE
	# 翻转前因「先 fire 再 handler」，USE_ACTION_AT 在牌进临时区前就 fire，故曾拆出空步骤
	# _step_fire_use_action_at 占位。翻转后 card_to_temp_zone handler 先跑（牌进临时区、监听器已注册），
	# 再 fire USE_ACTION_AT，监听器读到正确状态，空步骤已合并回 card_to_temp_zone。
	steps = [
		{step_name = &"validate_card",       timing_point = _TimingConst.USE_ACTION_BEFORE, handler = _step_validate_card},
		{step_name = &"card_to_temp_zone",   timing_point = _TimingConst.USE_ACTION_AT,      handler = _step_card_to_temp_zone},
		{step_name = &"execute_effects",    timing_point = _TimingConst.USE_ACTION_AFTER,  handler = _step_execute_effects},
		{step_name = &"settle",             timing_point = _TimingConst.USE_ACTION_SETTLE,  handler = _step_settle},
	]


func get_display_name() -> String:
	return "使用行动牌"


## ① 验证行动牌
## 检查：该行动牌当前是否可用
## 记录：使用的行动牌、所属机甲、执行者
func _step_validate_card(action: Action) -> Dictionary:
	var result: Dictionary = {}
	var card_id: StringName = action.record.get("card_instance_id", action.record.get("attack_card_id", &""))
	var player_id: StringName = action.record.get("player_id", &"")

	if card_id == &"":
		return {"error": "缺少 card_instance_id"}

	var card = context.game_state.get_card(card_id)
	if card == null:
		return {"error": "找不到行动牌实例"}

	# 记录行动牌信息
	result["card_instance_id"] = card_id
	result["card_def_id"] = _as_card_def_id(action, card)

	# 记录所属机甲
	var mech_id: StringName = action.record.get("mech_id", &"")
	if mech_id == &"":
		var mech = context.game_state.get_mech_for_player(player_id)
		mech_id = mech.mech_id if mech else &""
	result["mech_id"] = mech_id
	# 同时记录 source_mech_id（用于效果动作参数提取）
	result["source_mech_id"] = mech_id

	# pilot_009 美杜莎受控使用：牌 owner（目标）!= executor（美杜莎）时，
	# 校验 executor 对该类型有临时控制权（is_card_type_controlled_by）。
	# 裁定：受控攻击牌扣美杜莎攻击数、用美杜莎装备/位置；牌物理在目标手牌。
	var _ctrl_card = context.game_state.get_card(card_id)
	var _ctrl_owner_pid: StringName = _ctrl_card.owner_player_id if _ctrl_card != null else &""
	if _ctrl_owner_pid != &"" and _ctrl_owner_pid != player_id:
		var _ctrl_owner_mech = context.game_state.get_mech_for_player(_ctrl_owner_pid)
		if _ctrl_owner_mech == null:
			return {"error": "受控牌持有者机甲不存在"}
		if _ctrl_card.def == null:
			return {"error": "受控牌无定义"}
		var _ctrl_type: StringName = StringName(String(_ctrl_card.def.action_type))
		if not _ActionPilotEffects.is_card_type_controlled_by(_ctrl_owner_mech.mech_id, _ctrl_type, player_id):
			return {"error": "无权使用此受控牌（未控制该类型）"}

	# 检查攻击牌的攻击次数限制
	# 效果产生的使用攻击牌（联合攻击等，source_action_id 非空）不消耗攻击次数
	# （_step_settle 对 source_action_id 非空不 +1），故跳过 attack_count 限制；
	# 但 destroyed / cannot_attack 状态仍阻止攻击。否则 Target 在敌方回合联合攻击时，
	# 其 attack_count_this_turn 未随敌方回合重置（TurnService 仅重置当前回合玩家机甲），
	# can_attack() 误拒致 validate 报错、动作链卡死。
	# 转化行动牌（virtual_transform=true）：转化牌为虚拟牌，不受攻击次数/类型限制，整体跳过。
	var _vt_transform: bool = bool(action.record.get("virtual_transform", false))
	if not _vt_transform and card.def and card.def.action_type == "攻击":
		var mech = context.game_state.mechs.get(mech_id)
		if mech:
			# pilot_010 刻托 effect_03（权限型）：本回合已用3张实体攻击牌则禁止新的实体攻击牌 use_action。
			# virtual_transform 虚拟当作攻击不进此分支（不计数/不限制，裁定歧义3）。
			if not _ActionPilotEffects.can_pilot_010_use_physical_attack_card(context.game_state, mech_id):
				return {"error": "刻托本回合已使用3张攻击牌，不能再使用"}
			var src_action_id: StringName = action.source.get("source_action_id", &"") if action.source is Dictionary else &""
			if src_action_id != &"":
				if mech.destroyed or mech.has_status(&"cannot_attack"):
					return {"error": "机甲无法攻击"}
			elif not mech.can_attack():
				return {"error": "本回合无法再攻击"}

	# 带 AVAILABILITY 的牌只能从其合法响应窗口使用。掩护虽是辅助牌，
	# 也不能因为同时拥有 LISTEN 效果而绕过此限制主动打出。
	var card_mappings: Array = GeneratedActionEffects.get_effects_for_card(_as_card_def_id(action, card))
	var has_direct_or_listen: bool = false
	var has_availability: bool = false
	var all_effects: Dictionary = GeneratedActionEffects.build_all_effects()
	for mapping in card_mappings:
		var eid: StringName = mapping.get("effect_id", &"") if mapping is Dictionary else &""
		var eff: ActionEffect = all_effects.get(eid)
		if eff and (eff.mode == _TimingConst.MODE_DIRECT or eff.mode == _TimingConst.MODE_LISTEN):
			has_direct_or_listen = true
		if eff and eff.mode == _TimingConst.MODE_AVAILABILITY:
			has_availability = true
	if not has_direct_or_listen and not card_mappings.is_empty():
		return {"error": "此牌只能在响应窗口中使用"}
	if has_availability and action.record.get("attack_action_id", &"") == &"":
		return {"error": "此牌只能在合法响应窗口中使用"}

	return result


## ② 牌进入临时区
## 从持有者手中移除，进入临时区
## 注册DIRECT/LISTEN效果的临时监听器
func _step_card_to_temp_zone(action: Action) -> Dictionary:
	var result: Dictionary = {}
	var card_id: StringName = action.record.get("card_instance_id", &"")
	var player_id: StringName = action.record.get("player_id", &"")

	if card_id == &"" or player_id == &"":
		return result

	var player = context.game_state.players.get(player_id)
	if player == null:
		return result

	# 从手牌移除：受控使用时牌在 owner 手牌（目标），非 executor（美杜莎）手牌
	var _hand_card = context.game_state.get_card(card_id) if card_id != &"" else null
	var _hand_owner_pid: StringName = _hand_card.owner_player_id if _hand_card != null else &""
	var _hand_holder = player
	if _hand_owner_pid != &"" and _hand_owner_pid != player_id:
		_hand_holder = context.game_state.players.get(_hand_owner_pid)
	if _hand_holder != null:
		_hand_holder.action_hand.erase(card_id)

	# 注销手牌中的AVAILABILITY监听器
	if context.timing_engine != null:
		context.timing_engine.unregister_listeners_for_card(card_id)

	var card = context.game_state.get_card(card_id)
	if card != null:
		card.zone = &"temp_zone"

	# 转化行动牌（effect_130/135 维修臂）：标注 (转化维修) 标签 + 日志消息。
	# 牌进临时区时标注，结算后随牌进弃牌堆；供 UI/日志识别“此牌当作 XXX 打出”。
	if bool(action.record.get("virtual_transform", false)):
		var as_id: StringName = action.record.get("as_card_def_id", &"")
		var as_name: String = ""
		if as_id != &"" and context.card_database != null:
			var as_def = context.card_database.card_defs.get(as_id, null)
			if as_def != null:
				as_name = String(as_def.display_name)
		var vt_label: String = ("转化%s" % as_name) if as_name != "" else "转化"
		if card != null:
			card.counters["transform_label"] = vt_label
		if context.game_state != null:
			context.game_state.write_log(&"card_transformed", {
				"card_id": String(card_id),
				"card_name": String(card.def.display_name) if card != null and card.def != null else "",
				"as_name": as_name,
			})

	# 注册此牌的DIRECT/LISTEN效果
	_register_card_effects(action, card_id)

	# 诊断(双连卡临时区 bug)：记录牌进临时区
	if _DIAG_USE_CARD and card != null:
		SLog.log_raw("[DIAG use_action_card] %s 牌 %s 进 temp_zone, def=%s" % [String(action.action_id), String(card_id), String(card.def.card_id) if card.def else &""])

	return result


## 注册行动牌效果为临时监听器
## DIRECT效果在_step_execute_effects中直接执行
## AVAILABILITY效果在手牌阶段注册（不在使用时注册）
## LISTEN效果：bind_to_sub=false的绑定到本使用行动牌动作，
##   bind_to_sub=true的延迟到DIRECT效果产生的效果动作创建后再注册
func _register_card_effects(action: Action, card_id: StringName) -> void:
	if context == null or context.timing_engine == null:
		return

	var card = context.game_state.get_card(card_id)
	if card == null or card.def == null:
		return

	var card_mappings: Array = GeneratedActionEffects.get_effects_for_card(_as_card_def_id(action, card))
	var all_effects: Dictionary = GeneratedActionEffects.build_all_effects()

	for mapping in card_mappings:
		var effect_id: StringName = mapping.get("effect_id", &"") if mapping is Dictionary else &""
		if effect_id == &"":
			continue
		var effect: ActionEffect = all_effects.get(effect_id)
		if effect == null:
			continue

		if effect.mode == _TimingConst.MODE_LISTEN and effect.listen_timing != &"":
			if effect.permanent_while_in_hand:
				# 手牌期永久监听器（如推进 effect2）：已由 register_hand_card_availability 注册为
				# 永久监听器监听他人动作。使用此牌时不绑到自身 use_action_card，避免自触发。
				continue
			if mapping.get("bind_to_attack_action", false):
				# 迎击牌 effect2（如反击的反击攻击）：绑定到原 attack 动作（非本 use_action_card）。
				# attack_action_id 由 handle_response_selection 发起 use_action_card 时注入 record。
				# binding_context 携带反击牌持有者，供 _extract_attack_params 的 counter_strike
				# 分支取 attacker_id=迎击牌持有者（攻击2发动方），并补齐 source。
				var attack_action_id: StringName = action.record.get("attack_action_id", &"")
				if attack_action_id != &"":
					var bind_ctx: Dictionary = {
						"responder_mech_id": action.record.get("source_mech_id", action.record.get("mech_id", &"")),
						"responder_player_id": action.record.get("player_id", &""),
						"responder_card_id": card_id,
					}
					context.timing_engine.register_temporary_listener(
						effect.listen_timing,
						attack_action_id,
						&"attack",
						effect,
						&"",
						&"",
						bind_ctx
					)
			elif mapping.get("bind_to_sub", false):
				# 延迟注册：绑定到DIRECT效果产生的效果动作（如攻击A）
				# 存储到 action.record 中，在 _step_execute_effects 执行DIRECT效果后注册
				if not action.record.has("_pending_listen_effects"):
					action.record["_pending_listen_effects"] = []
				action.record["_pending_listen_effects"].append({
					"effect_id": effect_id,
					"timing": effect.listen_timing,
					"card_instance_id": card_id,
				})
			else:
				# 直接绑定到使用行动牌动作本身
				context.timing_engine.register_temporary_listener(
					effect.listen_timing,
					action.action_id,
					&"",
					effect
				)


## ③ 执行行动牌对应的效果/动作
## 执行DIRECT模式效果，并注册延迟的LISTEN效果
## 返回 effect_action_created=true 通知 ActionEngine 等待效果动作完成
func _step_execute_effects(action: Action) -> Dictionary:
	var result: Dictionary = {}
	var card_id: StringName = action.record.get("card_instance_id", &"")
	var card = context.game_state.get_card(card_id)
	if card == null or card.def == null:
		return result

	# 执行DIRECT模式效果
	# DIRECT 效果通过 TimingEngine._execute_effect → _execute_actions → execute_sub_action 执行。
	# execute_sub_action 在创建效果动作时会显式登记父子关系（child.parent_action_id 与
	# parent.pending_effect_action_ids），因此这里无需再用 ActionRegistry size 前后差检测。
	var card_mappings: Array = GeneratedActionEffects.get_effects_for_card(_as_card_def_id(action, card))
	var all_effects: Dictionary = GeneratedActionEffects.build_all_effects()

	for mapping in card_mappings:
		var effect_id: StringName = mapping.get("effect_id", &"") if mapping is Dictionary else &""
		if effect_id == &"":
			continue
		var effect: ActionEffect = all_effects.get(effect_id)
		if effect == null:
			continue

		if effect.mode == _TimingConst.MODE_DIRECT:
			# 通过TimingEngine执行DIRECT效果（含条件/目标/费用检查）
			context.timing_engine._execute_effect(effect, action.record.duplicate(), action)
			# 串行子动作：若该效果创建了未完成的子动作（_seq 已设置），停止遍历后续效果，
			# 待子动作完成后再续跑剩余动作（_continue_seq_effect_actions）。
			# 当前仅支持"最后一个 DIRECT 效果"内串行（识破 effect2：偷牌+移动）；暂不支持
			# pausing 效果之后还有其它 DIRECT 效果（无此用例，若需支持要改为游标续跑）。
			if action.record.has("_seq_effect_actions"):
				break

	# 注册延迟的LISTEN效果（绑定到DIRECT效果产生的效果动作）
	_register_pending_listen_effects(action)

	# pilot_001 effect_01：记录效果链已完成（USE_ACTION_AFTER 时点供 PAYLOAD_EFFECT_CHAIN_COMPLETED 检查）
	action.record["effect_chain_completed"] = true
	# 若 DIRECT 效果产生了未完成的效果动作（如破甲产生 attack A），通知 ActionEngine 暂停等待。
	if not action.pending_effect_action_ids.is_empty():
		result["effect_action_created"] = true

	# 诊断(双连卡临时区 bug)：记录效果动作创建情况
	if _DIAG_USE_CARD:
		SLog.log_raw("[DIAG use_action_card] %s execute_effects 末尾 pending_sub=%s sub_created=%s def=%s" % [String(action.action_id), str(action.pending_effect_action_ids), str(result.get("effect_action_created", false)), String(card.def.card_id)])

	return result


## 注册延迟的LISTEN效果
## 在DIRECT效果执行后，将bind_to_sub的LISTEN效果绑定到DIRECT产生的效果动作。
## 效果动作已由 execute_sub_action 显式登记到 action.pending_effect_action_ids，
## 故从该列表末尾取 attack 类型的效果动作作为绑定目标（不再依赖 source_action_id 字符串匹配
## 或 ActionRegistry.get_actions_by_type 取末尾的脆弱逻辑）。
func _register_pending_listen_effects(action: Action) -> void:
	if not action.record.has("_pending_listen_effects"):
		return
	var pending: Array = action.record["_pending_listen_effects"]
	if pending.is_empty():
		return

	if context == null or context.timing_engine == null or context.action_registry == null:
		return

	var all_effects: Dictionary = GeneratedActionEffects.build_all_effects()

	# 从 pending_effect_action_ids 末尾向前查找最近的 attack 效果动作
	var sub_action_id: StringName = &""
	for i in range(action.pending_effect_action_ids.size() - 1, -1, -1):
		var aid: StringName = action.pending_effect_action_ids[i]
		var sub_action = context.action_registry.get_action(aid)
		if sub_action and sub_action.action_type == &"attack":
			sub_action_id = aid
			break

	# 注册延迟的LISTEN效果
	for pending_info: Dictionary in pending:
		var effect_id: StringName = pending_info.get("effect_id", &"")
		var timing: StringName = pending_info.get("timing", &"")

		var effect: ActionEffect = all_effects.get(effect_id)
		if effect == null or timing == &"":
			continue

		var bind_id: StringName = sub_action_id if sub_action_id != &"" else action.action_id
		context.timing_engine.register_temporary_listener(
			timing,
			bind_id,
			&"attack" if bind_id != action.action_id else &"",
			effect,
			pending_info.get("card_instance_id", &"")
		)

	# 清理临时数据
	action.record.erase("_pending_listen_effects")


## 在 attack 子动作 run 之前，把挂起的 bind_to_sub LISTEN 效果注册到该子动作。
## 由 ActionService.execute_sub_action 在创建 attack 子动作后、run 之前回调。
## 修复注册时机 bug：DIRECT 效果（EXECUTE_ATTACK）创建 attack A 后会同步 run，
## 若 weapon/target 已预填（AI 打攻击牌 / 预填流程），attack A 不在 select_weapon 暂停，
## 会一路跑过 ATTACK_BEFORE（乃至更晚时点）。原 _register_pending_listen_effects 在
## _step_execute_effects 末尾才注册，监听器漏掉已 fire 的时点（如猛击 effect2 漏 ATTACK_BEFORE，
## extra_might 永不写入 -> AI 打猛击不加威力）。本方法把注册提前到 run 之前。
func _register_pending_listeners_on_sub(sub_action_id: StringName) -> void:
	if not record.has("_pending_listen_effects"):
		return
	if context == null or context.timing_engine == null:
		return
	var pending: Array = record["_pending_listen_effects"]
	if pending.is_empty():
		record.erase("_pending_listen_effects")
		return
	var all_effects: Dictionary = GeneratedActionEffects.build_all_effects()
	for pending_info: Dictionary in pending:
		var effect_id: StringName = pending_info.get("effect_id", &"")
		var timing: StringName = pending_info.get("timing", &"")
		var effect: ActionEffect = all_effects.get(effect_id)
		if effect == null or timing == &"":
			continue
		context.timing_engine.register_temporary_listener(
			timing,
			sub_action_id,
			&"attack",
			effect,
			pending_info.get("card_instance_id", &"")
		)
	record.erase("_pending_listen_effects")


## ④ 使用行动牌结算
## 非虚拟行动牌进入行动弃牌堆
func _step_settle(action: Action) -> Dictionary:
	var result: Dictionary = {}
	var card_id: StringName = action.record.get("card_instance_id", &"")
	var is_virtual: bool = action.record.get("is_virtual", false)

	# 诊断(双连卡临时区 bug)：记录 settle 进入时的 zone 与是否调 discard_card
	var settle_zone_before: StringName = &""
	var settle_card = context.game_state.get_card(card_id) if card_id != &"" and context.game_state != null else null
	if settle_card != null:
		settle_zone_before = settle_card.zone
	if _DIAG_USE_CARD:
		SLog.log_raw("[DIAG use_action_card] %s settle 进入, card=%s zone_before=%s virtual=%s" % [String(action.action_id), String(card_id), String(settle_zone_before), str(is_virtual)])

	if not is_virtual and card_id != &"" and context.deck_service != null:
		var card = context.game_state.get_card(card_id)
		var _vt_settle: bool = bool(action.record.get("virtual_transform", false))
		# 只有玩家主动使用攻击牌，才在整张牌效果完成后的结算阶段消耗攻击次数。
		# 效果产生的“使用攻击牌”不重复占用通常攻击次数。转化行动牌(virtual_transform)不消耗。
		if not _vt_settle and card != null and card.def != null and card.def.action_type == "攻击":
			var source_action_id: StringName = action.source.get("source_action_id", &"")
			if source_action_id == &"":
				var mech = context.game_state.mechs.get(action.record.get("mech_id", &""))
				if mech != null:
					mech.attack_count_this_turn += 1
		# 绑定到原 attack 动作的效果（如反击2）在原攻击 ATTACK_SETTLE 才触发，须等其触发后再弃置，
		# 故此处跳过，交由 attack_action._step_cleanup 弃置（规则：行动牌所有效果执行完才结算弃置）。
		# 转化行动牌(virtual_transform)：当作虚拟牌打出，非其原类型用途，无 bind_to_attack 延迟，直接弃置。
		if card != null and String(card.zone) != &"discard" and (_vt_settle or not _has_bind_to_attack_action_effect(card)):
			# pilot_007 夺取的牌跳过弃置（已被夺到手牌）；清除标记避免残留
			if card.counters.get("claimed_by_pilot_007", false):
				card.counters.erase("claimed_by_pilot_007")
			else:
				context.deck_service.discard_card(card_id, &"ACTION_CARD_PLAYED")
				# 诊断：discard_card 是异步效果动作(fire DISCARD 时点)，此处 result 不声明 effect_action_created
				# 若双连卡在此后仍停 temp_zone，说明 discard_card 效果动作未完成/settle 未等它。
			if _DIAG_USE_CARD:
				SLog.log_raw("[DIAG use_action_card] %s settle 调 discard_card, pending_sub=%s" % [String(action.action_id), str(action.pending_effect_action_ids)])

	return result


## 判断本牌是否含绑定到原 attack 动作的 LISTEN 效果（如反击2：counter_effect2）
## 此类牌的效果2监听原攻击动作的后续时点（ATTACK_SETTLE），在效果2触发前不应被本
## use_action_card 的 settle 弃置——弃牌须等效果2结算完，交由 attack_action._step_cleanup。
func _has_bind_to_attack_action_effect(card) -> bool:
	if card == null or card.def == null:
		return false
	# 判断原牌自身是否含 bind_to_attack_action 效果（不用 as_card_def_id：这是原牌属性）
	var card_mappings: Array = GeneratedActionEffects.get_effects_for_card(card.def.card_id)
	for mapping in card_mappings:
		if mapping is Dictionary and mapping.get("bind_to_attack_action", false):
			return true
	return false
