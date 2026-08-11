## DeckInfoPopup.gd - 牌堆信息弹窗
##
## 点击"牌堆信息"按钮后弹出的模态窗口，
## 显示行动牌堆、装备牌堆、行动弃牌堆、装备弃牌堆的卡牌列表（从上往下）。
## 默认牌堆显示「序号. 未知牌」（仅 face_up_bury 正面朝上的埋牌显示牌名），
## 弃牌堆为公开信息显示牌名。可切换"作弊视图"显示所有牌名。
extends PopupPanel
class_name DeckInfoPopup

var _context = null  # type: GameContext
var _content: VBoxContainer
var _cheat_view: bool = false  # 作弊视图：开则显示所有牌名
var _cheat_btn: Button


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

	# 作弊视图切换 + 关闭按钮行
	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(btn_row)
	_cheat_btn = Button.new()
	_cheat_btn.text = "作弊视图：关"
	_cheat_btn.custom_minimum_size = Vector2(150, 32)
	_cheat_btn.toggle_mode = true
	_cheat_btn.toggled.connect(Callable(self, "_on_cheat_toggled"))
	btn_row.add_child(_cheat_btn)
	var close_btn := Button.new()
	close_btn.text = "关闭"
	close_btn.custom_minimum_size = Vector2(140, 32)
	close_btn.pressed.connect(func(): visible = false)
	btn_row.add_child(close_btn)

	# 滚动容器
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(360, 400)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_content)


func _on_cheat_toggled(pressed: bool) -> void:
	_cheat_view = pressed
	_cheat_btn.text = "作弊视图：%s" % ("开" if pressed else "关")
	_refresh()


## 配置弹窗：从 GameContext 读取牌堆数据
func configure(game_context) -> void:
	_context = game_context
	# 同步按钮显示与当前作弊状态（跨次打开保持状态）
	if _cheat_btn:
		_cheat_btn.set_pressed_no_signal(_cheat_view)
		_cheat_btn.text = "作弊视图：%s" % ("开" if _cheat_view else "关")
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

	# ── 行动牌堆（默认未知牌，仅 face_up_bury 正面埋牌显示牌名；作弊视图全显）──
	_add_section("行动牌堆 (%d 张)" % deck_state.action_deck.size(), Color(0.9, 0.3, 0.2))
	if deck_state.action_deck.is_empty():
		_add_card_line("（空）", Color(0.5, 0.5, 0.5))
	else:
		for i: int in range(deck_state.action_deck.size()):
			var card_id: StringName = deck_state.action_deck[i]
			_add_card_line(_card_display(card_id, i + 1, _cheat_view), Color(0.85, 0.85, 0.85))

	# ── 装备牌堆 ──
	_add_section("装备牌堆 (%d 张)" % deck_state.equipment_deck.size(), Color(0.85, 0.75, 0.3))
	if deck_state.equipment_deck.is_empty():
		_add_card_line("（空）", Color(0.5, 0.5, 0.5))
	else:
		for i: int in range(deck_state.equipment_deck.size()):
			var card_id: StringName = deck_state.equipment_deck[i]
			_add_card_line(_card_display(card_id, i + 1, _cheat_view), Color(0.85, 0.85, 0.85))

	# ── 高级装备牌堆 ──
	if not deck_state.advanced_equipment_deck.is_empty():
		_add_section("高级装备牌堆 (%d 张)" % deck_state.advanced_equipment_deck.size(), Color(0.9, 0.6, 0.1))
		for i: int in range(deck_state.advanced_equipment_deck.size()):
			var card_id: StringName = deck_state.advanced_equipment_deck[i]
			_add_card_line(_card_display(card_id, i + 1, _cheat_view), Color(0.85, 0.85, 0.85))

	# ── 行动弃牌堆（公开信息，始终显示牌名）──
	_add_section("行动弃牌堆 (%d 张)" % deck_state.action_discard_pile.size(), Color(0.6, 0.6, 0.65))
	if deck_state.action_discard_pile.is_empty():
		_add_card_line("（空）", Color(0.5, 0.5, 0.5))
	else:
		for i: int in range(deck_state.action_discard_pile.size()):
			var card_id: StringName = deck_state.action_discard_pile[i]
			_add_card_line(_card_display(card_id, i + 1, true), Color(0.75, 0.75, 0.8))

	# ── 装备弃牌堆（公开信息，始终显示牌名）──
	_add_section("装备弃牌堆 (%d 张)" % deck_state.equipment_discard_pile.size(), Color(0.6, 0.6, 0.65))
	if deck_state.equipment_discard_pile.is_empty():
		_add_card_line("（空）", Color(0.5, 0.5, 0.5))
	else:
		for i: int in range(deck_state.equipment_discard_pile.size()):
			var card_id: StringName = deck_state.equipment_discard_pile[i]
			_add_card_line(_card_display(card_id, i + 1, true), Color(0.75, 0.75, 0.8))


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


## 获取卡牌显示文本。show_name=true 时显示牌名（弃牌堆公开/作弊视图）；
## 否则牌堆默认显示「未知牌」，仅 face_up_bury 正面朝上的埋牌显示牌名。
func _card_display(card_id: StringName, index: int, show_name: bool) -> String:
	var gs = _context.game_state
	var card = gs.cards.get(card_id)
	if show_name:
		if card and card.def:
			return "%d. %s" % [index, card.def.display_name]
		return "%d. [%s]" % [index, String(card_id)]
	# 默认：未知牌；face_up_bury 正面埋牌显示牌名
	if card and card.is_face_up_in_deck():
		var nm: String = card.def.display_name if card.def else String(card_id)
		return "%d. %s（正面）" % [index, nm]
	return "%d. 未知牌" % index
