## steal_action_card_action.gd — 偷取行动牌动作（识破效果1）
##
## 按规则书第22项识破效果1：
##   被攻击方从攻击者手牌选1张行动牌获得（攻击者手牌对防御方为暗牌）。
##
##   ① 确定要获得的牌（玩家暗牌选1张 / AI 随机 / 已指定）→ 发出 GAIN_CARD_BEFORE
##   ② 将牌从攻击者手牌转移给防御方手牌 → 发出 GAIN_CARD_AFTER
##   ③ 获取牌结算 → 发出 GAIN_CARD_SETTLE
##
## 仿 discard_card_action / gain_card_action：need_input 暂停让玩家选牌。
## 攻击方/防御方信息从攻击动作 record（经 attack_action_id）解析，
## 不依赖废弃的 game_state.current_attack_id / attacks。
extends Action
class_name StealActionCardAction

const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")


func _init() -> void:
	action_type = &"steal_action_card"


func setup_steps() -> void:
	steps = [
		{step_name = &"determine_cards",   timing_point = _TimingConst.GAIN_CARD_BEFORE, handler = _step_determine_cards},
		{step_name = &"transfer_to_holder", timing_point = _TimingConst.GAIN_CARD_AFTER,  handler = _step_transfer_to_holder},
		{step_name = &"settle",            timing_point = _TimingConst.GAIN_CARD_SETTLE, handler = _step_settle},
	]


func get_display_name() -> String:
	return "偷取行动牌"


## 从攻击动作 record 解析 attacker_id / target_id
## （新攻击流程不写 game_state.current_attack_id，攻击信息只在攻击动作 record 里）
func _resolve_attack_field(action: Action, field: StringName) -> StringName:
	# 1. record.attack_action_id → 查攻击动作 record
	var attack_action_id: StringName = action.record.get("attack_action_id", &"")
	if attack_action_id != &"" and context != null and context.action_registry != null:
		var atk = context.action_registry.get_action(attack_action_id)
		if atk != null and atk.record is Dictionary:
			var v: StringName = atk.record.get(field, &"")
			if v != &"":
				return v
	# 2. record 直接字段（_extract_steal_params 透传）
	var direct: StringName = action.record.get(field, &"")
	if direct != &"":
		return direct
	# 3. 旧路径兼容（旧流程仍写 current_attack_id / attacks）
	if context != null and context.game_state != null and context.game_state.current_attack_id != &"":
		var atk2: Dictionary = context.game_state.attacks.get(context.game_state.current_attack_id, {})
		return atk2.get(field, &"")
	return &""


## 解析偷牌来源玩家（from_attacker → 攻击方；from_target → 目标方）
func _resolve_from_player(action: Action) -> StringName:
	var from_player_id: StringName = action.record.get("from_player_id", &"")
	if from_player_id != &"":
		return from_player_id

	# pilot_012: from_target_id 直接指定偷牌来源机甲（机甲id，非攻击动作字段）
	var from_target_mid: StringName = action.record.get("from_target_id", &"")
	if from_target_mid != &"":
		var fp = context.game_state.get_player_for_mech(from_target_mid)
		if fp != null:
			return fp.player_id
		return &""

	var mech_id: StringName = &""
	if bool(action.record.get("from_attacker", false)):
		mech_id = _resolve_attack_field(action, &"attacker_id")
	elif bool(action.record.get("from_target", false)):
		mech_id = _resolve_attack_field(action, &"target_id")
	if mech_id == &"":
		return &""
	var player = context.game_state.get_player_for_mech(mech_id)
	if player != null:
		return player.player_id
	return &""


func _step_determine_cards(action: Action) -> Dictionary:
	var count: int = int(action.record.get("count", 1))
	var choose: bool = bool(action.record.get("choose", false))
	var from_player_id: StringName = _resolve_from_player(action)
	# 获得方 = 识破使用者（防御方），由 _extract_steal_params / source 注入
	var to_player_id: StringName = action.record.get("to_player_id", action.record.get("player_id", &""))
	# pilot_012: to_target_id（机甲id）解析 to_player_id
	var to_target_mid: StringName = action.record.get("to_target_id", &"")
	if to_target_mid != &"":
		var tp = context.game_state.get_player_for_mech(to_target_mid)
		if tp != null:
			to_player_id = tp.player_id

	# 写回 record 供 transfer 步骤使用
	action.record["from_player_id"] = from_player_id
	action.record["to_player_id"] = to_player_id

	# 已预选牌（玩家选完恢复 / 测试直接注入）：直接用
	var determined: Array = action.record.get("determined_card_ids", [])
	if not determined.is_empty():
		return {"determined_card_ids": determined}

	# 取消：玩家选「不偷任何牌」-> 偷0张完成（取消=跳过偷牌，非重弹）。
	# app_root._on_discard_selection_cancelled need_input 分支带 cancelled=true；
	# determined 为空（取消未选牌），须用 cancelled 区分「取消」与「首次运行」，否则重弹死循环。
	if action.record.get("cancelled", false):
		return {"determined_card_ids": []}

	# 来源/目标不可解析或来源手牌为空：无牌可偷，空转完成
	var from_state = context.game_state.players.get(from_player_id) if from_player_id != &"" else null
	if from_state == null or from_state.action_hand.is_empty():
		return {"determined_card_ids": []}

	# choose=true 且获得方为玩家：弹暗牌选牌 UI（攻击者手牌对防御方未知）
	var executor: StringName = action.record.get("executor", &"")
	# pilot_012: chooser_id 指定选牌执行者（选牌的人）
	var chooser: StringName = action.record.get("chooser_id", &"")
	if chooser != &"":
		executor = chooser
		action.record["executor"] = executor
	if choose and executor != &"system_random" and executor != &"system_default":
		# executor 未指定时默认为获得方玩家
		if executor == &"":
			executor = to_player_id
			action.record["executor"] = executor
		# AI 获得方（非 player）自动随机选牌，不弹窗
		if not _is_ai_player(executor):
			return {
				"need_input": true,
				"input_type": &"select_discard_cards",
				"input_params": {
					"action_id": action.action_id,
					"mode": &"need_input",  # 区分闪击 optional 弃牌（走 resume_pending_effect）
					"executor": executor,
					"count": count,
					"face_up": false,  # 攻击者手牌暗牌
					"discard_player_id": from_player_id,
					"action_verb": &"gain",  # 识破偷牌=获取（UI 显示"获取"而非"弃置"）
				},
			}

	# AI / system_random / 非 choose：随机取 N 张（走 context.rng 同步随机，锁步双端一致）
	var hand: Array = from_state.action_hand.duplicate()
	if context != null and context.rng != null:
		context.synced_shuffle(hand)
	else:
		hand.shuffle()
	determined = hand.slice(0, min(count, hand.size()))
	return {"determined_card_ids": determined}


## 判断 executor 是否为 AI（非人类玩家）
func _is_ai_player(player_id: StringName) -> bool:
	if player_id == &"" or context == null or context.game_state == null:
		return false
	var player = context.game_state.players.get(player_id)
	if player == null:
		return false
	return not player.is_human


func _step_transfer_to_holder(action: Action) -> Dictionary:
	var result: Dictionary = {}
	var determined: Array = action.record.get("determined_card_ids", [])
	var from_player_id: StringName = action.record.get("from_player_id", &"")
	var to_player_id: StringName = action.record.get("to_player_id", action.record.get("player_id", &""))

	if from_player_id == &"" or to_player_id == &"":
		push_warning("steal_action_card: 缺少 from_player_id/to_player_id，跳过转移")
		return result

	var from_state = context.game_state.players.get(from_player_id)
	var to_state = context.game_state.players.get(to_player_id)
	if from_state == null or to_state == null:
		return result

	var stolen: Array[StringName] = []
	for card_id in determined:
		if card_id == &"":
			continue
		var idx: int = from_state.action_hand.find(card_id)
		if idx < 0:
			continue
		from_state.action_hand.pop_at(idx)

		to_state.action_hand.append(card_id)
		var card = context.game_state.get_card(card_id)
		if card != null:
			card.owner_player_id = to_player_id
			card.zone = &"action_hand"
			# 行动牌进手牌后必须注册 AVAILABILITY 监听器，否则后续响应窗口列不出该牌
			if context != null and card.def != null and card.def.card_kind == &"action":
				if context.has_method(&"register_hand_card_availability"):
					context.register_hand_card_availability(card_id)
		stolen.append(card_id)

	# 通知：牌从攻击方转移到防御方
	if context != null and context.effect_engine != null and not stolen.is_empty():
		for card_id in stolen:
			context.effect_engine.fire_hook(&"ON_CARD_TRANSFERRED", {
				"card_id": card_id,
				"from_player_id": from_player_id,
				"to_player_id": to_player_id,
				"reason": &"STOLEN",
			})

	return result


func _step_settle(action: Action) -> Dictionary:
	return {}
