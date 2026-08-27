## TmpZonePanel.gd - 临时区（使用中行动牌）显示面板
##
## 规则书（各动作的生命周期与时点.txt L30）：行动牌打出后"离开持有者，进入临时区"，
## 效果执行期间停留，结算后才进弃牌堆。逻辑层在 use_action_card_action.gd 中将
## card.zone 置为 &"temp_zone"，本面板负责把这张"正在使用中"的牌实时展示出来。
##
## 半透明显示，位于手牌区上方。仅展示，不可点击。
##
## 差量刷新：标题/空位标签持久，卡牌按钮按牌实例 ID 缓存复用，
## 刷新时只做"增/删/改文本"，不再整树 queue_free 重建。
extends HBoxContainer
class_name TmpZonePanel

## 当前 GameContext 引用
var _context = null  # type: GameContext

## 半透明度
const _ALPHA: float = 0.7

## 标题标签（持久）
var _title_label: Label = null
## 无牌占位标签（持久，仅可见性切换）
var _empty_label: Label = null
## 卡牌按钮缓存：card_id -> Button
var _btn_cache: Dictionary = {}


func _ready() -> void:
	modulate.a = _ALPHA


## 配置面板，从 GameState 扫描 temp_zone 中的牌
func configure(game_context) -> void:
	_context = game_context
	_refresh()


## 刷新显示（差量）
func _refresh() -> void:
	_ensure_skeleton()

	if not _context:
		_hide_all()
		return

	var gs = _context.game_state

	# 扫描所有 zone == temp_zone 的牌（不分玩家；临时区牌必然属于当前正在执行的动作）
	var live_ids: Dictionary = {}
	var found: bool = false
	for card_id: StringName in gs.cards:
		var card = gs.cards.get(card_id)
		if card == null or card.def == null:
			continue
		if String(card.zone) != &"temp_zone":
			continue
		found = true
		live_ids[card_id] = true
		var btn: Button = _btn_cache.get(card_id)
		if btn == null:
			btn = Button.new()
			btn.custom_minimum_size = Vector2(120, 40)
			btn.disabled = true  # 仅展示
			_btn_cache[card_id] = btn
			add_child(btn)
		btn.text = "%s[%s]" % [card.def.display_name, _action_type_short(card.def)]
		btn.tooltip_text = card.def.effect_text
		# 颜色与 hand_panel 保持一致：攻击红 / 迎击青 / 辅助绿
		if card.def is ActionCardDef and card.def.action_type == &"攻击":
			btn.add_theme_color_override("font_color", Color(0.9, 0.3, 0.2))
		elif card.def is ActionCardDef and card.def.action_type == &"迎击":
			btn.add_theme_color_override("font_color", Color(0.3, 0.7, 0.9))
		else:
			btn.add_theme_color_override("font_color", Color(0.3, 0.85, 0.5))

	# 删除已离开临时区的按钮（先脱离布局再释放）
	for card_id in _btn_cache.keys():
		if not live_ids.has(card_id):
			var stale: Button = _btn_cache[card_id]
			_btn_cache.erase(card_id)
			remove_child(stale)
			stale.queue_free()

	_empty_label.visible = not found


## 构建持久骨架（标题 + 空位标签）
func _ensure_skeleton() -> void:
	if _title_label == null:
		_title_label = Label.new()
		_title_label.text = "临时区（使用中）"
		_title_label.add_theme_color_override("font_color", Color(0.85, 0.7, 0.4))
		add_child(_title_label)
	if _empty_label == null:
		_empty_label = Label.new()
		_empty_label.text = "无"
		_empty_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		add_child(_empty_label)


## 无上下文时清空（释放缓存按钮）
func _hide_all() -> void:
	for card_id in _btn_cache.keys():
		var stale: Button = _btn_cache[card_id]
		remove_child(stale)
		stale.queue_free()
	_btn_cache.clear()
	if _empty_label != null:
		_empty_label.visible = true


## 行动类型简写（与 HandPanel._action_type_short 一致）
func _action_type_short(def) -> String:
	if not def is ActionCardDef:
		return "?"
	if def.action_type == &"攻击":
		return "攻"
	elif def.action_type == &"迎击":
		return "迎"
	elif def.action_type == &"辅助":
		return "辅"
	return "?"
