## BattleMessageLog.gd — 战斗消息面板
##
## 在右侧面板中显示所有战斗事件的中文文字消息。
## 实时通过 EffectEngine.hook_fired 信号接收事件，
## 并通过 GameState.log 追赶补漏。
extends VBoxContainer
class_name BattleMessageLog

const _EffectConst = preload("res://scripts/effect_core/EffectConst.gd")

var _scroll_container: ScrollContainer
var _text_display: RichTextLabel
var _context = null  # type: GameContext
var _last_log_index: int = 0
var _messages: Array[String] = []

## 槽位中文名映射（与 EquipmentPanel 保持一致）
const SLOT_NAMES: Dictionary = {
	&"头部": "头部", &"躯干": "躯干", &"右臂": "右臂", &"左臂": "左臂",
	&"右腿": "右腿", &"左腿": "左腿",
	&"weapon_1": "武器1", &"weapon_2": "武器2",
	&"reserve_1": "备用1", &"reserve_2": "备用2",
	&"event": "事件", &"pilot": "机师",
}


func _ready() -> void:
	# 标题
	var title := Label.new()
	title.text = "── 战斗消息 ──"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color(0.75, 0.8, 0.85))
	add_child(title)

	# 滚动容器 + 文本显示
	_scroll_container = ScrollContainer.new()
	_scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll_container.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	add_child(_scroll_container)

	_text_display = RichTextLabel.new()
	_text_display.bbcode_enabled = true
	_text_display.fit_content = true
	_text_display.scroll_following = true
	_text_display.custom_minimum_size = Vector2(0, 0)
	_text_display.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text_display.add_theme_font_size_override("normal_font_size", 14)
	_scroll_container.add_child(_text_display)


## 配置面板：连接 GameContext 并追赶历史日志
func configure(game_context) -> void:
	_context = game_context
	_catch_up_log()


## 实时 hook 信号回调：立即翻译并显示（不等待 _refresh_battle）
## 注意：hook 事件也会写入 GameState.log，_catch_up_log 会跳过已处理的条目
func on_hook_fired(hook: StringName, payload: Dictionary) -> void:
	var text := _translate_hook(hook, payload)
	if text != "":
		add_message(text)
		# 推进日志索引，避免 _catch_up_log 重复翻译同一条目
		_advance_log_index()


## 追加一条消息并自动滚动
func add_message(text: String) -> void:
	_messages.append(text)
	_rebuild_display()


# ═══════════════════════════════════════════
# 内部方法
# ═══════════════════════════════════════════


## 追赶 GameState.log 中未读的条目
func _catch_up_log() -> void:
	if _context == null:
		return
	var gs = _context.game_state
	while _last_log_index < gs.log.size():
		var entry: Dictionary = gs.log[_last_log_index]
		var text := _translate_log_entry(entry)
		if text != "":
			_messages.append(text)
		_last_log_index += 1
	_rebuild_display()


## 推进日志索引到当前日志末尾（防止 _catch_up_log 重复翻译 hook 已处理的事件）
func _advance_log_index() -> void:
	if _context == null:
		return
	_last_log_index = _context.game_state.log.size()


## 重建 BBCode 显示文本
func _rebuild_display() -> void:
	var bbcode: String = ""
	for msg in _messages:
		bbcode += msg + "\n"
	_text_display.text = bbcode
	# 延迟一帧自动滚动到底部
	call_deferred("_scroll_to_bottom")


func _scroll_to_bottom() -> void:
	if _scroll_container and is_instance_valid(_scroll_container):
		var vbar = _scroll_container.get_v_scroll_bar()
		if vbar:
			_scroll_container.scroll_vertical = int(vbar.max_value)


# ═══════════════════════════════════════════
# Hook 翻译（实时信号）
# ═══════════════════════════════════════════


func _translate_hook(hook: StringName, payload: Dictionary) -> String:
	# 处理 MapService 历史遗留：ON_TURN_START 带 event=mech_moved
	if hook == &"ON_TURN_START" and payload.get("event") == &"mech_moved":
		return _fmt_mech_moved_hook(payload)

	match hook:
		_EffectConst.HOOK_TURN_START:
			return _fmt_turn_start_hook(payload)
		_EffectConst.HOOK_CARD_PLAYED:
			return _fmt_card_played_hook(payload)
		_EffectConst.HOOK_ATTACK_CARD_PLAYED:
			return _fmt_attack_card_played_hook(payload)
		_EffectConst.HOOK_ATTACK_DECLARED:
			return _fmt_attack_declared_hook(payload)
		_EffectConst.HOOK_ATTACK_HIT:
			return _fmt_attack_hit_hook(payload)
		_EffectConst.HOOK_ATTACK_MISS:
			return _fmt_attack_miss_hook(payload)
		_EffectConst.HOOK_DAMAGE_DEALT:
			return _fmt_damage_dealt_hook(payload)
		_EffectConst.HOOK_ATTACK_RESOLVED:
			return _fmt_attack_resolved_hook(payload)
		_EffectConst.HOOK_EQUIPMENT_SET:
			return _fmt_equipment_set_hook(payload)
		_EffectConst.HOOK_MECH_MOVED:
			return _fmt_mech_moved_hook(payload)
		_EffectConst.HOOK_MECH_DESTROYED:
			return _fmt_mech_destroyed_hook(payload)
		_EffectConst.HOOK_TURN_END:
			return _fmt_turn_end_hook(payload)
		_EffectConst.HOOK_EQUIPMENT_SOLD:
			return _fmt_equipment_sold_hook(payload)
		_EffectConst.HOOK_EQUIPMENT_BROKEN:
			return _fmt_equipment_broken_hook(payload)
	return ""


func _fmt_turn_start_hook(payload: Dictionary) -> String:
	var name := _player_name(String(payload.get("player_id", &"")))
	return "[color=cyan]>> %s 回合开始[/color]" % name


func _fmt_turn_end_hook(payload: Dictionary) -> String:
	var name := _player_name(String(payload.get("player_id", &"")))
	return "%s 回合结束" % name


func _fmt_card_played_hook(payload: Dictionary) -> String:
	var name := _player_name(String(payload.get("player_id", &"")))
	var card_name := _card_display_name(payload.get("card_id", &""))
	var kind: String = String(payload.get("card_kind", &""))
	var kind_text := "行动牌" if kind == "action" else "装备牌"
	return "%s 打出了 %s (%s)" % [name, card_name, kind_text]


func _fmt_attack_card_played_hook(payload: Dictionary) -> String:
	var name := _player_name_by_mech(String(payload.get("attacker_id", &"")))
	var card_name := _card_display_name(payload.get("attack_card_id", &""))
	return "[color=red]%s 使用攻击牌: %s[/color]" % [name, card_name]


func _fmt_attack_declared_hook(payload: Dictionary) -> String:
	return "[color=red]!! 发动攻击[/color]"


func _fmt_attack_hit_hook(payload: Dictionary) -> String:
	var attacker := _mech_display_name(String(payload.get("attacker_id", &"")))
	var target := _mech_display_name(String(payload.get("target_id", &"")))
	return "  [color=yellow]%s 命中了 %s[/color]" % [attacker, target]


func _fmt_attack_miss_hook(_payload: Dictionary) -> String:
	return "  [color=gray]攻击未命中[/color]"


func _fmt_damage_dealt_hook(payload: Dictionary) -> String:
	var target := _mech_display_name(String(payload.get("target_id", &"")))
	var damage: int = int(payload.get("damage", 0))
	var markers: int = int(payload.get("markers", 0))
	return "  [color=orange]%s 受到 %d 伤害, %d 损伤标记[/color]" % [target, damage, markers]


func _fmt_attack_resolved_hook(payload: Dictionary) -> String:
	if payload.get("hit", false):
		var damage: int = int(payload.get("damage", 0))
		return "  攻击结算: 命中 伤害%d" % damage
	else:
		return "  攻击结算: 未命中"


func _fmt_equipment_set_hook(payload: Dictionary) -> String:
	var name := _player_name(String(payload.get("player_id", &"")))
	var card_name := _card_display_name(payload.get("card_id", &""))
	var slot_name := _slot_display_name(String(payload.get("slot_id", &"")))
	return "%s 装备了 %s → %s" % [name, card_name, slot_name]


func _fmt_equipment_sold_hook(payload: Dictionary) -> String:
	var name := _player_name(String(payload.get("player_id", &"")))
	var card_name := _card_display_name(payload.get("card_id", &""))
	var gold: int = int(payload.get("gold", 0))
	return "%s 出售了 %s (+%d金币)" % [name, card_name, gold]


func _fmt_equipment_broken_hook(payload: Dictionary) -> String:
	var card_name := _card_display_name(payload.get("card_id", &""))
	return "[color=red]%s 已损坏![/color]" % card_name


func _fmt_mech_moved_hook(payload: Dictionary) -> String:
	var mech_name := _mech_display_name(String(payload.get("mech_id", &"")))
	var from: Dictionary = payload.get("from", {})
	var to: Dictionary = payload.get("to", {})
	var power: int = int(payload.get("power_spent", 0))
	return "%s 移动 (%d,%d)→(%d,%d) 消耗动力%d" % [
		mech_name,
		int(from.get("q", 0)), int(from.get("r", 0)),
		int(to.get("q", 0)), int(to.get("r", 0)),
		power,
	]


func _fmt_mech_destroyed_hook(payload: Dictionary) -> String:
	var mech_name := _mech_display_name(String(payload.get("mech_id", &"")))
	return "[color=red]✕ %s 被摧毁![/color]" % mech_name


# ═══════════════════════════════════════════
# Log entry 翻译（追赶补漏）
# ═══════════════════════════════════════════


func _translate_log_entry(entry: Dictionary) -> String:
	var event: String = String(entry.get("event", ""))
	match event:
		"turn_start":
			var name := _player_name(String(entry.get("player_id", "")))
			var turn: int = int(entry.get("turn_number", 0))
			return "[color=cyan]>> %s 回合%d开始[/color]" % [name, turn]
		"turn_end":
			var name := _player_name(String(entry.get("player_id", "")))
			var turn: int = int(entry.get("turn_number", 0))
			return "%s 回合%d结束" % [name, turn]
		"attack_declared":
			var attacker := _mech_display_name(String(entry.get("attacker_id", "")))
			var target := _mech_display_name(String(entry.get("target_id", "")))
			return "[color=red]%s 向 %s 发动攻击[/color]" % [attacker, target]
		"attack_resolved":
			if entry.get("hit", false):
				var damage: int = int(entry.get("damage", 0))
				var markers: int = int(entry.get("markers", 0))
				return "  攻击命中: 伤害%d 损伤标记%d" % [damage, markers]
			else:
				return "  攻击未命中"
		"attack_miss":
			return "  攻击未命中 (%s)" % String(entry.get("reason", ""))
		"attack_response":
			return "  迎击响应"
		"action_card_played":
			var name := _player_name(String(entry.get("player_id", "")))
			var card_name := _card_display_name(entry.get("card_id", &""))
			return "%s 打出了 %s" % [name, card_name]
		"equipment_set":
			var name := _player_name(String(entry.get("player_id", "")))
			var card_name := _card_display_name(entry.get("card_id", &""))
			var slot_name := _slot_display_name(String(entry.get("slot_id", "")))
			return "%s 装备了 %s → %s" % [name, card_name, slot_name]
		"equipment_sold":
			var name := _player_name(String(entry.get("player_id", "")))
			var card_name := _card_display_name(entry.get("card_id", &""))
			var gold: int = int(entry.get("gold", 0))
			return "%s 出售了 %s (+%d金币)" % [name, card_name, gold]
		"mech_moved":
			var mech_name := _mech_display_name(String(entry.get("mech_id", "")))
			var from_q: int = int(entry.get("from_q", 0))
			var from_r: int = int(entry.get("from_r", 0))
			var to_q: int = int(entry.get("to_q", 0))
			var to_r: int = int(entry.get("to_r", 0))
			var cost: int = int(entry.get("power_cost", 0))
			return "%s 移动 (%d,%d)→(%d,%d) 消耗动力%d" % [
				mech_name, from_q, from_r, to_q, to_r, cost,
			]
		"mech_destroyed":
			var mech_name := _mech_display_name(String(entry.get("mech_id", "")))
			return "[color=red]✕ %s 被摧毁![/color]" % mech_name
	return ""


# ═══════════════════════════════════════════
# 辅助方法
# ═══════════════════════════════════════════


## 玩家ID → 显示名
func _player_name(player_id: String) -> String:
	if player_id == "player":
		return "我方"
	elif player_id == "enemy":
		return "敌方"
	return player_id


## 通过机甲ID找所属玩家名
func _player_name_by_mech(mech_id: String) -> String:
	if _context == null:
		return mech_id
	var mech = _context.game_state.mechs.get(StringName(mech_id))
	if mech:
		return _player_name(String(mech.owner_player_id))
	return mech_id


## 机甲ID → 显示名
func _mech_display_name(mech_id: String) -> String:
	if _context == null:
		return mech_id
	var mech = _context.game_state.mechs.get(StringName(mech_id))
	if mech and mech.frame_def:
		return mech.frame_def.display_name
	if mech:
		return _player_name(String(mech.owner_player_id))
	return mech_id


## 卡牌实例ID → 显示名
func _card_display_name(card_id) -> String:
	if _context == null:
		return String(card_id)
	var card = _context.game_state.cards.get(StringName(card_id))
	if card and card.def:
		return card.def.display_name
	return String(card_id)


## 槽位ID → 中文名
func _slot_display_name(slot_id: String) -> String:
	return SLOT_NAMES.get(StringName(slot_id), slot_id)
