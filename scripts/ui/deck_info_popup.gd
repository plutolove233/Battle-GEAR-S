## DeckInfoPopup.gd — 牌堆信息弹窗
##
## 点击"牌堆信息"按钮后弹出的模态窗口，
## 显示行动牌堆、装备牌堆、行动弃牌堆、装备弃牌堆的卡牌列表（从上往下）。
extends PopupPanel
class_name DeckInfoPopup

var _context = null  # type: GameContext
var _content: VBoxContainer


func _ready() -> void:
	# 弹窗内 VBox + ScrollContainer
	var vbox := VBoxContainer.new()
	add_child(vbox)

	# 标题
	var title := Label.new()
	title.text = "── 牌堆信息 ──"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.3, 0.8, 0.9))
	vbox.add_child(title)

	# 滚动容器
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(360, 400)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_content)

	# 关闭按钮
	var close_btn := Button.new()
	close_btn.text = "关闭"
	close_btn.custom_minimum_size = Vector2(140, 32)
	close_btn.pressed.connect(func(): visible = false)
	vbox.add_child(close_btn)


## 配置弹窗：从 GameContext 读取牌堆数据
func configure(game_context) -> void:
	_context = game_context
	_refresh()


## 刷新显示内容
func _refresh() -> void:
	if _context == null:
		return

	# 清除现有内容
	for child in _content.get_children():
		child.queue_free()

	var gs = _context.game_state
	var deck_state = gs.deck_state

	# ── 行动牌堆 ──
	_add_section("行动牌堆 (%d 张)" % deck_state.action_deck.size(), Color(0.9, 0.3, 0.2))
	if deck_state.action_deck.is_empty():
		_add_card_line("（空）", Color(0.5, 0.5, 0.5))
	else:
		for i: int in range(deck_state.action_deck.size()):
			var card_id: StringName = deck_state.action_deck[i]
			_add_card_line(_card_display(card_id, i + 1), Color(0.85, 0.85, 0.85))

	# ── 装备牌堆 ──
	_add_section("装备牌堆 (%d 张)" % deck_state.equipment_deck.size(), Color(0.85, 0.75, 0.3))
	if deck_state.equipment_deck.is_empty():
		_add_card_line("（空）", Color(0.5, 0.5, 0.5))
	else:
		for i: int in range(deck_state.equipment_deck.size()):
			var card_id: StringName = deck_state.equipment_deck[i]
			_add_card_line(_card_display(card_id, i + 1), Color(0.85, 0.85, 0.85))

	# ── 高级装备牌堆 ──
	if not deck_state.advanced_equipment_deck.is_empty():
		_add_section("高级装备牌堆 (%d 张)" % deck_state.advanced_equipment_deck.size(), Color(0.9, 0.6, 0.1))
		for i: int in range(deck_state.advanced_equipment_deck.size()):
			var card_id: StringName = deck_state.advanced_equipment_deck[i]
			_add_card_line(_card_display(card_id, i + 1), Color(0.85, 0.85, 0.85))

	# ── 行动弃牌堆 ──
	_add_section("行动弃牌堆 (%d 张)" % deck_state.action_discard_pile.size(), Color(0.6, 0.6, 0.65))
	if deck_state.action_discard_pile.is_empty():
		_add_card_line("（空）", Color(0.5, 0.5, 0.5))
	else:
		for i: int in range(deck_state.action_discard_pile.size()):
			var card_id: StringName = deck_state.action_discard_pile[i]
			_add_card_line(_card_display(card_id, i + 1), Color(0.75, 0.75, 0.8))

	# ── 装备弃牌堆 ──
	_add_section("装备弃牌堆 (%d 张)" % deck_state.equipment_discard_pile.size(), Color(0.6, 0.6, 0.65))
	if deck_state.equipment_discard_pile.is_empty():
		_add_card_line("（空）", Color(0.5, 0.5, 0.5))
	else:
		for i: int in range(deck_state.equipment_discard_pile.size()):
			var card_id: StringName = deck_state.equipment_discard_pile[i]
			_add_card_line(_card_display(card_id, i + 1), Color(0.75, 0.75, 0.8))


## 添加分区标题
func _add_section(text: String, color: Color) -> void:
	var sep := HSeparator.new()
	_content.add_child(sep)
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", color)
	_content.add_child(label)


## 添加一行卡牌文本
func _add_card_line(text: String, color: Color) -> void:
	var label := Label.new()
	label.text = "  " + text
	label.add_theme_color_override("font_color", color)
	_content.add_child(label)


## 获取卡牌显示文本
func _card_display(card_id: StringName, index: int) -> String:
	var gs = _context.game_state
	var card = gs.cards.get(card_id)
	if card and card.def:
		return "%d. %s" % [index, card.def.display_name]
	return "%d. [%s]" % [index, String(card_id)]
