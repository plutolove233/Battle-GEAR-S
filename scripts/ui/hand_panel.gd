## HandPanel.gd — 手牌显示面板
##
## 显示玩家当前手中的行动牌和装备牌，支持点击打出。
## 包含抽牌滑入动画和打牌上浮效果。
extends HBoxContainer
class_name HandPanel

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
	var player = gs.players.get(local_player_id)
	if not player:
		# 回退到 active_player_id
		player = gs.players.get(gs.active_player_id)
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

	# ── 行动牌区域 ──
	_add_section_label("行动牌")
	for card_id: StringName in player.action_hand:
		var card = gs.cards.get(card_id)
		if not card or not card.def:
			continue
		var btn = Button.new()
		btn.text = "%s[%s]" % [card.def.display_name, _action_type_short(card.def)]
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
		add_child(btn)
		# 新抽到的牌播放滑入动画
		if card_id in new_action_cards:
			_animate_card_slide_in(btn)

	# ── 分隔 ──
	_add_section_label("装备牌")
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
		add_child(btn)
		# 新抽到的装备牌播放滑入动画
		if card_id in new_equip_cards:
			_animate_card_slide_in(btn)


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
func _add_section_label(text: String) -> void:
	var label = Label.new()
	label.text = "  %s  " % text
	label.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8))
	add_child(label)


## 卡牌滑入动画
##
## 注意：HandPanel 是 HBoxContainer，子节点的 position 由容器自动管理，
## 容器在 add_child 后并不会立即重排（重排发生在下一帧的
## NOTIFICATION_SORT_CHILDREN）。若在 add_child 后立即读取 btn.position
## 做 tween，读到的是未排序的初始值（所有按钮堆在 (0,0)），导致新抽到的牌
## 挤在左侧、要点一次其他可点击处才归位。
## 因此滑入动画只使用不被容器管理的属性（透明度），彻底避免与布局时机竞争。
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
