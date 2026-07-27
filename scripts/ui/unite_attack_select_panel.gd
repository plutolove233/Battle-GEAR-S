## UniteAttackSelectPanel.gd - 联合攻击单选面板
##
## 联合状态效果1：unite机甲攻击结算后弹出，列出 Target 手中所有攻击牌供单选，
## 确认后打出选中的1张（不消耗攻击次数），结算后去除此联合状态。取消则无事发生。
## 通用设计：不绑定具体玩家，由 app_root 按 target_mech_id 路由到对应人类玩家窗口。
extends PanelContainer
class_name UniteAttackSelectPanel

## 选择完成时发射（玩家点确认，selected_card_id 为空表示未选=不打出）
signal selection_completed(selected_card_id: StringName)
## 取消
signal selection_cancelled()

var _context = null  # type: GameContext
var _card_ids: Array = []  # 待选攻击牌 card_instance_id 列表
var _selected: StringName = &""  # 当前选中的牌（单选）
var _label: String = "联合攻击：选择1张攻击牌使用"

var _vbox: VBoxContainer
var _scroll: ScrollContainer
var _confirm_btn: Button


func configure(game_context, card_ids: Array, label: String = "联合攻击：选择1张攻击牌使用") -> void:
	_context = game_context
	_card_ids = card_ids
	_label = label
	_selected = &""
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

	var title := Label.new()
	title.add_theme_color_override("font_color", Color(0.9, 0.85, 0.7))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.text = "── %s ──" % _label
	title.name = "TitleLabel"
	_vbox.add_child(title)

	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(300, 220)
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
	_confirm_btn.custom_minimum_size = Vector2(260, 40)
	_confirm_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_confirm_btn.pressed.connect(func(): _on_confirm())
	_vbox.add_child(_confirm_btn)

	var cancel_btn = Button.new()
	cancel_btn.text = "取消（不联合攻击）"
	cancel_btn.custom_minimum_size = Vector2(260, 40)
	cancel_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	cancel_btn.pressed.connect(func(): selection_cancelled.emit())
	_vbox.add_child(cancel_btn)


func _refresh() -> void:
	if not _vbox:
		return
	var title = _vbox.get_node_or_null("TitleLabel")
	if title != null:
		title.text = "── %s ──" % _label
	_confirm_btn.text = "确认使用" if _selected != &"" else "确认使用（未选择）"
	_confirm_btn.disabled = (_selected == &"")
	_confirm_btn.add_theme_color_override("font_color", Color(0.3, 0.9, 0.4))

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
		btn.text = "%s[攻击牌]" % card.def.display_name
		btn.tooltip_text = card.def.effect_text
		btn.custom_minimum_size = Vector2(280, 36)
		btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		btn.add_theme_color_override("font_color", Color(0.7, 0.8, 0.9))
		var cid = card_id
		if cid == _selected:
			btn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
			btn.modulate = Color(1.2, 1.2, 0.8)
		btn.pressed.connect(func(): _on_card_selected(cid))
		scroll_content.add_child(btn)


## 单选：选中1张，再点同1张取消选中
func _on_card_selected(card_id: StringName) -> void:
	if _selected == card_id:
		_selected = &""
	else:
		_selected = card_id
	_refresh()


func _on_confirm() -> void:
	selection_completed.emit(_selected)
