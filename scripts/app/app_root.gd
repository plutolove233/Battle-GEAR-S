extends Control

const _DataRegistry = preload("res://scripts/data/data_registry.gd")
const _CampaignState = preload("res://scripts/campaign/campaign_state.gd")
const _BattleState = preload("res://scripts/battle/battle_state.gd")
const _RangeCalculator = preload("res://scripts/battle/RangeCalculator.gd")
const _BattleMessageLog = preload("res://scripts/ui/battle_message_log.gd")
const _EnemyInfoPopup = preload("res://scripts/ui/enemy_info_popup.gd")

var registry = null  # type: DataRegistry
var campaign = null  # type: CampaignState
var battle = null  # type: BattleState
var selected_equipment: Dictionary = {}
var current_screen: Control
var status_label: Label
var battle_summary_label: Label
var battle_board = null  # type: BattleBoard
var hand_panel = null  # type: HandPanel
var equipment_panel = null  # type: EquipmentPanel
var skill_bar = null  # type: SkillBar
var response_panel = null  # type: ResponsePanel
var message_log = null  # type: BattleMessageLog
var enemy_info_popup = null  # type: EnemyInfoPopup

## 攻击交互状态
var attack_mode: bool = false
var selected_attack_card_id: StringName = &""
var selected_weapon_id: StringName = &""

func _ready() -> void:
	_load_app_state()

func _load_app_state() -> void:
	registry = _DataRegistry.new()
	var load_result = registry.load_all()
	if not _status_ok(load_result):
		_show_error("资料载入失败: %s" % _status_message(load_result))
		return
	campaign = _CampaignState.new()
	var init_result = campaign.initialize(registry)
	if not _status_ok(init_result):
		_show_error("战役初始化失败: %s" % _status_message(init_result))
		return
	selected_equipment = {}
	_show_main_menu()

# ═══════════════════════════════════════════
# 主菜单
# ═══════════════════════════════════════════

func _show_main_menu() -> void:
	var layout := _begin_screen("机斗战甲")
	_add_button(layout, "新战役", Callable(self, "_show_loadout"))
	_add_button(layout, "图鉴", Callable(self, "_show_collection"))
	_add_button(layout, "退出", Callable(self, "_quit_app"))

# ═══════════════════════════════════════════
# 出击准备
# ═══════════════════════════════════════════

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
	var selection_result = campaign.select_equipment(ids)
	if not _status_ok(selection_result):
		_show_status("装备选择失败: %s" % _status_message(selection_result))
		return
	var context = campaign.build_tutorial_context()
	if not _status_ok(context):
		_show_status("战役上下文失败: %s" % _status_message(context))
		return
	battle = _BattleState.new()
	battle.pre_selected_equipment = ids
	var start_result = battle.start_tutorial(registry)
	if not _status_ok(start_result):
		_show_status("战斗启动失败: %s" % _status_message(start_result))
		return
	var turn_result = battle.start_turn("player")
	if not _status_ok(turn_result):
		battle.log.append({"message": "玩家回合启动失败", "details": {"reason": _status_message(turn_result)}})
	_show_battle()

# ═══════════════════════════════════════════
# 战斗界面 — 左右分区布局
# ═══════════════════════════════════════════

func _show_battle() -> void:
	var layout := _begin_screen("教学战斗")

	# ── 状态栏 ──
	battle_summary_label = Label.new()
	battle_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(battle_summary_label)

	# ── 主区域：左边地图 + 右边信息面板 ──
	var main_hbox := HBoxContainer.new()
	main_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_hbox.add_theme_constant_override("separation", 4)
	layout.add_child(main_hbox)

	# 左侧：地图
	battle_board = BattleBoard.new()
	battle_board.custom_minimum_size = Vector2(0, 0)
	battle_board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	battle_board.size_flags_vertical = Control.SIZE_EXPAND_FILL
	battle_board.hex_clicked.connect(Callable(self, "_on_battle_hex_clicked"))
	main_hbox.add_child(battle_board)

	# 右侧：装备面板 + 技能栏 + 消息日志
	var right_panel := VBoxContainer.new()
	right_panel.custom_minimum_size = Vector2(280, 0)
	right_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_hbox.add_child(right_panel)

	equipment_panel = EquipmentPanel.new()
	equipment_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	equipment_panel.custom_minimum_size = Vector2(0, 200)
	right_panel.add_child(equipment_panel)

	skill_bar = SkillBar.new()
	skill_bar.active_effect_clicked.connect(Callable(self, "_on_active_effect_clicked"))
	right_panel.add_child(skill_bar)

	# 消息日志（右侧面板底部，占据剩余空间）
	message_log = _BattleMessageLog.new()
	message_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_panel.add_child(message_log)

	# ── 手牌区 ──
	hand_panel = HandPanel.new()
	hand_panel.action_card_clicked.connect(Callable(self, "_on_action_card_clicked"))
	hand_panel.equipment_card_clicked.connect(Callable(self, "_on_equipment_card_clicked"))
	layout.add_child(hand_panel)

	# ── 操作栏 ──
	var action_bar := HBoxContainer.new()
	action_bar.alignment = BoxContainer.ALIGNMENT_CENTER
	layout.add_child(action_bar)
	_add_button(action_bar, "结束回合", Callable(self, "_end_player_turn"))
	_add_button(action_bar, "敌方信息", Callable(self, "_on_enemy_info_clicked"))
	_add_button(action_bar, "返回主菜单", Callable(self, "_show_main_menu"))

	# ── 敌方信息弹窗（初始隐藏）──
	enemy_info_popup = _EnemyInfoPopup.new()
	add_child(enemy_info_popup)

	# ── 迎击面板（初始隐藏）──
	response_panel = ResponsePanel.new()
	response_panel.response_selected.connect(Callable(self, "_on_response_selected"))
	response_panel.response_passed.connect(Callable(self, "_on_response_passed"))
	response_panel.visible = false
	layout.add_child(response_panel)

	# ── 连接 EffectEngine hook 信号 ──
	if battle.context and battle.context.effect_engine:
		battle.context.effect_engine.hook_fired.connect(Callable(self, "_on_hook_fired"))

	# 初始配置消息日志（追赶历史日志）
	if message_log and battle.context:
		message_log.configure(battle.context)

	_refresh_battle()

# ═══════════════════════════════════════════
# 战斗交互
# ═══════════════════════════════════════════

## 点击地图格子
func _on_battle_hex_clicked(hex: Dictionary) -> void:
	if battle == null:
		return

	# 如果在攻击模式，尝试攻击该位置上的机甲
	if attack_mode:
		_try_attack_target(hex)
		return

	# 否则尝试移动
	var result = battle.move_unit("player", hex)
	if not _status_ok(result):
		battle.log.append({"message": "无法移动", "details": {"reason": _status_message(result)}})
	_refresh_battle()

## 点击行动牌
func _on_action_card_clicked(card_id: StringName) -> void:
	if battle == null or battle.context == null:
		return
	var gs = battle.context.game_state
	var card = gs.get_card(card_id)
	if not card or not card.def:
		return

	# 判断行动牌类型
	var action_type: String = String(card.def.action_type)
	match action_type:
		"攻击":
			_enter_attack_mode(card_id)
		"迎击":
			battle.log.append({"message": "迎击牌在响应窗口自动使用", "details": {}})
		"辅助":
			_play_action_card(card_id)

## 点击装备牌
func _on_equipment_card_clicked(card_id: StringName) -> void:
	if battle == null or battle.context == null:
		return
	var gs = battle.context.game_state
	var card = gs.get_card(card_id)
	if not card or not card.def:
		return

	# 自动选择槽位并设置装备
	var player = gs.players.get(&"player")
	var mech = gs.get_mech_for_player(&"player")
	if not player or not mech:
		return

	var slot_id: StringName = &""
	if card.def.equipment_kind == &"PART":
		slot_id = card.def.slot
	elif card.def.equipment_kind == &"WEAPON":
		for ws_id: StringName in [&"weapon_1", &"weapon_2"]:
			if mech.slots.has(ws_id) and not mech.slots[ws_id].equipped_card:
				slot_id = ws_id
				break
		if slot_id == &"":
			slot_id = &"weapon_1"

	if slot_id == &"":
		battle.log.append({"message": "无可用槽位", "details": {}})
		_refresh_battle()
		return

	var result: Dictionary = battle.context.card_set_service.set_equipment(&"player", card_id, slot_id)
	if result.get("ok", false):
		battle.log.append({"message": "装备了 %s" % card.def.display_name, "details": {}})
	else:
		battle.log.append({"message": "装备失败: %s" % String(result.get("message", "")), "details": {}})
	_refresh_battle()

## 点击主动效果按钮
func _on_active_effect_clicked(effect_id: StringName) -> void:
	if battle == null or battle.context == null:
		return
	# TODO: 弹出选择界面让玩家选来源牌，当前简化为第一个匹配的
	var bindings = battle.context.effect_registry.get_all_active_bindings()
	for binding in bindings:
		if binding.effect.effect_id == effect_id:
			var success: bool = battle.context.effect_engine.use_active_effect(
				binding.get_source_instance_id(), effect_id, {}
			)
			if success:
				battle.log.append({"message": "使用了技能: %s" % binding.effect.display_name, "details": {}})
			else:
				battle.log.append({"message": "技能使用失败", "details": {}})
			break
	_refresh_battle()

## 结束玩家回合
func _end_player_turn() -> void:
	if battle == null:
		return
	attack_mode = false
	selected_attack_card_id = &""
	selected_weapon_id = &""
	var result = battle.end_player_turn()
	if not _status_ok(result):
		battle.log.append({"message": "结束回合失败", "details": {"reason": _status_message(result)}})
	_refresh_battle()
	_finish_battle_if_needed()

## 迎击选择
func _on_response_selected(card_id: StringName) -> void:
	if battle == null:
		return
	battle.submit_response(card_id)
	response_panel.visible = false
	_refresh_battle()

## 跳过迎击
func _on_response_passed() -> void:
	if battle == null:
		return
	battle.pass_response()
	response_panel.visible = false
	_refresh_battle()

## EffectEngine hook 信号回调：转发给消息日志
func _on_hook_fired(hook: StringName, payload: Dictionary) -> void:
	if message_log:
		message_log.on_hook_fired(hook, payload)

## 敌方信息按钮点击
func _on_enemy_info_clicked() -> void:
	if enemy_info_popup and battle and battle.context:
		enemy_info_popup.configure(battle.context)
		enemy_info_popup.popup_centered(Vector2i(320, 520))

# ═══════════════════════════════════════════
# 攻击交互流程
# ═══════════════════════════════════════════

## 进入攻击模式
func _enter_attack_mode(attack_card_id: StringName) -> void:
	if battle == null or battle.context == null:
		return
	var gs = battle.context.game_state
	var mech = gs.get_mech_for_player(&"player")
	if not mech:
		return

	# 获取武器列表
	var weapon_ids: Array[StringName] = mech.get_weapon_ids()
	if weapon_ids.is_empty():
		battle.log.append({"message": "没有可用武器", "details": {}})
		return

	# 如果有2把武器，暂时选第一把（后续可弹出武器选择）
	if weapon_ids.size() > 1:
		selected_weapon_id = weapon_ids[0]
	else:
		selected_weapon_id = weapon_ids[0]

	selected_attack_card_id = attack_card_id
	attack_mode = true

	# 高亮攻击范围
	var weapon_card = gs.get_card(selected_weapon_id)
	var weapon_range: int = 1
	if weapon_card and weapon_card.def:
		weapon_range = weapon_card.def.range_value
	var reachable: Array[Dictionary] = _RangeCalculator.get_weapon_reachable_hexes(
		mech.position, weapon_range, gs.map_state.cells
	)
	battle_board.highlight_hexes(reachable)
	battle.log.append({"message": "攻击模式：选择目标（点击敌方位置）", "details": {}})
	_refresh_battle()

## 尝试攻击目标
func _try_attack_target(hex: Dictionary) -> void:
	if battle == null or battle.context == null:
		return
	attack_mode = false
	battle_board.clear_highlight()

	var gs = battle.context.game_state
	# 检查hex上是否有敌方机甲
	var target_mech_id: StringName = &""
	for mech_id: StringName in gs.mechs:
		var m = gs.mechs[mech_id]
		if m.destroyed:
			continue
		if int(m.position.get("q", 0)) == int(hex.get("q", 0)) and int(m.position.get("r", 0)) == int(hex.get("r", 0)):
			if m.owner_player_id != &"player":
				target_mech_id = mech_id
				break

	if target_mech_id == &"":
		battle.log.append({"message": "该位置无敌方机甲", "details": {}})
		_refresh_battle()
		return

	# 发动攻击
	var player_mech = gs.get_mech_for_player(&"player")
	if not player_mech:
		return
	var result: Dictionary = battle.context.attack_service.declare_attack(
		player_mech.mech_id, target_mech_id, selected_weapon_id, selected_attack_card_id
	)

	attack_mode = false
	selected_attack_card_id = &""
	selected_weapon_id = &""

	if result.get("state", "") == "awaiting_response":
		# 显示迎击面板
		response_panel.configure(battle.context, result.get("attack_id", &""))
		response_panel.visible = true
		# 自动解决（简化处理）
		battle._auto_resolve_response()
		_finish_attack_and_refresh()
	elif result.get("ok", false):
		battle.log.append({"message": "攻击成功", "details": result})
		_refresh_battle()
	else:
		battle.log.append({"message": "攻击失败: %s" % String(result.get("message", "")), "details": {}})
		_refresh_battle()

	_finish_battle_if_needed()

## 打出辅助牌
func _play_action_card(card_id: StringName) -> void:
	if battle == null or battle.context == null:
		return
	var result: Dictionary = battle.context.card_play_service.play_action_card(&"player", card_id)
	if result.get("ok", false):
		battle.log.append({"message": "打出了行动牌", "details": {}})
	else:
		battle.log.append({"message": "打出失败: %s" % String(result.get("message", "")), "details": {}})
	_refresh_battle()

## 完成攻击并刷新
func _finish_attack_and_refresh() -> void:
	if battle == null:
		return
	var result: Dictionary = battle._finish_attack()
	battle.log.append({"message": "攻击结算", "details": result})
	_sync_and_refresh()

# ═══════════════════════════════════════════
# 刷新与工具
# ═══════════════════════════════════════════

func _refresh_battle() -> void:
	if battle == null:
		return

	# 同步兼容字段
	battle._sync_compat_fields()

	var player: Dictionary = battle.units.get("player", {})
	var enemy: Dictionary = battle.units.get("enemy", {})

	# 更新状态栏
	if battle_summary_label:
		battle_summary_label.text = "回合 %d | 行动方: %s | 我方 HP %d/%d 动力 %d/%d 金币 %d | 敌方 HP %d/%d" % [
			battle.turn_number,
			battle.active_side,
			int(player.get("life", 0)),
			int(player.get("max_life", 0)),
			int(player.get("power", 0)),
			int(player.get("max_power", 0)),
			int(player.get("gold", 0)),
			int(enemy.get("life", 0)),
			int(enemy.get("max_life", 0)),
		]

	# 更新地图
	if battle_board:
		battle_board.configure(battle.map_tiles, battle.units)

	# 更新手牌面板
	if hand_panel and battle.context:
		hand_panel.configure(battle.context)

	# 更新装备面板
	if equipment_panel and battle.context:
		var mech = battle.context.game_state.get_mech_for_player(&"player")
		if mech:
			equipment_panel.configure(mech)

	# 更新技能栏
	if skill_bar and battle.context:
		skill_bar.configure(battle.context)

	# 更新消息日志（追赶新日志条目）
	if message_log and battle.context:
		message_log.configure(battle.context)

func _sync_and_refresh() -> void:
	_refresh_battle()

func _finish_battle_if_needed() -> void:
	var result = battle.get_result()
	if String(result.get("state", "inactive")) == "active":
		return
	var record := {
		"state": String(result.get("state", "inactive")),
		"reason": String(result.get("reason", "")),
		"turn_count": battle.turn_number,
	}
	campaign.record_battle_result(record)
	_show_result(record)

# ═══════════════════════════════════════════
# 结果 / 战役中心 / 图鉴
# ═══════════════════════════════════════════

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

# ═══════════════════════════════════════════
# UI 工具方法
# ═══════════════════════════════════════════

func _begin_screen(title: String) -> VBoxContainer:
	_clear_screen()
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_bottom", 16)
	add_child(margin)
	current_screen = margin
	var layout := VBoxContainer.new()
	layout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layout.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.alignment = BoxContainer.ALIGNMENT_CENTER
	layout.add_theme_constant_override("separation", 4)
	margin.add_child(layout)
	var heading := Label.new()
	heading.text = title
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 22)
	layout.add_child(heading)
	status_label = Label.new()
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(status_label)
	return layout

func _clear_screen() -> void:
	# 断开 EffectEngine hook 信号，防止悬挂引用
	if battle and battle.context and battle.context.effect_engine:
		if battle.context.effect_engine.hook_fired.is_connected(Callable(self, "_on_hook_fired")):
			battle.context.effect_engine.hook_fired.disconnect(Callable(self, "_on_hook_fired"))
	if enemy_info_popup and is_instance_valid(enemy_info_popup):
		enemy_info_popup.queue_free()
	if current_screen != null and is_instance_valid(current_screen):
		current_screen.queue_free()
	current_screen = null
	status_label = null
	battle_summary_label = null
	message_log = null
	enemy_info_popup = null
	battle_board = null
	hand_panel = null
	equipment_panel = null
	skill_bar = null
	response_panel = null

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
	button.custom_minimum_size = Vector2(140, 32)
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
