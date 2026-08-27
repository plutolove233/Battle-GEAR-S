## HandPanel.gd - 手牌显示面板
##
## 显示玩家当前手中的行动牌和装备牌，支持点击打出。
## 包含抽牌滑入动画和打牌上浮效果。
## VBoxContainer：上方一行统计标签（行动牌上限/回合攻击数），下方一行卡牌。
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


## 配置面板，从 GameState 读取手牌数据
func configure(game_context) -> void:
	_context = game_context
	_refresh()


## 刷新手牌显示
func _refresh() -> void:
	# 清除现有内容
	for child in get_children():
		child.queue_free()

	if not _context:
		return

	var gs = _context.game_state
	# 读 local_player_id 的手牌（PvP 双窗口各看己方）；找不到则回退 active_player_id
	var _stat_pid: StringName = local_player_id if gs.players.has(local_player_id) else gs.active_player_id
	var player = gs.players.get(_stat_pid)
	if not player:
		return

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
	# 独立一行置于卡牌区上方，不干扰卡牌与其他模块显示。
	# 攻击 X：剩余可攻击次数=上限-已用（一开始 Y/Y，用完 0/Y），而非已用次数。
	var stats_row := HBoxContainer.new()
	stats_row.add_theme_constant_override("separation", 24)
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
	_add_stat_label(stats_row, "行动牌 %d/%d" % [player.action_hand.size(), int(player.action_card_limit)])
	_add_stat_label(stats_row, "攻击 %d/%d" % [_atk_remaining, _atk_limit])
	add_child(stats_row)

	# ── 卡牌行 ──
	var cards_row := HBoxContainer.new()
	cards_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# ── 行动牌区域 ──
	_add_section_label(cards_row, "行动牌")
	for card_id: StringName in player.action_hand:
		var card = gs.cards.get(card_id)
		if not card or not card.def:
			continue
		var btn = Button.new()
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
		btn.custom_minimum_size = Vector2(120, 44)
		btn.tooltip_text = card.def.effect_text
		# 攻击牌用绿色，辅助牌用蓝色
		if card.def is ActionCardDef and card.def.action_type == &"攻击":
			btn.add_theme_color_override("font_color", Color(0.9, 0.3, 0.2))
		elif card.def is ActionCardDef and card.def.action_type == &"迎击":
			btn.add_theme_color_override("font_color", Color(0.3, 0.7, 0.9))
		else:
			btn.add_theme_color_override("font_color", Color(0.3, 0.85, 0.5))
		var cid = card_id  # 闭包捕获
		btn.pressed.connect(func(): action_card_clicked.emit(cid))
		cards_row.add_child(btn)
		# 新抽到的牌播放滑入动画
		if card_id in new_action_cards:
			_animate_card_slide_in(btn)

	# ── 分隔 ──
	_add_section_label(cards_row, "装备牌")
	for card_id: StringName in player.equipment_hand:
		var card = gs.cards.get(card_id)
		if not card or not card.def:
			continue
		var btn = Button.new()
		btn.text = "%s" % card.def.display_name
		btn.custom_minimum_size = Vector2(120, 44)
		btn.tooltip_text = card.def.effect_text
		btn.add_theme_color_override("font_color", Color(0.85, 0.75, 0.3))
		var cid = card_id
		btn.pressed.connect(func(): equipment_card_clicked.emit(cid))
		cards_row.add_child(btn)
		# 新抽到的装备牌播放滑入动画
		if card_id in new_equip_cards:
			_animate_card_slide_in(btn)

	add_child(cards_row)


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


## 添加分隔标签
func _add_section_label(container, text: String) -> void:
	var label = Label.new()
	label.text = "  %s  " % text
	label.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8))
	container.add_child(label)


## 添加统计标签（行动牌上限/攻击数），金色醒目，区别于普通分区标签
func _add_stat_label(container, text: String) -> void:
	var label = Label.new()
	label.text = "  %s  " % text
	label.add_theme_color_override("font_color", Color(0.95, 0.82, 0.45))
	label.add_theme_font_size_override("font_size", 15)
	container.add_child(label)


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
