extends RefCounted

## test_pilot_046_popup_close.gd - 霍恩(pilot_046)隐藏装面板非按钮关闭路径（Bug3）
##
## 修复前：hidden_card_view_panel 是 PopupPanel，点弹窗外/Esc/焦点丢失只发 popup_hide
## 不发 cancelled -> _hidden_view_action_id 残留 + 效果动作挂起 + ActionUIBridge 共享
## 等待槽不清 -> can_trigger_active_effect 把所有主动效果按钮置灰（按钮死，不能再点）。
## 修复后（app_root 三件套）：
##   1. popup_hide_on_focus_loss=false（切窗口不自动关）；
##   2. popup_hide -> _on_hidden_view_popup_hidden 守卫式取消（_popup_suppress_vis 模态
##      堆栈隐藏期间跳过；id 已被 acquire/cancelled 取走时幂等空转）；
##   3. acquire/cancelled 回调先取 id 再隐藏面板（visible=false 同步双发 popup_hide 不误取消）。
##
## 用脚本级 app_root 实例（面板变量 null 有守卫，_net_exec 非 PvP 只本地分发）+ 真实
## battle 驱动真实回调链：
##   1. popup_hide 路径 -> 效果取消（不扣金不消耗额度）、_hidden_view_action_id 清空、
##      共享等待槽清空（按钮锁释放）、可再触发
##   2. acquire 路径先取 id -> resume selected_card_id（进 Phase B 而非被 popup_hide 误取消）
##   3. 守卫：_popup_suppress_vis 期间 popup_hide 不误取消（id/挂起保留）
##   4. 守卫：空 id popup_hide 幂等空转不崩溃

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _AppRootScript = preload("res://scripts/app/app_root.gd")

const _W1 = "weapon_001_光束军刀"  # cost 3（N）


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90046
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	return battle


func _pump_frames(n: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for i in n:
		await tree.process_frame


func _make_instance(gs, cdb, card_def_id: String, owner_id: StringName):
	var pdef = cdb.get_card(StringName(card_def_id))
	if pdef == null:
		return null
	var inst_id: StringName = gs.next_id(&"card")
	var card = _CardInstance.new(inst_id, pdef)
	card.owner_player_id = owner_id
	gs.cards[inst_id] = card
	return card


## 设霍恩为 player 机甲机师
func _setup_horn(battle) -> Dictionary:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(&"player")
	if mech == null:
		return {}
	var card = _make_instance(gs, cdb, "pilot_046_霍恩", &"player")
	if card == null:
		return {}
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	battle.context.action_ui_bridge.context = battle.context
	return {"pilot_card": card, "mech": mech, "gs": gs, "cdb": cdb}


## 放置一张隐藏装备到商店隐藏高级槽
func _place_hidden_shop_card(battle, def_id: String) -> StringName:
	var gs = battle.context.game_state
	var card = _make_instance(gs, battle.context.card_database, def_id, &"player")
	card.zone = &"shop"
	card.face_down = true
	gs.shop_state.hidden_advanced_slot = card.instance_id
	return card.instance_id


## 触发霍恩 DIRECT 按钮（effect_01）。挂起返回 effect_fire action；未挂起返回 null。
func _fire_pilot_046(battle, pilot_card, mech, player_id: StringName) -> _Action:
	battle.context.game_state.active_player_id = player_id
	battle.context.game_state.phase = &"MAIN"
	battle.context.action_service.execute(&"effect_fire", {
		"effect_id": &"pilot_046_effect_01",
		"player_id": player_id,
		"source_mech_id": mech.mech_id,
		"card_instance_id": pilot_card.instance_id,
		"phase": &"MAIN",
		"source": {
			"card_instance_id": pilot_card.instance_id,
			"mech_id": mech.mech_id,
			"player_id": player_id,
			"effect_id": &"pilot_046_effect_01",
		},
	})
	await _pump_frames(3)
	for a in battle.context.action_registry.get_actions_by_type(&"effect_fire"):
		if a.state == &"waiting_timing":
			return a
	return null


## 脚本级 app_root（不进场景树：面板变量为 null 有守卫；_net_exec 非 PvP 只本地分发）。
## 直接挂接本测试的 battle，供 _dispatch_input("resume_effect") 路由。
func _make_app_root(battle) -> _AppRootScript:
	var app_root := _AppRootScript.new()
	app_root.battle = battle
	return app_root


# ═══════════════════════════════════════════
# Bug3 主路径：popup_hide（非按钮关闭）-> 守卫式取消 + 按钮锁释放
# ═══════════════════════════════════════════
func test_p046_popup_hide_cancels_and_unlocks() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_horn(battle)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	var player = gs.players.get(&"player")
	gs.shop_state.hidden_advanced_slot = &""
	var shop_card_id = _place_hidden_shop_card(battle, _W1)
	var gold_before: int = player.gold

	var app_root := _make_app_root(battle)
	var ef = await _fire_pilot_046(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "应挂起 Phase A（hidden_card_view）"

	# 前置：共享等待槽被挂起占用（修复前的按钮置灰锁）
	var bridge = battle.context.action_ui_bridge
	var wait_info: Dictionary = bridge.get_waiting_action_info()
	if String(wait_info.get("action_id", &"")) != String(ef.action_id):
		return "共享等待槽应指向挂起效果，实=%s" % String(wait_info.get("action_id", &""))

	# 模拟 _show_popup hidden_card_view 分支捕获动作 id
	app_root._hidden_view_action_id = ef.action_id

	# 模拟非按钮关闭（点弹窗外/Esc）：popup_hide -> _on_hidden_view_popup_hidden
	app_root._on_hidden_view_popup_hidden()
	await _pump_frames(10)

	# ① id 已清空
	if app_root._hidden_view_action_id != &"":
		return "popup_hide 取消后 _hidden_view_action_id 应清空"
	# ② 效果动作结束（不再挂起）
	if battle.context.timing_engine.has_pending_effect(ef.action_id):
		return "popup_hide 取消后效果不应仍挂起"
	var ef_after = battle.context.action_registry.get_action(ef.action_id)
	if ef_after != null and String(ef_after.state) == &"waiting_timing":
		return "popup_hide 取消后效果动作不应仍 waiting_timing"
	# ③ 共享等待槽清空（按钮锁释放--can_trigger_active_effect 恢复）
	var wait2: Dictionary = bridge.get_waiting_action_info()
	if not wait2.is_empty():
		return "popup_hide 取消后共享等待槽应清空（按钮锁释放），实=%s" % str(wait2)
	# ④ 取消不扣金不消耗额度
	if player.gold != gold_before:
		return "取消不应扣金 前=%d 后=%d" % [gold_before, player.gold]
	if gs.shop_state.hidden_advanced_slot != shop_card_id:
		return "取消不应清空商店隐藏槽"
	# ⑤ 可再触发（修复前按钮永久置灰的复现点）
	var ef2 = await _fire_pilot_046(battle, s.pilot_card, s.mech, &"player")
	if ef2 == null:
		return "popup_hide 取消后应可再次触发（按钮不应死）"
	print("P046-POPUP-HIDE-OK 取消干净、按钮锁释放、可再触发")
	return true


# ═══════════════════════════════════════════
# Bug3 顺序配套：acquire 先取 id（popup_hide 同步双发不误取消）
# ═══════════════════════════════════════════
func test_p046_acquire_takes_id_before_hide() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_horn(battle)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	gs.shop_state.hidden_advanced_slot = &""
	var shop_card_id = _place_hidden_shop_card(battle, _W1)

	var app_root := _make_app_root(battle)
	var ef = await _fire_pilot_046(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "应挂起 Phase A"
	app_root._hidden_view_action_id = ef.action_id

	# 真实 acquire 回调（内部 visible=false 会同步发 popup_hide -> 守卫见空 id 空转）
	app_root._on_hidden_view_acquire(shop_card_id)
	await _pump_frames(10)

	# acquire 应以 selected_card_id 恢复 -> 进 Phase B（hidden_reserve_slot）而非误取消
	if app_root._hidden_view_action_id != &"":
		return "acquire 后 _hidden_view_action_id 应清空"
	var p: Dictionary = battle.context.timing_engine._pending_effect.get(ef.action_id, {})
	if String(p.get("phase", &"")) != "hidden_reserve_slot":
		return "acquire 应进 Phase B hidden_reserve_slot，实=%s（误取消？）" % String(p.get("phase", &""))
	print("P046-ACQUIRE-ORDER-OK acquire 先取 id，正常进 Phase B")
	return true


# ═══════════════════════════════════════════
# Bug3 守卫：模态堆栈隐藏期间（_popup_suppress_vis）popup_hide 不误取消
# ═══════════════════════════════════════════
func test_p046_popup_hide_suppress_guard() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_horn(battle)
	if s.is_empty():
		return "setup 失败"
	var gs = s.gs
	gs.shop_state.hidden_advanced_slot = &""
	_place_hidden_shop_card(battle, _W1)

	var app_root := _make_app_root(battle)
	var ef = await _fire_pilot_046(battle, s.pilot_card, s.mech, &"player")
	if ef == null:
		return "应挂起 Phase A"
	app_root._hidden_view_action_id = ef.action_id

	# 模态堆栈隐藏下层面板期间（_present_popup 设 _popup_suppress_vis=true 后隐藏面板）：
	# popup_hide 是程序性隐藏，非用户关闭 -> 跳过取消
	app_root._popup_suppress_vis = true
	app_root._on_hidden_view_popup_hidden()
	await _pump_frames(6)
	if app_root._hidden_view_action_id != ef.action_id:
		return "_popup_suppress_vis 期间 popup_hide 不应清 id"
	if not battle.context.timing_engine.has_pending_effect(ef.action_id):
		return "_popup_suppress_vis 期间 popup_hide 不应取消挂起效果"
	app_root._popup_suppress_vis = false

	# 空 id 幂等空转：不崩溃、无副作用
	app_root._hidden_view_action_id = &""
	app_root._on_hidden_view_popup_hidden()
	await _pump_frames(3)
	# 清理：取消挂起效果避免残留
	battle.context.timing_engine.resume_pending_effect(ef.action_id, {"cancelled": true})
	await _pump_frames(6)
	print("P046-SUPPRESS-GUARD-OK 模态隐藏不误取消、空 id 幂等")
	return true
