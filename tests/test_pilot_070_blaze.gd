## test_pilot_070_blaze.gd - 烈火（pilot_070）效果测试
##
## 烈火 1 按钮（被动）：effect_01(LISTEN ATTACK_AFTER 命中抽3打"燃"标签)。
##   权威效果：「若发动的攻击命中，则可以抽3张行动牌（这些牌本回合不占行动牌上限）。」
##   effect_01：LISTEN ATTACK_AFTER（listen_action_type=attack，优先级10）。我方机甲发起攻击
##              （SELF_MECH_IS_ATTACKER：binding mech_id == payload.attacker_id）且该攻击命中
##              （PAYLOAD_ATTACK_HIT：payload.hit==true）时，EXECUTE_GAIN_CARD 抽3张行动牌
##              （from_zone=action_deck / card_kind=action / player_id=$binding_context.player_id），
##              _tag_on_draw 给抽到的每张牌打"燃"标签（owner=抽牌玩家=效果拥有者）。
##              被动自动、无每回合限制、无弹窗。按钮1置灰+悬停显示（hide_button=false）。
##
## "燃"标签生命周期（ActionPilotEffects 通用模块，与效果绑定不绑机师）：
##   - 打标签：gain_card 的 _tag_on_draw 通用参数（抽牌即打标签，任意效果可复用）。
##   - 手牌上限/弃超限排除：list_ran_tagged_hand（app_root 预处理 + TurnService 兜底自动弃共用）。
##   - 回合结束清除：clear_all_ran_tags_for_player（TurnService 步骤7.1：弃完超限牌后清，
##     剩余燃牌恢复正常计上限）。
##   - UI 显示：card_has_ran_tag → hand_panel 显示"(燃)"后缀。
##
## 关键扩展点（本测试覆盖）：
##   1. gain_card 动作新增通用 _tag_on_draw 参数（抽牌即打运行时标签）。
##   2. 通用构建器 build_attack_hit_draw_and_tag_effect(params)（count/tag_name/reason 参数化）。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90070
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


## 设烈火为 owner_id 机甲的机师，返回 {mech, enemy_mech, card, gs, cdb, battle}；失败返回 null。
func _setup_liehuo(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var card = _make_instance(gs, cdb, "pilot_070_烈火", owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	var enemy_mech = gs.get_mech_for_player(&"enemy") if owner_id == &"player" else gs.get_mech_for_player(&"player")
	return {"card": card, "mech": mech, "enemy_mech": enemy_mech, "gs": gs, "cdb": cdb, "battle": battle}


## 构造攻击 action（fire ATTACK_AFTER 用）。record 带 attacker_id/target_id + 命中字段（hit/miss）。
func _make_attack(battle, attacker_id: StringName, target_id: StringName, weapon_range: int = 3) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_p070_atk_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {"attacker_id": attacker_id, "target_id": target_id, "weapon_range": weapon_range, "extra_range": 0}
	attack.state = &"running"
	attack.context = battle.context
	battle.context.action_registry.register(attack)
	return attack


## 清空玩家行动手牌（移回牌堆底，抽牌断言用）
func _clear_player_action_hand(battle) -> void:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	if player == null:
		return
	for cid in player.action_hand.duplicate():
		player.action_hand.erase(cid)
		var c = gs.get_card(cid)
		if c:
			c.zone = &"action_deck"
			gs.deck_state.action_deck.append(cid)


## 造一张行动牌实例并塞入 player 手牌（超限排除测试用），返回卡牌实例。
func _make_hand_action_card(battle, card_def_id: String):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var card = _make_instance(gs, cdb, card_def_id, &"player")
	if card == null:
		return null
	card.zone = &"action_hand"
	card.mech_id = gs.get_mech_for_player(&"player").mech_id
	gs.players.get(&"player").action_hand.append(card.instance_id)
	return card


# ═══════════════════════════════════════════
# 定义白盒测试
# ═══════════════════════════════════════════

## 测试1：effect_01 定义正确（LISTEN ATTACK_AFTER + attack + SELF_MECH_IS_ATTACKER +
##         PAYLOAD_ATTACK_HIT + EXECUTE_GAIN_CARD count3 _tag_on_draw 燃标签）
func test_pilot_070_effect_01_definition() -> Variant:
	var e = _ActionPilotEffects.build_pilot_effects().get(&"pilot_070_effect_01")
	if e == null:
		return "缺 pilot_070_effect_01"
	if e.mode != _TimingConst.MODE_LISTEN:
		return "effect_01 mode 应 LISTEN 实=%s" % String(e.mode)
	if e.listen_timing != _TimingConst.ATTACK_AFTER:
		return "effect_01 listen_timing 应 ATTACK_AFTER"
	if e.listen_action_type != &"attack":
		return "effect_01 listen_action_type 应 attack"
	if bool(e.hide_button):
		return "effect_01 应是按钮1（hide_button 应为 false）"
	if e.once_per_turn_key != &"":
		return "effect_01 不应有 once_per_turn_key（无每回合限制）实=%s" % String(e.once_per_turn_key)
	# 条件：SELF_MECH_IS_ATTACKER + PAYLOAD_ATTACK_HIT
	var ops: Array = []
	for c in e.conditions:
		ops.append(String(c.get("op", &"")))
	if not ops.has("SELF_MECH_IS_ATTACKER"):
		return "effect_01 应含条件 SELF_MECH_IS_ATTACKER，实际 ops=%s" % str(ops)
	if not ops.has("PAYLOAD_ATTACK_HIT"):
		return "effect_01 应含条件 PAYLOAD_ATTACK_HIT，实际 ops=%s" % str(ops)
	# actions: [EXECUTE_GAIN_CARD count=3 from action_deck + _tag_on_draw{tag_name=ran_tag}]
	var acts = e.actions
	if acts.size() != 1 or String(acts[0].get("type", &"")) != "EXECUTE_GAIN_CARD":
		return "effect_01 actions 应 [EXECUTE_GAIN_CARD]"
	var ap: Dictionary = acts[0].get("params", {})
	if int(ap.get("count", 0)) != 3:
		return "effect_01 应抽3张 实=%d" % int(ap.get("count", 0))
	if String(ap.get("from_zone", &"")) != "action_deck":
		return "effect_01 应抽行动牌（from_zone=action_deck）"
	if String(ap.get("card_kind", &"")) != "action":
		return "effect_01 card_kind 应 action"
	if String(ap.get("player_id", &"")) != "$binding_context.player_id":
		return "effect_01 player_id 应 $binding_context.player_id"
	var tag_cfg: Dictionary = ap.get("_tag_on_draw", {})
	if String(tag_cfg.get("tag_name", &"")) != "ran_tag":
		return "effect_01 _tag_on_draw.tag_name 应 ran_tag 实=%s" % str(tag_cfg.get("tag_name", &""))
	return true


## 测试2：我方攻击命中 → 抽3张行动牌，且抽到的牌都带"燃"标签
func test_pilot_070_hit_draw3_with_ran_tag() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_liehuo(battle, &"player")
	if s == null:
		return "setup 失败（缺 pilot_070_烈火）"
	var gs = s.gs
	battle.context.action_ui_bridge.context = battle.context
	_clear_player_action_hand(battle)
	var player_hand_before: int = gs.players.get(&"player").action_hand.size()
	# 我方攻击命中
	var mock_attack := _make_attack(battle, s.mech.mech_id, s.enemy_mech.mech_id, 3)
	mock_attack.record["hit"] = true
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_AFTER, mock_attack)
	await _pump_frames(6)
	var player = gs.players.get(&"player")
	if player.action_hand.size() != player_hand_before + 3:
		return "命中应抽3张行动牌 前=%d 后=%d" % [player_hand_before, player.action_hand.size()]
	# 抽到的牌都应带燃标签
	var tagged: int = 0
	for cid: StringName in player.action_hand:
		var c = gs.get_card(cid)
		if _ActionPilotEffects.card_has_ran_tag(c):
			tagged += 1
	if tagged != 3:
		return "抽到的3张牌应都带燃标签 实=%d" % tagged
	return true


## 测试3：未命中（miss=true 无 hit）→ 不抽牌、不打标签
func test_pilot_070_miss_no_draw() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_liehuo(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	battle.context.action_ui_bridge.context = battle.context
	_clear_player_action_hand(battle)
	var player_hand_before: int = gs.players.get(&"player").action_hand.size()
	var mock_attack := _make_attack(battle, s.mech.mech_id, s.enemy_mech.mech_id, 3)
	mock_attack.record["miss"] = true
	mock_attack.record["hit"] = false
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_AFTER, mock_attack)
	await _pump_frames(6)
	var player = gs.players.get(&"player")
	if player.action_hand.size() != player_hand_before:
		return "未命中不应抽牌 前=%d 后=%d" % [player_hand_before, player.action_hand.size()]
	for cid: StringName in player.action_hand:
		if _ActionPilotEffects.card_has_ran_tag(gs.get_card(cid)):
			return "未命中不应打燃标签"
	return true


## 测试4：非我方攻击（敌方攻击命中）→ 不抽牌（SELF_MECH_IS_ATTACKER 拦截）
func test_pilot_070_not_my_attack_no_draw() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_liehuo(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	battle.context.action_ui_bridge.context = battle.context
	_clear_player_action_hand(battle)
	var player_hand_before: int = gs.players.get(&"player").action_hand.size()
	# 敌方攻击命中我方
	var mock_attack := _make_attack(battle, s.enemy_mech.mech_id, s.mech.mech_id, 3)
	mock_attack.record["hit"] = true
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_AFTER, mock_attack)
	await _pump_frames(6)
	var player = gs.players.get(&"player")
	if player.action_hand.size() != player_hand_before:
		return "非我方攻击不应抽牌 前=%d 后=%d" % [player_hand_before, player.action_hand.size()]
	for cid: StringName in player.action_hand:
		if _ActionPilotEffects.card_has_ran_tag(gs.get_card(cid)):
			return "非我方攻击不应打燃标签"
	return true


## 测试5：list_ran_tagged_hand 排除燃牌 → 超限计算只数非燃牌（app_root/TurnService 共用口径）
func test_pilot_070_hand_limit_excludes_ran() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_liehuo(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	_clear_player_action_hand(battle)
	# 手牌：3张普通 + 3张带燃标签
	var plain_cards: Array = []
	for i in 3:
		var c = _make_hand_action_card(battle, "action_001_进攻")
		if c == null:
			return "造普通行动牌失败"
		plain_cards.append(c)
	var ran_cards: Array = []
	for i in 3:
		var c = _make_hand_action_card(battle, "action_001_进攻")
		if c == null:
			return "造燃牌失败"
		c.add_tag(&"ran_tag", &"player", {})
		ran_cards.append(c)
	var player = gs.players.get(&"player")
	# list_ran_tagged_hand 返回且只返回3张燃牌
	var ran_ids: Array = _ActionPilotEffects.list_ran_tagged_hand(gs, &"player")
	if ran_ids.size() != 3:
		return "list_ran_tagged_hand 应返回3张燃牌 实=%d" % ran_ids.size()
	for c in ran_cards:
		if not ran_ids.has(c.instance_id):
			return "燃牌 %s 应出现在 list_ran_tagged_hand" % String(c.instance_id)
	# 超限计算口径（app_root/TurnService 共用）：counted = hand.size - ran.size
	var counted_hand: int = player.action_hand.size() - ran_ids.size()
	if counted_hand != 3:
		return "计上限手牌应=3（6-3燃）实=%d" % counted_hand
	if counted_hand > int(player.action_card_limit):
		return "不应超限（3<=上限%d）" % int(player.action_card_limit)
	return true


## 测试6：回合结束清标签——clear_all_ran_tags_for_player 清除全部燃标签（恢复正常计上限）
func test_pilot_070_clear_ran_at_turn_end() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_liehuo(battle, &"player")
	if s == null:
		return "setup 失败"
	var gs = s.gs
	_clear_player_action_hand(battle)
	# 3张燃牌 + 1张普通牌
	var ran_cards: Array = []
	for i in 3:
		var c = _make_hand_action_card(battle, "action_001_进攻")
		if c == null:
			return "造燃牌失败"
		c.add_tag(&"ran_tag", &"player", {})
		ran_cards.append(c)
	_make_hand_action_card(battle, "action_001_进攻")
	if _ActionPilotEffects.list_ran_tagged_hand(gs, &"player").size() != 3:
		return "清前应3张燃牌"
	# 回合结束后清除（TurnService 步骤7.1）
	_ActionPilotEffects.clear_all_ran_tags_for_player(gs, &"player")
	if _ActionPilotEffects.list_ran_tagged_hand(gs, &"player").size() != 0:
		return "清后应0张燃牌"
	for c in ran_cards:
		if c.has_tag(&"ran_tag"):
			return "燃牌 %s 标签应被清除" % String(c.instance_id)
	return true
