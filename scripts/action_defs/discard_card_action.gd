## discard_card_action.gd — 弃置牌动作
##
## 按新规则文档定义：
##   ① 确定真正要弃置的牌 → 发出 DISCARD_BEFORE
##   ② 将牌转移到弃牌堆 → 发出 DISCARD_AFTER
##   ③ 弃置牌结算 → 发出 DISCARD_SETTLE
##
## 如果执行者是机甲/玩家，则跳出UI选框让其选择弃置的牌
extends Action
class_name DiscardCardAction

const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _GeneratedEventEffects = preload("res://scripts/generated_database/GeneratedEventEffects.gd")
const SLog = preload("res://scripts/services/slog.gd")


func _init() -> void:
	action_type = &"discard_card"


func setup_steps() -> void:
	# 弃置流程插 tmp_zone 阶段（用户决策9）：
	#   ① determine_cards：确定要弃的牌 + 快照来源(mech_id/slot_id/zone/reason) → DISCARD_BEFORE
	#   ② move_to_tmp：牌移入 tmp_zone（从原区域/手牌移除，zone=temp_zone）
	#   ③ transfer_to_pile：牌从 tmp_zone 移入对应弃牌堆
	#   ④ fire_discard_after：→ DISCARD_AFTER（监听器此时看到牌已经在弃牌堆）
	#   ⑤ settle：→ DISCARD_SETTLE
	steps = [
		{step_name = &"determine_cards",  timing_point = _TimingConst.DISCARD_BEFORE, handler = _step_determine_cards},
		{step_name = &"move_to_tmp",      timing_point = &"",                         handler = _step_move_to_tmp},
		{step_name = &"transfer_to_pile", timing_point = &"",                         handler = _step_transfer_to_pile},
		{step_name = &"fire_after",       timing_point = _TimingConst.DISCARD_AFTER,  handler = _step_fire_discard_after},
		{step_name = &"settle",           timing_point = _TimingConst.DISCARD_SETTLE, handler = _step_settle},
	]


func get_display_name() -> String:
	return "弃置牌"


func _step_determine_cards(action: Action) -> Dictionary:
	var card_ids: Array = action.record.get("card_ids", [])
	var count: int = action.record.get("count", 1)
	# count<=0：无牌可弃，直接弃0张完成、不弹窗（索伦 pilot_044 X=0 时抽1弃0；对后续所有效果通用）。
	if count <= 0:
		return {"determined_card_ids": []}
	var executor: StringName = action.record.get("executor", &"")

	# from_target=true：从攻击目标玩家手牌弃牌（预判 effect2）。
	# target_id 是被攻击机甲，反查其玩家作为弃牌对象；executor 默认 system_random（暗牌随机弃）。
	# 新攻击流程攻击信息只在攻击动作 record 里（经 attack_action_id 查），不依赖 game_state.current_attack_id。
	if action.record.get("from_target", false):
		var from_target_id: StringName = action.record.get("target_id", &"")
		if from_target_id == &"":
			var attack_action_id: StringName = action.record.get("attack_action_id", &"")
			if attack_action_id != &"" and context != null and context.action_registry != null:
				var atk = context.action_registry.get_action(attack_action_id)
				if atk != null and atk.record is Dictionary:
					from_target_id = atk.record.get("target_id", &"")
		if from_target_id != &"" and context != null and context.game_state != null:
			var target_player = context.game_state.get_player_for_mech(from_target_id)
			if target_player != null:
				action.record["player_id"] = target_player.player_id
				# choose=true：预判使用方（动作来源玩家=攻击方）选 Target 的暗牌弃置；
				# 否则 system_random 暗牌随机弃。
				if action.record.get("choose", false):
					if executor == &"" or executor == &"system_random":
						# executor = 预判使用方（攻击方）。attack.record 无 player_id，
						# 从 attacker_id 反查玩家（source.player_id 优先，再 record.attacker_id）
						var src_pid: StringName = action.source.get("player_id", &"") if action.source is Dictionary else &""
						if src_pid == &"":
							var atk_id: StringName = action.record.get("attacker_id", &"")
							if atk_id == &"":
								var aaid: StringName = action.record.get("attack_action_id", &"")
								if aaid != &"" and context != null and context.action_registry != null:
									var atk = context.action_registry.get_action(aaid)
									if atk != null and atk.record is Dictionary:
										atk_id = atk.record.get("attacker_id", &"")
							if atk_id != &"" and context != null and context.game_state != null:
								var atk_player = context.game_state.get_player_for_mech(atk_id)
								if atk_player != null:
									src_pid = atk_player.player_id
						if src_pid != &"":
							executor = src_pid
						else:
							executor = &"system_random"
				elif executor == &"":
					executor = &"system_random"
			else:
				push_warning("discard_card: from_target 反查目标玩家失败，target_id=%s" % String(from_target_id))
		else:
			push_warning("discard_card: from_target 缺少 target_id/attack_action_id，退回默认弃牌逻辑")
	elif action.record.get("from_opposing", false):
		# 肯特 granted 帝国压制：从对侧（非 source_mech 的攻击参与方）弃牌，使用方选 2 张暗牌。
		# source_mech=binding_context.mech_id（肯特被授予机甲，攻或守）；
		# 对侧 = source==attacker?target:source==target?attacker。
		# player_id=对侧玩家（被弃方）；executor=使用方（source_mech 的玩家，选牌）。
		var fo_source_mech: StringName = action.record.get("source_mech", &"")
		var fo_attacker: StringName = action.record.get("attacker_id", &"")
		var fo_target: StringName = action.record.get("target_id", &"")
		var fo_opposing: StringName = &""
		if fo_source_mech == fo_attacker and fo_target != &"":
			fo_opposing = fo_target
		elif fo_source_mech == fo_target and fo_attacker != &"":
			fo_opposing = fo_attacker
		if fo_opposing != &"" and context != null and context.game_state != null:
			var fo_player = context.game_state.get_player_for_mech(fo_opposing)
			if fo_player != null:
				action.record["player_id"] = fo_player.player_id
		# executor = 使用方（source_mech 的玩家）；choose=true 触发选牌 UI
		if (executor == &"" or executor == &"system_random") and fo_source_mech != &"" and context != null and context.game_state != null:
			var fo_src_player = context.game_state.get_player_for_mech(fo_source_mech)
			if fo_src_player != null:
				executor = fo_src_player.player_id

	# need_input 恢复：玩家/AI 已选好要弃的牌（on_ui_confirmed 回填 determined_card_ids，
	# 经 ActionEngine.continue_action merge 进 record 后重跑本步）。直接快照并返回，
	# 避免再次走 need_input 死循环。
	var _already: Array = action.record.get("determined_card_ids", [])
	if not _already.is_empty():
		_snapshot_discard_sources(action, _already)
		return {"determined_card_ids": _already}

	# 取消：玩家选「不弃置任何牌」-> 弃0张完成（取消=跳过弃牌，非重弹）。
	# app_root._on_discard_selection_cancelled need_input 分支带 cancelled=true；
	# 此处 determined_card_ids 为空（取消未选牌），须用 cancelled 标志区分「取消」与
	# 「首次运行未选」，否则会再次走到 need_input 重弹窗死循环。
	if action.record.get("cancelled", false):
		return {"determined_card_ids": []}

	# 弃全部手牌行动牌（德伦迪 pilot_042 弃所有）：不弹窗，直接取该玩家全部行动手牌弃置。
	# player_id 由 _extract_discard_params 从 binding_context 补全；缺省退回 source.player_id。
	if action.record.get("discard_all_action_hand", false):
		var _da_pid: StringName = action.record.get("player_id", action.source.get("player_id", &"") if action.source is Dictionary else &"")
		var _da_player = context.game_state.players.get(_da_pid) if (_da_pid != &"" and context != null and context.game_state != null) else null
		var _da_ids: Array = []
		if _da_player != null:
			_da_ids = _da_player.action_hand.duplicate()
		_snapshot_discard_sources(action, _da_ids)
		return {"determined_card_ids": _da_ids}

	# 如果已指定具体牌，无需选择
	if not card_ids.is_empty():
		_snapshot_discard_sources(action, card_ids)
		return {"determined_card_ids": card_ids}

	# 如果执行者是玩家，需要UI选择
	# mode=need_input：app_root._show_popup/_on_discard_selection_completed 据此区分
	# 「动作 need_input（走 ui_confirmed->continue_action 重跑本步）」与
	# 「闪击 optional 弃牌（走 resume_pending_effect）」。漏标 mode 会被误判为 optional，
	# 提交时 resume_pending_effect 对非挂起动作 no-op，弃牌永不执行、游戏停滞。
	# 与 steal_action_card._step_determine_cards 的 need_input input_params 一致。
	if executor != &"" and executor != &"system_random" and executor != &"system_default":
		# 目标手牌为空：无牌可弃，弃0张完成（与 steal_action_card 一致）。
		# 否则空手弹窗0张牌、确认disabled、只能取消->重弹->死循环卡死。
		# player_id 为 from_target 解析出的被弃方；为空（非 from_target 自弃场景）退回 executor。
		var _hand_owner_pid: StringName = action.record.get("player_id", &"")
		if _hand_owner_pid == &"":
			_hand_owner_pid = executor
		var _hand_owner = context.game_state.players.get(_hand_owner_pid) if (_hand_owner_pid != &"" and context != null and context.game_state != null) else null
		if _hand_owner == null or _hand_owner.action_hand.is_empty():
			return {"determined_card_ids": []}
		# 实际可弃数 = min(指定数, 手牌数)。扭转钢鞭 effect_100 count=2 但目标可能仅1张行动牌：
		# 按拆解歧义1「有几张弃几张」，UI 强制精确 count 张，若不减会 confirm disabled 卡死。
		var _eff_count: int = min(count, _hand_owner.action_hand.size())
		# 布彻尔 pilot_064「未响应弃目标2张」：目标行动牌总数≤count 时不弹窗直接全部弃置
		# （有几张弃几张，含0张提前返回）。手牌>count 仍需弹窗选 count 张。
		# 通用参数 auto_discard_all_if_covered，任何弃牌效果可复用。
		if bool(action.record.get("auto_discard_all_if_covered", false)) and _hand_owner.action_hand.size() <= count:
			var _auto_all_ids: Array = _hand_owner.action_hand.duplicate()
			_snapshot_discard_sources(action, _auto_all_ids)
			return {"determined_card_ids": _auto_all_ids}
		return {
			"need_input": true,
			"input_type": &"select_discard_cards",
			"input_params": {
				"action_id": action.action_id,
				"mode": &"need_input",
				"executor": executor,
				"count": _eff_count,
				"face_up": action.record.get("face_up", true),
				"discard_player_id": action.record.get("player_id", &""),
				"action_verb": &"discard",
				"no_cancel": bool(action.record.get("no_cancel", false)),
			},
		}

	# 系统随机弃置
	if executor == &"system_random":
		var player_id: StringName = action.record.get("player_id", action.source.get("player_id", &""))
		var player = context.game_state.players.get(player_id)
		if player != null:
			var hand: Array = player.action_hand.duplicate()
			if context != null and context.rng != null:
				context.synced_shuffle(hand)
			else:
				hand.shuffle()
			card_ids = hand.slice(0, min(count, hand.size()))
		_snapshot_discard_sources(action, card_ids)
		return {"determined_card_ids": card_ids}

	# 系统默认：弃置指定数量的前N张牌
	var player_id: StringName = action.record.get("player_id", action.source.get("player_id", &""))
	var player = context.game_state.players.get(player_id)
	if player != null:
		var action_hand: Array = player.action_hand
		card_ids = action_hand.slice(0, min(count, action_hand.size()))

	_snapshot_discard_sources(action, card_ids)
	return {"determined_card_ids": card_ids}


## 快照每张将弃牌的来源信息（在移入 tmp_zone 前调用，此时 card.slot_id/mech_id/zone 仍有效）
## 存入 action.record["discard_snapshots"]，DISCARD_AFTER 时点 payload 携带，供离场效果按 reason/slot 过滤
func _snapshot_discard_sources(action: Action, card_ids: Array) -> void:
	var reason: StringName = action.record.get("reason", &"")
	var snapshots: Array = []
	for card_id: StringName in card_ids:
		if card_id == &"":
			continue
		var card = context.game_state.get_card(card_id) if context != null and context.game_state != null else null
		var snap: Dictionary = {
			"card_id": card_id,
			"reason": reason,
		}
		if card != null:
			# 归属回退：手牌装备牌 mech_id 历史上为空（抽牌/商店购买路径只设 owner_player_id），
			# 逐点补设 mech_id 后仍可能有旧存档/特殊入口的牌为空，此处按 owner_player_id 反查
			# 持有者机甲兜底，保证 from_mech_id 归属判定（霍克 pilot_055 卖出翻倍等弃牌归属条件）不落空。
			var snap_mech_id: StringName = card.mech_id
			if snap_mech_id == &"" and card.owner_player_id != &"" and context != null and context.game_state != null:
				var snap_owner_mech = context.game_state.get_mech_for_player(card.owner_player_id)
				snap_mech_id = snap_owner_mech.mech_id if snap_owner_mech != null else &""
			snap["from_mech_id"] = snap_mech_id
			snap["from_slot_id"] = card.slot_id
			snap["from_zone"] = card.zone
			snap["def_id"] = card.def.card_id if card.def != null else &""
			snap["card_kind"] = card.def.card_kind if card.def != null else &""
			# 背面朝上（备用区白板）标记：供弃装获金类效果（pilot_088 莽克）判断「正面设置」排除备用区
			snap["face_down"] = card.get("face_down") == true
		snapshots.append(snap)
	action.record["discard_snapshots"] = snapshots


## ② 牌移入 tmp_zone（从原区域/手牌移除，zone=temp_zone）
## 离场效果在 DISCARD_AFTER 时点触发时，牌处于 tmp_zone，效果子动作结算后才入弃牌堆
func _step_move_to_tmp(action: Action) -> Dictionary:
	var card_ids: Array = action.record.get("determined_card_ids", [])
	for card_id: StringName in card_ids:
		if card_id == &"":
			continue
		var card = context.game_state.get_card(card_id) if context != null and context.game_state != null else null
		if card == null:
			continue
		# 从原区域/手牌移除（保留快照已记录的 from_mech_id/from_slot_id）
		context.game_state.remove_card_from_all_zones(card_id)
		# 行动牌离开手牌时注销其 AVAILABILITY 监听器（迎击牌等），避免弃置后仍作为响应窗口可选项残留
		if card.def != null and card.def.card_kind == &"action" and context.has_method("unregister_hand_card_availability"):
			context.unregister_hand_card_availability(card_id)
		# 注：装备牌的 permanent listener 不在此注销--离场诱发效果（effect_003/005/031）
		# 监听 DISCARD_AFTER，须在 DISCARD_AFTER fire 时仍处于注册态才能触发。统一改在
		# _step_settle（DISCARD_AFTER 之后）注销，避免离场效果被提前移除而静默失效。
		# 移入 tmp_zone
		card.zone = &"temp_zone"
	return {}


## ③ DISCARD_AFTER 时点 fire（离场效果监听此时点）
## payload 携带 discard_snapshots（含 from_mech_id/from_slot_id/reason/card_id/def_id）
func _step_fire_discard_after(action: Action) -> Dictionary:
	# 时点由 setup_steps 的 timing_point=DISCARD_AFTER 自动 fire
	# 这里只需确保 payload 含 discard_snapshots（fire_timing 读 action.record.duplicate）
	return {}


## ④ 牌从 tmp_zone 移入对应弃牌堆
func _step_transfer_to_pile(action: Action) -> Dictionary:
	var result: Dictionary = {}
	var card_ids: Array = action.record.get("determined_card_ids", [])
	var reason: StringName = action.record.get("reason", &"")
	var snapshots: Array = action.record.get("discard_snapshots", [])

	for idx in range(card_ids.size()):
		var card_id: StringName = card_ids[idx]
		if card_id == &"":
			continue
		var card = context.game_state.get_card(card_id)
		if card == null:
			continue

		# pilot_022 塔莉娅"策"标签：带"策"标签的行动牌从临时区进弃牌堆（通用"使用"判定，
		# 含迪恩转化代价牌）时，塔莉娅抽2；标签入弃牌堆即消失（无论使用/直接弃置）。
		# 用快照 from_zone 而非 card.zone 判定：move_to_tmp 已把 card.zone 置 temp_zone，
		# 直接弃置（action_hand，未经过使用）也会命中 card.zone，故看 discard 动作开始时的 zone。
		# 使用中的牌（use_action_card _step_card_to_temp_zone）from_zone=temp_zone 计入；
		# 手牌直接弃置 from_zone=action_hand 不计入（回合超限/预判/肯特压制等），仅清标签。
		var _snap_idx: Dictionary = snapshots[idx] if idx < snapshots.size() else {}
		if card.def != null and card.def.card_kind == &"action" and _ActionPilotEffects.pilot_022_card_has_any_ce(card):
			if _snap_idx.get("from_zone", &"") == &"temp_zone":
				var _p021_ce_drawn: int = _ActionPilotEffects.pilot_022_trigger_ce_draw(context, card)
				if _p021_ce_drawn > 0:
					SLog.log_raw("[pilot_022] 策标签牌使用后塔莉娅抽2 x%d card=%s" % [_p021_ce_drawn, String(card_id)])
			else:
				_ActionPilotEffects.pilot_022_clear_all_ce(card)
		# pilot_086 塔妮拉"交"标签：带"交"标签的行动牌从临时区进弃牌堆（通用"使用"判定，
		# 含迪恩转化代价牌等）时，使用方先抽1 + 塔妮拉后抽1，标签入弃牌堆即消失。
		# from_zone==temp_zone 计入（使用中），from_zone==action_hand 仅清标签不抽。
		if card.def != null and card.def.card_kind == &"action" and _ActionPilotEffects.pilot_086_card_has_any_jiao(card):
			if _snap_idx.get("from_zone", &"") == &"temp_zone":
				var _p087_jiao_drawn: int = _ActionPilotEffects.pilot_086_trigger_jiao_draw(context, card)
				if _p087_jiao_drawn > 0:
					SLog.log_raw("[pilot_086] 交标签牌使用后双方各抽1 x%d card=%s" % [_p087_jiao_drawn, String(card_id)])
			else:
				_ActionPilotEffects.pilot_086_clear_all_jiao(card)
		# 温斯顿 pilot_082"联"标签：联牌离开持有者手牌/临时区进弃牌堆（使用/弃置）即消失。
		# 使用路径在 USE_ACTION_AT 已触发施加联合状态，入弃牌堆无需再保留标签。
		if card.def != null and card.def.card_kind == &"action" and _ActionPilotEffects.pilot_082_card_has_any_lian(card):
			_ActionPilotEffects.pilot_082_clear_all_lian(card)
		# 设置弃牌区（牌已在 tmp_zone，remove_card_from_all_zones 已在 move_to_tmp 调用）
		# 事件牌永久离场：zone=removed 且不入任何弃牌堆。
		# 事件牌堆只减不回（结算/弃置/顶掉的事件牌永不重洗），removed 使其不再出现在区域查询中。
		var is_event_discard: bool = card.def != null and card.def.card_kind == &"event"
		card.zone = &"removed" if is_event_discard else &"discard"
		card.slot_id = &""
		card.mech_id = &""

		# 按类型分入弃牌堆（事件牌不入堆，永久离场）
		if not is_event_discard:
			var target_pile: Array = context.game_state.deck_state.action_discard_pile
			if card.def and card.def.card_kind == &"equipment":
				target_pile = context.game_state.deck_state.equipment_discard_pile
			if not target_pile.has(card_id):
				target_pile.append(card_id)

		# 写日志（消息面板通过 SessionLogger 的 card_discarded 日志显示，不走 legacy hook）
		context.game_state.write_log(&"card_discarded", {
			"card_id": String(card_id),
			"reason": String(reason),
		})

	return result


func _step_settle(action: Action) -> Dictionary:
	# DISCARD_AFTER 已 fire（离场诱发效果已触发），此处注销被弃装备牌的 permanent listener，
	# 使其后续不再在未来时点触发（如已离场的联邦右腿 ATTACK_PRE 不再响应该回合后续攻击）。
	var settle_card_ids: Array = action.record.get("determined_card_ids", [])
	# transfer_to_pile 已把 card.mech_id 清空，事件牌清理需按 discard_snapshots 取 from_mech_id
	var settle_snapshots: Array = action.record.get("discard_snapshots", [])
	if context != null and context.timing_engine != null:
		for idx in range(settle_card_ids.size()):
			var card_id: StringName = settle_card_ids[idx]
			if card_id == &"":
				continue
			var s_card = context.game_state.get_card(card_id) if context.game_state != null else null
			if s_card == null or s_card.def == null:
				continue
			if s_card.def.card_kind == &"equipment":
				context.timing_engine.unregister_permanent_listeners_for_card(card_id)
				# 拘束钩爪 effect_104：武器离场时移除其施加的 LOCKED 状态（此牌弃置则锁定解除）
				if context.game_actions != null and context.game_actions.has_method("remove_locked_status_by_source_card"):
					context.game_actions.remove_locked_status_by_source_card(card_id)
			elif s_card.def.card_kind == &"event":
				# 事件牌离场：注销监听器 + 撤派生加成 + 清其施加的状态 + 重算动力上限
				# （与 set_event_card_action._step_activate 的注册路径对称）。
				context.timing_engine.unregister_permanent_listeners_for_card(card_id)
				var ev_snap: Dictionary = settle_snapshots[idx] if idx < settle_snapshots.size() else {}
				var ev_mech_id: StringName = StringName(String(ev_snap.get("from_mech_id", &"")))
				if ev_mech_id != &"":
					_GeneratedEventEffects.unregister_derived_bonuses(ev_mech_id)
					_GeneratedEventEffects.remove_status_by_source_card(context, card_id)
					var ev_mech = context.game_state.mechs.get(ev_mech_id) if context.game_state != null else null
					if ev_mech != null:
						var old_max_power: int = ev_mech.max_power
						ev_mech.max_power = ev_mech.get_total_power()
						ev_mech.sync_own_power_after_max_change(old_max_power)
	return {}
