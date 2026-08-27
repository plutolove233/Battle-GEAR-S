## HandPanel.gd - 手牌显示面板
##
## 显示玩家当前手中的行动牌和装备牌，支持点击打出。
## 包含抽牌滑入动画和打牌上浮效果。
## VBoxContainer：上方一行统计标签（行动牌上限/回合攻击数），下方一行卡牌。
##
## 差量刷新：骨架（统计行/分区标签）只建一次，卡牌按钮按牌实例 ID 缓存复用，
## 刷新时只做"增/删/改文本"，不再整树 queue_free 重建（旧实现是每次点击/刷新
## 都销毁全部按钮再重建，制造大量节点与主题查询开销）。
extends VBoxContainer
class_name HandPanel

const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")

## 行动牌被点击时发射
signal action_card_clicked(card_id: StringName)
## 装备牌被点击时发射
signal equipment_card_clicked(card_id: StringName)

## 当前 GameContext 引用
var _context = null  # type: GameContext

## 本面板显示哪一方的手牌（PvP host=player, client=enemy）。默认 player 兼容原 PvE。
var local_player_id: StringName = &"player"

## 上次手牌中的卡牌ID集合（用于检测新抽的牌）
var _last_action_hand: Array[StringName] = []
var _last_equip_hand: Array[StringName] = []

# ── 差量刷新缓存 ──
## 统计标签（持久，只改文本）
var _stat_action_label: Label = null
## 攻击统计标签（持久，只改文本）
var _stat_attack_label: Label = null
## 卡牌行容器（持久）
var _cards_row: HBoxContainer = null
## 行动牌区标签（持久，cards_row 第 0 个子节点）
var _action_section_label: Label = null
## 装备牌区标签（持久，位于行动牌按钮之后）
var _equip_section_label: Label = null
## 行动牌按钮缓存：card_id -> Button（牌实例 ID 生命周期内不变，可安全复用）
var _action_btns: Dictionary = {}
## 装备牌按钮缓存：card_id -> Button
var _equip_btns: Dictionary = {}


## 配置面板，从 GameState 读取手牌数据
func configure(game_context) -> void:
	_context = game_context
	_refresh()


## 刷新手牌显示（差量）
func _refresh() -> void:
	if not _context:
		_teardown()
		return

	var gs = _context.game_state
	# 读 local_player_id 的手牌（PvP 双窗口各看己方）；找不到则回退 active_player_id
	var _stat_pid: StringName = local_player_id if gs.players.has(local_player_id) else gs.active_player_id
	var player = gs.players.get(_stat_pid)
	if not player:
		_teardown()
		return

	_ensure_skeleton()

	# 检测新抽到的牌（对比上次手牌）
	var new_action_cards: Array[StringName] = []
	for card_id: StringName in player.action_hand:
		if not card_id in _last_action_hand:
			new_action_cards.append(card_id)
	_last_action_hand = player.action_hand.duplicate()

	var new_equip_cards: Array[StringName] = []
	for card_id: StringName in player.equipment_hand:
		if not card_id in _last_equip_hand:
			new_equip_cards.append(card_id)
	_last_equip_hand = player.equipment_hand.duplicate()

	# ── 统计标签行：行动牌上限 + 回合攻击数（X/Y=剩余/上限）──
	# 攻击 X：剩余可攻击次数=上限-已用（一开始 Y/Y，用完 0/Y），而非已用次数。
	var _stat_mech = gs.get_mech_for_player(_stat_pid) if _stat_pid != &"" else null
	var _atk_used: int = 0
	if _stat_mech != null and "attack_count_this_turn" in _stat_mech:
		_atk_used = int(_stat_mech.attack_count_this_turn)
	var _atk_limit: int = 0
	if _stat_mech != null and "max_attacks_per_turn" in _stat_mech:
		_atk_limit = int(_stat_mech.max_attacks_per_turn)
	else:
		_atk_limit = int(player.attack_limit)
	var _atk_remaining: int = max(0, _atk_limit - _atk_used)
	_stat_action_label.text = "  行动牌 %d/%d  " % [player.action_hand.size(), int(player.action_card_limit)]
	_stat_attack_label.text = "  攻击 %d/%d  " % [_atk_remaining, _atk_limit]

	# ── 卡牌行（差量更新）──
	_update_action_buttons(player, new_action_cards, gs)
	_update_equip_buttons(player, new_equip_cards, gs)
	_normalize_button_order(player, gs)


## 构建持久骨架（仅首次调用时创建）
func _ensure_skeleton() -> void:
	if _cards_row != null:
		return

	var stats_row := HBoxContainer.new()
	stats_row.add_theme_constant_override("separation", 24)
	_stat_action_label = _make_stat_label("")
	_stat_attack_label = _make_stat_label("")
	stats_row.add_child(_stat_action_label)
	stats_row.add_child(_stat_attack_label)
	add_child(stats_row)

	_cards_row = HBoxContainer.new()
	_cards_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_action_section_label = _make_section_label("行动牌")
	_equip_section_label = _make_section_label("装备牌")
	_cards_row.add_child(_action_section_label)
	_cards_row.add_child(_equip_section_label)
	add_child(_cards_row)


## 差量更新行动牌按钮：删消失/建新增/改留存
func _update_action_buttons(player, new_action_cards: Array[StringName], gs) -> void:
	var live_ids: Dictionary = {}
	for card_id: StringName in player.action_hand:
		var card = gs.cards.get(card_id)
		if not card or not card.def:
			continue
		live_ids[card_id] = true
		var btn: Button = _action_btns.get(card_id)
		if btn == null:
			btn = _make_action_button(card_id)
			_action_btns[card_id] = btn
			_cards_row.add_child(btn)
			# 新抽到的牌播放滑入动画
			if card_id in new_action_cards:
				_animate_card_slide_in(btn)
		_apply_action_button_state(btn, card)
	# 删除已不在手牌中的按钮（先脱离布局再释放，避免干扰本次归一化排序）
	for card_id in _action_btns.keys():
		if not live_ids.has(card_id):
			var stale: Button = _action_btns[card_id]
			_action_btns.erase(card_id)
			_cards_row.remove_child(stale)
			stale.queue_free()


## 差量更新装备牌按钮：删消失/建新增/改留存
func _update_equip_buttons(player, new_equip_cards: Array[StringName], gs) -> void:
	var live_ids: Dictionary = {}
	for card_id: StringName in player.equipment_hand:
		var card = gs.cards.get(card_id)
		if not card or not card.def:
			continue
		live_ids[card_id] = true
		var btn: Button = _equip_btns.get(card_id)
		if btn == null:
			btn = _make_equip_button(card_id)
			_equip_btns[card_id] = btn
			_cards_row.add_child(btn)
			# 新抽到的装备牌播放滑入动画
			if card_id in new_equip_cards:
				_animate_card_slide_in(btn)
		btn.text = "%s" % card.def.display_name
		btn.tooltip_text = card.def.effect_text
		btn.add_theme_color_override("font_color", Color(0.85, 0.75, 0.3))
	for card_id in _equip_btns.keys():
		if not live_ids.has(card_id):
			var stale: Button = _equip_btns[card_id]
			_equip_btns.erase(card_id)
			_cards_row.remove_child(stale)
			stale.queue_free()


## 把按钮排列成与手牌数组一致的顺序：
## [行动牌区标签, 行动牌按钮(按数组序), 装备牌区标签, 装备牌按钮(按数组序)]。
## 手牌数组只增删不重排，创建顺序通常已正确，此处 move_child 仅在错位时触发。
func _normalize_button_order(player, gs) -> void:
	var idx := 1  # 0 号位是"行动牌"区标签
	for card_id: StringName in player.action_hand:
		var btn = _action_btns.get(card_id)
		if btn == null:
			continue
		if btn.get_index() != idx:
			_cards_row.move_child(btn, idx)
		idx += 1
	if _equip_section_label.get_index() != idx:
		_cards_row.move_child(_equip_section_label, idx)
	idx += 1
	for card_id: StringName in player.equipment_hand:
		var btn = _equip_btns.get(card_id)
		if btn == null:
			continue
		if btn.get_index() != idx:
			_cards_row.move_child(btn, idx)
		idx += 1


## 新建行动牌按钮（按下回调只捕获不变的牌实例 ID）
func _make_action_button(card_id: StringName) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(120, 44)
	var cid = card_id  # 闭包捕获
	btn.pressed.connect(func(): action_card_clicked.emit(cid))
	return btn


## 更新行动牌按钮的文本/提示/颜色（标签后缀随牌上状态变化，每次都要重算）
func _apply_action_button_state(btn: Button, card) -> void:
	# 里昂狩猎标签：抽到的攻击牌若有有效 hunting 标签，显示"牌名(狩)"后缀
	var _hunting_suffix := "(狩)" if _ActionPilotEffects.pilot_006_card_has_active_hunting_tag(card) else ""
	# pilot_021 塔莉娅：禁/策标签后缀（效果1赐予牌禁本回合使用；策=交出去的牌）
	var _p021_suffix := ""
	if _ActionPilotEffects.pilot_021_card_has_any_jin(card):
		_p021_suffix += "(禁)"
	if _ActionPilotEffects.pilot_021_card_has_any_ce(card):
		_p021_suffix += "(策)"
	# pilot_087 塔妮拉：交标签后缀（效果1交出去的牌，他人使用后双方各抽1）
	var _p087_suffix := "(交)" if _ActionPilotEffects.pilot_087_card_has_any_jiao(card) else ""
	# 烈火"燃"标签后缀（攻击命中抽3：本回合不占行动牌上限）
	var _ran_suffix := "(燃)" if _ActionPilotEffects.card_has_ran_tag(card) else ""
	# 温斯顿"联"标签后缀（效果1当作联合时，交出的牌上打"联"标签；其他机甲使用后触发联合获金等）
	var _p082_suffix := "(联)" if _ActionPilotEffects.pilot_082_card_has_any_lian(card) else ""
	btn.text = "%s%s%s%s%s%s[%s]" % [card.def.display_name, _hunting_suffix, _p021_suffix, _p087_suffix, _ran_suffix, _p082_suffix, _action_type_short(card.def)]
	btn.tooltip_text = card.def.effect_text
	# 攻击牌用红色，迎击牌用青色，其余（辅助）绿色
	if card.def is ActionCardDef and card.def.action_type == &"攻击":
		btn.add_theme_color_override("font_color", Color(0.9, 0.3, 0.2))
	elif card.def is ActionCardDef and card.def.action_type == &"迎击":
		btn.add_theme_color_override("font_color", Color(0.3, 0.7, 0.9))
	else:
		btn.add_theme_color_override("font_color", Color(0.3, 0.85, 0.5))


## 新建装备牌按钮
func _make_equip_button(card_id: StringName) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(120, 44)
	var cid = card_id  # 闭包捕获
	btn.pressed.connect(func(): equipment_card_clicked.emit(cid))
	return btn


## 清空全部缓存并释放骨架与按钮（仅在无上下文/无玩家时）
func _teardown() -> void:
	_action_btns.clear()
	_equip_btns.clear()
	_stat_action_label = null
	_stat_attack_label = null
	_action_section_label = null
	_equip_section_label = null
	_cards_row = null
	for child in get_children():
		child.queue_free()
	_last_action_hand.clear()
	_last_equip_hand.clear()


## 获取行动类型的简写
func _action_type_short(def) -> String:
	if not def is ActionCardDef:
		return "?"
	if def.action_type == &"攻击":
		return "攻"
	elif def.action_type == &"迎击":
		return "迎"
	elif def.action_type == &"辅助":
		return "辅"
	return "?"


## 新建分区标签
func _make_section_label(text: String) -> Label:
	var label = Label.new()
	label.text = "  %s  " % text
	label.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8))
	return label


## 新建统计标签（行动牌上限/攻击数），金色醒目，区别于普通分区标签
func _make_stat_label(text: String) -> Label:
	var label = Label.new()
	label.text = "  %s  " % text
	label.add_theme_color_override("font_color", Color(0.95, 0.82, 0.45))
	label.add_theme_font_size_override("font_size", 15)
	return label


## 卡牌滑入动画
##
## 注意：HandPanel 是 VBoxContainer，卡牌行是其子 HBoxContainer，
## 卡牌按钮由容器自动管理布局。滑入动画只使用不被容器管理的属性（透明度），
## 彻底避免与布局时机竞争。
func _animate_card_slide_in(btn: Button) -> void:
	btn.modulate.a = 0.0
	var tween = create_tween()
	tween.tween_property(btn, "modulate:a", 1.0, 0.25).set_ease(Tween.EASE_OUT)


## 打牌上浮效果（由外部调用）
func animate_card_played(_card_id: StringName) -> void:
	# 查找并播放上浮动画
	for child in get_children():
		if child is Button:
			# 简化：对所有按钮播放一个短暂的缩放效果
			pass
	# 简化实现：整体闪一下
	modulate.a = 0.5
	var tween = create_tween()
	tween.tween_property(self, "modulate:a", 1.0, 0.3)
