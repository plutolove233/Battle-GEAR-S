## BattleMessageLog.gd — 战斗消息面板
##
## 在右侧面板中显示所有战斗事件的中文文字消息（事无巨细）。
## 实时通过 EffectEngine.hook_fired 信号接收事件，
## 并通过 GameState.log 追赶补漏。
extends VBoxContainer
class_name BattleMessageLog
const SLog = preload("res://scripts/services/slog.gd")

const _EffectConst = preload("res://scripts/effect_core/EffectConst.gd")
const _EquipmentCardDef = preload("res://scripts/card_defs/EquipmentCardDef.gd")

var _scroll_container: ScrollContainer
var _text_display: RichTextLabel
var _context = null  # type: GameContext
var _last_log_index: int = 0
var _messages: Array[String] = []

## 消息缓冲上限。_messages 永不裁剪会让 _rebuild_display（O(N) 字符串拼接 +
## RichTextLabel 整段 BBCode 重排）随游戏推进越来越慢--每条时点/钩子消息触发一次重建，
## 移动每格发 4 条时点消息尤为明显（"逐渐卡顿、移动为甚"根因）。裁到最近 N 条后，
## 单次重建成本恒定，长局后期与开局同样流畅。N=500 兼顾回看与性能。
const _MAX_MESSAGES := 500

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
	"hand_limit": "超出上限", "end_turn_unset": "未设置装备",
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


## 新动作系统：TimingEngine 时点信号回调
## 将新时点事件翻译为中文消息并显示
func on_timing_fired(timing: StringName, payload: Dictionary) -> void:
	var text := _translate_timing(timing, payload)
	if text != "":
		add_message(text)


## 装备牌效果发动信号回调（来自 TimingEngine.equipment_effect_fired）
## 显示「⚙ [装备] 牌名 发动效果: 描述 (机甲)」，供玩家核查每件装备执行情况。
func on_equipment_effect_fired(card_name: String, _effect_id: StringName, description: String, source_mech_id: StringName) -> void:
	var mech_name := _mech_display_name(String(source_mech_id))
	var text := "[color=#b9f]⚙ [装备] %s 发动效果[/color]: %s (%s)" % [card_name, description, mech_name]
	add_message(text)


## 追加一条消息并自动滚动
func add_message(text: String) -> void:
	_messages.append(text)
	_trim_messages()
	SLog.log_message(text)
	_rebuild_display()


# ═══════════════════════════════════════════
# 内部方法
# ═══════════════════════════════════════════


## 追赶 GameState.log 中未读的条目
func _catch_up_log() -> void:
	if _context == null:
		return
	var gs = _context.game_state
	var added := false
	while _last_log_index < gs.log.size():
		var entry: Dictionary = gs.log[_last_log_index]
		var text := _translate_log_entry(entry)
		if text != "":
			_messages.append(text)
			SLog.log_message(text)
			added = true
		_last_log_index += 1
	_trim_messages()
	# 仅当确实追加了新条目时才重建--configure 在每次 _refresh_battle / _refresh_panels_only /
	# _refresh_damage_ui 都会调用，若无新消息也重建则每次刷新都付 O(N) 拼接+整段重排，
	# 随消息累积越来越慢（"各种操作逐渐卡顿"根因之二）。新消息已由 add_message 实时重建过，
	# 此处无新增则跳过。
	if added:
		_rebuild_display()


## 裁剪消息缓冲到最近 _MAX_MESSAGES 条（丢弃最旧的），限制 _rebuild_display 成本。
func _trim_messages() -> void:
	while _messages.size() > _MAX_MESSAGES:
		_messages.remove_at(0)


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
		# ── 新增：动力/状态 ──
		&"ON_POWER_CHANGED":
			return _fmt_power_changed_hook(payload)
		&"ON_STATUS_ADDED":
			return _fmt_status_added_hook(payload)
		&"ON_STATUS_REMOVED":
			return _fmt_status_removed_hook(payload)
		&"ON_GOLD_CHANGED":
			return _fmt_gold_changed_hook(payload)
		&"ON_CARD_GAINED":
			return _fmt_card_gained_hook(payload)
		&"ON_CARD_TRANSFERRED":
			return _fmt_card_transferred_hook(payload)
		&"ON_ENERGY_APPLIED_TO_WEAPON":
			return _fmt_energy_applied_hook(payload)
		&"ON_ATTACK_NEGATED":
			return _fmt_attack_negated_hook(payload)
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
	var source: String = String(payload.get("source_card_id", &""))
	var source_text := _card_display_name(payload.get("source_card_id", &""))
	return "  [color=orange]%s 受到 %d 伤害[/color] (剩余HP:%d | 来源:%s)" % [target, amount, hp, source_text]


func _fmt_token_placed_hook(payload: Dictionary) -> String:
	var target := _mech_display_name(String(payload.get("target_id", payload.get("mech_id", &""))))
	var slot := _slot_display_name(String(payload.get("slot_id", &"")))
	var amount: int = int(payload.get("amount", 1))
	return "  └ %s 放置 %d 个损伤标记 → %s" % [target, amount, slot]


func _fmt_gold_gained_hook(payload: Dictionary) -> String:
	var name := _player_name(String(payload.get("player_id", &"")))
	var amount: int = int(payload.get("amount", 0))
	var reason: String = String(payload.get("reason", &""))
	return "  └ %s 获得 %d 金币 (原因:%s)" % [name, amount, reason]


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


func _fmt_power_changed_hook(payload: Dictionary) -> String:
	var mech_name := _mech_display_name(String(payload.get("mech_id", &"")))
	var delta: int = int(payload.get("delta", 0))
	var current: int = int(payload.get("current_power", 0))
	var reason: String = String(payload.get("reason", &""))
	var sign := "+" if delta >= 0 else ""
	var reason_text := " (%s)" % reason if reason != "" else ""
	return "  └ %s 动力%s%d → 当前:%d%s" % [mech_name, sign, delta, current, reason_text]


func _fmt_status_added_hook(payload: Dictionary) -> String:
	var target_id: String = String(payload.get("target_id", payload.get("mech_id", payload.get("player_id", &""))))
	var target_name := _mech_display_name(target_id)
	var status: Dictionary = payload.get("status", {})
	var status_type: String = String(status.get("type", &""))
	var source_card := _card_display_name(status.get("source_card_id", &""))
	var delta: int = int(status.get("delta", 0))
	var detail := ""
	if delta != 0:
		var sign := "+" if delta >= 0 else ""
		detail = " 数值:%s%d" % [sign, delta]
	return "  └ %s 获得状态:%s%s (来源:%s)" % [target_name, status_type, detail, source_card]


func _fmt_status_removed_hook(payload: Dictionary) -> String:
	var target_id: String = String(payload.get("target_id", &""))
	var target_name := _mech_display_name(target_id)
	var status: Dictionary = payload.get("status", {})
	var status_type: String = String(status.get("type", &""))
	var reason: String = String(payload.get("reason", &""))
	var reason_text := " (%s)" % reason if reason != "" else ""
	return "  └ %s 移除状态:%s%s" % [target_name, status_type, reason_text]


func _fmt_gold_changed_hook(payload: Dictionary) -> String:
	var name := _player_name(String(payload.get("player_id", &"")))
	var delta: int = int(payload.get("delta", 0))
	var current: int = int(payload.get("current_gold", 0))
	var reason: String = String(payload.get("reason", &""))
	var sign := "+" if delta >= 0 else ""
	var reason_text := " (%s)" % reason if reason != "" else ""
	return "  └ %s 金币%s%d → 当前:%d%s" % [name, sign, delta, current, reason_text]


func _fmt_card_gained_hook(payload: Dictionary) -> String:
	var name := _player_name(String(payload.get("player_id", &"")))
	var card_name := _card_display_name(payload.get("card_id", &""))
	var from_zone: String = String(payload.get("from_zone", &""))
	var reason: String = String(payload.get("reason", &""))
	var reason_text := " (%s)" % reason if reason != "" else ""
	var from_text := " 从%s" % from_zone if from_zone != "" else ""
	return "[color=#9ad]%s 获得 %s%s%s[/color]" % [name, card_name, from_text, reason_text]


func _fmt_card_transferred_hook(payload: Dictionary) -> String:
	var card_name := _card_display_name(payload.get("card_id", &""))
	var from_name := _player_name(String(payload.get("from_player_id", &"")))
	var to_name := _player_name(String(payload.get("to_player_id", &"")))
	var reason: String = String(payload.get("reason", &""))
	var reason_text := " (%s)" % reason if reason != "" else ""
	return "[color=#9ad]%s → %s: %s%s[/color]" % [from_name, to_name, card_name, reason_text]


func _fmt_energy_applied_hook(payload: Dictionary) -> String:
	var mech_name := _mech_display_name(String(payload.get("mech_id", &"")))
	var weapon_name := _card_display_name(payload.get("weapon_id", &""))
	var delta: int = int(payload.get("delta", 0))
	return "[color=yellow]%s 对 %s 施加聚能 (+%d威力)[/color]" % [mech_name, weapon_name, delta]


func _fmt_attack_negated_hook(payload: Dictionary) -> String:
	var source_card := _card_display_name(payload.get("source_card_id", &""))
	return "[color=green]✓ 攻击被无效! (来源:%s)[/color]" % source_card


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
		"card_transformed":
			var ct_card := _card_display_name(entry.get("card_id", &""))
			var ct_as: String = String(entry.get("as_name", ""))
			if ct_as != "":
				return "[color=#b9f]%s（转化%s）[/color]" % [ct_card, ct_as]
			return "[color=#b9f]%s（转化）[/color]" % ct_card
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
		"gold_gained":
			var name := _player_name(String(entry.get("player_id", "")))
			var amount: int = int(entry.get("amount", 0))
			var cur: int = int(entry.get("current_gold", 0))
			var reason: String = String(entry.get("reason", ""))
			return "  └ %s 获得 %d 金币 (当前:%d 原因:%s)" % [name, amount, cur, reason]
		"hp_healed":
			var target := _mech_display_name(String(entry.get("mech_id", "")))
			var amount: int = int(entry.get("amount", 0))
			var hp: int = int(entry.get("current_hp", 0))
			return "  [color=green]%s 回复 %d HP[/color] (当前HP:%d)" % [target, amount, hp]
		"power_changed":
			var mech_name := _mech_display_name(String(entry.get("mech_id", "")))
			var delta: int = int(entry.get("delta", 0))
			var cur: int = int(entry.get("current_power", 0))
			var reason: String = String(entry.get("reason", ""))
			var sign := "+" if delta >= 0 else ""
			return "  └ %s 动力%s%d → 当前:%d (%s)" % [mech_name, sign, delta, cur, reason]
		"damage_dealt":
			var target := _mech_display_name(String(entry.get("mech_id", "")))
			var amount: int = int(entry.get("amount", 0))
			var hp: int = int(entry.get("current_hp", 0))
			return "  [color=orange]%s 受到 %d 伤害[/color] (剩余HP:%d)" % [target, amount, hp]
		"damage_token_placed":
			var target := _mech_display_name(String(entry.get("mech_id", "")))
			var slot := _slot_display_name(String(entry.get("slot_id", "")))
			return "  └ %s 放置 1 个损伤标记 → %s" % [target, slot]
		"cards_drawn":
			var name := _player_name(String(entry.get("player_id", "")))
			var kind: String = String(entry.get("card_kind", ""))
			var kind_text := "行动牌" if kind == "action" else "装备牌"
			var card_ids: Array = entry.get("card_ids", [])
			var names: Array = []
			for cid in card_ids:
				names.append(_card_display_name(cid))
			var list := "、".join(names) if names.size() > 0 else ""
			var reason: String = String(entry.get("reason", ""))
			return "[color=#9ad]%s 抽 %d 张%s: %s[/color] (来源:%s)" % [name, int(entry.get("count", 0)), kind_text, list, reason]
		"card_gained":
			var name := _player_name(String(entry.get("player_id", "")))
			var card_name := _card_display_name(entry.get("card_id", &""))
			var reason: String = String(entry.get("reason", ""))
			return "[color=#9ad]%s 获得 %s (%s)[/color]" % [name, card_name, reason]
		"status_added":
			var target := _mech_display_name(String(entry.get("target_id", "")))
			var st: String = String(entry.get("status_type", ""))
			var delta: int = int(entry.get("delta", 0))
			var detail := " 数值:%+d" % delta if delta != 0 else ""
			return "  └ %s 获得状态:%s%s" % [target, st, detail]
		"marker_gold":
			var mech_name := _mech_display_name(String(entry.get("mech_id", "")))
			var roll: int = int(entry.get("roll", 0))
			var gold: int = int(entry.get("gold_gained", 0))
			return "[color=gold]◆ %s 触发金币标记，投骰 %d，获得 %d 金币[/color]" % [mech_name, roll, gold]
		"marker_event":
			var mech_name := _mech_display_name(String(entry.get("mech_id", "")))
			return "[color=#7c6]✦ %s 触发事件标记（效果待实装，无事发生）[/color]" % mech_name
		"marker_trap":
			var mech_name := _mech_display_name(String(entry.get("mech_id", "")))
			return "[color=#e66]▲ %s 触发陷阱标记，引发爆炸！[/color]" % mech_name
		"marker_trap_exploded":
			var traps_n: int = int(entry.get("traps_triggered", 1))
			var mechs_n: int = int(entry.get("mechs_affected", 0))
			return "[color=#e66]💥 陷阱爆炸：引爆 %d 个陷阱，波及 %d 台机甲[/color]" % [traps_n, mechs_n]
		"marker_trap_placed":
			return "[color=#e66]▼ 陷阱标记已设置[/color]"
		"event_markers_regenerated":
			return "[color=#7c6]✦ 事件标记已全部消失，地图上重新生成 %d 个事件标记[/color]" % int(entry.get("count", 0))
		"map_features_configured":
			return "[color=gray]地图已配置: 绿格%d 红格%d 金币点%d 事件点%d[/color]" % [
				int(entry.get("green_tiles", 0)), int(entry.get("red_tiles", 0)),
				int(entry.get("gold_points", 0)), int(entry.get("event_points", 0)),
			]
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
# Timing 翻译（新动作系统）— 详细参数输出
# ═══════════════════════════════════════════


## 时点名 → 中文消息
const TIMING_NAMES: Dictionary = {
	&"ROUND_START": "新轮次开始",
	&"TURN_BEFORE_START": "回合开始前",
	&"TURN_START": "回合开始时",
	&"TURN_AFTER_START": "回合开始后",
	&"TURN_BEFORE_END": "回合结束前",
	&"TURN_END": "回合结束时",
	&"TURN_AFTER_END": "回合结束后",
	&"ATTACK_BEFORE": "攻击前",
	&"ATTACK_PRE": "攻击时前",
	&"ATTACK_AT": "攻击时",
	&"ATTACK_AFTER": "攻击后",
	&"ATTACK_SETTLE": "攻击结算",
	&"USE_ACTION_BEFORE": "使用行动牌前",
	&"USE_ACTION_AT": "使用行动牌时",
	&"USE_ACTION_AFTER": "使用行动牌后",
	&"USE_ACTION_SETTLE": "使用行动牌结算",
	&"STAT_MOD_BEFORE": "数值修正前",
	&"STAT_MOD_AFTER": "数值修正后",
	&"STAT_MOD_SETTLE": "数值修正结算",
	&"BASIC_MOVE_BEFORE": "基础移动前",
	&"BASIC_MOVE_AT": "基础移动时",
	&"BASIC_MOVE_AFTER": "基础移动后",
	&"BASIC_MOVE_SETTLE": "基础移动结算",
	&"SINGLE_MOVE_SETTLE": "单次移动结算",
	&"SET_EQUIP_BEFORE": "设置装备牌前",
	&"SET_EQUIP_AT": "设置装备牌时",
	&"SET_EQUIP_AFTER": "设置装备牌后",
	&"SET_EQUIP_SETTLE": "设置装备牌结算",
	&"GAIN_CARD_BEFORE": "获取牌前",
	&"GAIN_CARD_AFTER": "获取牌后",
	&"GAIN_CARD_SETTLE": "获取牌结算",
	&"DISCARD_BEFORE": "弃置牌前",
	&"DISCARD_AFTER": "弃置牌后",
	&"DISCARD_SETTLE": "弃置牌结算",
	&"EFFECT_FIRE_BEFORE": "效果发动前",
	&"EFFECT_FIRE_AFTER": "效果发动后",
	&"EFFECT_FIRE_SETTLE": "效果发动结算",
	&"HP_CHANGE_BEFORE": "生命变动前",
	&"HP_CHANGE_AFTER": "生命变动后",
	&"HP_CHANGE_SETTLE": "生命变动结算",
	&"DAMAGE_CHANGE_BEFORE": "损伤变动前",
	&"DAMAGE_CHANGE_AFTER": "损伤变动后",
	&"DAMAGE_CHANGE_SETTLE": "损伤变动结算",
	&"SHOW_CARD_BEFORE": "展示牌前",
	&"SHOW_CARD_AFTER": "展示牌后",
	&"SHOW_CARD_SETTLE": "展示牌结算",
	&"VICTORY_REACHED": "达到胜利条件",
}


func _translate_timing(timing: StringName, payload: Dictionary) -> String:
	var name: String = TIMING_NAMES.get(timing, "")
	if name == "":
		return ""
	var action_type: String = String(payload.get("action_type", ""))
	var player_id: String = String(payload.get("player_id", ""))
	var prefix := ""
	if player_id != "":
		prefix = _player_name(player_id) + " "

	# 攻击时点的特殊格式化
	match timing:
		&"ATTACK_AT":
			var attacker := _mech_display_name(String(payload.get("attacker_id", &"")))
			var target := _mech_display_name(String(payload.get("target_id", &"")))
			var weapon_id: String = String(payload.get("weapon_id", &""))
			var weapon_name := _weapon_info(weapon_id) if weapon_id != "" else "未选择武器"
			var power: int = int(payload.get("weapon_might", payload.get("power", 0)))
			var rng: int = int(payload.get("weapon_range", payload.get("range_value", 0)))
			var responded: bool = payload.get("responded", false)
			var response_text := ""
			if responded:
				var response_src := _card_display_name(payload.get("response_card_id", &""))
				response_text = " | 已响应(%s)" % response_src
			var source_text := _source_text(payload)
			return "[color=red]⏱ 攻击时 | 攻击方:%s | 目标:%s | 武器:%s | 威力:%d | 射程:%d%s | 来源:%s[/color]" % [attacker, target, weapon_name, power, rng, response_text, source_text]
		&"ATTACK_BEFORE":
			var attacker := _mech_display_name(String(payload.get("attacker_id", &"")))
			var weapon_id: String = String(payload.get("weapon_id", &""))
			var weapon_name := _weapon_info(weapon_id) if weapon_id != "" else "未选择武器"
			var power: int = int(payload.get("weapon_might", payload.get("power", 0)))
			var rng: int = int(payload.get("weapon_range", payload.get("range_value", 0)))
			var source_text := _source_text(payload)
			return "[color=#cc8]⏱ 攻击前 | 攻击方:%s | 武器:%s | 威力:%d | 射程:%d | 来源:%s[/color]" % [attacker, weapon_name, power, rng, source_text]
		&"ATTACK_PRE":
			var attacker := _mech_display_name(String(payload.get("attacker_id", &"")))
			var target := _mech_display_name(String(payload.get("target_id", &"")))
			var max_targets: int = int(payload.get("max_targets", 1))
			var source_text := _source_text(payload)
			return "[color=#cc8]⏱ 攻击时前 | 攻击方:%s | 目标:%s | 可选目标数:%d | 来源:%s[/color]" % [attacker, target, max_targets, source_text]
		&"ATTACK_AFTER":
			var attacker := _mech_display_name(String(payload.get("attacker_id", &"")))
			var target := _mech_display_name(String(payload.get("target_id", &"")))
			var hit: bool = payload.get("hit", false)
			var damage: int = int(payload.get("damage", 0))
			var markers: int = int(payload.get("markers", 0))
			var power: int = int(payload.get("power", 0))
			var source_text := _source_text(payload)
			if hit:
				return "[color=yellow]⏱ 攻击后 | %s → %s 命中 | 威力:%d | 伤害:%d | 损伤:%d | 来源:%s[/color]" % [attacker, target, power, damage, markers, source_text]
			return "[color=gray]⏱ 攻击后 | %s → %s 未命中 | 来源:%s[/color]" % [attacker, target, source_text]
		&"ATTACK_SETTLE":
			var attacker := _mech_display_name(String(payload.get("attacker_id", &"")))
			var target := _mech_display_name(String(payload.get("target_id", &"")))
			var hit: bool = payload.get("hit", false)
			var responded: bool = payload.get("responded", false)
			var details := ""
			if hit:
				var damage: int = int(payload.get("damage", 0))
				var markers: int = int(payload.get("markers", 0))
				details = "命中 伤害:%d 损伤:%d" % [damage, markers]
			else:
				details = "未命中"
			if responded:
				details += " [已响应]"
			return "[color=#88aacc]⏱ 攻击结算 | %s → %s | %s[/color]" % [attacker, target, details]
		&"USE_ACTION_AT":
			var card_name := _card_display_name(payload.get("card_instance_id", &""))
			var mech_id: String = String(payload.get("mech_id", payload.get("source_mech_id", &"")))
			var mech_name := _mech_display_name(mech_id)
			var source_mech_id: String = String(payload.get("source_mech_id", &""))
			var source_name := _mech_display_name(source_mech_id)
			var source_text := _source_text(payload)
			return "[color=cyan]⏱ 使用行动牌时 | 牌:%s | 执行者:%s | 所属机甲:%s | 来源:%s[/color]" % [card_name, mech_name, source_name, source_text]
		&"USE_ACTION_BEFORE":
			var card_name := _card_display_name(payload.get("card_instance_id", &""))
			var mech_id: String = String(payload.get("mech_id", payload.get("source_mech_id", &"")))
			var mech_name := _mech_display_name(mech_id)
			var source_text := _source_text(payload)
			return "[color=cyan]⏱ 使用行动牌前 | 牌:%s | 机甲:%s | 来源:%s[/color]" % [card_name, mech_name, source_text]
		&"USE_ACTION_AFTER":
			var card_name := _card_display_name(payload.get("card_instance_id", &""))
			return "[color=cyan]⏱ 使用行动牌后 | 牌:%s[/color]" % card_name
		&"USE_ACTION_SETTLE":
			var card_name := _card_display_name(payload.get("card_instance_id", &""))
			return "[color=cyan]⏱ 使用行动牌结算 | 牌:%s[/color]" % card_name
		&"STAT_MOD_BEFORE":
			var target_id: String = String(payload.get("target_id", payload.get("mech_id", &"")))
			var target_name := _mech_display_name(target_id)
			var stat_type: String = String(payload.get("stat_type", ""))
			var value: int = int(payload.get("value", 0))
			var method: String = String(payload.get("method", "add"))
			var method_text := _method_text(method)
			var sign := "+" if value >= 0 else ""
			var target_type_text := _stat_target_type_text(stat_type)
			var source_text := _source_text(payload)
			return "[color=#cc8]⏱ 数值修正前 | 对象:%s(%s) | 类型:%s | 方式:%s | 数值:%s%d | 来源:%s[/color]" % [target_name, target_type_text, stat_type, method_text, sign, value, source_text]
		&"STAT_MOD_AFTER":
			var target_id: String = String(payload.get("target_id", payload.get("mech_id", &"")))
			var target_name := _mech_display_name(target_id)
			var stat_type: String = String(payload.get("stat_type", ""))
			var old_value: int = int(payload.get("old_value", 0))
			var new_value: int = int(payload.get("new_value", 0))
			var method: String = String(payload.get("method", "add"))
			var method_text := _method_text(method)
			var target_type_text := _stat_target_type_text(stat_type)
			var source_text := _source_text(payload)
			return "[color=#88aacc]⏱ 数值修正后 | 对象:%s(%s) | 类型:%s | 方式:%s | %d→%d | 来源:%s[/color]" % [target_name, target_type_text, stat_type, method_text, old_value, new_value, source_text]
		&"STAT_MOD_SETTLE":
			var target_id: String = String(payload.get("target_id", payload.get("mech_id", &"")))
			var target_name := _mech_display_name(target_id)
			var stat_type: String = String(payload.get("stat_type", ""))
			return "[color=#88aacc]⏱ 数值修正结算 | 对象:%s | 类型:%s[/color]" % [target_name, stat_type]
		&"HP_CHANGE_BEFORE":
			var mech_ids: Array = payload.get("mech_ids", [])
			var target_name := _mech_display_name(String(mech_ids[0] if mech_ids.size() > 0 else ""))
			var value: int = int(payload.get("value", 0))
			var method: String = String(payload.get("method", "decrease"))
			var method_text := _method_text(method)
			var reason: String = String(payload.get("reason", ""))
			var source_text := _source_text(payload)
			return "[color=orange]⏱ 生命变动前 | 对象:%s | 方式:%s | 数值:%d | 原因:%s | 来源:%s[/color]" % [target_name, method_text, value, reason, source_text]
		&"HP_CHANGE_AFTER":
			var mech_ids: Array = payload.get("mech_ids", [])
			var target_name := _mech_display_name(String(mech_ids[0] if mech_ids.size() > 0 else ""))
			var old_hp: int = int(payload.get("old_hp", 0))
			var new_hp: int = int(payload.get("new_hp", 0))
			var method: String = String(payload.get("method", "decrease"))
			var method_text := _method_text(method)
			var value: int = int(payload.get("value", 0))
			return "[color=orange]⏱ 生命变动后 | 对象:%s | 方式:%s%d | HP:%d→%d[/color]" % [target_name, method_text, value, old_hp, new_hp]
		&"HP_CHANGE_SETTLE":
			var mech_ids: Array = payload.get("mech_ids", [])
			var target_name := _mech_display_name(String(mech_ids[0] if mech_ids.size() > 0 else ""))
			return "[color=orange]⏱ 生命变动结算 | 对象:%s[/color]" % target_name
		&"DAMAGE_CHANGE_BEFORE":
			var mech_ids: Array = payload.get("mech_ids", [])
			var target_name := _mech_display_name(String(mech_ids[0] if mech_ids.size() > 0 else ""))
			var value: int = int(payload.get("value", 0))
			var method: String = String(payload.get("method", "increase"))
			var method_text := _method_text(method)
			var reason: String = String(payload.get("reason", ""))
			var source_text := _source_text(payload)
			var slots: Array = payload.get("slots", [])
			var slots_text := "、".join(slots.map(func(s): return _slot_display_name(String(s)))) if slots.size() > 0 else "全部"
			var executor: String = String(payload.get("executor", ""))
			var executor_text := _mech_display_name(executor) if executor != "" else "系统"
			return "[color=orange]⏱ 损伤变动前 | 对象:%s | 区域:%s | 方式:%s%d | 原因:%s | 执行者:%s | 来源:%s[/color]" % [target_name, slots_text, method_text, value, reason, executor_text, source_text]
		&"DAMAGE_CHANGE_AFTER":
			var mech_ids: Array = payload.get("mech_ids", [])
			var target_name := _mech_display_name(String(mech_ids[0] if mech_ids.size() > 0 else ""))
			var value: int = int(payload.get("value", 0))
			var method: String = String(payload.get("method", "increase"))
			var method_text := _method_text(method)
			return "[color=orange]⏱ 损伤变动后 | 对象:%s | 方式:%s%d[/color]" % [target_name, method_text, value]
		&"DAMAGE_CHANGE_SETTLE":
			var mech_ids: Array = payload.get("mech_ids", [])
			var target_name := _mech_display_name(String(mech_ids[0] if mech_ids.size() > 0 else ""))
			return "[color=orange]⏱ 损伤变动结算 | 对象:%s[/color]" % target_name
		&"GAIN_CARD_BEFORE":
			var card_ids: Array = payload.get("card_ids", [])
			var count: int = card_ids.size() if card_ids.size() > 0 else int(payload.get("count", 0))
			var reason: String = String(payload.get("reason", ""))
			var from_zone: String = String(payload.get("from_zone", ""))
			var target_mech_id: String = String(payload.get("mech_id", payload.get("target_mech_id", &"")))
			var target_name := _mech_display_name(target_mech_id)
			var source_text := _source_text(payload)
			var card_names: Array = []
			for cid in card_ids:
				card_names.append(_card_display_name(cid))
			var cards_text := "、".join(card_names) if card_names.size() > 0 else "%d张" % count
			return "[color=#9ad]⏱ 获取牌前 | 牌:%s | 对象:%s | 来源:%s | 原因:%s | 效果来源:%s[/color]" % [cards_text, target_name, from_zone, reason, source_text]
		&"GAIN_CARD_AFTER":
			var card_ids: Array = payload.get("card_ids", [])
			var names: Array = []
			for cid in card_ids:
				names.append(_card_display_name(cid))
			var list := "、".join(names) if names.size() > 0 else "未知"
			var target_mech_id: String = String(payload.get("mech_id", payload.get("target_mech_id", &"")))
			var target_name := _mech_display_name(target_mech_id)
			var reason: String = String(payload.get("reason", ""))
			return "[color=#9ad]⏱ 获取牌后 | 牌:%s | 对象:%s | 原因:%s[/color]" % [list, target_name, reason]
		&"GAIN_CARD_SETTLE":
			return "[color=#9ad]⏱ 获取牌结算[/color]"
		&"DISCARD_BEFORE":
			var card_ids: Array = payload.get("card_ids", [])
			var count: int = int(payload.get("count", 0))
			var reason: String = String(payload.get("reason", ""))
			var executor: String = String(payload.get("executor", ""))
			var executor_text := _mech_display_name(executor) if executor != "" else "系统"
			var source_text := _source_text(payload)
			var card_names: Array = []
			for cid in card_ids:
				card_names.append(_card_display_name(cid))
			var cards_text := "、".join(card_names) if card_names.size() > 0 else "%d张" % count
			return "[color=gray]⏱ 弃置牌前 | 牌:%s | 数量:%d | 执行方:%s | 原因:%s | 来源:%s[/color]" % [cards_text, count, executor_text, reason, source_text]
		&"DISCARD_AFTER":
			var card_ids: Array = payload.get("card_ids", [])
			var names: Array = []
			for cid in card_ids:
				names.append(_card_display_name(cid))
			var list := "、".join(names) if names.size() > 0 else "未知"
			var reason: String = String(payload.get("reason", ""))
			return "[color=gray]⏱ 弃置牌后 | 牌:%s | 原因:%s[/color]" % [list, reason]
		&"DISCARD_SETTLE":
			return "[color=gray]⏱ 弃置牌结算[/color]"
		&"SET_EQUIP_BEFORE":
			var card_name := _card_display_name(payload.get("card_id", &""))
			var mech_id: String = String(payload.get("mech_id", &""))
			var mech_name := _mech_display_name(mech_id)
			var source_text := _source_text(payload)
			return "[color=green]⏱ 设置装备前 | 装备:%s | 机甲:%s | 来源:%s[/color]" % [card_name, mech_name, source_text]
		&"SET_EQUIP_AT":
			var card_name := _card_display_name(payload.get("card_id", &""))
			var slot_id: String = String(payload.get("slot_id", &""))
			var slot_name := _slot_display_name(slot_id)
			var mech_id: String = String(payload.get("mech_id", &""))
			var mech_name := _mech_display_name(mech_id)
			return "[color=green]⏱ 设置装备时 | 装备:%s | 区域:%s | 机甲:%s[/color]" % [card_name, slot_name, mech_name]
		&"SET_EQUIP_AFTER":
			var card_name := _card_display_name(payload.get("card_id", &""))
			var slot_id: String = String(payload.get("slot_id", &""))
			var slot_name := _slot_display_name(slot_id)
			var mech_id: String = String(payload.get("mech_id", &""))
			var mech_name := _mech_display_name(mech_id)
			return "[color=green]⏱ 设置装备后 | 装备:%s → %s | 机甲:%s[/color]" % [card_name, slot_name, mech_name]
		&"SET_EQUIP_SETTLE":
			var card_name := _card_display_name(payload.get("card_id", &""))
			return "[color=green]⏱ 设置装备结算 | 装备:%s[/color]" % card_name
		&"EFFECT_FIRE_BEFORE":
			var effect_id: String = String(payload.get("effect_id", &""))
			var source_text := _source_text(payload)
			var target_text := _effect_targets_text(payload)
			return "[color=#cc8]⏱ 效果发动前 | 效果ID:%s | 对象:%s | 来源:%s[/color]" % [effect_id, target_text, source_text]
		&"EFFECT_FIRE_AFTER":
			var effect_id: String = String(payload.get("effect_id", &""))
			return "[color=#88aacc]⏱ 效果发动后 | 效果ID:%s[/color]" % effect_id
		&"EFFECT_FIRE_SETTLE":
			var effect_id: String = String(payload.get("effect_id", &""))
			return "[color=#88aacc]⏱ 效果发动结算 | 效果ID:%s[/color]" % effect_id
		&"BASIC_MOVE_BEFORE":
			var mech_name := _mech_display_name(String(payload.get("mech_id", &"")))
			var target_q: int = int(payload.get("target_q", 0))
			var target_r: int = int(payload.get("target_r", 0))
			var power: int = int(payload.get("current_power", 0))
			var source_text := _source_text(payload)
			return "[color=#9ad]⏱ 基础移动前 | 机甲:%s | 目标:(%d,%d) | 当前动力:%d | 来源:%s[/color]" % [mech_name, target_q, target_r, power, source_text]
		&"BASIC_MOVE_AT":
			var mech_name := _mech_display_name(String(payload.get("mech_id", &"")))
			var cost: int = int(payload.get("power_cost", 0))
			return "[color=#9ad]⏱ 基础移动时 | 机甲:%s | 消耗动力:%d[/color]" % [mech_name, cost]
		&"BASIC_MOVE_AFTER":
			var mech_name := _mech_display_name(String(payload.get("mech_id", &"")))
			var target_q: int = int(payload.get("target_q", 0))
			var target_r: int = int(payload.get("target_r", 0))
			var remaining_power: int = int(payload.get("remaining_power", 0))
			return "[color=#9ad]⏱ 基础移动后 | 机甲:%s → (%d,%d) | 剩余动力:%d[/color]" % [mech_name, target_q, target_r, remaining_power]
		&"BASIC_MOVE_SETTLE":
			var mech_name := _mech_display_name(String(payload.get("mech_id", &"")))
			return "[color=#9ad]⏱ 基础移动结算 | 机甲:%s[/color]" % mech_name
		&"SINGLE_MOVE_SETTLE":
			var mech_name := _mech_display_name(String(payload.get("mech_id", &"")))
			return "[color=#9ad]⏱ 单次移动结算 | 机甲:%s[/color]" % mech_name
		&"SHOW_CARD_BEFORE":
			var card_names: Array = []
			var card_ids: Array = payload.get("card_ids", [])
			for cid in card_ids:
				card_names.append(_card_display_name(cid))
			var cards_text := "、".join(card_names) if card_names.size() > 0 else "未知"
			var viewer := _mech_display_name(String(payload.get("viewer_mech_id", &"")))
			var persistent: bool = payload.get("persistent", false)
			var persist_text := " [持续展示]" if persistent else ""
			return "[color=#9ad]⏱ 展示牌前 | 牌:%s | 展示给:%s%s[/color]" % [cards_text, viewer, persist_text]
		&"SHOW_CARD_AFTER":
			var card_names: Array = []
			var card_ids: Array = payload.get("card_ids", [])
			for cid in card_ids:
				card_names.append(_card_display_name(cid))
			var cards_text := "、".join(card_names) if card_names.size() > 0 else "未知"
			return "[color=#9ad]⏱ 展示牌后 | 牌:%s[/color]" % cards_text
		&"SHOW_CARD_SETTLE":
			return "[color=#9ad]⏱ 展示牌结算[/color]"
		&"VICTORY_REACHED":
			var victory_type: String = String(payload.get("victory_type", ""))
			var winner := _player_name(String(payload.get("winner_id", &"")))
			return "[color=gold]★ 达到胜利条件! | 方式:%s | 胜利者:%s[/color]" % [victory_type, winner]
		_:
			if action_type != "":
				return "[color=#88aacc][⏱ %s%s: %s] 参数:%s[/color]" % [prefix, _action_type_display(action_type), name, _compact_payload(payload)]
			return "[color=#88aacc][⏱ %s] 参数:%s[/color]" % [name, _compact_payload(payload)]


# ═══════════════════════════════════════════
# 辅助方法 — 新增
# ═══════════════════════════════════════════


## 修正方式 → 中文
func _method_text(method: String) -> String:
	match method:
		"add", "increase": return "增加"
		"sub", "decrease": return "减少"
		"restore": return "回复"
	return method


## 数值类型 → 对象类型描述
func _stat_target_type_text(stat_type: String) -> String:
	match stat_type:
		"护甲", "armor": return "机甲"
		"动力", "power": return "机甲"
		"金币", "gold": return "机甲"
		"威力", "might", "attack_power": return "攻击动作"
		"范围", "range", "attack_range": return "攻击动作"
	return "对象"


## 来源信息 → 可读文本
func _source_text(payload: Dictionary) -> String:
	var parts: Array = []
	var effect_id: String = String(payload.get("effect_id", &""))
	if effect_id != "":
		parts.append("效果:%s" % effect_id)
	var source_card := _card_display_name(payload.get("source_card_id", &""))
	if source_card != "—" and source_card != "":
		parts.append("牌:%s" % source_card)
	var source_mech_id: String = String(payload.get("source_mech_id", &""))
	if source_mech_id != "":
		var mech_name := _mech_display_name(source_mech_id)
		if mech_name != source_mech_id:
			parts.append("机甲:%s" % mech_name)
	var source_action_id: String = String(payload.get("source_action_id", payload.get("action_id", &"")))
	if source_action_id != "":
		parts.append("动作:%s" % source_action_id)
	var card_instance_id: String = String(payload.get("card_instance_id", &""))
	if card_instance_id != "" and source_card == "—":
		var cn := _card_display_name(card_instance_id)
		if cn != card_instance_id:
			parts.append("牌:%s" % cn)
	return "、".join(parts) if not parts.is_empty() else "系统"


## 效果目标 → 可读文本
func _effect_targets_text(payload: Dictionary) -> String:
	var parts: Array = []
	var target_id: String = String(payload.get("target_id", &""))
	if target_id != "":
		parts.append(_mech_display_name(target_id))
	var target_ids: Array = payload.get("target_ids", [])
	for tid in target_ids:
		parts.append(_mech_display_name(String(tid)))
	var target_card_id: String = String(payload.get("target_card_id", payload.get("weapon_id", &"")))
	if target_card_id != "":
		parts.append(_card_display_name(target_card_id))
	return "、".join(parts) if not parts.is_empty() else "—"


func _action_type_display(action_type: String) -> String:
	match action_type:
		"attack": return "攻击"
		"use_action_card": return "使用行动牌"
		"stat_modify": return "数值修正"
		"basic_move": return "基础移动"
		"single_move": return "单次移动"
		"set_equipment": return "设置装备"
		"gain_card": return "获取牌"
		"discard_card": return "弃牌"
		"effect_fire": return "效果发动"
		"hp_change": return "生命变动"
		"damage_change": return "损伤变动"
		"show_card": return "展示牌"
		"turn": return "回合"
		"charge": return "聚能"
		"repair": return "维修"
		"lock_on": return "锁定"
		"combine": return "联合"
	return action_type


# ═══════════════════════════════════════════
# 辅助方法 — 原有
# ═══════════════════════════════════════════


## 压缩 payload 为简洁的字符串显示
func _compact_payload(payload: Dictionary) -> String:
	var parts: Array = []
	for key in payload.keys():
		# 跳过一些大字段
		if key == "modifiers" or key == "available_cards":
			continue
		var value = payload[key]
		var value_str := ""
		if value is Array:
			if value.size() <= 3:
				value_str = str(value)
			else:
				value_str = "[%d项]" % value.size()
		elif value is Dictionary:
			value_str = "{...}"
		else:
			value_str = str(value)
		parts.append("%s:%s" % [key, value_str])
	return "{" + ", ".join(parts) + "}"


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
		"temp_zone": return "临时区"
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
