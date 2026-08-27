## HiddenCardViewPanel.gd — 查看隐藏装备面板（霍恩 pilot_046 等 HIDDEN_VIEW_AND_ACQUIRE）
##
## 阻塞弹窗 Phase A：列出「商店隐藏高级牌 + 其他机甲备用区隐藏装备」（白板，牌面原价）。
## 点击候选牌选中，点「花费获取」扣除该牌牌面原价金币后置于目标备用区（Phase B 由 choice_panel 完成）。
## 查看无条件：打开面板即可看到候选牌；关闭=取消获取（效果可反复再点）。
## 获取每回合1次：acquire_used 时「花费获取」置灰（TimingEngine 仍会二次校验兜底）。
extends PopupPanel
class_name HiddenCardViewPanel

## 花费获取信号（card_id=选中候选牌 instance_id）
signal acquire_clicked(card_id: StringName)
## 关闭面板信号（取消效果）
signal cancelled()

var _gold_label: Label = null
var _content: VBoxContainer = null
var _acquire_btn: Button = null
## 候选牌按钮缓存（单选）
var _candidate_buttons: Array[Button] = []
var _candidate_ids: Array[StringName] = []
## 各候选牌牌面原价（花费获取扣款额）
var _candidate_costs: Array[int] = []
var _selected_index: int = -1
var _gold: int = 0
var _acquire_used: bool = false


func _ready() -> void:
	var vbox := VBoxContainer.new()
	add_child(vbox)

	# 标题
	var heading := Label.new()
	heading.text = "── 查看隐藏装备 ──"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 18)
	heading.add_theme_color_override("font_color", Color(0.6, 0.7, 1.0))
	vbox.add_child(heading)

	# 玩家金币显示
	_gold_label = Label.new()
	_gold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_gold_label.add_theme_font_size_override("font_size", 16)
	_gold_label.add_theme_color_override("font_color", Color(1, 0.85, 0.3))
	vbox.add_child(_gold_label)

	# 滚动容器
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(420, 320)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_content)

	# 操作按钮区
	var button_box := HBoxContainer.new()
	button_box.alignment = BoxContainer.ALIGNMENT_CENTER
	button_box.add_theme_constant_override("separation", 10)
	vbox.add_child(button_box)

	_acquire_btn = Button.new()
	_acquire_btn.text = "花费获取"
	_acquire_btn.custom_minimum_size = Vector2(120, 36)
	_acquire_btn.pressed.connect(func():
		if _selected_index >= 0 and _selected_index < _candidate_ids.size():
			acquire_clicked.emit(_candidate_ids[_selected_index])
	)
	button_box.add_child(_acquire_btn)

	var close_btn := Button.new()
	close_btn.text = "关闭"
	close_btn.custom_minimum_size = Vector2(100, 36)
	close_btn.pressed.connect(func():
		visible = false
		cancelled.emit()
	)
	vbox.add_child(close_btn)


## 配置面板。candidates 每项 {card_id, name, rarity, cost, source_type, source_label, ...}；
## gold=本窗口玩家的金币；acquire_used=本回合获取额度已用（花费获取置灰）。
func configure(candidates: Array[Dictionary], gold: int, acquire_used: bool = false) -> void:
	# 清除旧候选
	for child in _content.get_children():
		child.queue_free()
	_candidate_buttons.clear()
	_candidate_ids.clear()
	_candidate_costs.clear()
	_selected_index = -1
	_gold = gold
	_acquire_used = acquire_used

	if _gold_label:
		_gold_label.text = "金币: %d" % gold

	for c in candidates:
		var cid: StringName = c.get("card_id", &"")
		var cname: String = String(c.get("name", "？"))
		var crarity: String = String(c.get("rarity", "N"))
		var ccost: int = int(c.get("cost", 0))
		var csrc: String = String(c.get("source_label", ""))
		_candidate_ids.append(cid)
		_candidate_costs.append(ccost)

		var btn := Button.new()
		btn.custom_minimum_size = Vector2(380, 40)
		btn.text = "%s [%s]  %s  %d金币" % [cname, crarity, csrc, ccost]
		var idx := _candidate_buttons.size()
		btn.toggle_mode = true
		btn.toggled.connect(func(_on: bool):
			_select_index(idx)
		)
		_set_rarity_color(btn, crarity)
		_content.add_child(btn)
		_candidate_buttons.append(btn)

	if candidates.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "（没有可获取的隐藏装备牌）"
		empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		_content.add_child(empty_lbl)

	# 花费获取：选中 + 金够 + 额度未用才可点
	_refresh_acquire_button()


## 单选：只保留选中项的 toggle 状态
func _select_index(idx: int) -> void:
	_selected_index = idx
	for i in range(_candidate_buttons.size()):
		_candidate_buttons[i].button_pressed = (i == idx)
	_refresh_acquire_button()


## 花费获取按钮可用性：已选牌 + 金币够（≥牌面原价） + 每回合额度未用满
func _refresh_acquire_button() -> void:
	if _acquire_btn == null:
		return
	var has_sel: bool = _selected_index >= 0 and _selected_index < _candidate_ids.size()
	var cost_ok: bool = true
	if has_sel:
		cost_ok = _gold >= _candidate_costs[_selected_index]
	_acquire_btn.disabled = (not has_sel) or _acquire_used or not cost_ok
	if _acquire_used:
		_acquire_btn.tooltip_text = "本回合已使用过获取（每回合1次）"
	elif not has_sel:
		_acquire_btn.tooltip_text = "先选择1张隐藏装备牌"
	elif not cost_ok:
		_acquire_btn.tooltip_text = "金币不足（需要%d）" % _candidate_costs[_selected_index]
	else:
		_acquire_btn.tooltip_text = ""


## 按稀有度着色候选按钮
func _set_rarity_color(btn: Button, rarity: String) -> void:
	match rarity:
		"N":
			btn.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
		"R":
			btn.add_theme_color_override("font_color", Color(0.3, 0.9, 0.5))
		"SR":
			btn.add_theme_color_override("font_color", Color(0.3, 0.7, 1.0))
		"SSR":
			btn.add_theme_color_override("font_color", Color(1.0, 0.7, 0.3))
