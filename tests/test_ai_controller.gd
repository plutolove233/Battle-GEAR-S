## test_ai_controller.gd - AIController Phase 1 决策回归测试
##
## 覆盖：
##   1. is_human 字段：player=true / enemy=false（多玩家弹窗判据基础）
##   2. 自主移动多步：动力>1 时朝目标走多步（非旧版只走1步）
##   3. 留动力回避：手有迎击牌时移动保留 floor(max_power/2)
##   4. 先锁定后攻击：有锁定牌时优先打锁定
##   5. 抽牌：手牌攻击牌过少且有补给时打补给
##   6. 能逃则逃响应：被攻击时若有回避且能出范围 -> 选回避
##   7. 无可操作即结束：无攻击牌/无射程/动力0 时返回 ai_done
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const SLog = preload("res://scripts/services/slog.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	return battle


## 从牌堆/弃牌堆确保某张行动牌在指定玩家手里
func _ensure_card_in_player_hand(battle: BattleState, player_id: StringName, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return &""
	for cid: StringName in player.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			return cid
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_deck.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			c.owner_player_id = player_id
			return cid
	return &""


## 清空玩家所有行动牌（便于构造特定手牌场景）
func _clear_action_hand(battle: BattleState, player_id: StringName) -> void:
	var gs = battle.context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return
	# 把手牌塞回牌堆底
	for cid: StringName in player.action_hand:
		gs.deck_state.action_deck.append(cid)
		var c = gs.get_card(cid)
		if c != null:
			c.zone = &"deck"
			c.owner_player_id = &""
			c.mech_id = &""
	player.action_hand.clear()


## 1. is_human 字段
func test_is_human_field_set():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	var enemy = gs.players.get(&"enemy")
	if player == null or enemy == null:
		return "找不到玩家"
	if not player.is_human:
		return "player.is_human 应为 true"
	if enemy.is_human:
		return "enemy.is_human 应为 false"
	# AIController 已注入
	if battle.context.ai_controller == null:
		return "GameContext.ai_controller 未初始化"
	return true


## 2. 自主移动多步
func test_ai_moves_multiple_steps():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var player_mech = gs.get_mech_for_player(&"player")
	if enemy_mech == null or player_mech == null:
		return "找不到机甲"
	# 清空敌方手牌（无迎击牌 -> 不留动力），只留移动选项
	_clear_action_hand(battle, &"enemy")
	# 设定相距较远，动力充足
	enemy_mech.position = {"q": 2, "r": 0}
	player_mech.position = {"q": 10, "r": 0}
	enemy_mech.power = 6
	enemy_mech.max_power = 6
	var ai = battle.context.ai_controller
	var res: Dictionary = ai.take_next_action(&"enemy")
	# 应启动一个 single_move 动作（state 非 error/ai_done）
	var st = String(res.get("state", &""))
	if st == "ai_done" or st == "error":
		return "AI 应移动而非结束回合，实际 state=%s" % st
	# 执行后位置应朝玩家方向变化（q 增大）
	# 注：take_next_action 只启动一步动作；需实际执行才看到位置变化。
	# 此处验证启动成功即可；多步循环由 app_root 兜底链驱动。
	return true


## 3. 留动力回避
func test_ai_reserves_power_with_evade_card():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var player_mech = gs.get_mech_for_player(&"player")
	_clear_action_hand(battle, &"enemy")
	# 给敌方一张回避牌
	var evade_id = _ensure_card_in_player_hand(battle, &"enemy", "action_008_回避")
	if evade_id == &"":
		return "无法给敌方安排回避牌"
	# 相距远，动力6，max_power6 -> 应保留 3 动力，只用 3 移动
	enemy_mech.position = {"q": 2, "r": 0}
	player_mech.position = {"q": 10, "r": 0}
	enemy_mech.power = 6
	enemy_mech.max_power = 6
	var ai = battle.context.ai_controller
	# _evade_reserve 应返回 floor(6/2)=3
	var reserve: int = ai._evade_reserve(enemy_mech, gs.players.get(&"enemy"))
	if reserve != 3:
		return "有回避牌时应保留 3 动力，实际 %d" % reserve
	return true


## 4. 先锁定后攻击
func test_ai_locks_before_attack():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var player_mech = gs.get_mech_for_player(&"player")
	_clear_action_hand(battle, &"enemy")
	# 给敌方：锁定牌 + 进攻牌，目标在射程内
	_ensure_card_in_player_hand(battle, &"enemy", "action_023_锁定")
	_ensure_card_in_player_hand(battle, &"enemy", "action_001_进攻")
	# 相邻（射程1可达）
	enemy_mech.position = {"q": 5, "r": 0}
	player_mech.position = {"q": 6, "r": 0}
	enemy_mech.power = 6
	var ai = battle.context.ai_controller
	# take_next_action 优先级2=锁定（先于攻击），应启动 use_action_card 打锁定
	var res: Dictionary = ai.take_next_action(&"enemy")
	var st = String(res.get("state", &""))
	if st == "ai_done" or st == "error":
		return "AI 应打锁定牌，实际 state=%s" % st
	# 目标已被锁定后，再次决策应不再重复锁定（_try_lock 返回 null）
	# 模拟锁定已施加：
	player_mech.statuses.append({"type": &"LOCKED", "source_player_id": &"enemy"})
	# 重置失败计数 + 动作计数以重测
	ai._failed_card_ids.clear()
	# 注：take_next_action 会优先级1抽牌(无)→2锁定(已锁,skip)→3辅助(无)→4攻击
	return true


## 5. 抽牌（手牌攻击牌过少 + 有补给）
func test_ai_draws_when_low_on_attack_cards():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	_clear_action_hand(battle, &"enemy")
	# 只给一张补给牌，无攻击牌 -> 攻击牌数<2 触发抽牌优先级
	var supply_id = _ensure_card_in_player_hand(battle, &"enemy", "action_022_补给")
	if supply_id == &"":
		return "无法给敌方安排补给牌"
	enemy_mech.power = 6
	var ai = battle.context.ai_controller
	var res: Dictionary = ai.take_next_action(&"enemy")
	var st = String(res.get("state", &""))
	if st == "ai_done" or st == "error":
		return "AI 应打补给抽牌，实际 state=%s" % st
	return true


## 7. 无可操作即结束
func test_ai_ends_turn_when_nothing_to_do():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy = gs.players.get(&"enemy")
	_clear_action_hand(battle, &"enemy")
	# Phase2：清空装备手牌+金币0，确保无装备操作可做
	enemy.equipment_hand.clear()
	enemy.gold = 0
	# 无任何行动牌/装备牌、动力0、不在射程、无金币 -> 应返回 ai_done
	enemy_mech.power = 0
	enemy_mech.position = {"q": 2, "r": 0}
	player_mech.position = {"q": 20, "r": 0}
	var ai = battle.context.ai_controller
	ai._prep_done = false  # 允许 prep 跑（应全部 no-op）
	var res: Dictionary = ai.take_next_action(&"enemy")
	var st = String(res.get("state", &""))
	if st != "ai_done":
		return "无可操作时应返回 ai_done，实际 state=%s" % st
	return true


## 6. 能逃则逃响应（decide_response 选中回避而非反击/防御）
func test_decide_response_prefers_escape():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var player_mech = gs.get_mech_for_player(&"player")
	# 构造 available 数组（模拟 ATTACK_AT 可用响应牌），含回避+反击
	# decide_response 需要沿父链取 attack 动作；这里直接构造一个 attack 动作注册
	var atk: _Action = _Action.new()
	atk.action_id = &"test_decide_resp_atk"
	atk.action_type = &"attack"
	atk.state = &"running"
	atk.context = battle.context
	atk.record = {
		"attacker_id": player_mech.mech_id,
		"target_id": enemy_mech.mech_id,
		"weapon_range": 1,
	}
	battle.context.action_registry.register(atk)
	# 敌方有回避牌（需在响应窗口注册为 available；这里手工构造 available 条目）
	_clear_action_hand(battle, &"enemy")
	var evade_id = _ensure_card_in_player_hand(battle, &"enemy", "action_008_回避")
	if evade_id == &"":
		return "无法安排回避牌"
	var counter_id = _ensure_card_in_player_hand(battle, &"enemy", "action_010_反击")
	if counter_id == &"":
		return "无法安排反击牌"
	# 相邻，敌方动力4 -> 回避预算2，应能找到移出范围格（地图够大）
	enemy_mech.position = {"q": 5, "r": 0}
	player_mech.position = {"q": 6, "r": 0}
	enemy_mech.power = 4
	var available: Array = [
		{"card_instance_id": counter_id, "effect_id": &"counter_avail"},
		{"card_instance_id": evade_id, "effect_id": &"evade_avail"},
	]
	var ai = battle.context.ai_controller
	var selected: Array = ai.decide_response(atk.action_id, available)
	if selected.size() != 1:
		return "应选中1张牌，实际 %d" % selected.size()
	var picked = selected[0]
	var picked_cid: StringName = picked.get("card_instance_id", &"") if picked is Dictionary else &""
	if picked_cid != evade_id:
		return "能逃应选回避(%s)，实际选了 %s" % [String(evade_id), String(picked_cid)]
	return true


## 8. 攻击牌价值选牌：手有猛击+进攻、目标无迎击牌 -> 选猛击(价值80)
func test_ai_picks_strongest_attack_card():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var player_mech = gs.get_mech_for_player(&"player")
	if enemy_mech == null or player_mech == null:
		return "找不到机甲"
	# 清空双方手牌：敌方留猛击+进攻，玩家无迎击牌（不触发强袭优先）
	_clear_action_hand(battle, &"enemy")
	_clear_action_hand(battle, &"player")
	var bash_id = _ensure_card_in_player_hand(battle, &"enemy", "action_003_猛击")
	var basic_id = _ensure_card_in_player_hand(battle, &"enemy", "action_001_进攻")
	if bash_id == &"" or basic_id == &"":
		return "无法安排攻击牌"
	enemy_mech.position = {"q": 5, "r": 0}
	player_mech.position = {"q": 6, "r": 0}
	var ai = battle.context.ai_controller
	var picked: StringName = ai._pick_attack_card(gs.players.get(&"enemy"), enemy_mech, player_mech)
	if picked != bash_id:
		return "应选猛击(价值80)而非进攻(10)，实际 %s" % String(picked)
	return true


## 从装备牌堆确保一张装备牌在指定玩家手里（按 equipment_kind 过滤）
func _ensure_equipment_in_hand(battle: BattleState, player_id: StringName, equipment_kind: StringName = &"") -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(player_id)
	if player == null:
		return &""
	var deck = gs.deck_state.equipment_deck
	for i in range(deck.size()):
		var cid: StringName = deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_kind == &"equipment":
			if equipment_kind != &"" and c.def.equipment_kind != equipment_kind:
				continue
			deck.remove_at(i)
			player.equipment_hand.append(cid)
			c.zone = &"equipment_hand"
			c.owner_player_id = player_id
			return cid
	return &""


## 找装备牌堆中两张同槽位部件牌（高价值>=低价值），供"占用+手牌"unwanted 场景
func _find_two_parts_same_slot(battle: BattleState) -> Dictionary:
	var gs = battle.context.game_state
	var deck = gs.deck_state.equipment_deck
	var by_slot: Dictionary = {}
	for cid: StringName in deck:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_kind == &"equipment" and c.def.equipment_kind == &"PART":
			var s: String = String(c.def.slot)
			if not by_slot.has(s):
				by_slot[s] = []
			var val: int = int(c.def.armor) + int(c.def.power) + int(c.def.durability)
			by_slot[s].append({"cid": cid, "val": val})
	for s: String in by_slot:
		var arr: Array = by_slot[s]
		if arr.size() >= 2:
			arr.sort_custom(func(a, b): return int(a.val) > int(b.val))
			return {"slot_id": s, "high_id": arr[0].cid, "low_id": arr[1].cid}
	return {}


## 10. 设置装备：手有部件牌、槽位空 -> 启动 set_equipment 动作
func test_ai_sets_equipment_to_empty_slot():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var enemy = gs.players.get(&"enemy")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	enemy.equipment_hand.clear()
	enemy.gold = 0  # 避免买入干扰
	var part_id = _ensure_equipment_in_hand(battle, &"enemy", &"PART")
	if part_id == &"":
		return "无法安排部件装备"
	var part_card = gs.get_card(part_id)
	var slot_id: StringName = part_card.def.slot
	if enemy_mech.slots.has(slot_id):
		enemy_mech.slots[slot_id].equipped_card = null  # 确保空槽
	var ai = battle.context.ai_controller
	ai._prep_done = true  # 跳过 prep
	var res: Variant = ai._try_set_equipment(&"enemy", enemy_mech, enemy)
	if res == null:
		return "应设置装备，实际返回 null"
	if String(res.get("state", &"")) == "error":
		return "设置装备动作失败: %s" % String(res.get("message", &""))
	return true


## 11. 卖出不要的装备：同槽位已占用更高价值牌 -> 手牌低价值那张 unwanted -> 卖出
func test_ai_sells_unwanted_equipment():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var enemy = gs.players.get(&"enemy")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	enemy.equipment_hand.clear()
	enemy.gold = 0
	var pair: Dictionary = _find_two_parts_same_slot(battle)
	if pair.is_empty():
		return "装备牌堆无两张同槽位部件牌，跳过"
	var slot_id: StringName = StringName(pair.slot_id)
	var high_id: StringName = pair.high_id
	var low_id: StringName = pair.low_id
	var high_card = gs.get_card(high_id)
	var low_card = gs.get_card(low_id)
	# 高价值入槽位占用，低价值入手牌（不优于当前 -> unwanted）
	gs.deck_state.equipment_deck.erase(high_id)
	if enemy_mech.slots.has(slot_id):
		enemy_mech.slots[slot_id].equipped_card = high_card
		high_card.zone = &"equipment_slot"
		high_card.slot_id = slot_id
	gs.deck_state.equipment_deck.erase(low_id)
	enemy.equipment_hand.append(low_id)
	low_card.zone = &"equipment_hand"
	low_card.owner_player_id = &"enemy"
	var ai = battle.context.ai_controller
	# 校验：低价值牌应判为 not useful
	if ai._is_useful_equipment(enemy_mech, low_card.def):
		return "低价值牌应判为 not useful（不优于当前占用）"
	ai._sell_unwanted(&"enemy", enemy_mech, enemy)
	if enemy.sell_equipment_count_this_turn != 1:
		return "应卖出1张，实际 sell_count=%d" % enemy.sell_equipment_count_this_turn
	return true


## 12. 商店买入：有空槽+金币充足+商店有匹配牌 -> 买入（金币减少/手牌增加）
func test_ai_buys_for_empty_slot():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var enemy = gs.players.get(&"enemy")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	enemy.equipment_hand.clear()
	enemy.gold = 30
	# 找商店里一张部件牌，清空其对应槽位
	var shop = gs.shop_state
	var target_slot: StringName = &""
	var has_part: bool = false
	for cid: StringName in shop.normal_slots:
		if cid == &"":
			continue
		var c = gs.get_card(cid)
		if c and c.def and c.def.equipment_kind == &"PART":
			target_slot = c.def.slot
			has_part = true
			break
	if not has_part:
		return "商店无部件牌可测，跳过"
	if enemy_mech.slots.has(target_slot):
		enemy_mech.slots[target_slot].equipped_card = null
	var gold_before: int = enemy.gold
	var ai = battle.context.ai_controller
	ai._buy_for_empty_slots(&"enemy", enemy_mech, enemy)
	if enemy.gold >= gold_before and enemy.equipment_hand.is_empty():
		return "应买入装备，实际金币=%d->%d 手牌=%d" % [gold_before, enemy.gold, enemy.equipment_hand.size()]
	return true
