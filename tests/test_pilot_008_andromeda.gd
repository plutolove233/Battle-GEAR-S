## test_pilot_008_andromeda.gd - 安德洛美达（pilot_008）专项逻辑测试
##
## 验证重做后的 3 效果（3 按钮：01a/01b 合并为按钮1「回收维修」+ 02「逆转治疗」+ 03「逆转维修」）：
##   effect_01 回收维修（强制，非选框）：维修被使用(01a,USE_ACTION_SETTLE)/弃置(01b,DISCARD_SETTLE)后
##     强制从弃牌堆回收到手牌 + X+1(max5)。01a/01b 共享 once_per_turn（每任意玩家回合1次）。
##   effect_02 逆转治疗：5+X格内机甲即将回复生命(HP_CHANGE_BEFORE,restore)时，弹窗确认 ->
##     改为受到等量伤害（按实际可回复量，无源伤害）。满血(实际回复0)不触发。
##   effect_03 逆转维修：5+X格内机甲即将移除损伤(DAMAGE_CHANGE_BEFORE,decrease)时，弹窗确认 ->
##     改为设置等量损伤（安德洛美达选位置）。无损伤(实际可移除0)不触发。
##     设装备替换移区域损伤也走 damage_change(decrease,direct_remove)，可被本效果逆转。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 12345
	battle.pvp_map_features = true
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	var enemy_player = battle.context.game_state.players.get(&"enemy")
	if enemy_player != null:
		enemy_player.is_human = true
	_clear_all_pilot_static()
	return battle


func _clear_all_pilot_static() -> void:
	for src in _ActionPilotEffects._pilot_006_marks.keys():
		_ActionPilotEffects.clear_pilot_006_mark(src)
	var ctl_sources: Array = []
	for target in _ActionPilotEffects._pilot_009_control.keys():
		var types: Dictionary = _ActionPilotEffects._pilot_009_control[target]
		for ct in types.keys():
			ctl_sources.append(types[ct].get("source_pilot", &""))
	for s in ctl_sources:
		_ActionPilotEffects.clear_pilot_009_control_for_source(s)
	var b_sources: Array = []
	for bid in _ActionPilotEffects._pilot_002_batches.keys():
		b_sources.append(_ActionPilotEffects._pilot_002_batches[bid].get("grant_source", &""))
	for s in b_sources:
		_ActionPilotEffects.clear_pilot_002_batches_for_source(s)
	for src in _ActionPilotEffects._pilot_003_skip.keys():
		_ActionPilotEffects.clear_pilot_003_skip_for_source(src)
	_ActionPilotEffects.clear_pilot_008_recovered()


func _make_instance(gs, cdb, card_def_id: String, owner_id: StringName):
	var pdef = cdb.get_card(StringName(card_def_id))
	if pdef == null:
		return null
	var inst_id: StringName = gs.next_id(&"card")
	var card = _CardInstance.new(inst_id, pdef)
	card.owner_player_id = owner_id
	gs.cards[inst_id] = card
	return card


## 清空地图全部格子地形为 NORMAL（避免 pvp 随机 GREEN/RED 干扰射程 BFS）
func _clear_map_terrain(battle) -> void:
	var ms = battle.context.game_state.map_state
	if ms == null:
		return
	for key in ms.cells:
		ms.cells[key].terrain = &"NORMAL"


## 设置安德洛美达 + 把双方机甲摆近（distance<=5），返回 {card,mech,player,gs,cdb}
func _setup_andromeda(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var player = gs.players.get(owner_id)
	var card = _make_instance(gs, cdb, "pilot_008_安德洛美达", owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"card": card, "mech": mech, "player": player, "gs": gs, "cdb": cdb}


## 构造一个已注册的指定类型动作（fire 时点用）
func _make_action(battle, action_type: StringName, record: Dictionary) -> _Action:
	var a := _Action.new()
	a.action_id = &"test_p008_%d" % [randi() % 1000000]
	a.action_type = action_type
	a.record = record
	a.state = &"running"
	a.context = battle.context
	battle.context.action_registry.register(a)
	return a


## 把维修牌放入弃牌堆（模拟刚被使用/弃置后的状态）
func _put_repair_in_discard(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var repair = _make_instance(gs, cdb, "action_013_维修", owner_id)
	if repair == null:
		return null
	gs.deck_state.action_discard_pile.append(repair.instance_id)
	repair.zone = &"discard"
	return repair


## 找到挂起（waiting_timing）的指定类型动作（仅 timing 挂起=效果触发，不含 waiting_input UI 挂起）
func _find_waiting_timing(battle, action_type: StringName) -> _Action:
	for a in battle.context.action_registry.get_actions_by_type(action_type):
		if a.state == &"waiting_timing":
			return a
	return null


## 找到 waiting_input 的指定类型动作（放置/移除面板等待 UI 输入）
func _find_waiting_input(battle, action_type: StringName) -> _Action:
	for a in battle.context.action_registry.get_actions_by_type(action_type):
		if a.state == &"waiting_input":
			return a
	return null


## 清理全部未完成动作（避免遗留挂起动作在帧 flush 时干扰后续测试）
func _cancel_active(battle) -> void:
	for aid in battle.context.action_registry.get_active_ids():
		battle.context.action_engine.cancel_action(aid)


## 走真实 discard_card 动作强制弃置指定牌（fire DISCARD_BEFORE/AFTER/SETTLE 时点，
## action_type=discard_card，自动生成 discard_snapshots）。card_ids 须已在玩家 action_hand。
func _force_discard(battle, player_id: StringName, card_ids: Array, reason: StringName = &"test") -> void:
	battle.context.action_service.execute(&"discard_card", {
		"card_ids": card_ids,
		"player_id": player_id,
		"executor": &"system_default",
		"reason": reason,
		"source": {"player_id": String(player_id)},
	})


# ═══════════════════════════════════════════
# effect_01 回收维修
# ═══════════════════════════════════════════

## 01a：维修被使用后(USE_ACTION_SETTLE)强制回收 + X+1
func test_effect01a_recover_on_use() -> Variant:
	var battle := _new_battle()
	var st = _setup_andromeda(battle, &"player")
	if st == null:
		return "安德洛美达设置失败"
	var gs = st.gs
	var player = st.player
	player.action_hand.clear()
	var repair = _put_repair_in_discard(battle, &"player")
	if repair == null:
		return "找不到 action_013_维修"
	var x_before: int = _ActionPilotEffects.get_pilot_008_x(st.card)
	var use_act := _make_action(battle, &"use_action_card", {"card_instance_id": repair.instance_id})
	battle.context.timing_engine.fire_timing(_TimingConst.USE_ACTION_SETTLE, use_act)
	if not player.action_hand.has(repair.instance_id):
		return "01a 应强制回收维修到手牌"
	if _ActionPilotEffects.get_pilot_008_x(st.card) != x_before + 1:
		return "01a 应 X+1 实=%d" % _ActionPilotEffects.get_pilot_008_x(st.card)
	var rc = gs.get_card(repair.instance_id)
	if rc == null or String(rc.zone) != &"action_hand":
		return "回收的维修 zone 应为 action_hand 实=%s" % str(rc.zone if rc else null)
	_clear_all_pilot_static()
	return true


## 01b：维修被弃置后(DISCARD_SETTLE)强制回收 + X+1
## 01b：维修在多张弃置中被弃 -> 强制回收到安德洛美达手牌 + X+1
## 走真实 discard_card 动作（action_type=discard_card，验证 listen_action_type 匹配 + 多牌 snapshots）
func test_effect01b_recover_on_discard() -> Variant:
	var battle := _new_battle()
	var st = _setup_andromeda(battle, &"player")
	if st == null:
		return "安德洛美达设置失败"
	var gs = st.gs
	var player = st.player
	var enemy = gs.players.get(&"enemy")
	player.action_hand.clear()
	enemy.action_hand.clear()
	# 敌方手牌含维修 + 2张其他行动牌（多张弃置场景）
	var repair = _make_instance(gs, st.cdb, "action_013_维修", &"enemy")
	if repair == null:
		return "找不到 action_013_维修"
	var filler_ids: Array = []
	for i in range(2):
		var f = _make_instance(gs, st.cdb, "action_002_强袭", &"enemy")
		if f == null:
			return "找不到 action_002_强袭 填充牌"
		enemy.action_hand.append(f.instance_id)
		f.zone = &"action_hand"
		filler_ids.append(f.instance_id)
	enemy.action_hand.append(repair.instance_id)
	repair.zone = &"action_hand"
	var x_before: int = _ActionPilotEffects.get_pilot_008_x(st.card)
	# 真实弃置3张（含维修）：走 discard_card 动作 fire DISCARD_SETTLE
	_force_discard(battle, &"enemy", [repair.instance_id, filler_ids[0], filler_ids[1]])
	# 01b 应强制回收本次弃置中的维修到安德洛美达(玩家)手牌 + X+1
	if not player.action_hand.has(repair.instance_id):
		return "01b 应回收本次弃置中的维修到安德洛美达手牌"
	if _ActionPilotEffects.get_pilot_008_x(st.card) != x_before + 1:
		return "01b 应 X+1 实=%d（预期%d）" % [_ActionPilotEffects.get_pilot_008_x(st.card), x_before + 1]
	# 维修应已从弃牌堆移出；其他两张填充牌应留在弃牌堆
	if gs.deck_state.action_discard_pile.has(repair.instance_id):
		return "维修应已从弃牌堆移出"
	if not gs.deck_state.action_discard_pile.has(filler_ids[0]) or not gs.deck_state.action_discard_pile.has(filler_ids[1]):
		return "其他弃置牌应留在弃牌堆"
	_clear_all_pilot_static()
	return true


## 01b：本次弃置不含维修 -> 不触发（即便弃牌堆里有跨回合残留的维修也不误触发）
func test_effect01b_no_repair_in_discard_no_trigger() -> Variant:
	var battle := _new_battle()
	var st = _setup_andromeda(battle, &"player")
	if st == null:
		return "安德洛美达设置失败"
	var gs = st.gs
	var player = st.player
	var enemy = gs.players.get(&"enemy")
	player.action_hand.clear()
	enemy.action_hand.clear()
	# 先往弃牌堆塞一张残留维修（模拟跨回合残留），再弃2张非维修牌
	var lingering = _put_repair_in_discard(battle, &"enemy")
	if lingering == null:
		return "找不到 action_013_维修"
	var f1 = _make_instance(gs, st.cdb, "action_002_强袭", &"enemy")
	var f2 = _make_instance(gs, st.cdb, "action_002_强袭", &"enemy")
	if f1 == null or f2 == null:
		return "找不到 action_002_强袭 填充牌"
	enemy.action_hand.append(f1.instance_id)
	enemy.action_hand.append(f2.instance_id)
	f1.zone = &"action_hand"
	f2.zone = &"action_hand"
	var x_before: int = _ActionPilotEffects.get_pilot_008_x(st.card)
	_force_discard(battle, &"enemy", [f1.instance_id, f2.instance_id])
	# 本次弃置不含维修，01b 不应触发
	if player.action_hand.has(lingering.instance_id):
		return "本次弃置无维修，不应回收弃牌堆残留的维修"
	if _ActionPilotEffects.get_pilot_008_x(st.card) != x_before:
		return "不应 X+1 实=%d（预期%d）" % [_ActionPilotEffects.get_pilot_008_x(st.card), x_before]
	_clear_all_pilot_static()
	return true


## 01a/01b 共享 once_per_turn：01a 用过后同回合 01b 不再触发
func test_effect01_once_per_turn_shared() -> Variant:
	var battle := _new_battle()
	var st = _setup_andromeda(battle, &"player")
	if st == null:
		return "安德洛美达设置失败"
	var gs = st.gs
	var player = st.player
	player.action_hand.clear()
	# 第一张维修：被使用 -> 01a 回收
	var repair1 = _put_repair_in_discard(battle, &"player")
	if repair1 == null:
		return "找不到 action_013_维修"
	var use_act := _make_action(battle, &"use_action_card", {"card_instance_id": repair1.instance_id})
	battle.context.timing_engine.fire_timing(_TimingConst.USE_ACTION_SETTLE, use_act)
	if not player.action_hand.has(repair1.instance_id):
		return "01a 应回收第一张维修"
	# 第二张维修：被弃置 -> 01b 应因 once_per_turn 已用而不触发
	player.action_hand.clear()
	gs.deck_state.action_discard_pile.clear()
	var enemy = gs.players.get(&"enemy")
	enemy.action_hand.clear()
	var repair2 = _make_instance(gs, st.cdb, "action_013_维修", &"enemy")
	if repair2 == null:
		return "找不到第二张维修"
	enemy.action_hand.append(repair2.instance_id)
	repair2.zone = &"action_hand"
	var x_after_a: int = _ActionPilotEffects.get_pilot_008_x(st.card)
	_force_discard(battle, &"enemy", [repair2.instance_id])
	if player.action_hand.has(repair2.instance_id):
		return "01b 同回合不应再次回收（once_per_turn 共享）"
	if _ActionPilotEffects.get_pilot_008_x(st.card) != x_after_a:
		return "01b 不应再次 X+1 实=%d（预期%d）" % [_ActionPilotEffects.get_pilot_008_x(st.card), x_after_a]
	_clear_all_pilot_static()
	return true


# ═══════════════════════════════════════════
# effect_01b 经真实弃牌路径（验证绕过动作的弃牌已改走 discard_card 动作发时点）
# ═══════════════════════════════════════════

## 01b 经真实路径：美杜莎蛇发支配「支付弃1张」弃维修 -> 安德洛美达回收 + X+1
## 验证 pilot_009_pay_and_record_type 走 deck_service.discard_card（发 DISCARD_SETTLE），
## 而非旧的无时点 helper。
func test_effect01b_recover_via_pilot_009_pay() -> Variant:
	var battle := _new_battle()
	var st = _setup_andromeda(battle, &"player")
	if st == null:
		return "安德洛美达设置失败"
	var gs = st.gs
	var player = st.player
	player.action_hand.clear()
	# 美杜莎支付弃的维修牌（放入玩家手牌，owner=玩家）
	var repair = _make_instance(gs, st.cdb, "action_013_维修", &"player")
	if repair == null:
		return "找不到 action_013_维修"
	player.action_hand.append(repair.instance_id)
	repair.zone = &"action_hand"
	var x_before: int = _ActionPilotEffects.get_pilot_008_x(st.card)
	# 走真实 pilot_009_pay 路径（应经 deck_service.discard_card 发 DISCARD_SETTLE）
	var card_type: StringName = battle.context.game_actions.pilot_009_pay_and_record_type({"card_id": repair.instance_id})
	if String(card_type) != "辅助":
		return "pilot_009_pay 应返回维修类型(辅助) 实=%s" % String(card_type)
	if not player.action_hand.has(repair.instance_id):
		return "01b 经美杜莎支付弃维修后应回收到安德洛美达手牌"
	if _ActionPilotEffects.get_pilot_008_x(st.card) != x_before + 1:
		return "01b 经美杜莎支付弃维修应 X+1 实=%d" % _ActionPilotEffects.get_pilot_008_x(st.card)
	# 维修应已从弃牌堆移出（被回收到手牌）
	if gs.deck_state.action_discard_pile.has(repair.instance_id):
		return "维修应已从弃牌堆移出到手牌"
	_clear_all_pilot_static()
	return true


## 01b 经真实路径：肯特帝国压制弃对侧（含维修）-> 安德洛美达回收首张维修 + X+1
## 验证 pilot_005_discard_opposing 走 deck_service.discard_cards（批量，发 DISCARD_SETTLE）。
func test_effect01b_recover_via_pilot_005_imperial() -> Variant:
	var battle := _new_battle()
	var st = _setup_andromeda(battle, &"player")
	if st == null:
		return "安德洛美达设置失败"
	var gs = st.gs
	var player = st.player
	var enemy = gs.players.get(&"enemy")
	var player_mech = st.mech
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if enemy_mech == null:
		return "enemy_mech 缺失"
	player.action_hand.clear()
	enemy.action_hand.clear()
	# 敌方手牌：维修 + 1张强袭（帝国压制弃前2张，维修在其中）
	var repair = _make_instance(gs, st.cdb, "action_013_维修", &"enemy")
	if repair == null:
		return "找不到 action_013_维修"
	var filler = _make_instance(gs, st.cdb, "action_002_强袭", &"enemy")
	if filler == null:
		return "找不到 action_002_强袭"
	enemy.action_hand.append(repair.instance_id)
	enemy.action_hand.append(filler.instance_id)
	repair.zone = &"action_hand"
	filler.zone = &"action_hand"
	var x_before: int = _ActionPilotEffects.get_pilot_008_x(st.card)
	# 帝国压制：source=玩家机甲(肯特授予)，攻击方=玩家，目标=敌方 -> 弃对侧(敌方)前2张
	var parent_act := _make_action(battle, &"attack", {"attacker_id": player_mech.mech_id, "target_id": enemy_mech.mech_id})
	battle.context.game_actions.pilot_005_discard_opposing({}, {
		"attacker_id": player_mech.mech_id,
		"target_id": enemy_mech.mech_id,
		"binding_context": {"mech_id": player_mech.mech_id},
	}, parent_act)
	if not player.action_hand.has(repair.instance_id):
		return "01b 经帝国压制弃维修后应回收到安德洛美达手牌"
	if _ActionPilotEffects.get_pilot_008_x(st.card) != x_before + 1:
		return "01b 经帝国压制弃维修应 X+1 实=%d" % _ActionPilotEffects.get_pilot_008_x(st.card)
	# 另一张强袭应留在弃牌堆
	if not gs.deck_state.action_discard_pile.has(filler.instance_id):
		return "强袭填充牌应留在弃牌堆"
	_clear_all_pilot_static()
	return true


## 01b 经真实路径：美杜莎蛇发支配「立即弃置目标全部辅助牌」（含多张维修）-> 回收首张维修 + X+1（只1次）
## 验证 pilot_009_discard_all_controlled_type 走 deck_service.discard_cards（批量），
## 一次弃置含多张维修时只 fire 一次 SETTLE，取首张维修（裁定）。
func test_effect01b_recover_via_pilot_009_discard_all() -> Variant:
	var battle := _new_battle()
	var st = _setup_andromeda(battle, &"player")
	if st == null:
		return "安德洛美达设置失败"
	var gs = st.gs
	var player = st.player
	var enemy = gs.players.get(&"enemy")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if enemy_mech == null:
		return "enemy_mech 缺失"
	player.action_hand.clear()
	enemy.action_hand.clear()
	# 敌方手牌：2张维修 + 1张强袭（立即弃置全部辅助牌=2张维修，取首张回收）
	var repair1 = _make_instance(gs, st.cdb, "action_013_维修", &"enemy")
	var repair2 = _make_instance(gs, st.cdb, "action_013_维修", &"enemy")
	if repair1 == null or repair2 == null:
		return "找不到 action_013_维修"
	var filler = _make_instance(gs, st.cdb, "action_002_强袭", &"enemy")
	if filler == null:
		return "找不到 action_002_强袭"
	enemy.action_hand.append(repair1.instance_id)
	enemy.action_hand.append(repair2.instance_id)
	enemy.action_hand.append(filler.instance_id)
	repair1.zone = &"action_hand"
	repair2.zone = &"action_hand"
	filler.zone = &"action_hand"
	var x_before: int = _ActionPilotEffects.get_pilot_008_x(st.card)
	# 立即弃置目标全部辅助牌（维修是辅助）
	battle.context.game_actions.pilot_009_discard_all_controlled_type(
		{"card_type": &"辅助"},
		{"target_id": enemy_mech.mech_id})
	# 取首张维修(repair1)回收到安德洛美达手牌 + X+1（只 fire 一次，X 只 +1）
	if not player.action_hand.has(repair1.instance_id):
		return "01b 经立即弃置应回收首张维修到安德洛美达手牌"
	if player.action_hand.has(repair2.instance_id):
		return "01b 一次弃置只回收首张维修，第二张不应也回收到手牌"
	if _ActionPilotEffects.get_pilot_008_x(st.card) != x_before + 1:
		return "01b 一次弃置只 X+1 一次 实=%d" % _ActionPilotEffects.get_pilot_008_x(st.card)
	# 第二张维修应留在弃牌堆（未被回收）
	var pile: Array = gs.deck_state.action_discard_pile
	if not pile.has(repair2.instance_id):
		return "第二张维修应留在弃牌堆"
	# 强袭是攻击牌，不被辅助过滤弃置，应留在敌方手牌
	if not enemy.action_hand.has(filler.instance_id):
		return "强袭(攻击)不被辅助过滤弃置，应留在敌方手牌"
	_clear_all_pilot_static()
	return true


## 复现：敌方回合末超限弃牌含维修 -> 安德洛美达应回收（用户报告获取不了）
func test_effect01b_recover_via_turn_end_overlimit() -> Variant:
	var battle := _new_battle()
	var st = _setup_andromeda(battle, &"player")
	if st == null:
		return "安德洛美达设置失败"
	var gs = st.gs
	var player = st.player
	var enemy = gs.players.get(&"enemy")
	player.action_hand.clear()
	enemy.action_hand.clear()
	# 敌方手牌：1张维修 + 4张强袭 = 5张，limit 4 -> 回合末超限弃1张
	# action_card_limit 默认 5（pilot 不改），但 pilot_008安德洛美达 limit 4（自身）。
	# 为稳定复现，直接把 enemy.action_card_limit 莅 3，5张手牌超限弃2张（含维修排末尾被pop）
	enemy.action_card_limit = 3
	var repair = _make_instance(gs, st.cdb, "action_013_维修", &"enemy")
	if repair == null:
		return "找不到 action_013_维修"
	var fillers: Array = []
	for i in range(4):
		var f = _make_instance(gs, st.cdb, "action_002_强袭", &"enemy")
		if f == null:
			return "找不到 action_002_强袭"
		enemy.action_hand.append(f.instance_id)
		f.zone = &"action_hand"
		fillers.append(f.instance_id)
	# 维修放末尾：pop_back 先弹出维修
	enemy.action_hand.append(repair.instance_id)
	repair.zone = &"action_hand"
	var x_before: int = _ActionPilotEffects.get_pilot_008_x(st.card)
	# 走真实回合末弃牌流程
	battle.context.turn_service.end_turn(&"enemy")
	# 诊断：看维修在哪
	var rc = gs.get_card(repair.instance_id)
	var repair_zone: String = String(rc.zone) if rc != null else "null"
	if not player.action_hand.has(repair.instance_id):
		return "回合末超限弃维修应被安德洛美达回收（实 zone=%s player_hand=%s enemy_hand=%s discard=%s x=%d）" % [repair_zone, str(player.action_hand.size()), str(enemy.action_hand.size()), str(gs.deck_state.action_discard_pile.has(repair.instance_id)), _ActionPilotEffects.get_pilot_008_x(st.card)]
	if _ActionPilotEffects.get_pilot_008_x(st.card) != x_before + 1:
		return "回合末回收应 X+1 实=%d" % _ActionPilotEffects.get_pilot_008_x(st.card)
	_clear_all_pilot_static()
	return true


## 复现：安德洛美达自己回合末超限弃牌含维修 -> 回收后又被 while 重 pop 死循环？
func test_effect01b_recover_via_own_turn_end_overlimit() -> Variant:
	var battle := _new_battle()
	var st = _setup_andromeda(battle, &"player")
	if st == null:
		return "安德洛美达设置失败"
	var gs = st.gs
	var player = st.player
	player.action_hand.clear()
	player.action_card_limit = 3
	var repair = _make_instance(gs, st.cdb, "action_013_维修", &"player")
	if repair == null:
		return "找不到 action_013_维修"
	var fillers: Array = []
	for i in range(4):
		var f = _make_instance(gs, st.cdb, "action_002_强袭", &"player")
		if f == null:
			return "找不到 action_002_强袭"
		player.action_hand.append(f.instance_id)
		f.zone = &"action_hand"
		fillers.append(f.instance_id)
	player.action_hand.append(repair.instance_id)
	repair.zone = &"action_hand"
	var x_before: int = _ActionPilotEffects.get_pilot_008_x(st.card)
	battle.context.turn_service.end_turn(&"player")
	var rc = gs.get_card(repair.instance_id)
	var repair_zone: String = String(rc.zone) if rc != null else "null"
	var in_player_hand: bool = player.action_hand.has(repair.instance_id)
	var in_discard: bool = gs.deck_state.action_discard_pile.has(repair.instance_id)
	var x_after: int = _ActionPilotEffects.get_pilot_008_x(st.card)
	# 预期：维修应回收到安德洛美达手牌 + X+1，且放末尾（不覆盖第一张行动牌）
	if not in_player_hand:
		return "自己回合末超限弃维修应回收到手牌（实 zone=%s in_hand=%s in_discard=%s x_before=%d x_after=%d）" % [repair_zone, in_player_hand, in_discard, x_before, x_after]
	if x_after != x_before + 1:
		return "应 X+1 实=%d（x_before=%d）" % [x_after, x_before]
	if player.action_hand[player.action_hand.size() - 1] != repair.instance_id:
		return "回收的维修应放手牌末尾（实末位=%s 手牌=%s）" % [String(player.action_hand[player.action_hand.size() - 1]), str(player.action_hand)]
	_clear_all_pilot_static()
	return true


## 复现 _net_end_turn 路径：deck_service.discard_cards 批量弃牌（模拟 PvP 回合末玩家选弃含维修）。
## 原代码走 game_actions.discard_action_card（legacy 只 fire ON_CARD_DISCARDED hook 不发时点）-> 01b 永不触发。
## 改走 deck_service.discard_cards -> discard_card 动作发 DISCARD_SETTLE -> 01b 触发回收。
func test_effect01b_recover_via_deck_service_discard_cards() -> Variant:
	var battle := _new_battle()
	var st = _setup_andromeda(battle, &"player")
	if st == null:
		return "安德洛美达设置失败"
	var gs = st.gs
	var player = st.player
	var enemy = gs.players.get(&"enemy")
	player.action_hand.clear()
	enemy.action_hand.clear()
	var repair = _make_instance(gs, st.cdb, "action_013_维修", &"enemy")
	if repair == null:
		return "找不到 action_013_维修"
	var f1 = _make_instance(gs, st.cdb, "action_002_强袭", &"enemy")
	var f2 = _make_instance(gs, st.cdb, "action_002_强袭", &"enemy")
	if f1 == null or f2 == null:
		return "找不到填充牌"
	enemy.action_hand.append(repair.instance_id)
	enemy.action_hand.append(f1.instance_id)
	enemy.action_hand.append(f2.instance_id)
	repair.zone = &"action_hand"
	f1.zone = &"action_hand"
	f2.zone = &"action_hand"
	var x_before: int = _ActionPilotEffects.get_pilot_008_x(st.card)
	# 模拟 _net_end_turn 改后的 deck_service.discard_cards 路径
	battle.context.deck_service.discard_cards([repair.instance_id, f1.instance_id, f2.instance_id], &"END_TURN_HAND_LIMIT")
	if not player.action_hand.has(repair.instance_id):
		return "_net_end_turn 路径应回收维修到安德洛美达手牌"
	if _ActionPilotEffects.get_pilot_008_x(st.card) != x_before + 1:
		return "应 X+1 实=%d" % _ActionPilotEffects.get_pilot_008_x(st.card)
	if not gs.deck_state.action_discard_pile.has(f1.instance_id) or not gs.deck_state.action_discard_pile.has(f2.instance_id):
		return "非维修牌应留在弃牌堆"
	_clear_all_pilot_static()
	return true


# ═══════════════════════════════════════════
# effect_02 逆转治疗
# ═══════════════════════════════════════════

## 安德洛美达(player)在范围内，enemy 受伤未满血，回复4 -> 确认逆转 -> enemy 受到等量伤害
func test_effect02_redirect_heal_to_damage() -> Variant:
	var battle := _new_battle()
	_clear_map_terrain(battle)
	var st = _setup_andromeda(battle, &"player")
	if st == null:
		return "安德洛美达设置失败"
	var gs = st.gs
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if enemy_mech == null:
		return "enemy_mech 缺失"
	# 摆近：distance<=5
	st.mech.position = {"q": 5, "r": 2}
	enemy_mech.position = {"q": 7, "r": 2}
	# enemy 受伤（差6满血），回复4 -> 实际可回复4
	enemy_mech.current_hp = enemy_mech.max_hp - 6
	var hp_before: int = enemy_mech.current_hp
	battle.context.action_service.execute(&"hp_change", {
		"mech_ids": [enemy_mech.mech_id],
		"value": 4,
		"method": &"restore",
		"source": {"player_id": &"player"},
	})
	var hc = _find_waiting_timing(battle, &"hp_change")
	if hc == null:
		return "effect_02 应挂起 hp_change 等待确认（state=%s）" % str(enemy_mech.current_hp)
	# 确认逆转（option 0）
	battle.context.timing_engine.resume_pending_effect(hc.action_id, {"chosen_option_index": 0})
	# 实际回复量 = min(4, 6) = 4 -> 逆转为受到4伤害 -> HP-4
	if enemy_mech.current_hp != hp_before - 4:
		return "逆转后 enemy 应受4伤害 HP=%d（before=%d）" % [enemy_mech.current_hp, hp_before]
	_clear_all_pilot_static()
	return true


## 取消逆转 -> 回复原样生效
func test_effect02_cancel_keeps_heal() -> Variant:
	var battle := _new_battle()
	_clear_map_terrain(battle)
	var st = _setup_andromeda(battle, &"player")
	if st == null:
		return "安德洛美达设置失败"
	var gs = st.gs
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if enemy_mech == null:
		return "enemy_mech 缺失"
	st.mech.position = {"q": 5, "r": 2}
	enemy_mech.position = {"q": 7, "r": 2}
	enemy_mech.current_hp = enemy_mech.max_hp - 6
	var hp_before: int = enemy_mech.current_hp
	battle.context.action_service.execute(&"hp_change", {
		"mech_ids": [enemy_mech.mech_id],
		"value": 4,
		"method": &"restore",
		"source": {"player_id": &"player"},
	})
	var hc = _find_waiting_timing(battle, &"hp_change")
	if hc == null:
		return "effect_02 应挂起"
	battle.context.timing_engine.resume_pending_effect(hc.action_id, {"cancelled": true})
	# 取消 -> 回复原样：HP+4（封顶 max）
	if enemy_mech.current_hp != mini(enemy_mech.max_hp, hp_before + 4):
		return "取消后应正常回复 HP=%d（预期%d）" % [enemy_mech.current_hp, mini(enemy_mech.max_hp, hp_before + 4)]
	_clear_all_pilot_static()
	return true


## 满血（实际回复0）-> effect_02 不触发，hp_change 正常完成不挂起
func test_effect02_full_hp_no_trigger() -> Variant:
	var battle := _new_battle()
	_clear_map_terrain(battle)
	var st = _setup_andromeda(battle, &"player")
	if st == null:
		return "安德洛美达设置失败"
	var gs = st.gs
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if enemy_mech == null:
		return "enemy_mech 缺失"
	st.mech.position = {"q": 5, "r": 2}
	enemy_mech.position = {"q": 7, "r": 2}
	enemy_mech.current_hp = enemy_mech.max_hp  # 满血
	battle.context.action_service.execute(&"hp_change", {
		"mech_ids": [enemy_mech.mech_id],
		"value": 4,
		"method": &"restore",
		"source": {"player_id": &"player"},
	})
	var hc = _find_waiting_timing(battle, &"hp_change")
	if hc != null:
		return "满血(实际回复0)不应触发 effect_02 挂起"
	if enemy_mech.current_hp != enemy_mech.max_hp:
		return "满血回复应不变 HP=%d" % enemy_mech.current_hp
	_clear_all_pilot_static()
	return true


## 超出 5+X 范围 -> effect_02 不触发
func test_effect02_out_of_range_no_trigger() -> Variant:
	var battle := _new_battle()
	_clear_map_terrain(battle)
	var st = _setup_andromeda(battle, &"player")
	if st == null:
		return "安德洛美达设置失败"
	var gs = st.gs
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if enemy_mech == null:
		return "enemy_mech 缺失"
	st.mech.position = {"q": 0, "r": 0}
	enemy_mech.position = {"q": 10, "r": 0}  # 距离>5
	enemy_mech.current_hp = enemy_mech.max_hp - 6
	var hp_before: int = enemy_mech.current_hp
	battle.context.action_service.execute(&"hp_change", {
		"mech_ids": [enemy_mech.mech_id],
		"value": 4,
		"method": &"restore",
		"source": {"player_id": &"player"},
	})
	var hc = _find_waiting_timing(battle, &"hp_change")
	if hc != null:
		return "超范围不应触发 effect_02 挂起"
	if enemy_mech.current_hp != mini(enemy_mech.max_hp, hp_before + 4):
		return "超范围应正常回复 HP=%d" % enemy_mech.current_hp
	_clear_all_pilot_static()
	return true


# ═══════════════════════════════════════════
# effect_03 逆转维修
# ═══════════════════════════════════════════

## 安德洛美达在范围内，enemy 有损伤，移除2 -> 确认逆转 -> method=increase，原损伤保留，挂放置面板
func test_effect03_redirect_removal_to_placement() -> Variant:
	var battle := _new_battle()
	_clear_map_terrain(battle)
	var st = _setup_andromeda(battle, &"player")
	if st == null:
		return "安德洛美达设置失败"
	var gs = st.gs
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if enemy_mech == null:
		return "enemy_mech 缺失"
	st.mech.position = {"q": 5, "r": 2}
	enemy_mech.position = {"q": 7, "r": 2}
	# enemy 头部放3损伤
	var head_slot = enemy_mech.slots.get(&"头部")
	if head_slot == null:
		return "头部槽缺失"
	head_slot.region_damage_tokens = 3
	if head_slot.equipped_card != null:
		head_slot.equipped_card.damage_tokens = 3
	var dmg_before: int = enemy_mech.get_damage_token_count()
	battle.context.action_service.execute(&"damage_change", {
		"mech_ids": [enemy_mech.mech_id],
		"value": 2,
		"method": &"decrease",
		"source": {"player_id": &"player"},
	})
	var dc = _find_waiting_timing(battle, &"damage_change")
	if dc == null:
		return "effect_03 应挂起 damage_change 等待确认"
	battle.context.timing_engine.resume_pending_effect(dc.action_id, {"chosen_option_index": 0})
	# 逆转后：method=increase，原3损伤保留（移除取消），挂放置面板(amount=2,executor=安德洛美达)
	var dc2 = _find_waiting_input(battle, &"damage_change")
	if dc2 == null:
		return "逆转后应挂放置面板(waiting_input)"
	if String(dc2.record.get("method", &"")) != &"increase":
		return "逆转后 method 应为 increase 实=%s" % String(dc2.record.get("method", &""))
	if int(dc2.record.get("value", 0)) != 2:
		return "逆转后 value 应为2(实际可移除量) 实=%d" % int(dc2.record.get("value", 0))
	if StringName(dc2.record.get("executor", &"")) != &"player":
		return "逆转后 executor 应为安德洛美达玩家 实=%s" % String(dc2.record.get("executor", &""))
	if enemy_mech.get_damage_token_count() != dmg_before:
		return "原损伤应保留(移除取消) 实=%d（预期%d）" % [enemy_mech.get_damage_token_count(), dmg_before]
	_cancel_active(battle)
	_clear_all_pilot_static()
	return true


## 无损伤（实际可移除0）-> effect_03 不触发
func test_effect03_no_damage_no_trigger() -> Variant:
	var battle := _new_battle()
	_clear_map_terrain(battle)
	var st = _setup_andromeda(battle, &"player")
	if st == null:
		return "安德洛美达设置失败"
	var gs = st.gs
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if enemy_mech == null:
		return "enemy_mech 缺失"
	st.mech.position = {"q": 5, "r": 2}
	enemy_mech.position = {"q": 7, "r": 2}
	# 清空所有损伤
	for sid in enemy_mech.slots:
		var s = enemy_mech.slots[sid]
		if s != null:
			s.region_damage_tokens = 0
			if s.equipped_card != null:
				s.equipped_card.damage_tokens = 0
	battle.context.action_service.execute(&"damage_change", {
		"mech_ids": [enemy_mech.mech_id],
		"value": 2,
		"method": &"decrease",
		"source": {"player_id": &"player"},
	})
	var dc = _find_waiting_timing(battle, &"damage_change")
	if dc != null:
		return "无损伤(实际可移除0)不应触发 effect_03 挂起"
	_cancel_active(battle)
	_clear_all_pilot_static()
	return true


## 设装备替换移区域损伤走 damage_change(direct_remove)；安德洛美达在范围内可被 effect_03 逆转
func test_effect03_set_equipment_direct_remove_interceptable() -> Variant:
	var battle := _new_battle()
	_clear_map_terrain(battle)
	var st = _setup_andromeda(battle, &"player")
	if st == null:
		return "安德洛美达设置失败"
	var gs = st.gs
	var cdb = st.cdb
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if enemy_mech == null:
		return "enemy_mech 缺失"
	st.mech.position = {"q": 5, "r": 2}
	enemy_mech.position = {"q": 7, "r": 2}
	# enemy 头部已有装备(耐久2) + 区域3损伤
	var head_slot = enemy_mech.slots.get(&"头部")
	if head_slot == null:
		return "头部槽缺失"
	# 放一张头部装备
	var head_equip = _make_instance(gs, cdb, "part_001_量产装_头部", &"enemy")
	if head_equip == null:
		return "找不到头部装备"
	head_slot.equipped_card = head_equip
	head_slot.region_damage_tokens = 3
	head_equip.damage_tokens = 3
	# 准备一张新头部装备替换
	var new_equip = _make_instance(gs, cdb, "part_001_量产装_头部", &"enemy")
	if new_equip == null:
		return "找不到新头部装备"
	gs.players.get(&"enemy").equipment_hand.append(new_equip.instance_id)
	new_equip.zone = &"equipment_hand"
	battle.context.action_service.execute(&"set_equipment", {
		"card_id": new_equip.instance_id,
		"mech_id": enemy_mech.mech_id,
		"slot_id": &"头部",
		"player_id": &"enemy",
		"source": {"player_id": &"enemy", "mech_id": enemy_mech.mech_id},
	})
	# effect_03 应挂起 damage_change（逆转弹窗）
	var dc = _find_waiting_timing(battle, &"damage_change")
	if dc == null:
		return "设装备移损伤应被 effect_03 拦截挂起（direct_remove 走 damage_change）"
	if not bool(dc.record.get("direct_remove", false)) and String(dc.record.get("method", &"")) != &"decrease":
		return "应为 direct_remove decrease 损伤变动"
	# 确认逆转 -> method=increase，原区域损伤保留
	battle.context.timing_engine.resume_pending_effect(dc.action_id, {"chosen_option_index": 0})
	var dc2 = _find_waiting_input(battle, &"damage_change")
	if dc2 == null:
		return "逆转后应挂放置面板"
	if String(dc2.record.get("method", &"")) != &"increase":
		return "逆转后 method 应为 increase 实=%s" % String(dc2.record.get("method", &""))
	# 原区域3损伤应保留（移除取消）
	if head_slot.region_damage_tokens != 3:
		return "设装备移损伤被逆转后原区域损伤应保留 实=%d" % head_slot.region_damage_tokens
	_cancel_active(battle)
	_clear_all_pilot_static()
	return true


## 无安德洛美达时，设装备 direct_remove 正常移除区域损伤（不弹逆转窗）
func test_effect03_direct_remove_no_pilot_normal() -> Variant:
	var battle := _new_battle()
	_clear_map_terrain(battle)
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if enemy_mech == null:
		return "enemy_mech 缺失"
	# 不设安德洛美达
	var head_slot = enemy_mech.slots.get(&"头部")
	if head_slot == null:
		return "头部槽缺失"
	var old_equip = _make_instance(gs, cdb, "part_001_量产装_头部", &"enemy")
	if old_equip == null:
		return "找不到头部装备"
	var old_durability: int = old_equip.def.durability if "durability" in old_equip.def else 2
	head_slot.equipped_card = old_equip
	head_slot.region_damage_tokens = 3
	old_equip.damage_tokens = 3
	var new_equip = _make_instance(gs, cdb, "part_001_量产装_头部", &"enemy")
	if new_equip == null:
		return "找不到新头部装备"
	gs.players.get(&"enemy").equipment_hand.append(new_equip.instance_id)
	new_equip.zone = &"equipment_hand"
	battle.context.action_service.execute(&"set_equipment", {
		"card_id": new_equip.instance_id,
		"mech_id": enemy_mech.mech_id,
		"slot_id": &"头部",
		"player_id": &"enemy",
		"source": {"player_id": &"enemy", "mech_id": enemy_mech.mech_id},
	})
	# 无安德洛美达：direct_remove 正常移除 min(耐久, 区域损伤)，不应挂起逆转
	var expect_removed: int = mini(old_durability, 3)
	if head_slot.region_damage_tokens != 3 - expect_removed:
		return "无安德洛美达应正常移除%d损伤，剩余%d 实=%d" % [expect_removed, 3 - expect_removed, head_slot.region_damage_tokens]
	var dc = _find_waiting_timing(battle, &"damage_change")
	if dc != null and dc.state == &"waiting_timing":
		return "无安德洛美达不应挂起逆转弹窗"
	_cancel_active(battle)
	_clear_all_pilot_static()
	return true
