## MechDetailPanel.gd - 机甲详细信息弹窗
##
## 由装备面板「详情」按钮打开。展示机甲 HP/动力/护甲的当前值，
## 以及动力上限与护甲的来源明细（基础框架/装备/损伤/光环/派生/临时/状态），
## 并列出当前全部状态。供玩家核查数值来源、排查装备效果。
##
## 通用：configure(mech, context) 接受任意玩家的机甲，PvP 多人类玩家可复用。
extends PopupPanel
class_name MechDetailPanel

var _context = null  # type: GameContext
var _mech = null     # type: MechState
var _armor_container: VBoxContainer = null
var _power_container: VBoxContainer = null
var _status_container: VBoxContainer = null
var _summary_label: Label = null


func _ready() -> void:
	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(420, 0)
	add_child(vbox)

	var title := Label.new()
	title.text = "── 机甲详情 ──"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.8, 0.85, 0.95))
	vbox.add_child(title)

	_summary_label = Label.new()
	_summary_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_summary_label)

	vbox.add_child(HSeparator.new())

	vbox.add_child(_make_header("护甲来源"))
	_armor_container = VBoxContainer.new()
	vbox.add_child(_armor_container)

	vbox.add_child(HSeparator.new())

	vbox.add_child(_make_header("动力来源"))
	_power_container = VBoxContainer.new()
	vbox.add_child(_power_container)

	vbox.add_child(HSeparator.new())

	vbox.add_child(_make_header("状态"))
	_status_container = VBoxContainer.new()
	vbox.add_child(_status_container)

	var close_btn := Button.new()
	close_btn.text = "关闭"
	close_btn.custom_minimum_size = Vector2(140, 32)
	close_btn.pressed.connect(func(): visible = false)
	vbox.add_child(close_btn)


## 配置弹窗：传入要展示的机甲与 GameContext
func configure(mech, game_context) -> void:
	_mech = mech
	_context = game_context
	_refresh()


func _refresh() -> void:
	if _mech == null:
		return
	var mech_name: String = _mech.frame_def.display_name if (_mech.frame_def != null) else String(_mech.mech_id)
	var owner := String(_mech.owner_player_id)
	_summary_label.text = "%s（玩家:%s）\nHP: %d/%d   动力: %d/%d   护甲: %d" % [
		mech_name, owner,
		_mech.current_hp, _mech.max_hp,
		_mech.power, _mech.max_power,
		_mech.get_armor(),
	]
	_refresh_armor()
	_refresh_power()
	_refresh_status()


func _refresh_armor() -> void:
	for c in _armor_container.get_children():
		c.queue_free()
	var items: Array = _mech.get_armor_breakdown(_context)
	var total := 0
	for item in items:
		total += int(item.get("amount", 0))
		_add_breakdown_line(_armor_container, item)
	_add_total_line(_armor_container, total)


func _refresh_power() -> void:
	for c in _power_container.get_children():
		c.queue_free()
	# 当前/上限/已消耗
	_add_info_line(_power_container, "当前动力: %d / 上限: %d" % [_mech.power, _mech.max_power], Color(0.85, 0.85, 0.95))
	_add_info_line(_power_container, "本回合已消耗: %d" % _mech.power_spent_this_turn, Color(0.75, 0.75, 0.8))
	var items: Array = _mech.get_power_breakdown(_context)
	var total := 0
	for item in items:
		total += int(item.get("amount", 0))
		_add_breakdown_line(_power_container, item)
	_add_total_line(_power_container, total, "上限合计")


func _refresh_status() -> void:
	for c in _status_container.get_children():
		c.queue_free()
	if _mech.statuses.is_empty():
		var lbl := Label.new()
		lbl.text = "（无状态）"
		lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		_status_container.add_child(lbl)
		return
	for st: Dictionary in _mech.statuses:
		var stype := String(st.get("type", &""))
		var parts: Array = []
		var stacks := int(st.get("stacks", 0))
		if stacks != 0:
			parts.append("层数%d" % stacks)
		var delta := int(st.get("delta", 0))
		if delta != 0:
			parts.append("数值%+d" % delta)
		var dur := String(st.get("duration", &""))
		if dur != "":
			parts.append("持续%s" % dur)
		var src := _resolve_source(st.get("source_card_id", &""))
		if src != "":
			parts.append("来源:%s" % src)
		var text := stype
		if not parts.is_empty():
			text += "（%s）" % " ".join(parts)
		var lbl := Label.new()
		lbl.text = "• " + text
		lbl.add_theme_color_override("font_color", Color(0.85, 0.8, 0.6))
		_status_container.add_child(lbl)


# ── 内部辅助 ──


func _make_header(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", Color(0.7, 0.8, 0.95))
	lbl.add_theme_font_size_override("font_size", 15)
	return lbl


func _add_info_line(container: Container, text: String, color: Color) -> void:
	var lbl := Label.new()
	lbl.text = "  " + text
	lbl.add_theme_color_override("font_color", color)
	container.add_child(lbl)


func _add_breakdown_line(container: Container, item: Dictionary) -> void:
	var amount := int(item.get("amount", 0))
	var temporary := bool(item.get("temporary", false))
	var sign_str := "+" if amount >= 0 else ""
	var lbl := Label.new()
	lbl.text = "  %s   %s%d" % [String(item.get("label", "")), sign_str, amount]
	var color := Color(0.8, 0.85, 0.8)
	if amount < 0:
		color = Color(0.95, 0.55, 0.55)
	elif temporary:
		color = Color(0.7, 0.9, 0.95)
	lbl.add_theme_color_override("font_color", color)
	container.add_child(lbl)


func _add_total_line(container: Container, total: int, prefix: String = "合计") -> void:
	var lbl := Label.new()
	lbl.text = "  ───────\n  %s: %d" % [prefix, total]
	lbl.add_theme_color_override("font_color", Color(0.95, 0.9, 0.7))
	container.add_child(lbl)


func _resolve_source(card_id) -> String:
	if _context == null or _context.get("game_state") == null:
		return ""
	var cid_str := String(card_id)
	if cid_str == "":
		return ""
	var card = _context.game_state.get_card(StringName(cid_str))
	if card != null and card.def != null:
		return card.def.display_name
	return ""
