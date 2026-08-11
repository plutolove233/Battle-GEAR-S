## CardInstance.gd — 运行时卡牌实例
##
## CardInstance 表示游戏中实际存在的一张牌。
## 同一张 CardDef 有 count 张复制品，每张有独立的 instance_id 和运行时状态。
class_name CardInstance
extends RefCounted

## 全局唯一实例 ID（由 GameState.next_id 生成）
var instance_id: StringName = &""

## 静态定义引用
var def = null  # type: CardDef

## 所属玩家
var owner_player_id: StringName = &""

## 所属机甲（装备到机甲时设置）
var mech_id: StringName = &""

## 当前所在区域
## &"action_hand" / &"equipment_hand" / &"equipment_slot" / &"weapon_slot"
## &"event_slot" / &"pilot_slot" / &"reserve_slot" / &"discard"
## &"temp_zone"（使用行动牌动作执行期间，牌离开持有者进入临时区，结算后才进 discard）
## &"action_deck" / &"equipment_deck" / &"advanced_equipment_deck"
## &"pilot_deck" / &"event_deck" / &"shop"
##
## setter 监控「离开 action_deck」：当带 face_up_bury 标签的牌 zone 从 action_deck 变走，
## emit left_action_deck 信号（pilot_003 effect_02 事后处理：瑟尔基尔立即使用/弃置+抽1）。
var _zone: StringName = &""
var zone: StringName:
	get:
		return _zone
	set(value):
		if value == _zone:
			return
		var old := _zone
		_zone = value
		if old == &"action_deck" and value != &"action_deck" and has_tag(&"face_up_bury"):
			left_action_deck.emit(self)

## pilot_003 effect_02：带 face_up_bury 标签的牌离开 action_deck 时发射（_p003_mark_face_up 时 connect）。
signal left_action_deck(card: CardInstance)

## 区域内具体槽位（&"头部"/&"躯干"/&"weapon_1" 等）
var slot_id: StringName = &""

## 装备牌上的损伤计数
var damage_tokens: int = 0

## 是否背面朝上（备用区域中的装备牌）
var face_down: bool = false

## 效果是否被临时无效化
var disabled: bool = false
var effect_negated: bool = false  # NEGATE_EQUIPMENT_EFFECT 压制：效果无效但保留牌面 stats

## 事件牌计时器（仅 EventCardDef 使用）
var timer: int = 0

## 通用计数器（武器蓄能、事件进度等）
var counters: Dictionary = {}

## 通用标签（机师埋牌等效果复用）
## 键 = StringName("标签名@owner_pid")，owner_pid 去歧义：同标签名可指向不同玩家
## （如多个瑟尔基尔各埋各的牌，各自 owner_pid 独立）
## 值 = { "tag_name": StringName, "owner_pid": StringName, "source": StringName, ... }
var tags: Dictionary = {}

## 对哪些玩家可见（展示牌效果持续展示时使用）
## 存储玩家ID列表：Array[StringName]
var known_to: Array[StringName] = []

## 聚能状态层数（用于武器蓄能）
var energy_charge_stacks: int = 0

## ── 武器装备牌运行时修正（effect_093+ 武器效果用）──
## 持久/临时威力修正列表：[{delta, duration, bucket, source_card_id}]
## duration: &"PERMANENT"(跨回合持久) / &"THIS_OWNER_TURN"(到所属玩家回合结束) / &"THIS_TURN"
## bucket: 区分修正来源(weapon_012/014衰减、聚能临时、形态等)，便于精确清除/上限回复
var might_modifiers: Array = []
## 持久/临时射程修正列表（结构同 might_modifiers）
var range_modifiers: Array = []
## 武器形态（流星钢锤 effect_098/099）：&"" / &"normal" / &"extended"
var weapon_mode: StringName = &""
## 武器冷却截止回合序号（effect_125/126）：-1=无冷却；>当前回合序号时不可攻击
var cooldown_until_turn: int = -1
## 锁定状态关联（effect_104 拘束钩爪）：锁定期间本牌不能攻击。存被锁目标 mech_id，&""=未锁定
var lock_target_mech_id: StringName = &""


func _init(p_instance_id: StringName = &"", p_def = null) -> void:
	instance_id = p_instance_id
	def = p_def


## 获取牌面名称
func get_display_name() -> String:
	if def:
		return def.display_name
	return ""


# ── 通用标签系统（机师埋牌等效果复用）──

func _tag_key(tag_name: StringName, owner_pid: StringName) -> StringName:
	return StringName(String(tag_name) + "@" + String(owner_pid))


## 添加标签。data 为自定义元数据（face_up / source / ...）。同 owner 重复添加覆盖。
func add_tag(tag_name: StringName, owner_pid: StringName, data: Dictionary = {}) -> void:
	var entry: Dictionary = {
		"tag_name": tag_name,
		"owner_pid": owner_pid,
	}
	for k in data:
		entry[k] = data[k]
	tags[_tag_key(tag_name, owner_pid)] = entry


## 是否有该标签。owner_pid 为空时匹配任意 owner。
func has_tag(tag_name: StringName, owner_pid: StringName = &"") -> bool:
	if owner_pid == &"":
		for key in tags:
			if tags[key].get("tag_name", &"") == tag_name:
				return true
		return false
	return tags.has(_tag_key(tag_name, owner_pid))


## 取标签元数据。owner_pid 为空时返回第一个匹配。无则返回空字典。
func get_tag(tag_name: StringName, owner_pid: StringName = &"") -> Dictionary:
	if owner_pid != &"":
		return tags.get(_tag_key(tag_name, owner_pid), {})
	for key in tags:
		var entry: Dictionary = tags[key]
		if entry.get("tag_name", &"") == tag_name:
			return entry
	return {}


## 该标签的所有 owner。
func get_tag_owners(tag_name: StringName) -> Array[StringName]:
	var owners: Array[StringName] = []
	for key in tags:
		var entry: Dictionary = tags[key]
		if entry.get("tag_name", &"") == tag_name:
			owners.append(entry.get("owner_pid", &""))
	return owners


## 移除标签。owner_pid 为空时移除所有同名标签。
func remove_tag(tag_name: StringName, owner_pid: StringName = &"") -> void:
	if owner_pid != &"":
		tags.erase(_tag_key(tag_name, owner_pid))
		return
	var to_erase: Array = []
	for key in tags:
		if tags[key].get("tag_name", &"") == tag_name:
			to_erase.append(key)
	for key in to_erase:
		tags.erase(key)


## 是否为正面朝上的埋牌（牌堆中显示牌名 / 抽牌跳过判定用）。
func is_face_up_in_deck() -> bool:
	for key in tags:
		if bool(tags[key].get("face_up", false)):
			return true
	return false


## 正面朝上埋牌的 owner（effect_02 路由到正确的瑟尔基尔玩家）。无则返回 &""。
func get_face_up_tag_owner() -> StringName:
	for key in tags:
		var entry: Dictionary = tags[key]
		if bool(entry.get("face_up", false)):
			return entry.get("owner_pid", &"")
	return &""
