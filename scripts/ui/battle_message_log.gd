## BattleMessageLog.gd — 战斗消息面板
##
## 在右侧面板中显示所有战斗事件的中文文字消息（事无巨细）。
## 实时通过 EffectEngine.hook_fired 信号接收事件，
## 并通过 GameState.log 追赶补漏。
extends VBoxContainer
class_name BattleMessageLog

const _EffectConst = preload("res://scripts/effect_core/EffectConst.gd")
const _EquipmentCardDef = preload("res://scripts/card_defs/EquipmentCardDef.gd")

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

## 弃牌原因 → 中文名
const DISCARD_REASONS: Dictionary = {
	"played": "打出", "sold": "出售", "replaced": "替换", "RESPONSE_PLAY": "迎击打出",
	"EQUIPMENT_BROKEN": "装备损坏", "EFFECT_DISCARD": "效果弃置",
	"EFFECT_RANDOM_DISCARD": "效果随机弃置", "EVENT_TIMER_ZERO": "事件计时归零",
	"DESTROYED": "破坏", "PLAY_AS_CARD_COST": "当作他牌打出",
	"EQUIPMENT_BROKEN_BY_DAMAGE": "损伤致坏",
}

## 抽牌原因 → 中文名
const DRAW_REASONS: Dictionary = {
	"EFFECT_DRAW": "效果", "SWAP_DRAW": "交换上限", "TURN_START": "回合开始",
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
## 本地日志落盘统一由全局 SessionLogger 单例负责（一次启动一个文件），
## 面板本身只负责显示游戏内消息。
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
	SessionLogger.log_message(text)
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
			SessionLogger.log_message(text)
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
		_EffectConst.HOOK_TURN_END:
			return _fmt_turn_end_hook(payload)
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
		_EffectConst.HOOK_ATTACK_RESOLVED:
			return _fmt_attack_resolved_hook(payload)
		_EffectConst.HOOK_EQUIPMENT_SET:
			return _fmt_equipment_set_hook(payload)
		_EffectConst.HOOK_EQUIPMENT_SOLD:
			return _fmt_equipment_sold_hook(payload)
		_EffectConst.HOOK_EQUIPMENT_BROKEN:
			return _fmt_equipment_broken_hook(payload)
		_EffectConst.HOOK_MECH_MOVED:
			return _fmt_mech_moved_hook(payload)
		_EffectConst.HOOK_MECH_DESTROYED:
			return _fmt_mech_destroyed_hook(payload)
		_EffectConst.HOOK_REACTION_CARD_PLAYED:
			return _fmt_reaction_card_played_hook(payload)
		# ── 新增：抽牌 ──
		_EffectConst.HOOK_ACTION_CARD_DRAWN:
			return _fmt_card_drawn_hook(payload, &"action")
		&"ON_EQUIPMENT_CARD_DRAWN":
			return _fmt_card_drawn_hook(payload, &"equipment")
		&"ON_DRAW_FINISHED":
			return _fmt_draw_finished_hook(payload)
		_EffectConst.HOOK_TURN_DRAW_NOTIFY:
			return _fmt_turn_draw_notify(payload)
		# ── 新增：弃牌 ──
		_EffectConst.HOOK_CARD_DISCARDED:
			return _fmt_card_discarded_hook(payload)
		_EffectConst.HOOK_CARD_DISCARDED_NOTIFY:
			return _fmt_card_discarded_hook(payload)
		_EffectConst.HOOK_CARD_DESTROYED:
			return _fmt_card_destroyed_hook(payload)
		# ── 新增：其它细节 ──
		&"ON_DAMAGE_DEALT":
			return _fmt_damage_dealt_hook(payload)
		&"ON_AFTER_DAMAGE_TOKEN_PLACED":
			return _fmt_token_placed_hook(payload)
		&"ON_GOLD_GAINED":
			return _fmt_gold_gained_hook(payload)
		&"ON_HP_HEALED":
			return _fmt_hp_healed_hook(payload)
		&"ON_MECH_DESTROYED":
			return _fmt_mech_destroyed_hook(payload)
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
	var detail := ""
	var at: String = String(payload.get("action_type", &""))
	if at != "":
		detail = " [%s]" % _action_type_text(at)
	return "%s 打出了 %s (%s%s)" % [name, card_name, kind_text, detail]


func _fmt_attack_card_played_hook(payload: Dictionary) -> String:
	var name := _player_name_by_mech(String(payload.get("attacker_id", &"")))
	var card_name := _card_display_name(payload.get("attack_card_id", &""))
	var attacker_id := String(payload.get("attacker_id", &""))
	var detail := ""
	# 攻击上下文中带武器信息
	var w := _attack_weapon_info(attacker_id, payload)
	if w != "":
		detail = " 武器:%s" % w
	return "[color=red]%s 使用攻击牌: %s%s[/color]" % [name, card_name, detail]


func _fmt_attack_declared_hook(payload: Dictionary) -> String:
	var attacker := _mech_display_name(String(payload.get("attacker_id", &"")))
	var target := _mech_display_name(String(payload.get("target_id", &"")))
	var attack_id := String(payload.get("attack_id", &""))
	var wpn_id := _attack_ctx_field(attack_id, "weapon_id")
	var wpn := _weapon_info(wpn_id)
	var card_name := _card_display_name(payload.get("card_id", &""))
	var power: int = int(_attack_ctx_field(attack_id, "power"))
	var rng: int = int(_attack_ctx_field(attack_id, "range_value"))
	return "[color=red]!! %s 向 %s 发动攻击[/color]\n  攻击牌:%s | 武器:%s | 威力:%d | 射程:%d" % [
		attacker, target, card_name, wpn, power, rng,
	]


func _fmt_attack_hit_hook(payload: Dictionary) -> String:
	var attacker := _mech_display_name(String(payload.get("attacker_id", &"")))
	var target := _mech_display_name(String(payload.get("target_id", &"")))
	var attack_id := String(payload.get("attack_id", &""))
	var power: int = int(_attack_ctx_field(attack_id, "power"))
	var damage: int = int(_attack_ctx_field(attack_id, "damage"))
	var markers: int = int(_attack_ctx_field(attack_id, "markers"))
	var arm_bonus: int = int(_attack_ctx_field(attack_id, "temporary_armor_bonus"))
	var mod_summary := _attack_modifiers_summary(attack_id)
	var armor_line := "护甲修正+%d " % arm_bonus if arm_bonus > 0 else ""
	return "  [color=yellow]%s 命中 %s[/color] (威力%d → %s伤害%d, 损伤标记%d)%s" % [
		attacker, target, power, armor_line, damage, markers, mod_summary,
	]


func _fmt_attack_miss_hook(payload: Dictionary) -> String:
	var attack_id := String(payload.get("attack_id", &""))
	var target := _mech_display_name(String(_attack_ctx_field(attack_id, "target_id")))
	return "  [color=gray]攻击未命中 (%s 脱离射程)[/color]" % target


func _fmt_attack_resolved_hook(payload: Dictionary) -> String:
	var attack_id := String(payload.get("attack_id", &""))
	var attacker := _mech_display_name(String(payload.get("attacker_id", &"")))
	var target := _mech_display_name(String(payload.get("target_id", &"")))
	var hit: bool = bool(payload.get("hit", false))
	var damage: int = int(payload.get("damage", 0))
	var markers: int = int(payload.get("markers", 0))
	var wpn := _weapon_info(_attack_ctx_field(attack_id, "weapon_id"))
	var power: int = int(_attack_ctx_field(attack_id, "power"))
	var mod_summary := _attack_modifiers_summary(attack_id)
	if hit:
		return "  [color=orange]结算: %s 命中 %s[/color]\n  武器:%s | 最终权威:%d | 伤害:%d | 损伤标记:%d%s" % [
			attacker, target, wpn, power, damage, markers, mod_summary,
		]
	else:
		return "  [color=gray]攻击结算: 未命中[/color]"


func _fmt_equipment_set_hook(payload: Dictionary) -> String:
	var name := _player_name(String(payload.get("player_id", &"")))
	var card_name := _card_display_name(payload.get("card_id", &""))
	var slot_name := _slot_display_name(String(payload.get("slot_id", &"")))
	var stats := _equipment_stats(payload.get("card_id", &""))
	return "%s 设置装备: %s → %s%s" % [name, card_name, slot_name, stats]


func _fmt_equipment_sold_hook(payload: Dictionary) -> String:
	var name := _player_name(String(payload.get("player_id", &"")))
	var card_name := _card_display_name(payload.get("card_id", &""))
	var gold: int = int(payload.get("gold", 0))
	return "%s 出售了 %s (+%d金币)" % [name, card_name, gold]


func _fmt_equipment_broken_hook(payload: Dictionary) -> String:
	var card_name := _card_display_name(payload.get("card_id", &""))
	var slot := _slot_display_name(String(payload.get("slot_id", &"")))
	var dmg: int = int(payload.get("damage_tokens", 0))
	var dur: int = int(payload.get("durability", 0))
	return "[color=red]✕ %s 损坏![/color] (槽位:%s 损伤%d≥耐久%d)" % [card_name, slot, dmg, dur]


func _fmt_reaction_card_played_hook(payload: Dictionary) -> String:
	var target_id := String(payload.get("target_id", ""))
	var name := _player_name_by_mech(target_id)
	var card_name := _card_display_name(payload.get("response_card_id", &""))
	var is_cover: bool = bool(payload.get("is_cover", false))
	if is_cover:
		return "[color=green]%s 打出了掩护牌: %s[/color]" % [name, card_name]
	return "[color=cyan]%s 打出了迎击牌: %s[/color]" % [name, card_name]


func _fmt_card_drawn_hook(payload: Dictionary, kind: StringName) -> String:
	# 单张抽牌（每抽一张触发一次）
	var name := _player_name(String(payload.get("player_id", &"")))
	var card_name := _card_display_name(payload.get("card_id", &""))
	var reason: String = String(payload.get("reason", &""))
	var reason_text: String = DRAW_REASONS.get(reason, reason)
	var kind_text := "行动牌" if String(kind) == "action" else "装备牌"
	return "[color=#9ad]%s 抽到 %s: %s[/color] (来源:%s)" % [name, kind_text, card_name, reason_text]


func _fmt_draw_finished_hook(payload: Dictionary) -> String:
	# 一次抽牌动作完成的总览
	var name := _player_name(String(payload.get("player_id", &"")))
	var card_ids = payload.get("card_ids", [])
	var count: int = int(payload.get("count", 0))
	var reason: String = String(payload.get("reason", &""))
	var reason_text: String = DRAW_REASONS.get(reason, reason)
	var kind: String = String(payload.get("card_kind", &""))
	var kind_text := "行动牌" if kind == "action" else "装备牌"
	if count == 0:
		return ""
	# 列出本次抽到的全部牌名
	var names: Array = []
	for cid in card_ids:
		names.append(_card_display_name(cid))
	var list := "、".join(names) if names.size() > 0 else ""
	return "  └ %s 共抽取 %d 张%s (%s): %s" % [name, count, kind_text, reason_text, list]


## 回合开始抽牌通知（实时，Hook 通道）
func _fmt_turn_draw_notify(payload: Dictionary) -> String:
	var name := _player_name(String(payload.get("player_id", &"")))
	var parts: Array = []
	var action_ids = payload.get("action_card_ids", [])
	if action_ids.size() > 0:
		var names: Array = []
		for cid in action_ids:
			names.append(_card_display_name(cid))
		parts.append("行动牌(%d张): %s" % [action_ids.size(), "、".join(names)])
	var equip_ids = payload.get("equipment_card_ids", [])
	if equip_ids.size() > 0:
		var names: Array = []
		for cid in equip_ids:
			names.append(_card_display_name(cid))
		parts.append("装备牌(%d张): %s" % [equip_ids.size(), "、".join(names)])
	if parts.is_empty():
		return ""
	return "  └ %s 回合抽牌: %s" % [name, " | ".join(parts)]


func _fmt_card_discarded_hook(payload: Dictionary) -> String:
	var card_name := _card_display_name(payload.get("card_id", &""))
	var name := _player_name(String(payload.get("owner_player_id", &"")))
	var reason: String = String(payload.get("reason", &""))
	var reason_text: String = DISCARD_REASONS.get(reason, reason)
	var from_zone: String = String(payload.get("from_zone", &""))
	var from_text := _zone_text(from_zone)
	return "  [color=gray]弃置 %s[/color] (玩家:%s 来源:%s 原因:%s)" % [
		card_name, name, from_text, reason_text,
	]


func _fmt_card_destroyed_hook(payload: Dictionary) -> String:
	var card_name := _card_display_name(payload.get("card_id", &""))
	var name := _player_name(String(payload.get("owner_player_id", &"")))
	var reason: String = String(payload.get("reason", &""))
	return "[color=red]破坏 %s[/color] (玩家:%s 原因:%s)" % [card_name, name, reason]


func _fmt_damage_dealt_hook(payload: Dictionary) -> String:
	var target := _mech_display_name(String(payload.get("target_id", payload.get("mech_id", &""))))
	var amount: int = int(payload.get("amount", 0))
	var hp: int = int(payload.get("current_hp", 0))
	return "  [color=orange]%s 受到 %d 伤害[/color] (剩余HP:%d)" % [target, amount, hp]


func _fmt_token_placed_hook(payload: Dictionary) -> String:
	var target := _mech_display_name(String(payload.get("target_id", payload.get("mech_id", &""))))
	var slot := _slot_display_name(String(payload.get("slot_id", &"")))
	var amount: int = int(payload.get("amount", 1))
	return "  └ %s 放置 %d 个损伤标记 → %s" % [target, amount, slot]


func _fmt_gold_gained_hook(payload: Dictionary) -> String:
	var name := _player_name(String(payload.get("player_id", &"")))
	var amount: int = int(payload.get("amount", 0))
	return "  └ %s 获得 %d 金币" % [name, amount]


func _fmt_hp_healed_hook(payload: Dictionary) -> String:
	var target := _mech_display_name(String(payload.get("mech_id", &"")))
	var amount: int = int(payload.get("amount", 0))
	var hp: int = int(payload.get("current_hp", 0))
	return "  [color=green]%s 回复 %d HP[/color] (当前HP:%d)" % [target, amount, hp]


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
		"turn_draw":
			return _fmt_turn_draw_log(entry)
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
				return "  [color=orange]攻击命中: 伤害%d 损伤标记%d[/color]" % [damage, markers]
			else:
				return "  [color=gray]攻击未命中[/color]"
		"attack_miss":
			return "  [color=gray]攻击未命中 (%s)[/color]" % String(entry.get("reason", ""))
		"attack_negated":
			return "  [color=green]攻击被识破，未造成伤害[/color]"
		"attack_response":
			var name := _player_name(String(entry.get("player_id", "")))
			var card_name := _card_display_name(entry.get("response_card_id", &""))
			return "[color=cyan]%s 打出了迎击牌: %s[/color]" % [name, card_name]
		"cover_played":
			var name := _player_name(String(entry.get("cover_player_id", "")))
			var card_name := _card_display_name(entry.get("cover_card_id", &""))
			return "[color=green]%s 打出了掩护牌: %s[/color]" % [name, card_name]
		"action_card_played":
			var name := _player_name(String(entry.get("player_id", "")))
			var card_name := _card_display_name(entry.get("card_id", &""))
			return "%s 打出了 %s" % [name, card_name]
		"equipment_set":
			var name := _player_name(String(entry.get("player_id", "")))
			var card_name := _card_display_name(entry.get("card_id", &""))
			var slot_name := _slot_display_name(String(entry.get("slot_id", "")))
			var stats := _equipment_stats(entry.get("card_id", &""))
			return "%s 装备了 %s → %s%s" % [name, card_name, slot_name, stats]
		"equipment_sold":
			var name := _player_name(String(entry.get("player_id", "")))
			var card_name := _card_display_name(entry.get("card_id", &""))
			var gold: int = int(entry.get("gold", 0))
			return "%s 出售了 %s (+%d金币)" % [name, card_name, gold]
		"card_discarded":
			var card_name := _card_display_name(entry.get("card_id", &""))
			var reason: String = String(entry.get("reason", ""))
			var reason_text: String = DISCARD_REASONS.get(reason, reason)
			return "  [color=gray]弃置 %s (原因:%s)[/color]" % [card_name, reason_text]
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


## 回合开始抽牌日志条目：详细列出抽到的行动牌与装备牌
func _fmt_turn_draw_log(entry: Dictionary) -> String:
	var name := _player_name(String(entry.get("player_id", "")))
	var parts: Array = []
	var action_ids = entry.get("action_card_ids", [])
	if action_ids.size() > 0:
		var names: Array = []
		for cid in action_ids:
			names.append(_card_display_name(cid))
		parts.append("行动牌(%d张): %s" % [action_ids.size(), "、".join(names)])
	var equip_ids = entry.get("equipment_card_ids", [])
	if equip_ids.size() > 0:
		var names: Array = []
		for cid in equip_ids:
			names.append(_card_display_name(cid))
		parts.append("装备牌(%d张): %s" % [equip_ids.size(), "、".join(names)])
	if parts.is_empty():
		return ""
	return "  └ %s 抽牌: %s" % [name, " | ".join(parts)]


# ═══════════════════════════════════════════
# 辅助方法
# ═══════════════════════════════════════════


## 行动牌类型 → 中文
func _action_type_text(at: String) -> String:
	match at:
		"攻击": return "攻击"
		"迎击": return "迎击"
		"辅助": return "辅助"
	return at


## 卡牌区域 → 中文
func _zone_text(zone: String) -> String:
	match zone:
		"hand": return "手牌"
		"equipped": return "装备区"
		"discard": return "弃牌堆"
		"deck": return "牌库"
		"": return "—"
	return zone


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
	if _context == null or mech_id == "":
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
	var cid_str := String(card_id)
	if cid_str == "":
		return "—"
	var card = _context.game_state.cards.get(StringName(cid_str))
	if card and card.def:
		return card.def.display_name
	return cid_str


## 槽位ID → 中文名
func _slot_display_name(slot_id: String) -> String:
	return SLOT_NAMES.get(StringName(slot_id), slot_id)


## 从当前攻击上下文中读取字段
func _attack_ctx_field(attack_id: String, field: String) -> String:
	if _context == null or attack_id == "":
		return ""
	var atk = _context.game_state.attacks.get(StringName(attack_id))
	if atk == null:
		return ""
	var v = atk.get(field, "")
	if v == null:
		return ""
	return str(v)


## 攻击修正项汇总（猛击+4、掩护-5、防御等）
func _attack_modifiers_summary(attack_id: String) -> String:
	if _context == null or attack_id == "":
		return ""
	var atk = _context.game_state.attacks.get(StringName(attack_id))
	if atk == null:
		return ""
	var mods = atk.get("modifiers", [])
	if mods == null or mods.is_empty():
		return ""
	var parts: Array = []
	for m in mods:
		var t: String = String(m.get("type", ""))
		var d: int = int(m.get("delta", 0))
		var src := _card_display_name(m.get("source_card_id", &""))
		var sign := "+" if d >= 0 else ""
		var label := "权威" if t == "attack_power" else ("射程" if t == "attack_range" else t)
		parts.append("%s%s%d(%s)" % [label, sign, d, src])
	return " | 修正: " + ", ".join(parts)


## 武器信息：名称 + 威力/射程/类型
func _weapon_info(weapon_id) -> String:
	if _context == null:
		return String(weapon_id)
	var card = _context.game_state.cards.get(StringName(String(weapon_id)))
	if card == null or card.def == null:
		return _card_display_name(weapon_id)
	var name: String = card.def.display_name
	if not (card.def is _EquipmentCardDef):
		return name
	var might: int = int(card.def.might) if "might" in card.def else 0
	var rng: int = int(card.def.range_value) if "range_value" in card.def else 0
	var wk: String = String(card.def.weapon_kind) if "weapon_kind" in card.def else ""
	var dur: int = int(card.def.durability) if "durability" in card.def else 0
	var base := "%s(权威%d/射程%d" % [name, might, rng]
	if wk != "":
		base += "/%s" % wk
	if dur > 0:
		base += "/耐久%d" % dur
	base += ")"
	return base


## 攻击牌打出钩子里读武器信息（payload 无 attack_id 时，尝试用 attacker 当前武器）
func _attack_weapon_info(attacker_id: String, payload: Dictionary) -> String:
	var attack_id := String(payload.get("attack_id", &""))
	if attack_id != "":
		var wid := _attack_ctx_field(attack_id, "weapon_id")
		if wid != "":
			return _weapon_info(wid)
	# 退路：payload 直接含 weapon_id
	var w = payload.get("weapon_id", &"")
	if String(w) != "":
		return _weapon_info(w)
	return ""


## 装备信息：稀有度 + 关键数值
func _equipment_stats(card_id) -> String:
	if _context == null:
		return ""
	var card = _context.game_state.cards.get(StringName(String(card_id)))
	if card == null or card.def == null:
		return ""
	var def = card.def
	var rarity: String = String(def.rarity) if "rarity" in def else ""
	var parts: Array = []
	if def is _EquipmentCardDef:
		if def.equipment_kind == &"WEAPON":
			if "might" in def and int(def.might) > 0:
				parts.append("权威%d" % int(def.might))
			if "range_value" in def:
				parts.append("射程%d" % int(def.range_value))
			if "weapon_kind" in def and String(def.weapon_kind) != "":
				parts.append(String(def.weapon_kind))
			if "durability" in def and int(def.durability) > 0:
				parts.append("耐久%d" % int(def.durability))
		else:
			if "armor" in def and int(def.armor) != 0:
				parts.append("护甲%d" % int(def.armor))
			if "power" in def and int(def.power) != 0:
				parts.append("动力%d" % int(def.power))
			if "durability" in def and int(def.durability) > 0:
				parts.append("耐久%d" % int(def.durability))
	var rarity_text := ""
	if rarity != "":
		rarity_text = " [%s]" % rarity
	if parts.is_empty():
		return rarity_text
	return " (" + "、".join(parts) + ")" + rarity_text
