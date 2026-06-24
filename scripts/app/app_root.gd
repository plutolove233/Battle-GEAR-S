extends Control

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const CampaignState = preload("res://scripts/campaign/campaign_state.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const BattleBoard = preload("res://scripts/ui/battle_board.gd")

var registry: DataRegistry
var campaign: CampaignState
var battle: BattleState
var selected_equipment: Dictionary = {}
var current_screen: Control
var status_label: Label
var battle_summary_label: Label
var battle_log: RichTextLabel
var battle_board: BattleBoard

func _ready() -> void:
	_load_app_state()

func _load_app_state() -> void:
	registry = DataRegistry.new()
	var load_result := registry.load_all()
	if not _status_ok(load_result):
		_show_error("资料载入失败: %s" % _status_message(load_result))
		return
	campaign = CampaignState.new()
	var init_result := campaign.initialize(registry)
	if not _status_ok(init_result):
		_show_error("战役初始化失败: %s" % _status_message(init_result))
		return
	selected_equipment = {}
	_show_main_menu()

func _show_main_menu() -> void:
	var layout := _begin_screen("机斗战甲")
	_add_button(layout, "新战役", Callable(self, "_show_loadout"))
	_add_button(layout, "图鉴", Callable(self, "_show_collection"))
	_add_button(layout, "退出", Callable(self, "_quit_app"))

func _show_loadout() -> void:
	var layout := _begin_screen("出击准备")
	var pilot: Dictionary = campaign.selected_pilot
	_add_text(layout, "机师: %s" % String(pilot.get("name", "克劳德")))
	_add_text(layout, "选择可用装备")
	for item in campaign.list_available_equipment():
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var id := String(item.get("id", ""))
		if id == "":
			continue
		var checkbox := CheckBox.new()
		checkbox.text = _equipment_label(item)
		checkbox.button_pressed = bool(selected_equipment.get(id, false))
		checkbox.toggled.connect(Callable(self, "_on_equipment_toggled").bind(id))
		layout.add_child(checkbox)
	_add_button(layout, "开始教学战斗", Callable(self, "_start_tutorial_battle"))
	_add_button(layout, "返回", Callable(self, "_show_main_menu"))

func _start_tutorial_battle() -> void:
	var ids: Array[String] = []
	for id in selected_equipment.keys():
		if bool(selected_equipment[id]):
			ids.append(String(id))
	var selection_result := campaign.select_equipment(ids)
	if not _status_ok(selection_result):
		_show_status("装备选择失败: %s" % _status_message(selection_result))
		return
	var context := campaign.build_tutorial_context()
	if not _status_ok(context):
		_show_status("战役上下文失败: %s" % _status_message(context))
		return
	battle = BattleState.new()
	var start_result := battle.start_tutorial(registry)
	if not _status_ok(start_result):
		_show_status("战斗启动失败: %s" % _status_message(start_result))
		return
	for equipment_id in ids:
		var equip_result := battle.set_equipment("player", equipment_id)
		if not _status_ok(equip_result):
			battle.log.append({"message": "装备未带入: %s" % equipment_id, "details": {"reason": _status_message(equip_result)}})
	var turn_result := battle.start_turn("player")
	if not _status_ok(turn_result):
		battle.log.append({"message": "玩家回合启动失败", "details": {"reason": _status_message(turn_result)}})
	_show_battle()

func _show_battle() -> void:
	var layout := _begin_screen("教学战斗")
	battle_summary_label = Label.new()
	battle_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(battle_summary_label)
	var action_bar := HBoxContainer.new()
	action_bar.alignment = BoxContainer.ALIGNMENT_CENTER
	layout.add_child(action_bar)
	_add_button(action_bar, "武器1攻击", Callable(self, "_attack_with_first_weapon"))
	_add_button(action_bar, "结束回合", Callable(self, "_end_player_turn"))
	_add_button(action_bar, "返回主菜单", Callable(self, "_show_main_menu"))
	battle_board = BattleBoard.new()
	battle_board.custom_minimum_size = Vector2(640, 430)
	battle_board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	battle_board.size_flags_vertical = Control.SIZE_EXPAND_FILL
	battle_board.hex_clicked.connect(Callable(self, "_on_battle_hex_clicked"))
	layout.add_child(battle_board)
	battle_log = RichTextLabel.new()
	battle_log.custom_minimum_size = Vector2(640, 150)
	battle_log.fit_content = false
	battle_log.scroll_following = true
	layout.add_child(battle_log)
	_refresh_battle()

func _on_battle_hex_clicked(hex: Dictionary) -> void:
	if battle == null:
		return
	var result := battle.move_unit("player", hex)
	if not _status_ok(result):
		battle.log.append({"message": "无法移动", "details": {"reason": _status_message(result)}})
	_refresh_battle()

func _attack_with_first_weapon() -> void:
	if battle == null:
		return
	var result := battle.attack("player", "enemy", 0)
	if not _status_ok(result):
		battle.log.append({"message": "攻击失败", "details": {"reason": _status_message(result)}})
	_refresh_battle()
	_finish_battle_if_needed()

func _end_player_turn() -> void:
	if battle == null:
		return
	var result := battle.end_player_turn()
	if not _status_ok(result):
		battle.log.append({"message": "结束回合失败", "details": {"reason": _status_message(result)}})
	_refresh_battle()
	_finish_battle_if_needed()

func _finish_battle_if_needed() -> void:
	var result := battle.get_result()
	if String(result.get("state", "inactive")) == "active":
		return
	var record := {
		"state": String(result.get("state", "inactive")),
		"reason": String(result.get("reason", "")),
		"turn_count": battle.turn_number,
	}
	campaign.record_battle_result(record)
	_show_result(record)

func _show_result(result: Dictionary) -> void:
	var layout := _begin_screen("战斗结果")
	var state := String(result.get("state", "inactive"))
	var state_text := "胜利" if state == "victory" else "失败"
	_add_text(layout, state_text)
	_add_text(layout, "原因: %s" % String(result.get("reason", "")))
	_add_text(layout, "回合数: %d" % int(result.get("turn_count", 0)))
	_add_button(layout, "重试", Callable(self, "_start_tutorial_battle"))
	_add_button(layout, "返回战役中心", Callable(self, "_show_campaign_hub"))
	_add_button(layout, "返回主菜单", Callable(self, "_show_main_menu"))

func _show_campaign_hub() -> void:
	var layout := _begin_screen("战役中心")
	var pilot: Dictionary = campaign.selected_pilot
	_add_text(layout, "当前机师: %s" % String(pilot.get("name", "克劳德")))
	if campaign.last_result.is_empty():
		_add_text(layout, "上次结果: 暂无")
	else:
		var state := String(campaign.last_result.get("state", "inactive"))
		var result_text := "胜利" if state == "victory" else "失败"
		_add_text(layout, "上次结果: %s - %s" % [result_text, String(campaign.last_result.get("reason", ""))])
		_add_text(layout, "上次回合数: %d" % int(campaign.last_result.get("turn_count", 0)))
	_add_button(layout, "再来一战", Callable(self, "_start_tutorial_battle"))
	_add_button(layout, "调整装备", Callable(self, "_show_loadout"))
	_add_button(layout, "返回主菜单", Callable(self, "_show_main_menu"))

func _show_collection() -> void:
	var layout := _begin_screen("图鉴")
	_add_text(layout, "奖励与解锁不在最小实现范围内。")
	_add_button(layout, "返回主菜单", Callable(self, "_show_main_menu"))

func _show_error(message: String) -> void:
	var layout := _begin_screen("启动失败")
	_add_text(layout, message)
	_add_button(layout, "退出", Callable(self, "_quit_app"))

func _refresh_battle() -> void:
	if battle == null:
		return
	var player: Dictionary = battle.units.get("player", {})
	var enemy: Dictionary = battle.units.get("enemy", {})
	battle_summary_label.text = "回合 %d / 行动方: %s\n我方 %d/%d  动力 %d/%d\n敌方 %d/%d" % [
		battle.turn_number,
		battle.active_side,
		int(player.get("life", 0)),
		int(player.get("max_life", 0)),
		int(player.get("power", 0)),
		int(player.get("max_power", 0)),
		int(enemy.get("life", 0)),
		int(enemy.get("max_life", 0)),
	]
	battle_board.configure(battle.map_tiles, battle.units)
	var lines: Array[String] = []
	for entry in battle.log:
		if typeof(entry) == TYPE_DICTIONARY:
			var line := String(entry.get("message", ""))
			var details: Dictionary = entry.get("details", {})
			if not details.is_empty():
				line += " %s" % JSON.stringify(details)
			lines.append(line)
	battle_log.text = "\n".join(lines)

func _begin_screen(title: String) -> VBoxContainer:
	_clear_screen()
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 32)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_right", 32)
	margin.add_theme_constant_override("margin_bottom", 24)
	add_child(margin)
	current_screen = margin
	var layout := VBoxContainer.new()
	layout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layout.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.alignment = BoxContainer.ALIGNMENT_CENTER
	layout.add_theme_constant_override("separation", 12)
	margin.add_child(layout)
	var heading := Label.new()
	heading.text = title
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 28)
	layout.add_child(heading)
	status_label = Label.new()
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(status_label)
	return layout

func _clear_screen() -> void:
	if current_screen != null and is_instance_valid(current_screen):
		current_screen.queue_free()
	current_screen = null
	status_label = null
	battle_summary_label = null
	battle_log = null
	battle_board = null

func _add_text(parent: Node, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label

func _add_button(parent: Node, text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(180, 36)
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

func _on_equipment_toggled(pressed: bool, id: String) -> void:
	selected_equipment[id] = pressed

func _equipment_label(item: Dictionary) -> String:
	if item.has("name"):
		return "%s (%s)" % [String(item.get("name", "")), String(item.get("rarity", "N"))]
	return "%s-%s (%s)" % [String(item.get("set_name", "装备")), String(item.get("slot", "")), String(item.get("rarity", "N"))]

func _show_status(message: String) -> void:
	if status_label != null:
		status_label.text = message
	else:
		push_warning(message)

func _status_ok(status: Dictionary) -> bool:
	return bool(status.get("ok", false))

func _status_message(status: Dictionary) -> String:
	return String(status.get("message", "unknown error"))

func _quit_app() -> void:
	get_tree().quit()
