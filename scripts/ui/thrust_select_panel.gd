## ThrustSelectPanel.gd - 多选行动牌面板（推进/掩护共用）
##
## CHOOSE_MANY_CARDS 效果弹窗：列出手中所有指定 card_def_id 的牌供多选，
## 确认后逐张执行 per_card_actions 并弃置。推进（动力+4）/掩护（威力-5）共用。
## 文案参数化：label/per_card_suffix/confirm_verb/cancel_label 由调用方传入。
extends PanelContainer
class_name ThrustSelectPanel

## 选择完成时发射（玩家点确认后，可能为空数组=不打出）
signal selection_completed(selected_card_ids: Array[StringName])
## 取消
signal selection_cancelled()

var _context = null  # type: GameContext
var _card_ids: Array = []  # 待选 card_instance_id 列表
var _selected: Array[StringName] = []
var _max_count: int = 0  # 0 = 不限
var _label: String = "选择要一起打出的牌"
var _per_card_suffix: String = ""
var _confirm_verb: String = "打出"
var _cancel_label: String = "不打出"

var _vbox: VBoxContainer
var _scroll: ScrollContainer
var _confirm_btn: Button
var _cancel_btn: Button
var _count_label: Label


func configure(game_context, card_ids: Array, label: String = "选择要一起打出的牌", per_card_suffix: String = "", confirm_verb: String = "打出", cancel_label: String = "不打出", max_count: int = 0) -> void:
	_context = game_context
	_card_ids = card_ids
	_label = label
	_per_card_suffix = per_card_suffix
	_confirm_verb = confirm_verb
	_cancel_label = cancel_label
	_max_count = max_count
	_selected.clear()
	_ensure_layout()
	_refresh()


func _ready() -> void:
	call_deferred("_ensure_layout")


func _ensure_layout() -> void:
	if _vbox:
		return
	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 8)
	add_child(_vbox)

	_count_label = Label.new()
	_count_label.add_theme_color_override("font_color", Color(0.9, 0.85, 0.7))
	_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_vbox.add_child(_count_label)

	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(280, 200)
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_vbox.add_child(_scroll)

	var scroll_content = VBoxContainer.new()
	scroll_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_content.add_theme_constant_override("separation", 4)
	_scroll.add_child(scroll_content)
	_scroll.set_meta("content", scroll_content)

	_confirm_btn = Button.new()
	_confirm_btn.custom_minimum_size = Vector2(200, 40)
	_confirm_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_confirm_btn.pressed.connect(func(): _on_confirm())
	_vbox.add_child(_confirm_btn)

	_cancel_btn = Button.new()
	_cancel_btn.custom_minimum_size = Vector2(200, 40)
	_cancel_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_cancel_btn.pressed.connect(func(): selection_cancelled.emit())
	_vbox.add_child(_cancel_btn)


func _refresh() -> void:
	if not _vbox:
		return
	_count_label.text = "── %s ──" % _label
	_confirm_btn.text = "确认%s (%d)" % [_confirm_verb, _selected.size()]
	_confirm_btn.disabled = false
	_confirm_btn.add_theme_color_override("font_color", Color(0.3, 0.9, 0.4))
	if _cancel_btn:
		_cancel_btn.text = _cancel_label

	var scroll_content = _scroll.get_meta("content") if _scroll.has_meta("content") else null
	if not scroll_content:
		return
	for child in scroll_content.get_children():
		child.queue_free()
	if not _context:
		return
	var gs = _context.game_state
	for card_id in _card_ids:
		var card = gs.cards.get(card_id) if gs else null
		if card == null or card.def == null:
			continue
		var btn = Button.new()
		btn.text = "%s%s" % [card.def.display_name, _per_card_suffix]
		btn.tooltip_text = card.def.effect_text
		btn.custom_minimum_size = Vector2(260, 36)
		btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		btn.add_theme_color_override("font_color", Color(0.3, 0.85, 0.5))
		var cid = card_id
		if cid in _selected:
			btn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
			btn.modulate = Color(1.2, 1.2, 0.8)
		btn.pressed.connect(func(): _on_card_toggle(cid))
		scroll_content.add_child(btn)


func _on_card_toggle(card_id: StringName) -> void:
	if card_id in _selected:
		_selected.erase(card_id)
	else:
		if _max_count > 0 and _selected.size() >= _max_count:
			return  # 已达上限，不再追加
		_selected.append(card_id)
	_refresh()


func _on_confirm() -> void:
	selection_completed.emit(_selected.duplicate())
