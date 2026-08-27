## gain_card_action.gd — 获取牌动作
##
## 按新规则文档定义：
##   ① 提取牌信息 → 发出 GAIN_CARD_BEFORE
##   ② 转移牌给机甲 → 发出 GAIN_CARD_AFTER
##   ③ 获取牌结算 → 发出 GAIN_CARD_SETTLE
extends Action
class_name GainCardAction

const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")


func _init() -> void:
	action_type = &"gain_card"


func setup_steps() -> void:
	steps = [
		{step_name = &"extract_info",  timing_point = _TimingConst.GAIN_CARD_BEFORE, handler = _step_extract_info},
		{step_name = &"transfer_card", timing_point = _TimingConst.GAIN_CARD_AFTER,  handler = _step_transfer_card},
		{step_name = &"settle",        timing_point = _TimingConst.GAIN_CARD_SETTLE, handler = _step_settle},
	]


func get_display_name() -> String:
	return "获取牌"


func _step_extract_info(action: Action) -> Dictionary:
	# 预初始化 typed 空 drawn_card_ids：银雪窥牌等效果使本动作在 GAIN_CARD_BEFORE 挂起，
	# 挂起期间读 action.record["drawn_card_ids"] 的调用方若拿到未 typed 空数组，再赋给
	# Array[StringName] 会崩。此处先以 typed 空数组占位，transfer 阶段真实抽牌结果再覆盖。
	action.record["drawn_card_ids"] = ([] as Array[StringName])
	# 预打"抽取"标（GAIN_CARD_BEFORE 时点可读，与 transfer 后口径一致）。
	# 此前抽取标在 transfer 阶段（GAIN_CARD_AFTER 前）才打，GAIN_CARD_BEFORE 监听器
	# （格温 pilot_043 宣言抽取等）读不到 draw/draw_card_kind。判定口径统一：
	# card_ids 为空（系统从牌堆/弃牌堆自动取牌）= 抽取。transfer 的 _tag_draw 再次
	# 调用覆盖同值，无副作用。
	var card_ids: Array = action.record.get("card_ids", [])
	if card_ids.is_empty():
		var _pre_pid: StringName = action.record.get("player_id", &"")
		var _pre_mids: Array = action.record.get("mech_ids", [])
		if _pre_pid == &"" and not _pre_mids.is_empty() and context != null and context.game_state != null:
			var _pre_p = context.game_state.get_player_for_mech(_pre_mids[0])
			if _pre_p != null:
				_pre_pid = _pre_p.player_id
		_tag_draw(action, _pre_pid, action.record.get("from_zone", &""), action.record.get("card_kind", &""))
	return {}


func _step_transfer_card(action: Action) -> Dictionary:
	var result: Dictionary = {}
	var card_ids: Array = action.record.get("card_ids", [])
	var mech_ids: Array = action.record.get("mech_ids", [])
	var from_zone: StringName = action.record.get("from_zone", &"")
	var reason: StringName = action.record.get("reason", &"effect")
	var count: int = action.record.get("count", 1)

	# 统一"抽取"标（库马斯 pilot_035 等监听 GAIN_CARD_AFTER 判定"本次是否抽取"）。
	# 口径：card_ids 为空（无明确指定牌）、由系统从牌堆/弃牌堆自动取牌 = 抽取。
	# 觉醒（awaken_temp + 明确 card_ids 选牌获取）、回收维修（明确 card_ids）、识破偷牌
	# （steal_action_card 不走 gain_card）、给予转移（transfer 不走 gain_card）均天然不命中。
	var _is_draw := false
	var _draw_player_id: StringName = &""

	# 牌堆顶顺序抽（行动/装备）：委托 GameActions，保留 pilot_003 跳过正面牌 / ON_DRAW hook / 顺序抽。
	# 此前效果定义用自创原子动作 DRAW_ACTION/DRAW_EQUIPMENT 绕过获取牌动作与时点，
	# 现统一走 gain_card 动作（GAIN_CARD_BEFORE/AFTER/SETTLE 时点）。
	# 不走下方 _resolve_card_sources 的随机洗牌——"抽牌"是牌堆顶顺序抽。
	if card_ids.is_empty() and (from_zone == &"action_deck" or from_zone == &"equipment_deck" or from_zone == &"advanced_equipment_deck"):
		var player_id: StringName = action.record.get("player_id", &"")
		if player_id == &"" and not mech_ids.is_empty():
			var _gc_player = context.game_state.get_player_for_mech(mech_ids[0])
			if _gc_player != null:
				player_id = _gc_player.player_id
		if player_id != &"" and context.game_actions != null:
			var _drawn: Array[StringName] = []
			if from_zone == &"action_deck":
				_drawn = context.game_actions.draw_action_cards({"player_id": player_id, "count": count, "reason": reason})
			else:
				_drawn = context.game_actions.draw_equipment_cards({"player_id": player_id, "count": count, "reason": reason, "deck_type": from_zone})
			# 记录实际抽到的牌（含被 effect_02 移走的），供 TurnService/app_root 等调用方读 record 取用
			action.record["drawn_card_ids"] = _drawn
			_is_draw = true
			_draw_player_id = player_id
			# 通用"抽牌即打标签"参数（_tag_on_draw）：抽牌后给抽到的每张牌打指定运行时标签。
			# 烈火 pilot_070 命中抽3打"燃"标签（本回合不占行动牌上限）用；任意效果抽牌可复用，
			# 传 {"tag_name": <标签>, "owner": <owner_pid 可选，空=抽牌玩家>} 即生效。
			var _tag_cfg: Dictionary = action.record.get("_tag_on_draw", {})
			if _tag_cfg is Dictionary and not _tag_cfg.is_empty() and not _drawn.is_empty():
				var _tag_name: StringName = _tag_cfg.get("tag_name", &"")
				var _tag_owner: StringName = _tag_cfg.get("owner", &"")
				if _tag_owner == &"":
					_tag_owner = player_id
				if _tag_name != &"" and _tag_owner != &"":
					for _cid in _drawn:
						var _tc = context.game_state.get_card(_cid)
						if _tc != null and _tc.has_method(&"add_tag"):
							_tc.add_tag(_tag_name, _tag_owner, {})
		if _is_draw:
			_tag_draw(action, _draw_player_id, from_zone, &"")
		return result

	# 处理随机从弃牌堆/牌堆获取的情况
	if card_ids.is_empty():
		card_ids = _resolve_card_sources(action)
		if not card_ids.is_empty():
			# 回忆/补给：无明确 card_ids、系统随机从堆/弃牌堆取 -> 也是"抽取"（统一口径）。
			action.record["drawn_card_ids"] = card_ids
			_tag_draw(action, action.record.get("player_id", &""), from_zone, action.record.get("card_kind", &""))

	# 如果只有1个 mech_id 但有多张牌，将所有牌发给同一个机甲
	var target_mech_id: StringName = &""
	if mech_ids.size() == 1:
		target_mech_id = mech_ids[0]

	for i in range(card_ids.size()):
		var card_id: StringName = card_ids[i]
		var mech_id: StringName = target_mech_id if target_mech_id != &"" else (mech_ids[i] if i < mech_ids.size() else &"")
		if mech_id == &"":
			continue

		var card = context.game_state.get_card(card_id)
		if card == null:
			continue

		var player = context.game_state.get_player_for_mech(mech_id)
		if player == null:
			continue

		# 从原区域移除
		context.game_state.remove_card_from_all_zones(card_id)

		# 加入玩家手牌
		if card.def != null:
			if card.def.card_kind == &"action":
				player.action_hand.append(card_id)
				card.zone = &"action_hand"
				# 注册AVAILABILITY效果到TimingEngine
				if context != null:
					context.register_hand_card_availability(card_id)
			elif card.def.card_kind == &"equipment":
				player.equipment_hand.append(card_id)
				card.zone = &"equipment_hand"

		card.owner_player_id = player.player_id
		card.mech_id = mech_id

	return result


## 统一"抽取"标：mark 本次 gain_card 为抽取（供库马斯 pilot_035 等 GAIN_CARD_AFTER 监听器判定）。
## draw=true 表示"抽取"（card_ids 空、系统自动从堆/弃牌堆取牌）；非抽取（觉醒选牌获取/回收/
## 偷牌/给予转移）无此标。draw_mech_ids 记录抽取方机甲（effect 抽牌带 mech_ids；回合开始等仅带
## player_id 的从 player 反查），供"抽取方==标记机甲"条件匹配。
func _tag_draw(action: Action, player_id: StringName, from_zone: StringName, card_kind: StringName) -> void:
	action.record["draw"] = true
	var _kind: StringName = card_kind
	if _kind == &"":
		_kind = &"action" if (from_zone == &"action_deck" or from_zone == &"action_discard") else &"equipment"
	action.record["draw_card_kind"] = _kind
	var _mech_ids: Array = action.record.get("mech_ids", [])
	if _mech_ids.is_empty() and player_id != &"" and context != null and context.game_state != null:
		var _m = context.game_state.get_mech_for_player(player_id) if context.game_state.has_method("get_mech_for_player") else null
		if _m != null:
			_mech_ids = [_m.mech_id]
	action.record["draw_mech_ids"] = _mech_ids
	action.record["draw_player_id"] = player_id
	# 抽取结果回写 sink：效果动作创建 gain_card 子动作后，可在子动作完成前从自身 record 读抽取结果
	# （子动作完成后 registry 清理无法再读）。塔莉娅 draw_3 等"抽后立即消费"流程用。
	# params 带 _draw_result_sink={"parent_action_id": <父action_id>, "key": <父record键>}。
	if action.record.has("_draw_result_sink"):
		var _sink: Dictionary = action.record["_draw_result_sink"]
		if _sink is Dictionary and context != null and context.action_registry != null:
			# parent_action_id 缺省回退到子动作直接父动作（execute_sub_action 记录 parent_action_id），
			# 法尔科 pilot_073 等「抽牌后立即消费」效果静态定义 sink 无需运行时注入父 id。
			var _sink_pid: StringName = _sink.get("parent_action_id", &"")
			if _sink_pid == &"":
				_sink_pid = action.record.get("parent_action_id", &"")
			var _sink_parent = context.action_registry.get_action(_sink_pid)
			if _sink_parent != null:
				_sink_parent.record[_sink.get("key", &"drawn_card_ids")] = action.record.get("drawn_card_ids", [])


## 解析获取牌的来源（随机从弃牌堆/牌堆获取）
func _resolve_card_sources(action: Action) -> Array:
	var from_zone: StringName = action.record.get("from_zone", &"")
	var count: int = action.record.get("count", 1)
	var random: bool = action.record.get("random", false)
	var card_kind: StringName = action.record.get("card_kind", &"")

	if from_zone == &"" or not random:
		return []

	var pool: Array = []
	if from_zone == &"equipment_discard":
		pool = context.game_state.deck_state.equipment_discard_pile.duplicate()
	elif from_zone == &"action_discard":
		pool = context.game_state.deck_state.action_discard_pile.duplicate()
	elif from_zone == &"action_deck":
		pool = context.game_state.deck_state.action_deck.duplicate()
	elif from_zone == &"equipment_deck":
		pool = context.game_state.deck_state.equipment_deck.duplicate()

	if card_kind != &"":
		pool = pool.filter(func(card_id: StringName) -> bool:
			var card = context.game_state.cards.get(card_id)
			if card == null or card.def == null:
				return false
			return card.def.card_kind == card_kind
		)

	if context != null and context.rng != null:
		context.synced_shuffle(pool)
	else:
		pool.shuffle()
	return pool.slice(0, min(count, pool.size()))


func _step_settle(action: Action) -> Dictionary:
	# 即时使用：抽到的掩护若可即时生效（攻击进行中且满足掩护范围条件）-> 弹「使用/不使用」窗。
	# 仅处理新抽到的行动牌（drawn_card_ids），生成 immediate_use 子动作并挂起本动作。
	var drawn: Array = action.record.get("drawn_card_ids", [])
	if not drawn.is_empty():
		var player_id: StringName = action.record.get("player_id", &"")
		if player_id != &"" and context != null and context.action_service != null and context.action_service.has_method(&"try_cover_immediate_use"):
			if context.action_service.try_cover_immediate_use(action, drawn, player_id, action.action_id):
				return {"effect_action_created": true}
	return {}
