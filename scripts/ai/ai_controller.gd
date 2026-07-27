## ai_controller.gd - AI 玩家决策大脑
##
## 集中处理 AI 玩家的回合决策（移动/打牌/攻击/结束）与响应窗口决策（逃/反打）。
## battle_state.start_enemy_turn 调 on_turn_start；app_root._on_action_completed 兜底链
## 调 take_next_action 驱动多动作循环；ActionUIBridge._auto_respond 调 decide_response。
##
## 决策风格：贪心启发式，每步选当下最优。每次 take_next_action 至多启动一个动作，
## 动作完成（action_completed 信号）后再由 app_root._check_enemy_turn_complete 回调续跑，
## 直到无可行动作返回 ai_done 由 app_root 调 battle.finish_enemy_turn。
##
## AI/人类弹窗路由：AI 发起/响应的效果走 ActionUIBridge._auto_* 代码决策（不弹人类 UI），
## 人类才弹窗。判据为 PlayerState.is_human（支持多 AI/人类玩家）。
extends RefCounted
class_name AIController

const _TC = preload("res://scripts/action_core/TimingConst.gd")
const _RangeCalculator = preload("res://scripts/battle/RangeCalculator.gd")
const _HexGrid = preload("res://scripts/battle/hex_grid.gd")
const _MapCellState = preload("res://scripts/runtime/MapCellState.gd")
const _GameConfig = preload("res://scripts/config/GameConfig.gd")
const SLog = preload("res://scripts/services/slog.gd")

## 行动牌 ID（与 data/cards/action_cards.json 对应）
const CARD_ATTACK_BASIC = &"action_001_进攻"
const CARD_ASSAULT = &"action_002_强袭"
const CARD_PREDICT = &"action_007_预判"
const CARD_EVADE = &"action_008_回避"
const CARD_DEFEND = &"action_009_防御"
const CARD_COUNTER = &"action_010_反击"
const CARD_DASH = &"action_011_疾行"
const CARD_INSIGHT = &"action_012_识破"
const CARD_REPAIR = &"action_013_维修"
const CARD_CHARGE = &"action_014_聚能"
const CARD_BOOST = &"action_015_推进"
const CARD_RECALL = &"action_020_回忆"
const CARD_RECYCLE = &"action_019_回收"
const CARD_SUPPLY = &"action_022_补给"
const CARD_LOCK = &"action_023_锁定"
const CARD_BASH = &"action_003_猛击"
const CARD_ARMOR_BREAK = &"action_004_破甲"
const CARD_DOUBLE = &"action_005_双连"
const CARD_BLITZ = &"action_006_闪击"

## 每回合最大动作数（防失控循环）
const MAX_ACTIONS_PER_TURN = 20

var context = null

## 本回合已执行动作数
var _actions_this_turn: int = 0
## 本回合装备准备(sell+buy)是否已完成
var _prep_done: bool = false
## 本回合启动失败的行动牌 instance_id（避免反复重试同一张不可打牌）
var _failed_card_ids: Dictionary = {}


## ── 回合入口 ──

## 回合开始：抽牌/金币/动力，然后决策第一个动作。
## 返回动作结果（waiting_*/ai_done/battle_over）供 battle_state.start_enemy_turn 判断。
func on_turn_start(player_id: StringName) -> Dictionary:
	_actions_this_turn = 0
	_failed_card_ids.clear()
	_prep_done = false
	if context == null or context.game_state == null:
		return {"state": "ai_done"}
	context.turn_service.start_turn(player_id)
	return take_next_action(player_id)


## 决策并执行下一个动作；无可用动作则返回 ai_done。
func take_next_action(player_id: StringName) -> Dictionary:
	if context == null or context.game_state == null:
		return {"state": "ai_done"}
	var gs = context.game_state
	# 战斗已结束
	if context.victory_service != null and context.victory_service.check_victory().state != "active":
		return {"state": "battle_over"}
	var mech = gs.get_mech_for_player(player_id)
	if mech == null or mech.destroyed:
		return {"state": "ai_done"}
	var player = gs.players.get(player_id)
	if player == null:
		return {"state": "ai_done"}
	if _actions_this_turn >= MAX_ACTIONS_PER_TURN:
		SLog.log_raw("[AI] 达到单回合动作上限 %d，结束回合" % MAX_ACTIONS_PER_TURN)
		return {"state": "ai_done"}

	# 装备经济准备（同步：先卖出不要的装备换金，再买入空槽对应装备）--每回合仅一次
	if not _prep_done:
		_equipment_prep_sync(player_id, mech, player)
		_prep_done = true

	# 优先级顺序：设置装备 -> 抽牌 -> 锁定 -> 辅助增益 -> 攻击 -> 移动 -> 结束
	var priorities = [
		Callable(self, "_try_set_equipment"),
		Callable(self, "_try_draw"),
		Callable(self, "_try_lock"),
		Callable(self, "_try_support"),
		Callable(self, "_try_attack"),
		Callable(self, "_try_move"),
	]
	for cb: Callable in priorities:
		var res: Variant = cb.call(player_id, mech, player)
		if res == null:
			continue  # 该优先级无可用动作
		if String(res.get("state", &"")) == "error":
			# 动作未启动（创建失败），不计数，继续下一优先级
			continue
		_actions_this_turn += 1
		return res
	return {"state": "ai_done"}


## ── 响应窗口决策（被攻击时：能逃则逃，不能逃才反打）──
## available: timing_engine.get_available_cards 返回的 AVAILABILITY 响应牌数组
## 返回 selected_cards 数组（空=pass）
func decide_response(action_id: StringName, available: Array) -> Array:
	if available.is_empty():
		return []
	if context == null or context.game_state == null:
		return [available[0]]  # 退回最高优先级

	# 沿父链取攻击动作的 attacker_id / target_id / weapon_range
	var attacker_pos: Dictionary = {}
	var target_id: StringName = &""
	var weapon_range: int = 1
	if context.action_registry != null:
		var cur_id: StringName = action_id
		for _i in 4:
			var cur = context.action_registry.get_action(cur_id)
			if cur == null:
				break
			if cur.action_type == &"attack":
				var atk_id: StringName = cur.record.get("attacker_id", &"")
				var atk_mech = context.game_state.mechs.get(atk_id)
				if atk_mech != null:
					attacker_pos = atk_mech.position
				target_id = cur.record.get("target_id", &"")
				weapon_range = int(cur.record.get("weapon_range", 1))
				break
			cur_id = cur.parent_action_id
			if cur_id == &"":
				break

	# 分类可用响应牌
	var insight_card: Dictionary = {}
	var evade_cards: Array = []      # 回避/疾行（纯逃跑）
	var counter_cards: Array = []    # 反击（移动+反打）
	var defend_cards: Array = []     # 防御
	var other_cards: Array = []
	for entry in available:
		var card_id: StringName = entry.get("card_instance_id", &"")
		var card = context.game_state.get_card(card_id) if card_id != &"" else null
		var def_id: StringName = card.def.card_id if card != null and card.def != null else &""
		if def_id == CARD_INSIGHT:
			insight_card = entry
		elif def_id == CARD_EVADE or def_id == CARD_DASH:
			evade_cards.append(entry)
		elif def_id == CARD_COUNTER:
			counter_cards.append(entry)
		else:
			# 装备牌响应等非迎击牌：归 other（按既定优先级兜底）
			other_cards.append(entry)
		# 防御牌单独识别
		if def_id == CARD_DEFEND:
			defend_cards.append(entry)

	# 1. 识破：直接无效攻击+偷牌+移动，最强，优先用
	if not insight_card.is_empty():
		return [insight_card]

	# 2. 能逃则逃：若有回避/疾行且能移出攻击范围 -> 纯逃跑
	var responder_mech = context.game_state.mechs.get(target_id) if target_id != &"" else null
	if responder_mech != null and not evade_cards.is_empty():
		for entry in evade_cards:
			var card_id: StringName = entry.get("card_instance_id", &"")
			var card = context.game_state.get_card(card_id)
			var def_id: StringName = card.def.card_id if card != null and card.def != null else &""
			var budget: int = _evade_budget(responder_mech.power, def_id)
			if _can_escape(responder_mech.position, attacker_pos, weapon_range, budget):
				return [entry]

	# 3. 不能逃才反打：有反击 -> 反击（其移动由 _auto_move_target 尝试逃出范围，再反打）
	if not counter_cards.is_empty():
		return [counter_cards[0]]

	# 4. 防御：攻击有威胁时减伤
	if not defend_cards.is_empty():
		return [defend_cards[0]]

	# 5. 兜底：取最高优先级（含装备牌响应等）
	if not other_cards.is_empty():
		return [other_cards[0]]
	return [available[0]]


# ═══════════════════════════════════════════
# 优先级实现
# ═══════════════════════════════════════════

## 优先级1：抽牌（手牌攻击牌过少时用回忆/回收/补给）
func _try_draw(_player_id: StringName, mech, player) -> Variant:
	var attack_count: int = _count_action_type(player, &"攻击")
	# 攻击牌充足则不抽
	if attack_count >= 2:
		return null
	# 回忆：从行动弃牌堆抽2张（弃牌堆需有牌）
	var deck = context.game_state.deck_state
	if deck != null and not deck.action_discard_pile.is_empty():
		var card_id = _find_card_in_hand(player, CARD_RECALL)
		if card_id != &"":
			return _play_action_card(_player_id, card_id)
	# 补给：抽2行动+1装备（最通用）
	var card_id = _find_card_in_hand(player, CARD_SUPPLY)
	if card_id != &"":
		return _play_action_card(_player_id, card_id)
	# 回收：从装备弃牌堆抽1张
	if deck != null and not deck.equipment_discard_pile.is_empty():
		card_id = _find_card_in_hand(player, CARD_RECYCLE)
		if card_id != &"":
			return _play_action_card(_player_id, card_id)
	return null


## 优先级2：先锁定（有锁定牌且目标未被自己锁定）
func _try_lock(_player_id: StringName, mech, player) -> Variant:
	var target = _get_primary_target(mech)
	if target == null:
		return null
	# 目标已被自己锁定 -> 不重复锁
	if target.is_locked_by(_player_id):
		return null
	var card_id = _find_card_in_hand(player, CARD_LOCK)
	if card_id == &"":
		return null
	return _play_action_card(_player_id, card_id)


## 优先级3：辅助增益（聚能/推进/维修）
func _try_support(_player_id: StringName, mech, player) -> Variant:
	var target = _get_primary_target(mech)
	# 聚能：能攻击且有武器时，提升下次攻击
	if mech.can_attack() and not mech.get_weapon_ids().is_empty():
		var card_id = _find_card_in_hand(player, CARD_CHARGE)
		if card_id != &"":
			# 仅当目标在射程或即将进入射程时才聚能（避免浪费）
			if target != null and _weapon_can_hit(mech, target):
				return _play_action_card(_player_id, card_id)
	# 推进：动力不足但有攻击意图时 +5 动力
	if mech.power < 2:
		var card_id = _find_card_in_hand(player, CARD_BOOST)
		if card_id != &"":
			return _play_action_card(_player_id, card_id)
	# 维修：低血量时回复
	if mech.current_hp < mech.max_hp * 0.4:
		var card_id = _find_card_in_hand(player, CARD_REPAIR)
		if card_id != &"":
			return _play_action_card(_player_id, card_id)
	return null


## 优先级4：攻击（选牌+武器，强袭用于目标可能逃跑时）
func _try_attack(player_id: StringName, mech, player) -> Variant:
	if not mech.can_attack():
		return null
	var target = _get_primary_target(mech)
	if target == null:
		return null
	# 选一把能命中目标的武器
	var weapon_id = _pick_weapon_in_range(mech, target)
	if weapon_id == &"":
		return null  # 不在射程 -> 走移动优先级

	# 选攻击牌：强袭追击优先（目标可能逃），否则按价值排序选最强
	var attack_card = _pick_attack_card(player, mech, target)
	if attack_card == &"":
		return null

	var params: Dictionary = {
		"weapon_id": weapon_id,
		"target_id": target.mech_id,
		"mech_id": mech.mech_id,
	}
	return _play_action_card(player_id, attack_card, params)


## 选攻击牌：目标可能逃->优先强袭；否则按价值评分挑最强攻击牌
func _pick_attack_card(player, mech, target) -> StringName:
	if _target_might_flee(target):
		var assault = _find_card_in_hand(player, CARD_ASSAULT)
		if assault != &"":
			return assault
	var best_id: StringName = &""
	var best_score: int = -1
	for cid: StringName in player.action_hand:
		var card = context.game_state.get_card(cid)
		if card == null or card.def == null or card.def.action_type != &"攻击":
			continue
		var score: int = _score_attack_card(card.def.card_id, player, mech, target)
		if score > best_score:
			best_score = score
			best_id = cid
	return best_id


## 攻击牌价值评分（越大越优先）。
## 预判(锁定+弃牌+不可无效)>猛击(+4威力)>破甲(命中+2损伤)>闪击(重复,需弃牌)>
## 双连(多目标)>强袭(追击,兜底)>进攻(基础)。条件不满足则降级。
func _score_attack_card(card_id: StringName, player, mech, target) -> int:
	match card_id:
		CARD_PREDICT:
			return 100
		CARD_BASH:
			return 80
		CARD_ARMOR_BREAK:
			return 70
		CARD_BLITZ:
			# 闪击重复攻击需弃1张行动牌：手牌充足才划算
			return 60 if player.action_hand.size() >= 3 else 20
		CARD_DOUBLE:
			# 双连1~2目标：射程内>=2敌方才发挥，否则仅基础
			return 50 if _count_enemy_targets_in_range(mech) >= 2 else 15
		CARD_ASSAULT:
			return 40
		CARD_ATTACK_BASIC:
			return 10
		_:
			return 10  # 未知攻击牌按基础


## 统计当前机甲任一武器射程内的敌方机甲数（用于双连价值判断）
func _count_enemy_targets_in_range(mech) -> int:
	if context == null or context.game_state == null:
		return 0
	var map_cells: Dictionary = context.game_state.map_state.cells if context.game_state.map_state else {}
	var count: int = 0
	for mid: StringName in context.game_state.mechs:
		var m = context.game_state.mechs[mid]
		if m == null or m.destroyed:
			continue
		if m.owner_player_id == mech.owner_player_id:
			continue
		for wid: StringName in mech.get_weapon_ids():
			var wcard = context.game_state.get_card(wid)
			var wrange: int = 1
			if wcard != null and wcard.def != null:
				wrange = wcard.def.range_value
			if _RangeCalculator.is_in_weapon_range(mech.position, m.position, wrange, map_cells):
				count += 1
				break
	return count


## 优先级5：移动（朝目标多步靠近；手有迎击牌则留动力回避）
func _try_move(player_id: StringName, mech, player) -> Variant:
	if not mech.can_move():
		return null
	var target = _get_primary_target(mech)
	if target == null:
		return null
	# 留动力回避：手有迎击牌时保留 floor(max_power/2) 保证回避可用
	var reserve = _evade_reserve(mech, player)
	var usable_power = mech.power - reserve
	if usable_power <= 0:
		return null
	var step = _find_first_step_toward(mech.position, target.position, usable_power)
	if step.is_empty():
		return null
	if _HexGrid.distance(mech.position, step) == 0:
		return null  # 已到达/无路
	return _execute_move(player_id, step)


# ═══════════════════════════════════════════
# 装备经济（Phase 2：设置装备/卖出/商店购买）
# ═══════════════════════════════════════════

## 装备准备（同步）：先卖出不要的装备换金，再买入空槽对应装备。不返回动作。
func _equipment_prep_sync(player_id: StringName, mech, player) -> void:
	_sell_unwanted(player_id, mech, player)
	_buy_for_empty_slots(player_id, mech, player)


## 优先级0：设置装备（数值优先）。挑手牌中能改善机甲的最佳装备设置到槽位。
func _try_set_equipment(player_id: StringName, mech, player) -> Variant:
	var cand: Dictionary = _find_set_candidate(mech, player)
	if cand.is_empty():
		return null
	var card_id: StringName = cand.get("card_id", &"")
	var slot_id: StringName = cand.get("slot_id", &"")
	var params: Dictionary = {
		"card_id": card_id,
		"mech_id": mech.mech_id,
		"slot_id": slot_id,
		"player_id": player_id,
		"source": {"player_id": player_id, "mech_id": mech.mech_id, "card_instance_id": card_id},
	}
	var result: Dictionary = context.action_service.execute(&"set_equipment", params)
	if String(result.get("state", &"")) == "error":
		_failed_card_ids[card_id] = true
	return result


## 找手牌中最佳设置候选：空槽优先(+10000)，其次价值高；占用槽仅当新牌价值更高才替换
func _find_set_candidate(mech, player) -> Dictionary:
	var best: Dictionary = {}
	var best_score: int = -1
	for cid: StringName in player.equipment_hand:
		if _failed_card_ids.has(cid):
			continue
		var card = context.game_state.get_card(cid)
		if card == null or card.def == null:
			continue
		var def = card.def
		if def.card_kind != &"equipment":
			continue
		var slot_id: StringName = _pick_equipment_slot(mech, def)
		if slot_id == &"":
			continue
		var slot = mech.slots[slot_id]
		var new_val: int = _equipment_value(def)
		var is_empty: bool = (slot.equipped_card == null)
		if not is_empty:
			var cur_val: int = _equipment_value(slot.equipped_card.def)
			if new_val <= cur_val:
				continue  # 不比当前好，不替换
		var score: int = new_val + (10000 if is_empty else 0)
		if score > best_score:
			best_score = score
			best = {"card_id": cid, "slot_id": slot_id}
	return best


## 为装备牌选最佳槽位：PART->其 def.slot；WEAPON->空武器槽，无空槽则较弱武器槽(供替换判断)
func _pick_equipment_slot(mech, def) -> StringName:
	if def.equipment_kind == &"PART":
		var sid: StringName = def.slot
		if sid != &"" and mech.slots.has(sid):
			return sid
		return &""
	elif def.equipment_kind == &"WEAPON":
		for ws_id: StringName in [&"weapon_1", &"weapon_2"]:
			if mech.slots.has(ws_id) and mech.slots[ws_id].equipped_card == null:
				return ws_id
		# 无空槽：返回较弱武器的槽位
		var weaker: StringName = &""
		var weaker_val: int = 999999
		for ws_id2: StringName in [&"weapon_1", &"weapon_2"]:
			if not mech.slots.has(ws_id2):
				continue
			var slot = mech.slots[ws_id2]
			if slot.equipped_card == null:
				continue
			var v: int = _equipment_value(slot.equipped_card.def)
			if v < weaker_val:
				weaker_val = v
				weaker = ws_id2
		return weaker
	return &""


## 装备价值评分：PART=护甲+动力+耐久；WEAPON=威力*2+射程；加稀有度加成
func _equipment_value(def) -> int:
	if def == null:
		return 0
	var val: int = 0
	if def.equipment_kind == &"PART":
		val = int(def.armor) + int(def.power) + int(def.durability)
	elif def.equipment_kind == &"WEAPON":
		val = int(def.might) * 2 + int(def.range_value)
	val += _rarity_bonus(def.rarity)
	return val


func _rarity_bonus(rarity) -> int:
	match String(rarity):
		"N": return 0
		"R": return 2
		"SR": return 5
		"SSR": return 10
		_: return 0


## 装备是否能改善机甲（有空槽或比当前好）--不能则视为不要的装备
func _is_useful_equipment(mech, def) -> bool:
	var slot_id: StringName = _pick_equipment_slot(mech, def)
	if slot_id == &"":
		return false
	var slot = mech.slots[slot_id]
	if slot.equipped_card == null:
		return true
	return _equipment_value(def) > _equipment_value(slot.equipped_card.def)


## 卖出不要的装备（最多 SELL_LIMIT/turn，价值最低先卖）
func _sell_unwanted(player_id: StringName, mech, player) -> void:
	var limit: int = _GameConfig.SELL_EQUIPMENT_LIMIT_PER_TURN - player.sell_equipment_count_this_turn
	if limit <= 0:
		return
	var unwanted: Array = []
	for cid: StringName in player.equipment_hand:
		var card = context.game_state.get_card(cid)
		if card == null or card.def == null:
			continue
		if card.def.card_kind != &"equipment":
			continue
		if _is_useful_equipment(mech, card.def):
			continue
		unwanted.append({"card_id": cid, "value": _equipment_value(card.def)})
	if unwanted.is_empty():
		return
	unwanted.sort_custom(_cmp_value_asc)
	var sold: int = 0
	for u in unwanted:
		if sold >= limit:
			break
		var res: Dictionary = context.card_set_service.sell_equipment(player_id, u.card_id)
		if res.get("ok", false):
			sold += 1


func _cmp_value_asc(a, b) -> bool:
	return int(a.value) < int(b.value)


## 取机甲空的部件/武器槽位列表
func _get_empty_equipment_slots(mech) -> Array:
	var empty: Array = []
	for slot_id: StringName in mech.slots:
		var slot = mech.slots[slot_id]
		if slot == null or slot.equipped_card != null:
			continue
		if slot.slot_kind == &"PART" or slot.slot_kind == &"WEAPON":
			empty.append({"slot_id": slot_id, "kind": String(slot.slot_kind)})
	return empty


## 装备牌是否匹配任一空槽（PART 需 def.slot 对应空部件槽；WEAPON 需任一空武器槽）
func _matches_empty_slot(def, empty_slots: Array) -> bool:
	if def.equipment_kind == &"PART":
		var sid: String = String(def.slot)
		for e in empty_slots:
			if e.kind == "PART" and String(e.slot_id) == sid:
				return true
		return false
	elif def.equipment_kind == &"WEAPON":
		for e in empty_slots:
			if e.kind == "WEAPON":
				return true
		return false
	return false


## 买入空槽对应装备（循环买入，直到无空槽/无匹配/金币不足）
func _buy_for_empty_slots(player_id: StringName, mech, player) -> void:
	var guard: int = 0
	while guard < 10:
		guard += 1
		var empty_slots: Array = _get_empty_equipment_slots(mech)
		if empty_slots.is_empty():
			return
		var cand: Dictionary = _find_buy_candidate(player, empty_slots)
		if cand.is_empty():
			return
		var res: Dictionary
		if String(cand.get("kind", "")) == "normal":
			res = context.shop_service.buy_normal_equipment(player_id, int(cand.get("slot_index", 0)), false)
		else:
			res = context.shop_service.buy_advanced_equipment(player_id, false)
		if not res.get("ok", false):
			return


## 扫商店找匹配空槽且买得起的最佳装备（价值最高）
func _find_buy_candidate(player, empty_slots: Array) -> Dictionary:
	if empty_slots.is_empty():
		return {}
	var shop = context.game_state.shop_state
	if shop == null:
		return {}
	var best: Dictionary = {}
	var best_val: int = -1
	for i: int in range(shop.normal_slots.size()):
		var cid: StringName = shop.normal_slots[i]
		if cid == &"":
			continue
		var card = context.game_state.get_card(cid)
		if card == null or card.def == null:
			continue
		if not _matches_empty_slot(card.def, empty_slots):
			continue
		var price: int = context.shop_service._get_buy_price(card)
		if player.gold < price:
			continue
		var val: int = _equipment_value(card.def)
		if val > best_val:
			best_val = val
			best = {"kind": "normal", "slot_index": i}
	if shop.advanced_slot != &"":
		var acard = context.game_state.get_card(shop.advanced_slot)
		if acard != null and acard.def != null and _matches_empty_slot(acard.def, empty_slots):
			var price: int = context.shop_service._get_buy_price(acard)
			if player.gold >= price:
				var val: int = _equipment_value(acard.def)
				if val > best_val:
					best = {"kind": "advanced"}
	return best


# ═══════════════════════════════════════════
# 决策辅助
# ═══════════════════════════════════════════

## 取主目标机甲（1v1 即玩家机甲；多玩家取最近敌方）
func _get_primary_target(mech) -> Variant:
	if context == null or context.game_state == null:
		return null
	var best = null
	var best_dist: int = -1
	for mid: StringName in context.game_state.mechs:
		var m = context.game_state.mechs[mid]
		if m == null or m.destroyed:
			continue
		if m.owner_player_id == mech.owner_player_id:
			continue
		var d: int = _HexGrid.distance(mech.position, m.position)
		if best == null or d < best_dist:
			best = m
			best_dist = d
	return best


## 统计手牌中某 action_type 的数量
func _count_action_type(player, action_type: StringName) -> int:
	var n: int = 0
	for cid: StringName in player.action_hand:
		var card = context.game_state.get_card(cid)
		if card != null and card.def != null and card.def.action_type == action_type:
			n += 1
	return n


## 在手牌中找指定 card_id 的行动牌 instance_id
func _find_card_in_hand(player, card_id: StringName) -> StringName:
	for cid: StringName in player.action_hand:
		var card = context.game_state.get_card(cid)
		if card != null and card.def != null and card.def.card_id == card_id:
			return cid
	return &""


## 找手牌中第一张攻击牌
func _find_first_attack_card(player) -> StringName:
	for cid: StringName in player.action_hand:
		var card = context.game_state.get_card(cid)
		if card != null and card.def != null and card.def.action_type == &"攻击":
			return cid
	return &""


## 选一把能命中目标的武器（射程内）；优先伤害高的
func _pick_weapon_in_range(mech, target) -> StringName:
	var map_cells: Dictionary = context.game_state.map_state.cells if context.game_state.map_state else {}
	var best_id: StringName = &""
	var best_might: int = -1
	for wid: StringName in mech.get_weapon_ids():
		var wcard = context.game_state.get_card(wid)
		var wrange: int = 1
		var wmight: int = 0
		if wcard != null and wcard.def != null:
			wrange = wcard.def.range_value
			wmight = wcard.def.might
		if _RangeCalculator.is_in_weapon_range(mech.position, target.position, wrange, map_cells):
			if wmight > best_might:
				best_might = wmight
				best_id = wid
	return best_id


## 是否任一武器能命中目标
func _weapon_can_hit(mech, target) -> bool:
	return _pick_weapon_in_range(mech, target) != &""


## 目标是否可能逃跑（手有迎击牌）
func _target_might_flee(target) -> bool:
	var player = context.game_state.players.get(target.owner_player_id)
	if player == null:
		return false
	for cid: StringName in player.action_hand:
		var card = context.game_state.get_card(cid)
		if card != null and card.def != null and card.def.action_type == &"迎击":
			return true
	return false


## 迎击移动预算：回避/反击=Floor(power/2)，疾行/识破=power
func _evade_budget(power: int, card_id: StringName) -> int:
	if card_id == CARD_DASH or card_id == CARD_INSIGHT:
		return power
	return int(power / 2)


## 留动力回避量：手有回避/反击/防御->Floor(max_power/2)；仅疾行->0（疾行用全力，无法留）
func _evade_reserve(mech, player) -> int:
	var has_half: bool = false
	var has_dash_only: bool = false
	var has_any: bool = false
	for cid: StringName in player.action_hand:
		var card = context.game_state.get_card(cid)
		if card == null or card.def == null:
			continue
		if card.def.action_type != &"迎击":
			continue
		has_any = true
		if card.def.card_id == CARD_EVADE or card.def.card_id == CARD_COUNTER or card.def.card_id == CARD_DEFEND:
			has_half = true
		elif card.def.card_id == CARD_DASH:
			has_dash_only = true
	if has_half:
		return int(mech.max_power / 2)
	if has_dash_only and not has_half:
		return 0  # 疾行用全力，无法保留
	if has_any:
		return 1
	return 0


## 是否存在可移出攻击范围的可达格（在 budget 内）
func _can_escape(from_pos: Dictionary, attacker_pos: Dictionary, weapon_range: int, budget: int) -> bool:
	if attacker_pos.is_empty() or budget <= 0:
		return false
	var map_cells: Dictionary = context.game_state.map_state.cells if context.game_state.map_state else {}
	var reachable: Array[Dictionary] = _RangeCalculator.get_move_reachable_hexes(from_pos, budget, map_cells)
	for hex in reachable:
		if not _RangeCalculator.is_in_weapon_range(attacker_pos, hex, weapon_range, map_cells):
			return true
	return false


## BFS 寻路：从 origin 向 target 的第一步（预算 available_power）
func _find_first_step_toward(origin: Dictionary, target: Dictionary, available_power: int) -> Dictionary:
	if available_power <= 0:
		return {}
	var origin_key: String = _HexGrid.key(origin)
	var target_key: String = _HexGrid.key(target)
	if origin_key == target_key:
		return {}
	var map_cells: Dictionary = context.game_state.map_state.cells if context.game_state.map_state else {}
	var traversable: Dictionary = {}
	for cell_key: String in map_cells:
		var cell = map_cells[cell_key]
		traversable[cell_key] = cell
	if not traversable.has(origin_key) or not traversable.has(target_key):
		return {}
	var frontier: Array[Dictionary] = [origin.duplicate()]
	var came_from: Dictionary = {origin_key: ""}
	var index: int = 0
	while index < frontier.size():
		var current: Dictionary = frontier[index]
		index += 1
		var current_key: String = _HexGrid.key(current)
		if current_key == target_key:
			break
		for neighbor: Dictionary in _HexGrid.neighbors(current):
			var neighbor_key: String = _HexGrid.key(neighbor)
			if not traversable.has(neighbor_key) or came_from.has(neighbor_key):
				continue
			var cell = traversable[neighbor_key]
			# RED 不可通行（cell 可能是 MapCellState 对象或字典）
			var terrain: String = String(cell.terrain) if cell is _MapCellState else String(cell.get("terrain", &"NORMAL"))
			if terrain == "RED":
				continue
			came_from[neighbor_key] = current_key
			frontier.append(neighbor.duplicate())
	if not came_from.has(target_key):
		return {}
	var step_key: String = target_key
	var previous_key: String = String(came_from[step_key])
	while previous_key != origin_key:
		step_key = previous_key
		previous_key = String(came_from[step_key])
	var step_cell = traversable.get(step_key, {})
	if step_cell is _MapCellState:
		return {"q": step_cell.q, "r": step_cell.r}
	return step_cell.duplicate() if step_cell is Dictionary else {}


# ═══════════════════════════════════════════
# 动作执行
# ═══════════════════════════════════════════

## 打出行动牌（use_action_card 动作）
func _play_action_card(player_id: StringName, card_id: StringName, payload: Dictionary = {}) -> Dictionary:
	if _failed_card_ids.has(card_id):
		return {"state": "error", "message": "card previously failed this turn"}
	var params: Dictionary = {
		"player_id": player_id,
		"card_instance_id": card_id,
	}
	params.merge(payload, true)
	var result: Dictionary = context.action_service.execute(&"use_action_card", params)
	if String(result.get("state", &"")) == "error":
		_failed_card_ids[card_id] = true
		SLog.log_raw("[AI] 打牌失败 card=%s msg=%s" % [String(card_id), String(result.get("message", ""))])
	return result


## 执行移动（single_move 动作）
func _execute_move(player_id: StringName, target_cell: Dictionary) -> Dictionary:
	var mech = context.game_state.get_mech_for_player(player_id)
	var cell_id: String = "%d,%d" % [int(target_cell.get("q", 0)), int(target_cell.get("r", 0))]
	return context.action_service.execute(&"single_move", {
		"mech_id": mech.mech_id,
		"target_cell": cell_id,
		"available_power": mech.power,
		"player_id": player_id,
	})
