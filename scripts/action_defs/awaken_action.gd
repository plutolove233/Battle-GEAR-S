## awaken_action.gd - 觉醒效果动作（行动牌 action_024_觉醒）
##
## 按规则书第23项觉醒（new_logic/行动牌的效果与逻辑.txt）：
##   使用此牌直接执行。设集合A=空。
##   第1轮（SSR攻击牌）：若行动弃牌堆中存在SSR攻击牌，A += 弃牌堆中随机1张SSR攻击牌；
##     否则UI弹框列出弃牌堆所有【非SSR】行动牌种类及数量（SSR牌不进选框），玩家选1种B，
##     A += 弃牌堆中种类B的1张（进入临时区），之后 A += 行动牌堆顶第一张（进入临时区）。
##   第2轮（SSR迎击牌）：同上，目标改为SSR迎击牌，种类记为C。
##   最后执行获取牌动作：集合A中所有牌 -> 使用此牌的机甲/玩家（机甲1）。
##
## 统称说明：不限定为预判/识破，按 rarity=SSR + action_type(攻击/迎击) 匹配，
## 方便以后版本新增 SSR 攻击/迎击牌时自动适用。当前 SSR攻击牌=预判，SSR迎击牌=识破。
##
## 实现要点：
##   - 每轮 need_input 暂停让玩家选种类；恢复时幂等重跑 handler（chosen_card_def_id 注入 record）。
##   - SSR 牌只走"随机1张"直接获取路径，绝不进选框（修复：弃牌堆2张识破取1张后剩余不再入选框）。
##   - "随机1张"用 context.synced_shuffle（PvP 锁步确定）。
##   - 临时收集的牌从弃牌堆/牌堆移出，zone 标记 awaken_temp，最后由 gain_card 子动作转移入手牌。
##   - 空弃牌堆（该轮目标不在弃牌堆且无非SSR可选种类）：仍抽牌堆顶1张（用户拍板）。
extends Action
class_name AwakenAction

const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const SLog = preload("res://scripts/services/slog.gd")

const SSR_RARITY := "SSR"


func _init() -> void:
	action_type = &"awaken"


func setup_steps() -> void:
	# 觉醒自身的两轮选择不发时点（时点由末尾 gain_card 子动作的 GAIN_CARD_BEFORE/AFTER/SETTLE 发出）
	steps = [
		{step_name = &"predict_round", timing_point = &"", handler = _step_predict_round},
		{step_name = &"expose_round",  timing_point = &"", handler = _step_expose_round},
		{step_name = &"gain_cards",    timing_point = &"", handler = _step_gain_cards},
	]


func get_display_name() -> String:
	return "觉醒"


## 第1轮：SSR攻击牌
func _step_predict_round(action: Action) -> Dictionary:
	return _resolve_round(action, &"攻击", &"predict")


## 第2轮：SSR迎击牌
func _step_expose_round(action: Action) -> Dictionary:
	return _resolve_round(action, &"迎击", &"expose")


## 单轮逻辑（幂等：need_input 恢复时重跑，靠 record 标志/注入区分）
## action_type: 该轮目标类别（"攻击"=SSR攻击牌 / "迎击"=SSR迎击牌）
func _resolve_round(action: Action, action_type: StringName, round_key: StringName) -> Dictionary:
	var done_key: String = "_awaken_%s_done" % String(round_key)
	if bool(action.record.get(done_key, false)):
		return {}

	var player_id: StringName = action.record.get("player_id", &"")

	# ① 弃牌堆有该类SSR牌 -> 取随机1张（不抽牌堆顶）
	var found: Array[StringName] = _find_ssr_cards_in_discard(action_type)
	if not found.is_empty():
		var pool: Array = found.duplicate()
		if context != null and context.rng != null:
			context.synced_shuffle(pool)
		else:
			pool.shuffle()
		_collect_card(action, pool[0])
		# 记录"已直接获取该SSR牌"，供后续弹框提示（缺少另一类时显示"已获得 XXX ×1"）
		_record_direct_obtained(action, pool[0])
		action.record[done_key] = true
		SLog.log_raw("[AWAKEN] %s 第%s轮：弃牌堆有SSR%s牌，取随机1张 %s" % [String(action.action_id), String(round_key), String(action_type), String(pool[0])])
		return {}

	# ② 玩家已选种类（need_input 恢复 / AI 自动注入）-> 取弃牌堆该种类1张 + 牌堆顶1张
	var chosen_def: StringName = action.record.get("chosen_card_def_id", &"")
	if chosen_def != &"":
		var one: StringName = _take_one_of_type_from_discard(chosen_def)
		if one != &"":
			_collect_card(action, one)
		var top: StringName = _take_top_of_action_deck()
		if top != &"":
			_collect_card(action, top)
		action.record.erase("chosen_card_def_id")  # 清除，供下一轮复用此键
		action.record[done_key] = true
		SLog.log_raw("[AWAKEN] %s 第%s轮：玩家选种类 %s，取弃牌堆1张+牌堆顶1张" % [String(action.action_id), String(round_key), String(chosen_def)])
		return {}

	# ② b 取消（UI 无取消按钮，留作测试/扩展）-> 跳过弃牌堆选取，仅抽牌堆顶1张
	if bool(action.record.get("_awaken_skip_to_top", false)):
		action.record.erase("_awaken_skip_to_top")
		var top_s: StringName = _take_top_of_action_deck()
		if top_s != &"":
			_collect_card(action, top_s)
		action.record[done_key] = true
		SLog.log_raw("[AWAKEN] %s 第%s轮：取消选取，仅抽牌堆顶1张" % [String(action.action_id), String(round_key)])
		return {}

	# ③ 弃牌堆无非SSR可选种类（目标不在且无可选）-> 仅抽牌堆顶1张（用户拍板）
	var options: Array[Dictionary] = _build_discard_type_options()
	if options.is_empty():
		var top2: StringName = _take_top_of_action_deck()
		if top2 != &"":
			_collect_card(action, top2)
		action.record[done_key] = true
		SLog.log_raw("[AWAKEN] %s 第%s轮：弃牌堆无非SSR可选种类，仅抽牌堆顶1张" % [String(action.action_id), String(round_key)])
		return {}

	# ④ 需玩家选种类：弹框（人类弹窗 / AI 由 ActionUIBridge 自动选第一项）
	var label_text: String = "觉醒：选择1种行动牌（弃牌堆无SSR%s牌）" % String(action_type)
	# 提示：若另一类SSR牌已直接获取（或仍在弃牌堆将直接获取），显示"已获得 XXX ×1"
	var hint_text: String = _build_obtained_hint(action, action_type)
	return {
		"need_input": true,
		"input_type": &"select_awaken_card_type",
		"input_params": {
			"action_id": action.action_id,
			"mode": &"need_input",
			"executor": player_id,
			"player_id": player_id,
			"mech_id": action.record.get("mech_id", action.record.get("source_mech_id", &"")),
			"round": round_key,
			"options": options,
			"label": label_text,
			"hint": hint_text,
		},
	}


## 末步：执行获取牌动作（集合A -> 使用方手牌），委托 gain_card 子动作发 GAIN_CARD 时点
func _step_gain_cards(action: Action) -> Dictionary:
	var collected: Array = action.record.get("_awaken_collected", [])
	if collected.is_empty():
		SLog.log_raw("[AWAKEN] %s 集合A为空，无牌可获取" % String(action.action_id))
		return {}

	var player_id: StringName = action.record.get("player_id", &"")
	var mech_id: StringName = action.record.get("mech_id", action.record.get("source_mech_id", &""))
	if mech_id == &"" and player_id != &"" and context != null and context.game_state != null:
		var mech = context.game_state.get_mech_for_player(player_id)
		mech_id = mech.mech_id if mech != null else &""

	# 委托 gain_card 子动作转移（remove_card_from_all_zones + 入手牌 + 注册 AVAILABILITY + 发时点）
	var gain_def: Dictionary = {
		"type": &"EXECUTE_GAIN_CARD",
		"params": {
			"card_ids": collected,
			"mech_ids": [mech_id] if mech_id != &"" else [],
			"from_zone": &"awaken_temp",
			"reason": &"AWAKEN_DRAW",
		},
	}
	var payload: Dictionary = {"player_id": player_id, "source_mech_id": mech_id}
	if context != null and context.action_service != null:
		context.action_service.execute_sub_action(gain_def, payload, action)

	SLog.log_raw("[AWAKEN] %s 获取 %d 张牌" % [String(action.action_id), collected.size()])
	var result: Dictionary = {}
	if not action.pending_effect_action_ids.is_empty():
		result["effect_action_created"] = true
	return result


# ── 辅助方法 ──

## 在行动弃牌堆中查找所有 rarity=SSR 且 action_type 匹配的卡实例
func _find_ssr_cards_in_discard(action_type: StringName) -> Array[StringName]:
	var result: Array[StringName] = []
	if context == null or context.game_state == null or context.game_state.deck_state == null:
		return result
	for card_id: StringName in context.game_state.deck_state.action_discard_pile:
		var card = context.game_state.get_card(card_id)
		if card != null and card.def != null \
				and String(card.def.rarity) == SSR_RARITY \
				and String(card.def.action_type) == String(action_type):
			result.append(card_id)
	return result


## 弃牌堆中按种类分组构造弹框选项 [{def_id, label, count}]，排除 SSR 牌（SSR不进选框）
func _build_discard_type_options() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if context == null or context.game_state == null or context.game_state.deck_state == null:
		return result
	var order: Array[StringName] = []  # 保持首次出现顺序
	var counts: Dictionary = {}  # def_id -> count
	var names: Dictionary = {}  # def_id -> display_name
	for card_id: StringName in context.game_state.deck_state.action_discard_pile:
		var card = context.game_state.get_card(card_id)
		if card == null or card.def == null:
			continue
		if String(card.def.rarity) == SSR_RARITY:
			continue  # SSR 牌不进选框
		var did: StringName = card.def.card_id
		if not counts.has(did):
			order.append(did)
			counts[did] = 0
			names[did] = card.def.display_name
		counts[did] = int(counts[did]) + 1
	for did: StringName in order:
		result.append({
			"def_id": did,
			"label": "%s ×%d" % [String(names.get(did, String(did))), int(counts.get(did, 0))],
			"count": int(counts.get(did, 0)),
		})
	return result


## 从弃牌堆取该种类的第一张（同类卡实例等价，取第一张即可），移出弃牌堆
func _take_one_of_type_from_discard(def_id: StringName) -> StringName:
	if context == null or context.game_state == null or context.game_state.deck_state == null:
		return &""
	var discard: Array = context.game_state.deck_state.action_discard_pile
	for i in range(discard.size()):
		var card_id: StringName = discard[i]
		var card = context.game_state.get_card(card_id)
		if card != null and card.def != null and String(card.def.card_id) == String(def_id):
			discard.pop_at(i)
			return card_id
	return &""


## 取行动牌堆顶第一张（空则尝试洗入弃牌堆再取；仍空返回空）
func _take_top_of_action_deck() -> StringName:
	if context == null or context.game_state == null or context.game_state.deck_state == null:
		return &""
	var deck_state = context.game_state.deck_state
	if deck_state.action_deck.is_empty():
		if context.deck_service != null and context.deck_service.has_method(&"_reshuffle_discard_into_deck"):
			context.deck_service._reshuffle_discard_into_deck(&"action_deck")
	if deck_state.action_deck.is_empty():
		return &""
	var card_id: StringName = deck_state.action_deck.pop_front()
	var card = context.game_state.get_card(card_id)
	if card != null:
		card.zone = &"awaken_temp"
	return card_id


## 把1张牌收入集合A（从弃牌堆移出 + 标记临时区 + 追加到 record._awaken_collected）
func _collect_card(action: Action, card_id: StringName) -> void:
	if card_id == &"" or context == null or context.game_state == null:
		return
	# 从弃牌堆移除（牌堆顶的牌已由 _take_top_of_action_deck pop，无需再移）
	if context.game_state.deck_state != null:
		context.game_state.deck_state.action_discard_pile.erase(card_id)
	var card = context.game_state.get_card(card_id)
	if card != null:
		card.zone = &"awaken_temp"
	if not action.record.has("_awaken_collected"):
		action.record["_awaken_collected"] = []
	action.record["_awaken_collected"].append(card_id)


## 记录"已直接获取某SSR牌"（弃牌堆有该类SSR牌时随机取1张的路径）。
## 存 display_name 列表到 record._awaken_direct_obtained，供后续弹框提示。
func _record_direct_obtained(action: Action, card_id: StringName) -> void:
	if not action.record.has("_awaken_direct_obtained"):
		action.record["_awaken_direct_obtained"] = []
	var card = context.game_state.get_card(card_id) if context != null and context.game_state != null else null
	var name: String = card.def.display_name if (card != null and card.def != null) else "?"
	var arr: Array = action.record["_awaken_direct_obtained"]
	if not arr.has(name):
		arr.append(name)


## 构造"已获得 XXX ×1"提示：包含本牌此前已直接获取的SSR牌，以及另一类SSR牌
## 若仍在弃牌堆（将在其轮次直接获取）。仅"缺少之一"场景非空。
func _build_obtained_hint(action: Action, current_action_type: StringName) -> String:
	var names: Array[String] = []
	var obtained: Array = action.record.get("_awaken_direct_obtained", [])
	for n in obtained:
		var ns: String = String(n)
		if not names.has(ns):
			names.append(ns)
	# 另一类SSR牌若仍在弃牌堆（将在其轮次直接获取），把其卡名加入提示
	var other_type: StringName = &"迎击" if String(current_action_type) == "攻击" else &"攻击"
	var other_cards: Array[StringName] = _find_ssr_cards_in_discard(other_type)
	var seen: Dictionary = {}
	for n in names:
		seen[n] = true
	for cid: StringName in other_cards:
		var card = context.game_state.get_card(cid) if context != null and context.game_state != null else null
		if card != null and card.def != null:
			var nm: String = card.def.display_name
			if not seen.has(nm):
				seen[nm] = true
				names.append(nm)
	if names.is_empty():
		return ""
	var joined := ""
	for i in names.size():
		if i > 0:
			joined += "、"
		joined += names[i]
	return "已获得 " + joined + " ×1"
