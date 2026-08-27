## test_event_cards.gd - 事件牌系统测试
##
## 覆盖事件牌核心机制（set_event_card 动作 + EventTimerService 计时引擎 + 派生加成）：
##   1. 事件牌堆构建（教学战斗含全部事件牌实例）
##   2. set_event_card：指定实例设置（槽位/归属/timer 初始化）
##   3. set_event_card：不指定实例则抽事件牌堆顶
##   4. 事件牌堆耗尽：记日志取消，槽保持空
##   5. 顶掉旧事件牌：旧牌完整弃置且永久离场（zone=removed，不入弃牌堆）
##   6. instant 牌（增援 e001）：设置时结算（抽2行动）后立即离场
##   7. every_turn_end（拾荒 e005）：任意玩家回合结束都 tick，归零弃置
##   8. own_turn_end（招募 e007）：仅我方回合结束 tick
##   9. next_own_turn_end（强化 e011）：设置当回合结束跳过（armed），下个我方回合结束 tick
##  10. next_own_turn_start（陷落 e006）：仅我方回合开始 tick；到期抽新牌顶掉旧牌
##  11. 派生加成：护甲+5 / 动力+4 / 武器威力+4 / 范围+2，弃置后全部恢复
##  12. 陷落限制状态：设置时施加，离场清除
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _GenEventEffects = preload("res://scripts/generated_database/GeneratedEventEffects.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 91001
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	_clear_event_static()
	return battle


## 清空事件派生 registry 静态状态（跨测试泄漏防护，同 _clear_pilot_static 模式）
func _clear_event_static() -> void:
	for mid in _GenEventEffects._derived_registry.keys():
		_GenEventEffects.unregister_derived_bonuses(mid)


func _pump_frames(n: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for i in n:
		await tree.process_frame


## 从事件牌堆找指定 def 的实例 ID（不动牌堆）
func _find_event_instance(gs, card_def_id: StringName) -> StringName:
	for cid: StringName in gs.deck_state.event_deck:
		var card = gs.cards.get(cid)
		if card != null and card.def != null and card.def.card_id == card_def_id:
			return cid
	return &""


## 从事件牌堆移除并领取指定 def 的实例（设置到槽前调用，避免同 def 重复实例干扰）
func _take_event_instance(gs, card_def_id: StringName) -> StringName:
	var cid := _find_event_instance(gs, card_def_id)
	if cid != &"":
		gs.deck_state.event_deck.erase(cid)
	return cid


## 执行 set_event_card（指定实例），pump 帧等挂起链完成，返回动作 record
## active_player_id 置为机甲归属玩家（真实游戏事件标记在我方回合移动时触发；
## start_tutorial 不设置该字段，须模拟，否则 e001 增援的 only_off_turn 判定失效挂起）
func _do_set_event(battle, mech, card_instance_id: StringName, pump: int = 4) -> Dictionary:
	if battle.context.game_state.active_player_id == &"":
		battle.context.game_state.active_player_id = mech.owner_player_id
	var result: Dictionary = battle.context.action_service.execute(&"set_event_card", {
		"mech_id": mech.mech_id,
		"event_card_id": card_instance_id,
		"source": {"mech_id": mech.mech_id},
	})
	await _pump_frames(pump)
	if typeof(result) != TYPE_DICTIONARY:
		return {"state": &"error", "message": "execute 返回异常"}
	return result


# ═══════════════════════════════════════════
# 牌堆与设置动作
# ═══════════════════════════════════════════


## 教学战斗构建事件牌堆（20种定义按 count 生成实例，≥20张）
func test_event_deck_built():
	var battle := _new_battle()
	var gs = battle.context.game_state
	var deck_size: int = gs.deck_state.event_deck.size()
	if deck_size < 20:
		return "事件牌堆应≥20张 实际%d" % deck_size
	# 全部实例均为事件牌
	for cid: StringName in gs.deck_state.event_deck:
		var card = gs.cards.get(cid)
		if card == null or card.def == null or String(card.def.card_kind) != "event":
			return "事件牌堆含非事件牌 %s" % String(cid)
	return true


## 指定实例设置：入事件槽、归属、timer=timer_count、监听器注册
func test_set_event_card_places_card():
	var battle := _new_battle()
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	var cid := _take_event_instance(gs, &"event_005")
	if cid == &"":
		return "未找到 event_005 实例（数据缺失）"
	var result: Dictionary = await _do_set_event(battle, mech, cid)
	if String(result.get("state", &"")) == &"error":
		return "set_event_card 失败: %s" % String(result.get("message", ""))
	var slot = mech.slots.get(&"event")
	if slot == null or slot.equipped_card == null:
		return "事件槽应有牌"
	if slot.equipped_card.instance_id != cid:
		return "事件槽牌实例不符"
	if slot.equipped_card.zone != &"event_slot" or slot.equipped_card.mech_id != mech.mech_id:
		return "事件牌 zone/mech_id 未设置（zone=%s mech=%s）" % [String(slot.equipped_card.zone), String(slot.equipped_card.mech_id)]
	if int(slot.equipped_card.timer) != 3:
		return "e005 timer 应=3 实际%d" % int(slot.equipped_card.timer)
	return true


## 不指定实例：抽事件牌堆顶1张
func test_set_event_card_draws_from_deck_top():
	var battle := _new_battle()
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	var deck_before: int = gs.deck_state.event_deck.size()
	if deck_before == 0:
		return "事件牌堆为空（setup 异常）"
	var top_id: StringName = gs.deck_state.event_deck[0]
	var result: Dictionary = await _do_set_event(battle, mech, &"")
	if String(result.get("state", &"")) == &"error":
		return "set_event_card 失败: %s" % String(result.get("message", ""))
	if gs.deck_state.event_deck.size() != deck_before - 1:
		return "牌堆应-1 实际%d->%d" % [deck_before, gs.deck_state.event_deck.size()]
	var slot = mech.slots.get(&"event")
	if slot == null or slot.equipped_card == null or slot.equipped_card.instance_id != top_id:
		return "事件槽应是原堆顶牌 %s" % String(top_id)
	return true


## 事件牌堆耗尽：记日志取消动作，槽保持空
func test_set_event_card_empty_deck_cancels():
	var battle := _new_battle()
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	gs.deck_state.event_deck.clear()
	var result: Dictionary = await _do_set_event(battle, mech, &"", 1)
	# handler 返回 error -> ActionEngine cancel_action，state=cancelled（非 error 字符串）
	var st := String(result.get("state", &""))
	if st != &"error" and st != &"cancelled":
		return "牌堆耗尽应取消（实际 %s）" % st
	var slot = mech.slots.get(&"event")
	if slot != null and slot.equipped_card != null:
		return "牌堆耗尽后事件槽应保持空"
	return true


## 顶掉旧事件牌：旧牌完整弃置且永久离场（zone=removed，不入任何弃牌堆）
func test_replaced_event_discarded_permanently():
	var battle := _new_battle()
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	var cid_a := _take_event_instance(gs, &"event_005")
	var cid_b := _take_event_instance(gs, &"event_007")
	if cid_a == &"" or cid_b == &"":
		return "未找到 e005/e007 实例（数据缺失）"
	await _do_set_event(battle, mech, cid_a)
	await _do_set_event(battle, mech, cid_b)
	var slot = mech.slots.get(&"event")
	if slot == null or slot.equipped_card == null or slot.equipped_card.instance_id != cid_b:
		return "第二次设置后槽内应是新牌 e007"
	var old_card = gs.cards.get(cid_a)
	if old_card == null:
		return "旧牌实例应仍存在于 gs.cards"
	if old_card.zone != &"removed":
		return "被顶掉的事件牌应永久离场（zone=%s）" % String(old_card.zone)
	# 永久离场：不入行动/装备弃牌堆
	if gs.deck_state.action_discard_pile.has(cid_a) or gs.deck_state.equipment_discard_pile.has(cid_a):
		return "事件牌不应进入任何弃牌堆"
	return true


## instant 牌（增援 e001）：设置时结算（抽2行动牌）后立即离场
func test_instant_event_resolves_and_discards():
	var battle := _new_battle()
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	var player = gs.players.get(&"player")
	if player == null:
		return "玩家不存在"
	var cid := _take_event_instance(gs, &"event_001")
	if cid == &"":
		return "未找到 e001 实例（数据缺失）"
	var hand_before: int = player.action_hand.size()
	await _do_set_event(battle, mech, cid, 8)
	var card = gs.cards.get(cid)
	if card == null:
		return "e001 实例应存在"
	if card.zone != &"removed":
		return "instant 牌结算后应永久离场（zone=%s）" % String(card.zone)
	var slot = mech.slots.get(&"event")
	if slot != null and slot.equipped_card != null:
		return "instant 牌结算后事件槽应清空"
	var drawn: int = player.action_hand.size() - hand_before
	if drawn != 2:
		return "增援应抽2张行动牌 实际%d" % drawn
	return true


# ═══════════════════════════════════════════
# 计时引擎（EventTimerService）
# ═══════════════════════════════════════════


## every_turn_end（e005 timer=3）：任意玩家回合结束都 tick，3次后到期弃置
func test_every_turn_end_ticks():
	var battle := _new_battle()
	var gs = battle.context.game_state
	var ctx = battle.context
	var mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var cid := _take_event_instance(gs, &"event_005")
	if cid == &"":
		return "未找到 e005 实例（数据缺失）"
	await _do_set_event(battle, mech, cid)
	var card = gs.cards.get(cid)
	# 敌方回合结束也 tick（every_turn_end 双方都减）
	ctx.event_timer_service.tick_on_turn_end(&"enemy")
	if int(card.timer) != 2:
		return "敌方回合结束 every_turn_end 应 tick（timer 应=2 实际%d）" % int(card.timer)
	# 我方回合结束 tick -> 1
	ctx.event_timer_service.tick_on_turn_end(&"player")
	if int(card.timer) != 1:
		return "我方回合结束应 tick（timer 应=1 实际%d）" % int(card.timer)
	# 归零：弃置（永久离场）
	ctx.event_timer_service.tick_on_turn_end(&"enemy")
	if card.zone != &"removed":
		return "计时归零应弃置（zone=%s）" % String(card.zone)
	var slot = mech.slots.get(&"event")
	if slot != null and slot.equipped_card != null:
		return "到期后事件槽应清空"
	if gs.deck_state.action_discard_pile.has(cid) or gs.deck_state.equipment_discard_pile.has(cid):
		return "到期事件牌不应入弃牌堆"
	# enemy_mech 仅用于确认存在（教学战斗应有敌方机甲）
	if enemy_mech == null:
		return "教学战斗应有敌方机甲"
	return true


## own_turn_end（e007 timer=2）：仅我方回合结束 tick
func test_own_turn_end_only_owner_ticks():
	var battle := _new_battle()
	var gs = battle.context.game_state
	var ctx = battle.context
	var mech = gs.get_mech_for_player(&"player")
	var cid := _take_event_instance(gs, &"event_007")
	if cid == &"":
		return "未找到 e007 实例（数据缺失）"
	await _do_set_event(battle, mech, cid)
	var card = gs.cards.get(cid)
	# 敌方回合结束：不 tick
	ctx.event_timer_service.tick_on_turn_end(&"enemy")
	if int(card.timer) != 2:
		return "敌方回合结束 own_turn_end 不应 tick（timer=%d）" % int(card.timer)
	# 我方回合结束：tick
	ctx.event_timer_service.tick_on_turn_end(&"player")
	if int(card.timer) != 1:
		return "我方回合结束应 tick（timer 应=1 实际%d）" % int(card.timer)
	return true


## next_own_turn_end（e011 timer=2）：设置当回合结束跳过（armed），下个我方回合结束 tick
func test_next_own_turn_end_armed_skip():
	var battle := _new_battle()
	var gs = battle.context.game_state
	var ctx = battle.context
	var mech = gs.get_mech_for_player(&"player")
	var cid := _take_event_instance(gs, &"event_011")
	if cid == &"":
		return "未找到 e011 实例（数据缺失）"
	await _do_set_event(battle, mech, cid)
	var card = gs.cards.get(cid)
	if not bool(card.counters.get("timer_armed_pending", false)):
		return "next_own_turn_end 设置时应置 armed 标志"
	# 设置当回合（我方）结束：清 armed 跳过
	ctx.event_timer_service.tick_on_turn_end(&"player")
	if int(card.timer) != 2:
		return "设置当回合结束应跳过 tick（timer 应=2 实际%d）" % int(card.timer)
	if bool(card.counters.get("timer_armed_pending", false)):
		return "armed 标志应被消费清除"
	# 敌方回合结束：不 tick
	ctx.event_timer_service.tick_on_turn_end(&"enemy")
	if int(card.timer) != 2:
		return "敌方回合结束不应 tick（timer=%d）" % int(card.timer)
	# 下个我方回合结束：tick
	ctx.event_timer_service.tick_on_turn_end(&"player")
	if int(card.timer) != 1:
		return "下个我方回合结束应 tick（timer 应=1 实际%d）" % int(card.timer)
	return true


## next_own_turn_start（e006 timer=1）：仅我方回合开始 tick；到期可选抽新牌（弹窗挂起，
## 测试驱动玩家选"抽1张新事件牌" -> 新牌设置到已清空的事件槽）
func test_next_own_turn_start_ticks_and_replaces():
	var battle := _new_battle()
	var gs = battle.context.game_state
	var ctx = battle.context
	var mech = gs.get_mech_for_player(&"player")
	var cid := _take_event_instance(gs, &"event_006")
	if cid == &"":
		return "未找到 e006 实例（数据缺失）"
	await _do_set_event(battle, mech, cid)
	var card = gs.cards.get(cid)
	# 陷落限制状态：设置时施加（不能移动/不能攻击）
	if not mech.has_status(&"cannot_move") or not mech.has_status(&"cannot_attack"):
		return "陷落应施加不能移动/不能攻击状态"
	# 敌方回合开始：不 tick
	ctx.event_timer_service.tick_on_turn_start(&"enemy")
	if int(card.timer) != 1:
		return "敌方回合开始不应 tick（timer=%d）" % int(card.timer)
	# 我方回合开始：tick 归零 -> 到期（e007 效果弹"抽新事件牌"可选窗挂起）-> 陷落离场
	ctx.event_timer_service.tick_on_turn_start(&"player")
	await _pump_frames(2)
	if card.zone != &"removed":
		return "陷落到期应离场（zone=%s）" % String(card.zone)
	# 陷落状态随离场清除
	if mech.has_status(&"cannot_move") or mech.has_status(&"cannot_attack"):
		return "陷落离场后限制状态应清除"
	# 驱动挂起的 e007 弹窗（event_timer 虚拟动作 waiting_timing）：选"抽1张新事件牌"
	var suspended := &""
	for act in ctx.action_registry.get_actions_by_type(&"event_timer"):
		if act.state == &"waiting_timing":
			suspended = act.action_id
			break
	if suspended == &"":
		return "e007 到期抽新弹窗应挂起等待玩家选择"
	# 直调效果恢复（UI 路径经 ActionUIBridge.resolve_effect_input -> 同函数）
	ctx.timing_engine.resume_pending_effect(suspended, {"chosen_option_index": 0})
	await _pump_frames(4)
	var slot = mech.slots.get(&"event")
	if slot == null or slot.equipped_card == null:
		return "到期抽新牌后事件槽应有新牌"
	if slot.equipped_card.instance_id == cid:
		return "新事件牌不应是已离场的陷落牌"
	return true


# ═══════════════════════════════════════════
# 派生加成（强化牌）
# ═══════════════════════════════════════════


## 强化·护甲（e011）：设置后总护甲+5，顶掉后恢复
func test_derived_armor_bonus():
	var battle := _new_battle()
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	var cid := _take_event_instance(gs, &"event_011")
	if cid == &"":
		return "未找到 e011 实例（数据缺失）"
	var armor_before: int = mech.get_armor()
	await _do_set_event(battle, mech, cid)
	if mech.get_armor() != armor_before + 5:
		return "强化护甲应+5（前%d 后%d）" % [armor_before, mech.get_armor()]
	# 顶掉（用另一张事件牌）：派生加成随之消失
	var cid_b := _take_event_instance(gs, &"event_005")
	await _do_set_event(battle, mech, cid_b)
	if mech.get_armor() != armor_before:
		return "事件牌离场后护甲应恢复（%d）" % mech.get_armor()
	return true


## 强化·动力（e012）：设置后动力上限+4（get_total_power 与 max_power 同步）
func test_derived_power_bonus():
	var battle := _new_battle()
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	var cid := _take_event_instance(gs, &"event_012")
	if cid == &"":
		return "未找到 e012 实例（数据缺失）"
	var power_before: int = mech.get_total_power()
	var max_before: int = mech.max_power
	await _do_set_event(battle, mech, cid)
	if mech.get_total_power() != power_before + 4:
		return "强化动力应+4（前%d 后%d）" % [power_before, mech.get_total_power()]
	if mech.max_power != max_before + 4:
		return "max_power 应同步+4（前%d 后%d）" % [max_before, mech.max_power]
	return true


## 强化·威力/范围（e013/e014）：基础武器与装备武器统计均实时加成
func test_derived_weapon_bonuses():
	var battle := _new_battle()
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	# 基础武器路径（无装备武器时 weapon 槽为空 -> get_base_weapon_effective_stats）
	var base_stats: Dictionary = _ActionPilotEffects.get_base_weapon_effective_stats(mech, 0)
	if base_stats.is_empty():
		return "教学战斗机甲应有基础武器"
	var might_before: int = int(base_stats.get("might", 0))
	var range_before: int = int(base_stats.get("range_value", 0))
	# 强化·威力（weapon_might+4）
	var cid_m := _take_event_instance(gs, &"event_013")
	if cid_m == &"":
		return "未找到 e013 实例（数据缺失）"
	await _do_set_event(battle, mech, cid_m)
	var stats_m: Dictionary = _ActionPilotEffects.get_base_weapon_effective_stats(mech, 0)
	if int(stats_m.get("might", 0)) != might_before + 4:
		return "强化威力应+4（前%d 后%d）" % [might_before, int(stats_m.get("might", 0))]
	if int(stats_m.get("range_value", 0)) != range_before:
		return "强化威力不应影响范围"
	# 顶掉威力 -> 换范围（weapon_range+2）
	var cid_r := _take_event_instance(gs, &"event_014")
	await _do_set_event(battle, mech, cid_r)
	var stats_r: Dictionary = _ActionPilotEffects.get_base_weapon_effective_stats(mech, 0)
	if int(stats_r.get("might", 0)) != might_before:
		return "威力强化离场后应恢复"
	if int(stats_r.get("range_value", 0)) != range_before + 2:
		return "强化范围应+2（前%d 后%d）" % [range_before, int(stats_r.get("range_value", 0))]
	return true


# ═══════════════════════════════════════════
# 事件标记接入
# ═══════════════════════════════════════════


## 事件标记触发：发起 set_event_card 动作，事件槽获得牌堆顶牌
func test_event_marker_triggers_set_event_card():
	var battle := _new_battle()
	var gs = battle.context.game_state
	var ctx = battle.context
	var mech = gs.get_mech_for_player(&"player")
	# 放一个事件标记在机甲旁，机甲踩上（走 _check_map_markers 真链路）
	var cell: Dictionary = _neighbor_free_cell(gs, mech)
	gs.map_state.add_marker(gs.next_id(&"marker"), int(cell.q), int(cell.r), &"EVENT")
	ctx.map_service._check_map_markers(mech, cell)
	await _pump_frames(4)
	if not gs.map_state.get_markers_at(int(cell.q), int(cell.r)).is_empty():
		return "事件标记触发后应被移除"
	var slot = mech.slots.get(&"event")
	if slot == null or slot.equipped_card == null:
		return "事件标记触发应设置事件牌到事件槽"
	if slot.equipped_card.zone != &"event_slot":
		return "事件槽牌 zone 应=event_slot（实际 %s）" % String(slot.equipped_card.zone)
	return true


## 找机甲旁一个可通行空格
func _neighbor_free_cell(gs, mech) -> Dictionary:
	for n in _HexGrid_neighbors(mech.position):
		if gs.map_state.has_cell(n) and gs.map_state.get_cell_state(n).is_passable():
			return n
	return mech.position.duplicate()


func _HexGrid_neighbors(pos: Dictionary) -> Array:
	var _HexGrid = load("res://scripts/battle/hex_grid.gd")
	return _HexGrid.neighbors(pos)


## DevModeService 事件牌管理：设置（def 建实例走完整动作链+派生生效）/改计时/弃置（永久离场+派生恢复）
func test_dev_mode_event_card_management():
	var _DevModeService = load("res://scripts/services/DevModeService.gd")
	var battle := _new_battle()
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	if battle.context.game_state.active_player_id == &"":
		battle.context.game_state.active_player_id = mech.owner_player_id
	var dev = _DevModeService.new(battle.context)

	# ① 设置：event_011（强化·护甲+5）-> 槽有牌 + timer=timer_count + 派生护甲生效
	var armor_before: int = mech.get_armor()
	var res = dev.set_event_card(&"player", &"event_011")
	if not res.get("ok", false):
		return "dev 设置事件牌失败: %s" % String(res.get("message", ""))
	await _pump_frames(4)
	var slot = mech.slots.get(&"event")
	if slot == null or slot.equipped_card == null:
		return "dev 设置后事件槽应有牌"
	var ecard = slot.equipped_card
	if ecard.def.card_id != &"event_011":
		return "dev 设置后槽内应为 event_011（实际 %s）" % String(ecard.def.card_id)
	if int(ecard.get("timer")) != int(ecard.def.timer_count):
		return "dev 设置后 timer 应=timer_count %d（实际 %d）" % [int(ecard.def.timer_count), int(ecard.get("timer"))]
	if mech.get_armor() != armor_before + 5:
		return "dev 设置后护甲应+5（前%d 后%d）" % [armor_before, mech.get_armor()]

	# ② 改计时：timer 直接改数值，不触发到期结算
	var tres = dev.set_event_timer(&"player", 1)
	if not tres.get("ok", false):
		return "dev 改计时失败: %s" % String(tres.get("message", ""))
	if int(ecard.get("timer")) != 1:
		return "dev 改计时后 timer 应=1（实际 %d）" % int(ecard.get("timer"))
	if slot.equipped_card != ecard:
		return "dev 改计时不应触发离场（牌仍在槽）"

	# ③ 弃置：槽空 + 永久离场（zone=removed 不入弃牌堆）+ 派生护甲恢复
	var dres = dev.discard_event_card(&"player")
	if not dres.get("ok", false):
		return "dev 弃置事件牌失败: %s" % String(dres.get("message", ""))
	await _pump_frames(4)
	if slot.equipped_card != null:
		return "dev 弃置后事件槽应空"
	if ecard.zone != &"removed":
		return "dev 弃置后事件牌应永久离场 zone=removed（实际 %s）" % String(ecard.zone)
	if gs.deck_state.action_discard_pile.has(ecard.instance_id) or gs.deck_state.equipment_discard_pile.has(ecard.instance_id):
		return "dev 弃置后事件牌不应入弃牌堆"
	if mech.get_armor() != armor_before:
		return "dev 弃置后护甲应恢复（%d）" % mech.get_armor()
	return true
