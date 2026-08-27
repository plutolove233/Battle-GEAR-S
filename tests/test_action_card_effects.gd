## test_action_card_effects.gd — 攻击牌监听型附加效果测试
##
## 验证强袭/猛击/闪击/预判四张攻击牌的 LISTEN 附加效果生效，以及同因修复的
## 破甲命中条件、掩护威力修正。直接构造 attack 动作 + 注册临时监听器 + fire_timing。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _GeneratedActionEffects = preload("res://scripts/action_core/GeneratedActionEffects.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")


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


## 构造一个已注册的 attack 动作（running 态），返回 action
func _make_attack(battle, attacker_id: StringName, target_id: StringName, extra: Dictionary = {}) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_attack_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {
		"attacker_id": attacker_id,
		"target_id": target_id,
		"weapon_id": extra.get("weapon_id", &""),
		"weapon_might": int(extra.get("weapon_might", 5)),
		"weapon_range": int(extra.get("weapon_range", 1)),
		"target_count": 1,
	}
	attack.record.merge(extra, true)
	attack.state = &"running"
	attack.context = battle.context
	battle.context.action_registry.register(attack)
	return attack


## 把指定 card_def_id 的牌塞入玩家手牌
func _ensure_card_in_hand(battle, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
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
			return cid
	for i in range(gs.deck_state.action_discard_pile.size()):
		var cid: StringName = gs.deck_state.action_discard_pile[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_discard_pile.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			return cid
	return &""


## 注册一个 LISTEN 效果为绑定到指定 attack 的临时监听器
func _register_listen(battle, timing: StringName, attack: _Action, effect_id: StringName) -> void:
	var effects: Dictionary = _GeneratedActionEffects.build_all_effects()
	var effect = effects.get(effect_id)
	if effect == null:
		push_error("找不到效果: %s" % String(effect_id))
		return
	battle.context.timing_engine.register_temporary_listener(
		timing, attack.action_id, &"attack", effect, &"")


## ── 猛击：ATTACK_BEFORE 写 extra_might=+4 ──
func test_smash_writes_extra_might():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"weapon_might": 5})
	_register_listen(battle, _TimingConst.ATTACK_BEFORE, attack, &"smash_effect2")
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_BEFORE, attack)
	if int(attack.record.get("extra_might", 0)) != 4:
		return "猛击应写 extra_might=4，实际: %d" % int(attack.record.get("extra_might", 0))
	return true


## ── 掩护机制已重做为 LISTEN+permanent_while_in_hand+多选窗，见 test_cover_real_flow.gd ──
## （旧单步 fire_timing 测试已迁移：新机制需 CHOOSE_MANY_CARDS 弹窗选牌才写 extra_might）


## ── attack_action 伤害计算读取 extra_might ──
func test_calculate_damage_reads_extra_might():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	# 让目标护甲为0，威力5+extra_might4=9 → damage 9
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"weapon_might": 5, "hit": true})
	attack.record["extra_might"] = 4
	# 直接调 attack_action 的 _step_calculate_damage：通过 AttackAction 实例
	var AttackAction = preload("res://scripts/action_defs/attack_action.gd")
	var aa = AttackAction.new()
	aa.context = battle.context
	var result = aa._step_calculate_damage(attack)
	var damage = int(result.get("damage", -1))
	# damage = max(0, (5+4) - target_armor)。目标护甲可能非0，但至少应含 +4 威力
	# 用无 extra_might 的对照算差值
	var attack2 := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"weapon_might": 5, "hit": true})
	var result2 = aa._step_calculate_damage(attack2)
	var damage2 = int(result2.get("damage", -1))
	if damage - damage2 != 4:
		return "extra_might=4 应使伤害+4，对照=%d 加成=%d 差=%d" % [damage2, damage, damage - damage2]
	return true


## ── 破甲：ATTACK_HIT 条件——命中才 +2 markers ──
func test_armor_break_hit_adds_markers():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"hit": true})
	_register_listen(battle, _TimingConst.ATTACK_AFTER, attack, &"armor_break_effect2")
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_AFTER, attack)
	if int(attack.record.get("extra_markers", 0)) != 2:
		return "命中时破甲应写 extra_markers=2，实际: %d" % int(attack.record.get("extra_markers", 0))
	return true


## ── 破甲：未命中不触发 ──
func test_armor_break_miss_no_markers():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"hit": false})
	_register_listen(battle, _TimingConst.ATTACK_AFTER, attack, &"armor_break_effect2")
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_AFTER, attack)
	if int(attack.record.get("extra_markers", 0)) != 0:
		return "未命中时破甲不应写 extra_markers，实际: %d" % int(attack.record.get("extra_markers", 0))
	return true


## ── 强袭：ATTACK_WAS_RESPONDED 条件——被响应才触发 ──
## 强袭 effect2 的 actions 是 EXECUTE_SINGLE_MOVE（非原子），会尝试创建 single_move 效果动作。
## 单测中 single_move 会因 need_input 暂停。我们验证：responded=true 时强袭效果被执行（pending_sub_action 增加），
## responded=false 时不执行。
## 此处借用无响应窗口的 ATTACK_AFTER 隔离测试条件本身；真实 ATTACK_AT 时序由
## test_assault_chase_flow / test_assault_noncounter_response 端到端覆盖。
func test_assault_responded_triggers_move():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"responded": true})
	# 强袭需要攻击者有动力才能移动
	player_mech.power = 5
	_register_listen(battle, _TimingConst.ATTACK_AFTER, attack, &"assault_effect2")
	var before = attack.pending_effect_action_ids.size()
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_AFTER, attack)
	var after = attack.pending_effect_action_ids.size()
	if after <= before:
		return "被响应时强袭应触发移动效果动作，pending_sub_action 前=%d 后=%d" % [before, after]
	return true


func test_assault_not_responder_no_move():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"responded": false})
	player_mech.power = 5
	_register_listen(battle, _TimingConst.ATTACK_AFTER, attack, &"assault_effect2")
	var before = attack.pending_effect_action_ids.size()
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_AFTER, attack)
	var after = attack.pending_effect_action_ids.size()
	if after != before:
		return "未被响应时强袭不应触发移动，pending_sub_action 前=%d 后=%d" % [before, after]
	return true


## ── 预判：ATTACK_PRE 对目标施加锁定（非攻击者） ──
func test_predict_locks_target():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {"player_id": &"player"})
	# predict_effect2 需要 source.player_id 用于锁定来源
	attack.source = {"player_id": &"player", "mech_id": player_mech.mech_id, "card_instance_id": &"", "effect_id": &"predict_effect2"}
	_register_listen(battle, _TimingConst.ATTACK_PRE, attack, &"predict_effect2")
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_PRE, attack)
	# 敌方应被锁定
	if not enemy_mech.has_status(&"LOCKED"):
		return "预判应对目标(敌方)施加锁定，敌方 statuses: %s" % str(enemy_mech.statuses)
	# 攻击者不应被锁
	if player_mech.has_status(&"LOCKED"):
		return "预判不应锁定攻击者自身"
	return true


## ── 预判：predict_effect3 SET_ATTACK_UNNEGATABLE ──
func test_predict_unnegatable():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id)
	# 清空 target 手牌避免 ATTACK_AT 响应窗口拦截
	for cid: StringName in gs.players.get(&"enemy").action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	gs.players.get(&"enemy").action_hand.clear()
	attack.source = {"player_id": &"player", "mech_id": player_mech.mech_id, "card_instance_id": &"", "effect_id": &"predict_effect3"}
	_register_listen(battle, _TimingConst.ATTACK_AT, attack, &"predict_effect3")
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_AT, attack)
	if not attack.unnegatable:
		return "预判效果3应设 attack.unnegatable=true"
	return true


## ── 闪击：optional 弃牌挂起（_pending_effect 被设置，action 进入 waiting_timing） ──
func test_flash_optional_discard_pending():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	# 给玩家手牌塞2张行动牌（满足 HAS_ACTION_CARD_IN_HAND）
	var c1 = _ensure_card_in_hand(battle, "action_001_进攻")
	var c2 = _ensure_card_in_hand(battle, "action_001_进攻")
	if c1 == &"" or c2 == &"":
		return "无法塞入足够行动牌"
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {
		"weapon_might": 5, "weapon_range": 20, "player_id": &"player",
	})
	attack.source = {"player_id": &"player", "mech_id": player_mech.mech_id, "card_instance_id": &"", "effect_id": &"flash_effect2"}
	# 武器须在攻击者武器列表中（WEAPON_CAN_ATTACK_AGAIN 检查）
	var weapon_ids = player_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return "玩家机甲无武器"
	attack.record["weapon_id"] = weapon_ids[0]
	# 让目标在射程内：把敌方放到玩家相邻格 (3,2)
	enemy_mech.position = {"q": 3, "r": 2}
	_register_listen(battle, _TimingConst.ATTACK_SETTLE, attack, &"flash_effect2")
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_SETTLE, attack)
	# 应挂起并暂停
	if attack.state != &"waiting_timing":
		return "闪击应使 attack 暂停等待弃牌选择，state=%s" % String(attack.state)
	if not battle.context.timing_engine._pending_effect.has(attack.action_id):
		return "闪击应挂起 _pending_effect"
	# 玩家选第一张牌续跑
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"selected_action_card_ids": [c1]})
	# 选牌后应弃掉 c1
	var player = gs.players.get(&"player")
	if player.action_hand.has(c1):
		return "闪击续跑后应弃掉选中的牌"
	return true


## ── 闪击：取消则不再攻、不弃牌 ──
func test_flash_cancel_no_discard():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var c1 = _ensure_card_in_hand(battle, "action_001_进攻")
	if c1 == &"":
		return "无法塞入行动牌"
	var attack := _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {
		"weapon_might": 5, "weapon_range": 20, "player_id": &"player",
	})
	attack.source = {"player_id": &"player", "mech_id": player_mech.mech_id, "card_instance_id": &"", "effect_id": &"flash_effect2"}
	var weapon_ids = player_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return "玩家机甲无武器"
	attack.record["weapon_id"] = weapon_ids[0]
	enemy_mech.position = {"q": 3, "r": 2}
	_register_listen(battle, _TimingConst.ATTACK_SETTLE, attack, &"flash_effect2")
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_SETTLE, attack)
	var hand_before = gs.players.get(&"player").action_hand.size()
	battle.context.timing_engine.resume_pending_effect(attack.action_id, {"cancelled": true})
	var hand_after = gs.players.get(&"player").action_hand.size()
	if hand_after != hand_before:
		return "取消闪击不应弃牌，前=%d 后=%d" % [hand_before, hand_after]
	return true


## ── 回收/回忆（EXECUTE_GAIN_CARD 从弃牌堆随机获取）：UI 路径回归 ──
## 修复：ActionService._resolve_atomic_params 遇 parent_action.source 空键（UI 打牌只传
## player_id 不传 mech_id，source 里建 "mech_id":"" 键），Dictionary.get(key,默认) 返回空串
## 不落 payload 回退 -> mech_ids 为空 -> 回收/回忆从 UI 打出不把牌发给任何人。
## 走真实 UI 入口 battle.execute_use_action_card（只传 player_id/card_instance_id）。
func test_recycle_recall_from_discard_via_ui_path() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player = gs.players.get(&"player")
	# 装备弃牌堆放 1 张装备
	var equip = _make_instance(gs, cdb, "part_001_量产装_头部", &"player")
	if equip == null:
		return "找不到 part_001_量产装_头部"
	gs.deck_state.equipment_discard_pile.append(equip.instance_id)
	equip.zone = &"discard"
	# 行动弃牌堆放 1 张强袭
	var atk = _make_instance(gs, cdb, "action_002_强袭", &"player")
	if atk == null:
		return "找不到 action_002_强袭"
	gs.deck_state.action_discard_pile.append(atk.instance_id)
	atk.zone = &"discard"
	# 手牌放 回收 + 回忆
	var recycle = _make_instance(gs, cdb, "action_019_回收", &"player")
	if recycle == null:
		return "找不到 action_019_回收"
	var recall = _make_instance(gs, cdb, "action_020_回忆", &"player")
	if recall == null:
		return "找不到 action_020_回忆"
	player.action_hand.append(recycle.instance_id)
	recycle.zone = &"action_hand"
	player.action_hand.append(recall.instance_id)
	recall.zone = &"action_hand"
	var eq_before: int = player.equipment_hand.size()
	# 打回收（UI 路径，不传 mech_id/source）
	var r1: Dictionary = battle.execute_use_action_card(&"player", recycle.instance_id)
	if r1.get("state", &"error") == &"error":
		return "回收执行报错 %s" % str(r1.get("message", ""))
	await _pump_frames(3)
	if player.equipment_hand.size() != eq_before + 1:
		return "回收后装备手牌应+1（弃牌堆有牌） 前%d 后%d" % [eq_before, player.equipment_hand.size()]
	if not player.equipment_hand.has(equip.instance_id):
		return "回收应把弃牌堆的装备拿到手牌"
	# 打回忆（UI 路径）
	var r2: Dictionary = battle.execute_use_action_card(&"player", recall.instance_id)
	if r2.get("state", &"error") == &"error":
		return "回忆执行报错 %s" % str(r2.get("message", ""))
	await _pump_frames(3)
	if not player.action_hand.has(atk.instance_id):
		return "回忆应把行动弃牌堆的强袭拿到手牌"
	return true
