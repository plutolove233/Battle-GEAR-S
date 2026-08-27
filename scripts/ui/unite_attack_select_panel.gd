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
var _card_suffix: String = "[攻击牌]"  # 牌名后缀（联合攻击=攻击牌；pilot_003 置顶=空）
var _confirm_verb: String = "确认使用"  # 确认按钮文案
var _cancel_label: String = "取消（不联合攻击）"  # 取消按钮文案

var _vbox: VBoxContainer
var _scroll: ScrollContainer
var _confirm_btn: Button
var _cancel_btn: Button
var _disabled_card_ids: Dictionary = {} # card_id -> true（灰显不可选，用于美杜莎操控列出处于判定管线中的牌）
var _disabled_suffix: String = "" # 禁用牌后缀（如"·处理中"），空则用 _card_suffix
var _click_to_confirm: bool = false # 点牌即确认模式（美杜莎操控：点牌直接emit，复用 app_root 的"确定使用?"确认框，和手牌一致）
var _no_cancel: bool = false # 隐藏取消按钮（不可取消，如里欧娜 pilot_047 强制使用攻击牌）


## 通用单选面板：列出手牌供单选+取消，确认/取消信号由 app_root 路由。
## card_suffix/confirm_verb/cancel_label 可定制（pilot_003 effect_01 选置顶牌复用本面板）。
## disabled_card_ids：需显示但不可选的牌（灰显，如瑟尔基尔判定管线中的牌）；disabled_suffix 其后缀。
## click_to_confirm=true：点牌即 emit selection_completed（隐藏"确认"按钮），由 app_root 弹"确定使用?"确认框；
##   美杜莎操控用此模式使交互与手牌点击一致。默认 false（联合攻击/pilot_003 走 选中+确认按钮）。
## no_cancel=true：隐藏取消按钮（强制必须选，如里欧娜 pilot_047 战后威逼交牌）。
func configure(game_context, card_ids: Array, label: String = "联合攻击：选择1张攻击牌使用", card_suffix: String = "[攻击牌]", confirm_verb: String = "确认使用", cancel_label: String = "取消（不联合攻击）", disabled_card_ids: Array = [], disabled_suffix: String = "", click_to_confirm: bool = false, no_cancel: bool = false) -> void:
	_context = game_context
	_card_ids = card_ids
	_label = label
	_card_suffix = card_suffix
	_confirm_verb = confirm_verb
	_cancel_label = cancel_label
	_disabled_card_ids = {}
	for d in disabled_card_ids:
		_disabled_card_ids[d] = true
	_disabled_suffix = disabled_suffix
	_click_to_confirm = click_to_confirm
	_no_cancel = no_cancel
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

	_cancel_btn = Button.new()
	_cancel_btn.custom_minimum_size = Vector2(260, 40)
	_cancel_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_cancel_btn.pressed.connect(func(): selection_cancelled.emit())
	_vbox.add_child(_cancel_btn)


func _refresh() -> void:
	if not _vbox:
		return
	var title = _vbox.get_node_or_null("TitleLabel")
	if title != null:
		title.text = "── %s ──" % _label
	_confirm_btn.text = _confirm_verb if _selected != &"" else "%s（未选择）" % _confirm_verb
	_confirm_btn.disabled = (_selected == &"")
	_confirm_btn.visible = not _click_to_confirm
	_confirm_btn.add_theme_color_override("font_color", Color(0.3, 0.9, 0.4))
	_cancel_btn.text = _cancel_label
	_cancel_btn.visible = not _no_cancel

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
		var is_disabled: bool = _disabled_card_ids.has(card_id)
		var btn = Button.new()
		var suffix: String = _card_suffix
		if is_disabled and _disabled_suffix != "":
			suffix = _disabled_suffix
		btn.text = "%s%s" % [card.def.display_name, suffix]
		btn.tooltip_text = card.def.effect_text
		btn.custom_minimum_size = Vector2(280, 36)
		btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		btn.add_theme_color_override("font_color", Color(0.7, 0.8, 0.9))
		var cid = card_id
		if is_disabled:
			# 处于判定管线中（如瑟尔基尔 effect_02）-> 灰显不可选
			btn.disabled = true
			btn.modulate = Color(0.5, 0.5, 0.5)
			btn.tooltip_text = "处理中（不可选）" if card.def.effect_text == "" else "%s\n[处理中·不可选]" % card.def.effect_text
		elif cid == _selected:
			btn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
			btn.modulate = Color(1.2, 1.2, 0.8)
		if not is_disabled:
			btn.pressed.connect(func(): _on_card_selected(cid))
		scroll_content.add_child(btn)


## 单选：选中1张，再点同1张取消选中
## click_to_confirm 模式：点牌即 emit selection_completed（不进选中态），由 app_root 弹"确定使用?"确认框。
func _on_card_selected(card_id: StringName) -> void:
	if _click_to_confirm:
		_selected = card_id
		selection_completed.emit(card_id)
		return
	if _selected == card_id:
		_selected = &""
	else:
		_selected = card_id
	_refresh()


func _on_confirm() -> void:
	selection_completed.emit(_selected)
