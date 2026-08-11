## CardDisplayPanel.gd - 可拖拽非阻塞卡牌展示浮窗
##
## pilot_009 美杜莎「蛇发支配」展示目标行动牌用：非模态、可拖拽、可随时关闭。
## 只弹给查看者（美杜莎），不弹给被展示方（其自己的牌）。不进入模态弹窗堆栈、不抢焦点，
## 不阻塞并行的弃牌选1窗。
extends Panel
class_name CardDisplayPanel

## 标题栏（拖拽手柄）
var _title_bar: Panel
var _title_label: Label
var _close_btn: Button
var _holder_label: Label
var _scroll: ScrollContainer
var _list: VBoxContainer
## 拖拽中
var _dragging: bool = false
var _drag_offset: Vector2 = Vector2.ZERO
var _built: bool = false


func _ready() -> void:
	_ensure_layout()


func _ensure_layout() -> void:
	if _built:
		return
	_built = true
	# 固定尺寸、默认偏左：避免遮挡居中的弃牌选1窗。不在 CenterContainer 内（直接挂根节点），
	# 故 position 生效（左上角）；PRESET_TOP_LEFT 锚点保证不随父容器拉伸。
	custom_minimum_size = Vector2(280, 320)
	size = custom_minimum_size
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = Vector2(20, 60)
	mouse_filter = Control.MOUSE_FILTER_STOP

	_title_bar = Panel.new()
	# PRESET_TOP_LEFT（四锚皆0=对侧相等），避免 PRESET_TOP_WIDE（左右锚不等）下显式设 size
	# 触发 "non-equal opposite anchors" 警告。面板定宽，title_bar 用 size 显式撑满即可。
	_title_bar.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_title_bar.position = Vector2.ZERO
	_title_bar.size = Vector2(size.x, 34)
	_title_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	_title_bar.gui_input.connect(_on_title_bar_gui_input)
	add_child(_title_bar)

	_title_label = Label.new()
	_title_label.text = "目标行动牌"
	_title_label.position = Vector2(8, 6)
	_title_label.size = Vector2(200, 22)
	_title_bar.add_child(_title_label)

	_close_btn = Button.new()
	_close_btn.text = "✕"
	_close_btn.position = Vector2(size.x - 30, 4)
	_close_btn.size = Vector2(24, 24)
	_close_btn.pressed.connect(_on_close_pressed)
	_title_bar.add_child(_close_btn)

	_holder_label = Label.new()
	_holder_label.position = Vector2(8, 40)
	_holder_label.size = Vector2(size.x - 16, 20)
	_holder_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.4))
	add_child(_holder_label)

	_scroll = ScrollContainer.new()
	_scroll.position = Vector2(8, 64)
	_scroll.size = Vector2(size.x - 16, size.y - 72)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 4)
	_scroll.add_child(_list)


## 配置展示内容：holder_name=持有者（目标机甲）名，cards=[{name, type}]
func configure(title: String, holder_name: String, cards: Array) -> void:
	_ensure_layout()
	if _title_label:
		_title_label.text = title if title != "" else "目标行动牌"
	if _holder_label:
		_holder_label.text = "持有者：%s" % holder_name
	# 清空旧条目
	for ch in _list.get_children():
		ch.queue_free()
	for c in cards:
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var name_lbl := Label.new()
		name_lbl.text = String(c.get("name", "???"))
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var type_lbl := Label.new()
		type_lbl.text = String(c.get("type", ""))
		type_lbl.add_theme_color_override("font_color", Color(0.6, 0.7, 0.9))
		row.add_child(name_lbl)
		row.add_child(type_lbl)
		_list.add_child(row)
	visible = true


## 标题栏拖拽：全程用 global 坐标系，避免 local/global 混用导致的跳变偏移。
func _on_title_bar_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = true
			_drag_offset = get_global_mouse_position() - global_position
		else:
			_dragging = false
	elif event is InputEventMouseMotion and _dragging:
		global_position = get_global_mouse_position() - _drag_offset


func _on_close_pressed() -> void:
	visible = false
