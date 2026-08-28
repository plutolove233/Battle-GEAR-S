## test_pilot_003_serkyr.gd - 瑟尔基尔（pilot_003）专项逻辑测试
##
## 补 test_pilot_system.gd test27/30/31 之外的缺口：
##   effect_01 多牌插入 + deck_top_card_id 置顶参数 + owner 歧义去歧义
##   effect_02 自抽路径（drawer == 瑟尔基尔拥有者）：可用强制使用 / 标签移除防重入
##   effect_03 负面用例：自抽但无正面牌 -> 不 +1；非自抽（drawer != 拥有者）跳过正面牌 -> 不 +1
##   deck 显示契约：is_face_up_in_deck / get_face_up_tag_owner
##   2金币抽牌 paid_draw_action_card（共用 draw_action_cards 基建）
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _GameConfig = preload("res://scripts/config/GameConfig.gd")
const _Action = preload("res://scripts/action_core/Action.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 12345
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	# 清空 pilot_003 静态跳过态，避免跨测试泄漏（_pilot_003_skip 为 static）
	_ActionPilotEffects._pilot_003_skip.clear()
	return battle


## 建一张牌实例并登记到 gs.cards
func _make_instance(gs, cdb, card_id: String, owner_id: StringName):
	var pdef = cdb.get_card(StringName(card_id))
	if pdef == null:
		return null
	var inst_id: StringName = gs.next_id(&"card")
	var card = _CardInstance.new(inst_id, pdef)
	card.owner_player_id = owner_id
	gs.cards[inst_id] = card
	return card


## 给某机甲装上瑟尔基尔机师牌，返回 (pilot_card, mech, player)
func _setup_selkill(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	var player = gs.players.get(owner_id)
	var card = _make_instance(gs, cdb, "pilot_003_瑟尔基尔", owner_id)
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"card": card, "mech": mech, "player": player, "gs": gs, "cdb": cdb}


# ═══════════════════════════════════════════
# effect_01：多牌插入 + deck_top_card_id 置顶 + owner 歧义
# ═══════════════════════════════════════════

## 测试1：插入3张正面牌，deck_top_card_id 指定中间一张置顶。
## 断言：3 张都在牌堆、置顶牌在 index 0、3 张都打 face_up_bury 标签、置顶牌 owner=埋牌者。
func test_effect01_multi_insert_and_top() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_selkill(battle, &"player")
	var gs = s.gs
	var ga = battle.context.game_actions
	var cards: Array = []
	for cid in ["action_001_进攻", "action_002_强袭", "action_006_闪击"]:
		var c = _make_instance(gs, s.cdb, cid, &"player")
		if c == null:
			return "找不到 %s" % cid
		s.player.action_hand.append(c.instance_id)
		cards.append(c)
	var top_card = cards[1]  # 强袭置顶
	var payload: Dictionary = {"binding_context": {"card_instance_id": s.card.instance_id, "mech_id": s.mech.mech_id, "player_id": &"player"}, "pilot_003_face_up_cards": cards.map(func(c): return c.instance_id)}
	ga.pilot_003_insert_face_up_random({"card_ids": cards.map(func(c): return c.instance_id), "deck_top_card_id": top_card.instance_id}, payload)
	# 3 张都在牌堆
	for c in cards:
		if not gs.deck_state.action_deck.has(c.instance_id):
			return "牌 %s 应在行动牌堆" % String(c.instance_id)
	# 置顶牌在 index 0
	if gs.deck_state.action_deck[0] != top_card.instance_id:
		return "置顶牌应在 index 0 实=index%d" % gs.deck_state.action_deck.find(top_card.instance_id)
	# 3 张都打 face_up_bury 标签 + owner=埋牌者
	for c in cards:
		var dc = gs.get_card(c.instance_id)
		if dc == null or not dc.is_face_up_in_deck():
			return "牌 %s 应打 face_up_bury 标签" % String(c.instance_id)
		if dc.get_face_up_tag_owner() != &"player":
			return "牌 owner 应=player 实=%s" % String(dc.get_face_up_tag_owner())
	# 置顶牌不再在手牌
	if s.player.action_hand.has(top_card.instance_id):
		return "置顶牌应已离开手牌"
	return true


## 测试2：owner 歧义去歧义——两玩家各埋1张，标签按 owner_pid 隔离。
## 断言：cardA.has_tag(face_up_bury, player)=true 而 .has_tag(face_up_bury, enemy)=false；
##       get_face_up_tag_owner 各返正确 owner。
func test_effect01_owner_disambiguation() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_selkill(battle, &"player")
	var gs = s.gs
	var ga = battle.context.game_actions
	var cardA = _make_instance(s.gs, s.cdb, "action_001_进攻", &"player")
	var cardB = _make_instance(s.gs, s.cdb, "action_002_强袭", &"enemy")
	if cardA == null or cardB == null:
		return "找不到行动牌定义"
	s.player.action_hand.append(cardA.instance_id)
	var enemy = gs.players.get(&"enemy")
	if enemy == null:
		return "enemy 不存在"
	enemy.action_hand.append(cardB.instance_id)
	# player 埋 cardA
	ga.pilot_003_insert_face_up_random({"card_ids": [cardA.instance_id], "deck_top_card_id": cardA.instance_id},
		{"binding_context": {"card_instance_id": s.card.instance_id, "mech_id": s.mech.mech_id, "player_id": &"player"}})
	# enemy 埋 cardB（owner_pid=enemy，用同一瑟尔基尔来源模拟双埋牌者）
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	ga.pilot_003_insert_face_up_random({"card_ids": [cardB.instance_id], "deck_top_card_id": cardB.instance_id},
		{"binding_context": {"card_instance_id": s.card.instance_id, "mech_id": enemy_mech.mech_id, "player_id": &"enemy"}})
	var dA = gs.get_card(cardA.instance_id)
	var dB = gs.get_card(cardB.instance_id)
	if dA.get_face_up_tag_owner() != &"player":
		return "cardA owner 应=player 实=%s" % String(dA.get_face_up_tag_owner())
	if dB.get_face_up_tag_owner() != &"enemy":
		return "cardB owner 应=enemy 实=%s" % String(dB.get_face_up_tag_owner())
	# 标签按 owner_pid 隔离：cardA 有 player 标签无 enemy 标签
	if not dA.has_tag(&"face_up_bury", &"player"):
		return "cardA 应有 player face_up_bury 标签"
	if dA.has_tag(&"face_up_bury", &"enemy"):
		return "cardA 不应有 enemy face_up_bury 标签"
	return true


## 测试2b：effect_01 非置顶牌插入位置确定性（PvP 锁步两端一致）。
## 同种子建局两次（模拟 PvP 双端），各用相同 card_ids 调 insert，非置顶牌位置必须完全一致。
## 旧实现用 context.rng.randf() 决定位置，一旦两端 rng 调用次数发散就分歧；
## 新实现用 card_instance_id.hash() % deck.size() 确定，两端 card_id 相同 -> 位置必然一致。
func test_effect01_insert_position_deterministic() -> Variant:
	var battle1 := _new_battle()
	if battle1 == null or battle1.context == null:
		return "battle1 初始化失败"
	var s1 = _setup_selkill(battle1, &"player")
	var gs1 = s1.gs
	var ga1 = battle1.context.game_actions
	var cards1: Array = []
	for cid in ["action_001_进攻", "action_002_强袭", "action_006_闪击", "action_009_防御"]:
		var c = _make_instance(gs1, s1.cdb, cid, &"player")
		if c == null:
			return "找不到 %s" % cid
		s1.player.action_hand.append(c.instance_id)
		cards1.append(c)
	var top1 = cards1[1]  # 强袭置顶
	var payload1: Dictionary = {"binding_context": {"card_instance_id": s1.card.instance_id, "mech_id": s1.mech.mech_id, "player_id": &"player"}, "pilot_003_face_up_cards": cards1.map(func(c): return c.instance_id)}
	ga1.pilot_003_insert_face_up_random({"card_ids": cards1.map(func(c): return c.instance_id), "deck_top_card_id": top1.instance_id}, payload1)
	# 第二次建局（同种子 12345，模拟 PvP 对端）
	var battle2 := _new_battle()
	if battle2 == null or battle2.context == null:
		return "battle2 初始化失败"
	var s2 = _setup_selkill(battle2, &"player")
	var gs2 = s2.gs
	var ga2 = battle2.context.game_actions
	var cards2: Array = []
	for cid in ["action_001_进攻", "action_002_强袭", "action_006_闪击", "action_009_防御"]:
		var c = _make_instance(gs2, s2.cdb, cid, &"player")
		if c == null:
			return "找不到 %s（battle2）" % cid
		s2.player.action_hand.append(c.instance_id)
		cards2.append(c)
	var top2 = cards2[1]
	var payload2: Dictionary = {"binding_context": {"card_instance_id": s2.card.instance_id, "mech_id": s2.mech.mech_id, "player_id": &"player"}, "pilot_003_face_up_cards": cards2.map(func(c): return c.instance_id)}
	ga2.pilot_003_insert_face_up_random({"card_ids": cards2.map(func(c): return c.instance_id), "deck_top_card_id": top2.instance_id}, payload2)
	# 两端 card_instance_id 相同（同种子建局 + 同序创建）-> 插入位置必须一致
	if cards1[0].instance_id != cards2[0].instance_id:
		return "两端 card instance_id 应相同（同种子建局）实=%s vs %s" % [String(cards1[0].instance_id), String(cards2[0].instance_id)]
	# 牌堆大小一致
	if gs1.deck_state.action_deck.size() != gs2.deck_state.action_deck.size():
		return "两端牌堆大小应一致 实=%d vs %d" % [gs1.deck_state.action_deck.size(), gs2.deck_state.action_deck.size()]
	# 逐张对比牌堆顺序（完全一致才算确定性）
	if gs1.deck_state.action_deck.size() != gs2.deck_state.action_deck.size():
		return "牌堆大小不一致"
	for i in range(gs1.deck_state.action_deck.size()):
		if gs1.deck_state.action_deck[i] != gs2.deck_state.action_deck[i]:
			return "牌堆 index %d 不一致：端1=%s 端2=%s" % [i, String(gs1.deck_state.action_deck[i]), String(gs2.deck_state.action_deck[i])]
	return true


# ═══════════════════════════════════════════
# effect_02：自抽路径（drawer == 瑟尔基尔拥有者）
# ═══════════════════════════════════════════

## 测试3：瑟尔基尔拥有者自己抽到自己埋的可用攻击牌 -> 强制使用（drawer==owner 不 erase 手牌分支）。
## 断言：牌不在拥有者手牌、存在强制使用 use_action_card 动作、passive 不消耗攻击数、标签清除。
func test_effect02_self_draw_usable() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_selkill(battle, &"player")
	var gs = s.gs
	var ga = battle.context.game_actions
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	# 拉近距离：player(2,2)，enemy 移到(4,2) 距离2，光束手枪 range4 可命中
	enemy_mech.position = {"q": 4, "r": 2}
	var face_card = _make_instance(s.gs, s.cdb, "action_001_进攻", &"player")
	if face_card == null:
		return "找不到 action_001_进攻"
	s.player.action_hand.append(face_card.instance_id)
	var payload: Dictionary = {"binding_context": {"card_instance_id": s.card.instance_id, "mech_id": s.mech.mech_id, "player_id": &"player"}, "pilot_003_face_up_cards": [face_card.instance_id]}
	ga.pilot_003_insert_face_up_random({"card_ids": [face_card.instance_id]}, payload)
	ga.pilot_003_move_to_deck_top(face_card.instance_id)
	# player（拥有者）自己抽1 -> 离堆 -> 强制使用
	var p1_hand_before: int = s.player.action_hand.size()
	var attack_count_before: int = s.mech.attack_count_this_turn
	ga.draw_action_cards({"player_id": &"player", "count": 1, "reason": &"test_p003_self"})
	# 牌不在 player 手牌（被强制使用，进 use_action_card 动作）
	if s.player.action_hand.has(face_card.instance_id):
		return "正面牌不应留在 player 手牌"
	# 拥有者自己抽：抽1张+被拿走使用，净增0（区别于 enemy 抽时 owner +1）
	if s.player.action_hand.size() != p1_hand_before:
		return "自抽可用：拥有者手牌净增应为0 实增=%d" % (s.player.action_hand.size() - p1_hand_before)
	# 强制使用动作存在
	var forced_use_found := false
	for ua in battle.context.action_registry.get_actions_by_type(&"use_action_card"):
		if ua.record.get("card_instance_id", &"") == face_card.instance_id:
			forced_use_found = true
			break
	if not forced_use_found:
		return "应存在强制使用 use_action_card 动作"
	# passive 不消耗攻击数
	if s.mech.attack_count_this_turn != attack_count_before:
		return "强制使用不应消耗攻击数 实=%d" % s.mech.attack_count_this_turn
	# 标签清除（防重入）
	var fc = gs.get_card(face_card.instance_id)
	if fc == null or fc.is_face_up_in_deck():
		return "face_up_bury 标签应清除（防重入）"
	return true


## 测试3b：经 gain_card 动作抽取正面可用牌 -> 延迟到 GAIN_CARD_SETTLE 作为 gain_card 子动作串行判定（问题2）。
## 区别于 test_effect02_self_draw_usable（走 draw_action_cards 原子，即时路径）：
##   经 execute("gain_card") 抽牌时，判定成为 gain_card 的子动作（use_action_card.parent_action_id == gain_card），
##   使父级动作（如攻击中抽牌）等待判定完成再继续。
func test_effect02_gain_card_deferred_usable() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_selkill(battle, &"player")
	var gs = s.gs
	var ga = battle.context.game_actions
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	enemy_mech.position = {"q": 4, "r": 2}
	var face_card = _make_instance(s.gs, s.cdb, "action_001_进攻", &"player")
	if face_card == null:
		return "找不到 action_001_进攻"
	s.player.action_hand.append(face_card.instance_id)
	var payload: Dictionary = {"binding_context": {"card_instance_id": s.card.instance_id, "mech_id": s.mech.mech_id, "player_id": &"player"}, "pilot_003_face_up_cards": [face_card.instance_id]}
	ga.pilot_003_insert_face_up_random({"card_ids": [face_card.instance_id]}, payload)
	ga.pilot_003_move_to_deck_top(face_card.instance_id)
	# 经 gain_card 动作抽1（走 GAIN_CARD_BEFORE/AFTER/SETTLE 时点）
	var gc_result: Dictionary = battle.context.action_service.execute(&"gain_card", {
		"from_zone": &"action_deck", "card_kind": &"action", "count": 1,
		"player_id": &"player", "reason": &"test_p003_deferred",
	})
	var gc_action_id: StringName = gc_result.get("action_id", &"")
	if gc_action_id == &"":
		return "gain_card 未创建"
	# 正面牌被强制使用，不在 player 手牌
	if s.player.action_hand.has(face_card.instance_id):
		return "正面牌不应留在 player 手牌"
	# 延迟路径：use_action_card 应为 gain_card 的子动作（即时路径为顶层无 parent_action_id）
	var forced_use = null
	for ua in battle.context.action_registry.get_actions_by_type(&"use_action_card"):
		if ua.record.get("card_instance_id", &"") == face_card.instance_id:
			forced_use = ua
			break
	if forced_use == null:
		return "应存在强制使用 use_action_card 动作"
	var ua_parent: StringName = forced_use.record.get("parent_action_id", &"")
	if ua_parent == &"":
		return "延迟路径：use_action_card 应有 parent_action_id（即时路径为顶层无父）"
	if ua_parent != gc_action_id:
		return "延迟路径：use_action_card.parent_action_id(%s) 应 == gain_card(%s)" % [String(ua_parent), String(gc_action_id)]
	# 标签清除
	var fc = gs.get_card(face_card.instance_id)
	if fc == null or fc.is_face_up_in_deck():
		return "face_up_bury 标签应清除"
	return true


## 测试3c：经 gain_card 动作抽取正面不可用牌（防御）-> 延迟到 SETTLE 弃置+补偿抽（EXECUTE_GAIN_CARD 子动作串行）。
func test_effect02_gain_card_deferred_unusable() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_selkill(battle, &"player")
	var gs = s.gs
	var ga = battle.context.game_actions
	var face_card = _make_instance(s.gs, s.cdb, "action_009_防御", &"player")
	if face_card == null:
		return "找不到 action_009_防御"
	s.player.action_hand.append(face_card.instance_id)
	var payload: Dictionary = {"binding_context": {"card_instance_id": s.card.instance_id, "mech_id": s.mech.mech_id, "player_id": &"player"}, "pilot_003_face_up_cards": [face_card.instance_id]}
	ga.pilot_003_insert_face_up_random({"card_ids": [face_card.instance_id]}, payload)
	ga.pilot_003_move_to_deck_top(face_card.instance_id)
	var p1_hand_before: int = s.player.action_hand.size()
	# 经 gain_card 动作抽1
	var gc_result: Dictionary = battle.context.action_service.execute(&"gain_card", {
		"from_zone": &"action_deck", "card_kind": &"action", "count": 1,
		"player_id": &"player", "reason": &"test_p003_deferred_unusable",
	})
	var gc_action_id: StringName = gc_result.get("action_id", &"")
	if gc_action_id == &"":
		return "gain_card 未创建"
	# 不可用 -> 弃置 + 补偿抽（拥有者净增1：抽防御+弃防御+补偿抽1）
	if not gs.deck_state.action_discard_pile.has(face_card.instance_id):
		var fc = gs.get_card(face_card.instance_id)
		return "正面牌应进弃牌堆（zone=%s）" % (String(fc.zone) if fc else "null")
	if s.player.action_hand.size() != p1_hand_before + 1:
		return "延迟不可用：拥有者手牌净增应=1 实增=%d" % (s.player.action_hand.size() - p1_hand_before)
	# 延迟路径与即时路径行为一致（弃置+补偿抽），parenting 机制由 test_effect02_gain_card_deferred_usable
	# （use_action_card 为 gain_card 子动作）证明；此处补偿 gain_card 同步完成后被注册表清理，不可观测 parenting。
	var fc2 = gs.get_card(face_card.instance_id)
	if fc2 == null or fc2.is_face_up_in_deck():
		return "face_up_bury 标签应清除"
	return true


## 测试3d：攻击中经 gain_card 子动作抽正面牌 -> 攻击等待判定完成（问题2用户场景）。
## 链：attack ->(execute_sub_action gain_card)-> gain_card ->(SETTLE延迟判定)-> use_action_card。
## 断言等待链完整：use_action_card.parent==gain_card, gain_card.parent==attack, attack.pending 含 gain_card。
func test_effect02_gain_card_during_attack_waits() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_selkill(battle, &"player")
	var gs = s.gs
	var ga = battle.context.game_actions
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	enemy_mech.position = {"q": 4, "r": 2}
	# 构造进行中 attack（enemy 攻击 player 瑟尔基尔，未到 check_hit）
	var running_attack := _make_running_attack(battle, enemy_mech.mech_id, s.mech.mech_id)
	var face_card = _make_instance(s.gs, s.cdb, "action_001_进攻", &"player")
	if face_card == null:
		return "找不到 action_001_进攻"
	s.player.action_hand.append(face_card.instance_id)
	var payload: Dictionary = {"binding_context": {"card_instance_id": s.card.instance_id, "mech_id": s.mech.mech_id, "player_id": &"player"}, "pilot_003_face_up_cards": [face_card.instance_id]}
	ga.pilot_003_insert_face_up_random({"card_ids": [face_card.instance_id]}, payload)
	ga.pilot_003_move_to_deck_top(face_card.instance_id)
	# 攻击子动作抽1（gain_card 作为 attack 子动作；走 GAIN_CARD_SETTLE 延迟判定）
	var gc_result: Dictionary = battle.context.action_service.execute_sub_action(
		{"type": &"EXECUTE_GAIN_CARD", "params": {"from_zone": &"action_deck", "card_kind": &"action", "count": 1, "player_id": &"player", "reason": &"test_attack_draw"}},
		{}, running_attack)
	var gc_action_id: StringName = gc_result.get("action_id", &"")
	if gc_action_id == &"":
		return "gain_card 子动作未创建"
	# use_action_card 为 gain_card 子动作（延迟路径，挂起 select_weapon 故仍在注册表）
	var forced_use = null
	for ua in battle.context.action_registry.get_actions_by_type(&"use_action_card"):
		if ua.record.get("card_instance_id", &"") == face_card.instance_id:
			forced_use = ua
			break
	if forced_use == null:
		return "应存在强制使用 use_action_card 动作"
	if forced_use.record.get("parent_action_id", &"") != gc_action_id:
		return "use_action_card.parent(%s) 应 == gain_card(%s)" % [String(forced_use.record.get("parent_action_id", &"")), String(gc_action_id)]
	# gain_card 为 attack 子动作
	var gc_action = battle.context.action_registry.get_action(gc_action_id)
	if gc_action == null:
		return "gain_card 应仍在注册表（等待判定完成，未清理）"
	if gc_action.record.get("parent_action_id", &"") != running_attack.action_id:
		return "gain_card.parent(%s) 应 == attack(%s)" % [String(gc_action.record.get("parent_action_id", &"")), String(running_attack.action_id)]
	# attack 等待 gain_card 完成（pending_effect_action_ids 含 gain_card）
	if not running_attack.pending_effect_action_ids.has(gc_action_id):
		return "attack 应等待 gain_card（pending_effect_action_ids 含 gain_card）"
	# gain_card 等待 use_action_card 完成（pending 含 use_action_card）
	if not gc_action.pending_effect_action_ids.has(forced_use.action_id):
		return "gain_card 应等待 use_action_card（pending_effect_action_ids 含 use_action_card）"
	var fc = gs.get_card(face_card.instance_id)
	if fc == null or fc.is_face_up_in_deck():
		return "face_up_bury 标签应清除"
	return true


## 测试4：瑟尔基尔拥有者自己抽到自己埋的不可用牌（防御）-> 弃置 + 拥有者抽1补偿。
## 断言：牌进弃牌堆、拥有者手牌净增1（自抽补偿）、标签清除。
func test_effect02_self_draw_unusable() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_selkill(battle, &"player")
	var gs = s.gs
	var ga = battle.context.game_actions
	var face_card = _make_instance(s.gs, s.cdb, "action_009_防御", &"player")
	if face_card == null:
		return "找不到 action_009_防御"
	s.player.action_hand.append(face_card.instance_id)
	var payload: Dictionary = {"binding_context": {"card_instance_id": s.card.instance_id, "mech_id": s.mech.mech_id, "player_id": &"player"}, "pilot_003_face_up_cards": [face_card.instance_id]}
	ga.pilot_003_insert_face_up_random({"card_ids": [face_card.instance_id]}, payload)
	ga.pilot_003_move_to_deck_top(face_card.instance_id)
	var p1_hand_before: int = s.player.action_hand.size()
	# player（拥有者）自己抽1 -> 不可用 -> 弃置 + 拥有者抽1补偿
	ga.draw_action_cards({"player_id": &"player", "count": 1, "reason": &"test_p003_self_unusable"})
	# 牌进弃牌堆
	if not gs.deck_state.action_discard_pile.has(face_card.instance_id):
		var fc = gs.get_card(face_card.instance_id)
		return "正面牌应进弃牌堆（zone=%s）" % (String(fc.zone) if fc else "null")
	# 拥有者净增1：抽1+弃1+补偿抽1
	if s.player.action_hand.size() != p1_hand_before + 1:
		return "自抽不可用：拥有者手牌净增应=1 实增=%d" % (s.player.action_hand.size() - p1_hand_before)
	# 标签清除
	var fc2 = gs.get_card(face_card.instance_id)
	if fc2 == null or fc2.is_face_up_in_deck():
		return "face_up_bury 标签应清除"
	return true


## 测试4b：维修正面牌（需选目标，自动抽牌无人选）-> unusable 弃置+抽1，不 force_use 挂起。
## 问题1修复：_pilot_003_can_use_card 对辅助牌预检 target_rules 非 NO_TARGET -> false。
func test_effect02_repair_unusable() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_selkill(battle, &"player")
	var gs = s.gs
	var ga = battle.context.game_actions
	var face_card = _make_instance(s.gs, s.cdb, "action_013_维修", &"player")
	if face_card == null:
		return "找不到 action_013_维修"
	s.player.action_hand.append(face_card.instance_id)
	var payload: Dictionary = {"binding_context": {"card_instance_id": s.card.instance_id, "mech_id": s.mech.mech_id, "player_id": &"player"}, "pilot_003_face_up_cards": [face_card.instance_id]}
	ga.pilot_003_insert_face_up_random({"card_ids": [face_card.instance_id]}, payload)
	ga.pilot_003_move_to_deck_top(face_card.instance_id)
	var p1_hand_before: int = s.player.action_hand.size()
	ga.draw_action_cards({"player_id": &"player", "count": 1, "reason": &"test_p003_repair"})
	# 维修需选目标 -> 不可用 -> 弃置（不 force_use 挂起）
	if not gs.deck_state.action_discard_pile.has(face_card.instance_id):
		var fc = gs.get_card(face_card.instance_id)
		return "维修正面牌应进弃牌堆（unusable）实=%s" % (String(fc.zone) if fc else "null")
	# 拥有者净增1（自抽：抽维修+弃维修+补偿抽1）
	if s.player.action_hand.size() != p1_hand_before + 1:
		return "维修 unusable：拥有者手牌净增应=1 实增=%d" % (s.player.action_hand.size() - p1_hand_before)
	var fc2 = gs.get_card(face_card.instance_id)
	if fc2 == null or fc2.is_face_up_in_deck():
		return "face_up_bury 标签应清除"
	return true


## 测试4c：掩护正面牌（依赖攻击上下文 MODIFY_ATTACK_MIGHT，自动抽牌无进行中攻击）-> unusable 弃置+抽1。
## 问题1修复：effect actions 含 MODIFY_ATTACK_* 且无攻击上下文 -> false。
func test_effect02_cover_unusable() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_selkill(battle, &"player")
	var gs = s.gs
	var ga = battle.context.game_actions
	var face_card = _make_instance(s.gs, s.cdb, "action_016_掩护", &"player")
	if face_card == null:
		return "找不到 action_016_掩护"
	s.player.action_hand.append(face_card.instance_id)
	var payload: Dictionary = {"binding_context": {"card_instance_id": s.card.instance_id, "mech_id": s.mech.mech_id, "player_id": &"player"}, "pilot_003_face_up_cards": [face_card.instance_id]}
	ga.pilot_003_insert_face_up_random({"card_ids": [face_card.instance_id]}, payload)
	ga.pilot_003_move_to_deck_top(face_card.instance_id)
	var p1_hand_before: int = s.player.action_hand.size()
	ga.draw_action_cards({"player_id": &"player", "count": 1, "reason": &"test_p003_cover"})
	if not gs.deck_state.action_discard_pile.has(face_card.instance_id):
		var fc = gs.get_card(face_card.instance_id)
		return "掩护正面牌应进弃牌堆（unusable）实=%s" % (String(fc.zone) if fc else "null")
	if s.player.action_hand.size() != p1_hand_before + 1:
		return "掩护 unusable：拥有者手牌净增应=1 实增=%d" % (s.player.action_hand.size() - p1_hand_before)
	var fc2 = gs.get_card(face_card.instance_id)
	if fc2 == null or fc2.is_face_up_in_deck():
		return "face_up_bury 标签应清除"
	return true


## 测试4d：锁定正面牌（CHOOSE_OTHER_MECH，可选目标）-> force_use 强制使用，挂起等待人类选目标，不弃置。
## 问题1修复：_pilot_003_can_use_card 放行 CHOOSE_OTHER_MECH（锁定/联合），仅拒绝需选武器/相邻/攻击上下文的牌。
func test_effect02_lock_force_use() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_selkill(battle, &"player")
	var gs = s.gs
	var ga = battle.context.game_actions
	var face_card = _make_instance(s.gs, s.cdb, "action_023_锁定", &"player")
	if face_card == null:
		return "找不到 action_023_锁定"
	s.player.action_hand.append(face_card.instance_id)
	var payload: Dictionary = {"binding_context": {"card_instance_id": s.card.instance_id, "mech_id": s.mech.mech_id, "player_id": &"player"}, "pilot_003_face_up_cards": [face_card.instance_id]}
	ga.pilot_003_insert_face_up_random({"card_ids": [face_card.instance_id]}, payload)
	ga.pilot_003_move_to_deck_top(face_card.instance_id)
	var p1_hand_before: int = s.player.action_hand.size()
	ga.draw_action_cards({"player_id": &"player", "count": 1, "reason": &"test_p003_lock"})
	# 锁定可选目标 -> force_use，不进弃牌堆
	if gs.deck_state.action_discard_pile.has(face_card.instance_id):
		return "锁定正面牌应被 force_use，不应进弃牌堆"
	# 牌不在 player 手牌（被 force_use 移走）
	if s.player.action_hand.has(face_card.instance_id):
		return "锁定正面牌不应留在 player 手牌"
	# 存在强制使用 use_action_card 且挂起等待选目标
	var forced_ua = null
	for ua in battle.context.action_registry.get_actions_by_type(&"use_action_card"):
		if ua.record.get("card_instance_id", &"") == face_card.instance_id:
			forced_ua = ua
			break
	if forced_ua == null:
		return "应存在强制使用 use_action_card 动作"
	if not (forced_ua.state == &"waiting_input" or forced_ua.state == &"waiting_timing" or forced_ua.state == &"waiting_effect_action"):
		return "锁定 force_use 应挂起等待选目标 实=%s" % String(forced_ua.state)
	# 标签清除
	var fc = gs.get_card(face_card.instance_id)
	if fc == null or fc.is_face_up_in_deck():
		return "face_up_bury 标签应清除"
	return true


## 测试4e：联合正面牌（CHOOSE_OTHER_MECH + ADD_STATUS unite）-> force_use 使用联合效果，挂起等选目标，不弃置抽1。
## 问题1修复：联合应使用其效果（非 unusable 弃置+抽1）。
func test_effect02_unite_force_use() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_selkill(battle, &"player")
	var gs = s.gs
	var ga = battle.context.game_actions
	var face_card = _make_instance(s.gs, s.cdb, "action_018_联合", &"player")
	if face_card == null:
		return "找不到 action_018_联合"
	s.player.action_hand.append(face_card.instance_id)
	var payload: Dictionary = {"binding_context": {"card_instance_id": s.card.instance_id, "mech_id": s.mech.mech_id, "player_id": &"player"}, "pilot_003_face_up_cards": [face_card.instance_id]}
	ga.pilot_003_insert_face_up_random({"card_ids": [face_card.instance_id]}, payload)
	ga.pilot_003_move_to_deck_top(face_card.instance_id)
	ga.draw_action_cards({"player_id": &"player", "count": 1, "reason": &"test_p003_unite"})
	# 联合应使用效果 -> force_use，不进弃牌堆
	if gs.deck_state.action_discard_pile.has(face_card.instance_id):
		return "联合正面牌应被 force_use 使用效果，不应进弃牌堆"
	if s.player.action_hand.has(face_card.instance_id):
		return "联合正面牌不应留在 player 手牌"
	var forced_ua = null
	for ua in battle.context.action_registry.get_actions_by_type(&"use_action_card"):
		if ua.record.get("card_instance_id", &"") == face_card.instance_id:
			forced_ua = ua
			break
	if forced_ua == null:
		return "应存在强制使用 use_action_card 动作"
	if not (forced_ua.state == &"waiting_input" or forced_ua.state == &"waiting_timing" or forced_ua.state == &"waiting_effect_action"):
		return "联合 force_use 应挂起等待选目标 实=%s" % String(forced_ua.state)
	var fc = gs.get_card(face_card.instance_id)
	if fc == null or fc.is_face_up_in_deck():
		return "face_up_bury 标签应清除"
	return true


## 测试4f：多张正面牌同时离堆串行（先来后到）-- 锁定（force_use 挂起）阻塞后续防御（unusable）。
## 问题2修复：_p003_e02_queue 串行队列，force_use 挂起时 active=true，后续牌入队等待，
## 不抢占处理。抽2张（顶=锁定，次=防御）：锁定 force_use 挂起 -> 防御入队未处理（不进弃牌堆、仍在手牌）。
func test_effect02_serial_queue_force_then_wait() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_selkill(battle, &"player")
	var gs = s.gs
	var ga = battle.context.game_actions
	var lock_card = _make_instance(s.gs, s.cdb, "action_023_锁定", &"player")
	var defend_card = _make_instance(s.gs, s.cdb, "action_009_防御", &"player")
	if lock_card == null or defend_card == null:
		return "找不到锁定/防御牌定义"
	s.player.action_hand.append(lock_card.instance_id)
	s.player.action_hand.append(defend_card.instance_id)
	var payload: Dictionary = {"binding_context": {"card_instance_id": s.card.instance_id, "mech_id": s.mech.mech_id, "player_id": &"player"}, "pilot_003_face_up_cards": [lock_card.instance_id, defend_card.instance_id]}
	# 插入2张，锁定置顶（index 0）
	ga.pilot_003_insert_face_up_random({"card_ids": [lock_card.instance_id, defend_card.instance_id], "deck_top_card_id": lock_card.instance_id}, payload)
	# 确保防御紧跟锁定（index 1），保证抽牌顺序：先锁定后防御
	var deck: Array = gs.deck_state.action_deck
	var dpos: int = deck.find(defend_card.instance_id)
	if dpos != 1:
		deck.remove_at(dpos)
		deck.insert(1, defend_card.instance_id)
	# 抽2张：锁定先离堆 force_use 挂起，防御后离堆入队等待
	ga.draw_action_cards({"player_id": &"player", "count": 2, "reason": &"test_p003_serial"})
	# 锁定 force_use 挂起
	var lock_ua = null
	for ua in battle.context.action_registry.get_actions_by_type(&"use_action_card"):
		if ua.record.get("card_instance_id", &"") == lock_card.instance_id:
			lock_ua = ua
			break
	if lock_ua == null:
		return "锁定应 force_use 创建 use_action_card"
	if not (lock_ua.state == &"waiting_input" or lock_ua.state == &"waiting_timing" or lock_ua.state == &"waiting_effect_action"):
		return "锁定应挂起等待选目标 实=%s" % String(lock_ua.state)
	# 防御应仍在队列等待，未被处理：不进弃牌堆、仍在 player 手牌
	if gs.deck_state.action_discard_pile.has(defend_card.instance_id):
		return "锁定挂起时防御应等待，不应先弃置（串行先来后到）"
	if not s.player.action_hand.has(defend_card.instance_id):
		return "防御未被处理时应仍在 player 手牌"
	return true


# ═══════════════════════════════════════════
# effect_02 即时生效（immediate-use）：攻击进行中正面牌离堆即时使用
# ═══════════════════════════════════════════

## 构造一个进行中 attack 动作并注册（模拟 ATTACK_PRE 阶段，未到判断命中 idx<4）。
## attacker=攻击方机甲，target=被攻击方机甲。返回 attack 动作实例。
func _make_running_attack(battle, attacker_id: StringName, target_id: StringName, extra: Dictionary = {}) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_imm_%d" % [battle.context.action_registry.get_active_count() + 1000]
	attack.action_type = &"attack"
	attack.record = {
		"attacker_id": attacker_id,
		"target_id": target_id,
		"weapon_might": int(extra.get("weapon_might", 5)),
		"weapon_range": int(extra.get("weapon_range", 4)),
		"target_count": 1,
	}
	attack.record.merge(extra, true)
	# idx=2 对应 select_target(ATTACK_PRE)，未到 check_hit(idx=4)
	attack.current_step_index = 2
	attack.state = &"running"
	attack.context = battle.context
	battle.context.action_registry.register(attack)
	return attack


## 测试4g：迎击牌（防御）即时生效--瑟尔基尔被攻击时正面防御牌离堆 -> 强制使用 -> 攻击标记已响应。
## 不走 unusable（防御有 AVAILABILITY，can_use_card 返 false），而是即时生效 force_use 带 attack_action_id。
## 防御 effect1=RESPOND_ATTACK+护甲+5+损伤-1，NO_TARGET 同步完成。
func test_effect02_immediate_counter_defend() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_selkill(battle, &"player")
	var gs = s.gs
	var ga = battle.context.game_actions
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	# enemy 攻击 player(瑟尔基尔) -> 构造进行中 attack（target=player mech）
	var running_attack := _make_running_attack(battle, enemy_mech.mech_id, s.mech.mech_id)
	var face_card = _make_instance(s.gs, s.cdb, "action_009_防御", &"player")
	if face_card == null:
		return "找不到 action_009_防御"
	s.player.action_hand.append(face_card.instance_id)
	var payload: Dictionary = {"binding_context": {"card_instance_id": s.card.instance_id, "mech_id": s.mech.mech_id, "player_id": &"player"}, "pilot_003_face_up_cards": [face_card.instance_id]}
	ga.pilot_003_insert_face_up_random({"card_ids": [face_card.instance_id]}, payload)
	ga.pilot_003_move_to_deck_top(face_card.instance_id)
	var p1_hand_before: int = s.player.action_hand.size()
	# 在 attack 进行中抽1张（正面防御牌离堆）-> 即时生效 force_use
	ga.draw_action_cards({"player_id": &"player", "count": 1, "reason": &"test_imm_counter"})
	# 防御应被即时使用：牌进弃牌堆（use_action_card settle 弃牌），不在手牌
	if not gs.deck_state.action_discard_pile.has(face_card.instance_id):
		return "防御应被即时使用后进弃牌堆（settle 弃牌）"
	if s.player.action_hand.has(face_card.instance_id):
		return "防御正面牌应被 force_use 移走（不在手牌）"
	# 拥有者净增0（自抽：抽1+被即时使用移走，无补偿抽1，区别于 unusable 净增1）
	if s.player.action_hand.size() != p1_hand_before:
		return "即时生效使用：拥有者手牌净增应为0（无补偿抽1）实增=%d" % (s.player.action_hand.size() - p1_hand_before)
	# 攻击应被标记已响应（迎击牌 RESPOND_ATTACK 写 responded=true）
	if not bool(running_attack.record.get("responded", false)):
		return "迎击牌即时生效后攻击应标记已响应 实=%s" % str(running_attack.record.get("responded", false))
	# 标签清除
	var fc = gs.get_card(face_card.instance_id)
	if fc == null or fc.is_face_up_in_deck():
		return "face_up_bury 标签应清除"
	return true


## 测试4h：掩护牌即时生效--瑟尔基尔范围内机甲被攻击时正面掩护牌离堆 -> 强制使用 -> 攻击威力-5。
## 掩护不标记已响应（可与迎击牌共存）。
func test_effect02_immediate_cover_minus_might() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_selkill(battle, &"player")
	var gs = s.gs
	var ga = battle.context.game_actions
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var player_mech = s.mech
	# enemy 攻击 player 自身（在掩护范围内=自身）-> 构造进行中 attack
	var running_attack := _make_running_attack(battle, enemy_mech.mech_id, player_mech.mech_id, {"weapon_might": 10})
	var face_card = _make_instance(s.gs, s.cdb, "action_016_掩护", &"player")
	if face_card == null:
		return "找不到 action_016_掩护"
	s.player.action_hand.append(face_card.instance_id)
	var payload: Dictionary = {"binding_context": {"card_instance_id": s.card.instance_id, "mech_id": s.mech.mech_id, "player_id": &"player"}, "pilot_003_face_up_cards": [face_card.instance_id]}
	ga.pilot_003_insert_face_up_random({"card_ids": [face_card.instance_id]}, payload)
	ga.pilot_003_move_to_deck_top(face_card.instance_id)
	# 在 attack 进行中抽1张（正面掩护牌离堆）-> 即时生效 force_use -5
	ga.draw_action_cards({"player_id": &"player", "count": 1, "reason": &"test_imm_cover"})
	# 掩护应被即时使用后进弃牌堆（settle 弃牌），不在手牌
	if not gs.deck_state.action_discard_pile.has(face_card.instance_id):
		return "掩护应被即时使用后进弃牌堆（settle 弃牌）"
	if s.player.action_hand.has(face_card.instance_id):
		return "掩护正面牌应被 force_use 移走（不在手牌）"
	# 攻击威力应-5（MODIFY_ATTACK_MIGHT 写 attack.record["extra_might"]）
	var might_after: int = int(running_attack.record.get("extra_might", 0))
	if might_after != -5:
		return "掩护即时生效后攻击威力应-5 实=%d" % might_after
	# 掩护不标记已响应（可与迎击牌共存）
	if bool(running_attack.record.get("responded", false)):
		return "掩护不应标记攻击已响应（可与迎击牌共存）"
	return true


## 测试4i：迎击牌无即时生效条件时 unusable--无进行中攻击时正面防御牌离堆 -> unusable 弃置+抽1。
func test_effect02_immediate_counter_no_attack_unusable() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_selkill(battle, &"player")
	var gs = s.gs
	var ga = battle.context.game_actions
	# 无进行中攻击（回合抽牌场景）
	var face_card = _make_instance(s.gs, s.cdb, "action_009_防御", &"player")
	if face_card == null:
		return "找不到 action_009_防御"
	s.player.action_hand.append(face_card.instance_id)
	var payload: Dictionary = {"binding_context": {"card_instance_id": s.card.instance_id, "mech_id": s.mech.mech_id, "player_id": &"player"}, "pilot_003_face_up_cards": [face_card.instance_id]}
	ga.pilot_003_insert_face_up_random({"card_ids": [face_card.instance_id]}, payload)
	ga.pilot_003_move_to_deck_top(face_card.instance_id)
	var p1_hand_before: int = s.player.action_hand.size()
	ga.draw_action_cards({"player_id": &"player", "count": 1, "reason": &"test_imm_no_attack"})
	# 无即时生效条件 -> unusable 弃置 + 抽1补偿
	if not gs.deck_state.action_discard_pile.has(face_card.instance_id):
		return "无攻击时迎击牌应 unusable 弃置"
	if s.player.action_hand.size() != p1_hand_before + 1:
		return "unusable 应净增1（弃1+补偿抽1）实增=%d" % (s.player.action_hand.size() - p1_hand_before)
	return true


## 测试4j：双迎击牌串行--第1张迎击即时生效标记已响应后，第2张迎击 unusable（一次响应限制）。
## 抽2张（顶=防御1，次=防御2）：防御1即时生效标 responded -> 防御2 已响应不再即时生效 -> unusable 弃置+抽1。
func test_effect02_immediate_double_counter_second_unusable() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_selkill(battle, &"player")
	var gs = s.gs
	var ga = battle.context.game_actions
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var running_attack := _make_running_attack(battle, enemy_mech.mech_id, s.mech.mech_id)
	var card_a = _make_instance(s.gs, s.cdb, "action_009_防御", &"player")
	var card_b = _make_instance(s.gs, s.cdb, "action_009_防御", &"player")
	if card_a == null or card_b == null:
		return "找不到 action_009_防御"
	s.player.action_hand.append(card_a.instance_id)
	s.player.action_hand.append(card_b.instance_id)
	var payload: Dictionary = {"binding_context": {"card_instance_id": s.card.instance_id, "mech_id": s.mech.mech_id, "player_id": &"player"}, "pilot_003_face_up_cards": [card_a.instance_id, card_b.instance_id]}
	ga.pilot_003_insert_face_up_random({"card_ids": [card_a.instance_id, card_b.instance_id], "deck_top_card_id": card_a.instance_id}, payload)
	# 确保顺序：顶=card_a，次=card_b
	var deck: Array = gs.deck_state.action_deck
	var bpos: int = deck.find(card_b.instance_id)
	if bpos != 1:
		deck.remove_at(bpos)
		deck.insert(1, card_b.instance_id)
	var p1_hand_before: int = s.player.action_hand.size()
	# 抽2张：card_a 先离堆即时生效标记已响应，card_b 后离堆已响应 -> unusable
	ga.draw_action_cards({"player_id": &"player", "count": 2, "reason": &"test_imm_double"})
	# card_a 即时使用进弃牌堆，card_b unusable 也进弃牌堆
	if not gs.deck_state.action_discard_pile.has(card_a.instance_id):
		return "防御A应即时使用进弃牌堆"
	if not gs.deck_state.action_discard_pile.has(card_b.instance_id):
		return "防御B应 unusable 进弃牌堆（attack 已响应）"
	# 攻击标记已响应（由 card_a 的 RESPOND_ATTACK 写）
	if not bool(running_attack.record.get("responded", false)):
		return "防御A即时生效后攻击应标记已响应"
	# 拥有者净增1：抽2张(A即时用+B unusable弃+补偿抽1)，A被即时用无补偿，B unusable补偿抽1 -> 2-2+1=1
	if s.player.action_hand.size() != p1_hand_before + 1:
		return "双迎击：拥有者净增应=1（A即时用无补偿+B unusable补偿抽1）实增=%d" % (s.player.action_hand.size() - p1_hand_before)
	return true


# ═══════════════════════════════════════════
# effect_03：负面用例（+1 不生效边界）
# ═══════════════════════════════════════════

## 测试5：自抽但牌堆无正面牌 -> 不 +1（修复点：旧逻辑无条件 +1）。
## 瑟尔基尔拥有者勾选自己，抽1张但没跳过任何正面牌 -> 仅抽1张。
func test_effect03_self_skip_no_faceup_no_plus() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_selkill(battle, &"player")
	var gs = s.gs
	var ga = battle.context.game_actions
	# 勾选自己（self-skip 激活），但不插入任何正面牌
	ga.toggle_pilot_003_skip({"enable": true}, {"binding_context": {"card_instance_id": s.card.instance_id, "player_id": &"player"}})
	if not _ActionPilotEffects.is_pilot_003_self_skip_active(&"player", gs):
		return "self-skip 应激活"
	if gs.deck_state.action_deck.size() < 2:
		return "牌堆不足测试"
	var hand_before: int = s.player.action_hand.size()
	# 抽1张：牌堆无正面牌 -> 不跳过 -> 不 +1 -> 仅抽1张
	ga.draw_action_cards({"player_id": &"player", "count": 1, "reason": &"test_p003_noface"})
	if s.player.action_hand.size() != hand_before + 1:
		return "无正面牌时不应 +1，应抽1张 实增=%d" % (s.player.action_hand.size() - hand_before)
	return true


## 测试6：非自抽（drawer != 拥有者）即使跳过正面牌也不 +1。
## 瑟尔基尔拥有者=player，勾选 enemy（skip 对 enemy 生效），enemy 抽1跳过正面牌，
## 但 drawer(enemy) != 拥有者(player) -> +1 不生效 -> enemy 仅抽1张。
func test_effect03_nonself_skip_no_plus() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_selkill(battle, &"player")
	var gs = s.gs
	var ga = battle.context.game_actions
	var enemy = gs.players.get(&"enemy")
	if enemy == null:
		return "enemy 不存在"
	# 插入1张正面牌到顶（owner=player 埋的）
	var face_card = _make_instance(s.gs, s.cdb, "action_001_进攻", &"player")
	if face_card == null:
		return "找不到 action_001_进攻"
	s.player.action_hand.append(face_card.instance_id)
	var payload: Dictionary = {"binding_context": {"card_instance_id": s.card.instance_id, "mech_id": s.mech.mech_id, "player_id": &"player"}, "pilot_003_face_up_cards": [face_card.instance_id]}
	ga.pilot_003_insert_face_up_random({"card_ids": [face_card.instance_id], "deck_top_card_id": face_card.instance_id}, payload)
	# 勾选 enemy（skip 对 enemy 生效，但 self-skip 不生效：拥有者=player != enemy）
	ga.toggle_pilot_003_skip({"enable": true}, {"binding_context": {"card_instance_id": s.card.instance_id, "player_id": &"enemy"}})
	if not _ActionPilotEffects.is_pilot_003_skip_active(&"enemy"):
		return "enemy skip 应激活"
	if _ActionPilotEffects.is_pilot_003_self_skip_active(&"enemy", gs):
		return "enemy 非拥有者，self-skip 不应激活"
	if gs.deck_state.action_deck.size() < 3:
		return "牌堆不足测试"
	var enemy_hand_before: int = enemy.action_hand.size()
	# enemy 抽1：跳过顶上的正面牌，抽下一张非正面牌；drawer!=拥有者 -> 不 +1 -> 仅1张
	ga.draw_action_cards({"player_id": &"enemy", "count": 1, "reason": &"test_p003_nonself"})
	# 正面牌仍留在牌堆（被跳过，未被抽走）
	if not gs.deck_state.action_deck.has(face_card.instance_id):
		return "正面牌应仍在牌堆（被跳过）"
	# enemy 仅抽1张（不 +1）
	if enemy.action_hand.size() != enemy_hand_before + 1:
		return "非自抽即使跳过正面牌也不应 +1，应抽1张 实增=%d" % (enemy.action_hand.size() - enemy_hand_before)
	return true


# ═══════════════════════════════════════════
# deck 显示契约（CardInstance.is_face_up_in_deck / get_face_up_tag_owner）
# ═══════════════════════════════════════════

## 测试7：正面埋牌显示牌名，背面牌显示未知。验证 deck_info_popup._card_display 依赖的 CardInstance 契约。
func test_deck_display_contract() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_selkill(battle, &"player")
	var gs = s.gs
	var ga = battle.context.game_actions
	var face_card = _make_instance(s.gs, s.cdb, "action_001_进攻", &"player")
	s.player.action_hand.append(face_card.instance_id)
	ga.pilot_003_insert_face_up_random({"card_ids": [face_card.instance_id], "deck_top_card_id": face_card.instance_id},
		{"binding_context": {"card_instance_id": s.card.instance_id, "mech_id": s.mech.mech_id, "player_id": &"player"}})
	# 正面牌：is_face_up_in_deck=true，显示牌名
	var fc = gs.get_card(face_card.instance_id)
	if not fc.is_face_up_in_deck():
		return "正面埋牌 is_face_up_in_deck 应=true"
	if fc.get_face_up_tag_owner() != &"player":
		return "正面埋牌 owner 应=player"
	# 取一张牌堆里的背面牌（非正面埋牌），应 is_face_up_in_deck=false（显示"未知牌"）
	var back_card_id: StringName = &""
	for cid in gs.deck_state.action_deck:
		if cid != face_card.instance_id:
			var dc = gs.get_card(cid)
			if dc != null and not dc.is_face_up_in_deck():
				back_card_id = cid
				break
	if back_card_id == &"":
		return "牌堆应至少有1张背面牌"
	var bc = gs.get_card(back_card_id)
	if bc.is_face_up_in_deck():
		return "背面牌 is_face_up_in_deck 应=false"
	if bc.get_face_up_tag_owner() != &"":
		return "背面牌 get_face_up_tag_owner 应为空"
	return true


# ═══════════════════════════════════════════
# 2金币抽牌 paid_draw_action_card（所有玩家基础效果，共用 draw_action_cards）
# ═══════════════════════════════════════════

## 测试8：花2金币抽1张行动牌（每回合1次）。成功扣金币+计数+抽1；再次用拒；金币不足拒。
func test_paid_draw_action_card() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	var ga = battle.context.game_actions
	if gs.deck_state.action_deck.size() < 2:
		return "牌堆不足测试"
	var gold_before: int = player.gold
	var hand_before: int = player.action_hand.size()
	# 1. 成功抽1
	var r1: Dictionary = ga.paid_draw_action_card({"player_id": &"player"})
	if not r1.get("ok", false):
		return "首次付费抽牌应成功 实=%s" % String(r1.get("message", ""))
	if player.gold != gold_before - _GameConfig.PAID_DRAW_ACTION_COST:
		return "金币应扣%d 实=%d" % [_GameConfig.PAID_DRAW_ACTION_COST, player.gold]
	if player.paid_draw_count_this_turn != 1:
		return "计数应=1 实=%d" % player.paid_draw_count_this_turn
	if player.action_hand.size() != hand_before + _GameConfig.PAID_DRAW_ACTION_COUNT:
		return "手牌应+%d 实增=%d" % [_GameConfig.PAID_DRAW_ACTION_COUNT, player.action_hand.size() - hand_before]
	# 2. 再次用拒（本回合已用）
	var r2: Dictionary = ga.paid_draw_action_card({"player_id": &"player"})
	if r2.get("ok", false):
		return "本回合已用过应拒绝"
	# 3. 金币不足拒（模拟另一场景）
	player.paid_draw_count_this_turn = 0
	player.gold = _GameConfig.PAID_DRAW_ACTION_COST - 1
	var r3: Dictionary = ga.paid_draw_action_card({"player_id": &"player"})
	if r3.get("ok", false):
		return "金币不足应拒绝"
	return true
