## AttackService.gd — 攻击服务
##
## 实现两阶段攻击流程：
## 声明攻击 → 响应窗口 → 结算攻击
## 包含范围验证、伤害计算、损伤标记放置
##
## P0-1: 统一卡牌效果快照机制（不修改卡牌实例mech_id）
## P0-2: 新增 _resolve_card_effects_snapshot() 替代 _resolve_attack_card_effects
## P0-3: resolve_attack() 重构为完整多阶段流程
## P0-4: pending action 机制（闪击/反击/联合不递归调用declare_attack）
## P0-5: 掩护牌独立流程 submit_cover()
class_name AttackService
extends RefCounted

const _HexGrid = preload("res://scripts/battle/hex_grid.gd")
const _BattleMath = preload("res://scripts/battle/battle_math.gd")
const _RangeCalculator = preload("res://scripts/battle/RangeCalculator.gd")
const _EffectConst = preload("res://scripts/effect_core/EffectConst.gd")
const _EquipmentCardDef = preload("res://scripts/card_defs/EquipmentCardDef.gd")
const _EffectBinding = preload("res://scripts/effect_core/EffectBinding.gd")
const _AtomicActionResolver = preload("res://scripts/effect_core/AtomicActionResolver.gd")
const _ConditionChecker = preload("res://scripts/effect_core/ConditionChecker.gd")
const _TargetChecker = preload("res://scripts/effect_core/TargetChecker.gd")
const _CostChecker = preload("res://scripts/effect_core/CostChecker.gd")

var context = null  # type: GameContext


## 声明攻击
## 验证条件 → 创建攻击上下文 → 消耗攻击牌 → 触发钩子 → 进入响应窗口
## P0-1: 不再修改 attack_card.mech_id，改为在 attack_context 中保存来源信息
func declare_attack(attacker_id: StringName, target_id: StringName, weapon_id: StringName, attack_card_id: StringName) -> Dictionary:
	var gs = context.game_state

	# ── 1. 验证 ──
	var attacker = gs.mechs.get(attacker_id)
	var target = gs.mechs.get(target_id)

	if attacker == null:
		return {"ok": false, "message": "攻击者不存在"}
	if target == null:
		return {"ok": false, "message": "目标不存在"}
	if attacker.destroyed:
		return {"ok": false, "message": "攻击者已被摧毁"}
	if target.destroyed:
		return {"ok": false, "message": "目标已被摧毁"}

	# 验证武器属于攻击者
	var weapon_ids: Array[StringName] = attacker.get_weapon_ids()
	if not weapon_ids.has(weapon_id):
		return {"ok": false, "message": "武器不属于该机甲"}

	# 验证攻击牌在手牌中
	var player = gs.get_player_for_mech(attacker_id)
	if player == null:
		return {"ok": false, "message": "找不到攻击者所属玩家"}
	if not player.action_hand.has(attack_card_id):
		return {"ok": false, "message": "攻击牌不在手牌中"}

	# 验证攻击次数
	if not attacker.can_attack():
		return {"ok": false, "message": "本回合无法再攻击"}

	# 验证射程（使用RangeCalculator BFS动力可达）
	var weapon_card = gs.get_card(weapon_id)
	var weapon_range: int = _get_weapon_range(weapon_card)
	var map_cells: Dictionary = gs.map_state.cells if gs.map_state else {}
	if not _RangeCalculator.is_in_weapon_range(attacker.position, target.position, weapon_range, map_cells):
		return {"ok": false, "message": "目标不在射程内"}

	# ── 2. 创建攻击上下文 ──
	var attack_id: StringName = gs.next_id("attack")
	var weapon_might: int = _get_weapon_might(weapon_card)
	# P0-1: 在弃牌前保存攻击牌的效果列表（深拷贝），不再修改 attack_card.mech_id
	var attack_card = gs.get_card(attack_card_id)
	var attack_card_effects: Array = []
	if attack_card and attack_card.def and attack_card.def.effects:
		attack_card_effects = attack_card.def.effects.duplicate(true)

	var attack_context: Dictionary = {
		"attack_id": attack_id,
		"attacker_id": attacker_id,
		"target_id": target_id,
		"weapon_id": weapon_id,
		"attack_card_id": attack_card_id,
		"power": weapon_might,
		"range_value": weapon_range,
		"hit": false,
		"cancelled": false,
		# P0-1: 来源信息保存在 attack_context 中，不污染卡牌实例
		"attack_card_effects": attack_card_effects,
		"attack_card_instance": attack_card,
		"attack_source_player_id": player.player_id,
		"attack_source_mech_id": attacker_id,
	}
	gs.attacks[attack_id] = attack_context
	gs.current_attack_id = attack_id

	# ── 3. 从手牌移除攻击牌 ──
	player.action_hand.erase(attack_card_id)

	# P0-7: 从 EffectRegistry 注销（手牌中的牌不再自动注册，但安全起见仍注销）
	if context.effect_registry:
		context.effect_registry.unregister_card(attack_card)

	# ── 4. 消耗攻击次数 ──
	attacker.attack_count_this_turn += 1

	# ── 5. 触发攻击牌打出钩子 ──
	var card_played_payload := {
		"attack_id": attack_id,
		"attacker_id": attacker_id,
		"attack_card_id": attack_card_id,
		"source_player_id": player.player_id,
		"source_mech_id": attacker_id,
	}
	_fire_hook(_EffectConst.HOOK_ATTACK_CARD_PLAYED, card_played_payload)

	# ── 5b. 快照解析攻击牌的 CARD_PLAYED 效果 ──
	# 攻击牌已从手牌移除，EffectRegistry不再触发其效果，
	# 需要从 attack_context 中取出效果定义快照解析
	_resolve_card_effects_snapshot(attack_id, &"attack_card", _EffectConst.HOOK_ATTACK_CARD_PLAYED, card_played_payload)

	# ── 6. 触发攻击声明钩子 ──
	_fire_hook(_EffectConst.HOOK_ATTACK_DECLARED, {
		"attack_id": attack_id,
		"card_id": attack_card_id,
		"attacker_id": attacker_id,
		"target_id": target_id,
	})

	# ── 7. 检查是否被取消 ──
	if attack_context.get("cancelled", false):
		_cleanup_attack(attack_id)
		return {"ok": false, "message": "攻击被取消"}

	# ── 8. 触发响应窗口钩子 ──
	var response_payload := {
		"attack_id": attack_id,
		"attacker_id": attacker_id,
		"target_id": target_id,
	}
	_fire_hook(_EffectConst.HOOK_ATTACK_RESPONSE_WINDOW, response_payload)

	# ── 8b. 快照解析攻击牌的 RESPONSE_WINDOW 效果 ──
	# 注意：强袭的 move_current_power_after_response 效果在此处不解析
	# 它由 BattleState 层面在迎击窗口完成后检测并进入 ASSAULT_MOVEMENT 状态
	_resolve_card_effects_snapshot(attack_id, &"attack_card", _EffectConst.HOOK_ATTACK_RESPONSE_WINDOW, response_payload, true)

	gs.write_log(&"attack_declared", {
		"attack_id": String(attack_id),
		"attacker_id": String(attacker_id),
		"target_id": String(target_id),
	})
	return {"ok": true, "state": "awaiting_response", "attack_id": attack_id}


## 提交迎击响应
## P0-1: 在从手牌移除之前保存迎击牌效果快照
func submit_response(attack_id: StringName, response_card_id: StringName, payload: Dictionary) -> Dictionary:
	var gs = context.game_state
	var attack_context: Dictionary = gs.attacks.get(attack_id, {})

	if attack_context.is_empty():
		return {"ok": false, "message": "攻击上下文不存在"}

	var response_card = gs.get_card(response_card_id)
	if response_card == null:
		return {"ok": false, "message": "迎击牌不存在"}

	# 判断响应牌类型（迎击 vs 掩护）
	var is_cover: bool = false
	if response_card and response_card.def:
		var action_type: String = String(response_card.def.action_type)
		if action_type == "辅助":
			is_cover = true

	if is_cover:
		# 掩护牌走独立流程 P0-5
		var cover_player_id: StringName = payload.get("cover_player_id", &"")
		return submit_cover(attack_id, response_card_id, cover_player_id)

	# ── 迎击牌处理 ──
	# P0-1: 在从手牌移除之前保存迎击牌效果快照
	var response_card_effects: Array = []
	if response_card.def and response_card.def.effects:
		response_card_effects = response_card.def.effects.duplicate(true)

	attack_context["response_card_id"] = response_card_id
	attack_context["response_payload"] = payload
	attack_context["response_card_effects"] = response_card_effects
	attack_context["response_card_instance"] = response_card

	# P0-1: 保存迎击来源信息（不修改卡牌实例）
	var target_id: StringName = attack_context.get("target_id", &"")
	var defender_player = gs.get_player_for_mech(target_id)
	attack_context["response_source_player_id"] = defender_player.player_id if defender_player else &""
	attack_context["response_source_mech_id"] = target_id
	attack_context["response_card_def_id"] = response_card.def.card_id if response_card.def else &""

	# P1-1: 检测移动效果参数（回避/疾行/识破的移动）
	var has_movement: bool = false
	var power_fraction: float = 1.0
	var use_current_power: bool = false
	for effect in response_card_effects:
		if effect == null: continue
		for action: Dictionary in effect.actions:
			if String(action.get("type", "")) == "MOVE_MECH":
				has_movement = true
				var params: Dictionary = action.get("params", {})
				if params.has("power_fraction"):
					power_fraction = float(params["power_fraction"])
				if params.has("use_current_power"):
					use_current_power = bool(params["use_current_power"])

	attack_context["response_has_movement"] = has_movement
	attack_context["response_power_fraction"] = power_fraction
	attack_context["response_use_current_power"] = use_current_power

	# 从防守方手牌移除迎击牌
	if defender_player:
		defender_player.action_hand.erase(response_card_id)

	# P0-7: 从 EffectRegistry 注销
	if context.effect_registry:
		context.effect_registry.unregister_card(response_card)

	var player_id_str: String = String(defender_player.player_id) if defender_player else ""

	gs.write_log(&"attack_response", {
		"attack_id": String(attack_id),
		"response_card_id": String(response_card_id),
		"player_id": player_id_str,
		"is_cover": false,
	})

	# 触发响应牌打出钩子（用于消息日志等实时通知）
	_fire_hook(_EffectConst.HOOK_REACTION_CARD_PLAYED, {
		"attack_id": attack_id,
		"response_card_id": response_card_id,
		"target_id": String(target_id),
		"is_cover": false,
	})

	# 保存修改后的 attack_context
	gs.attacks[attack_id] = attack_context

	return {"ok": true, "attack_id": attack_id, "has_movement": has_movement}


## P0-5: 提交掩护牌
## 掩护是辅助牌，不走EffectRegistry自动触发，必须经过"发现→提示→选择→打出→弃牌→快照→修正"流程
func submit_cover(attack_id: StringName, cover_card_id: StringName, cover_player_id: StringName) -> Dictionary:
	var gs = context.game_state
	var attack_context: Dictionary = gs.attacks.get(attack_id, {})

	if attack_context.is_empty():
		return {"ok": false, "message": "攻击上下文不存在"}

	# ── 掩护合法性校验 ──
	var cover_card = gs.get_card(cover_card_id)
	if cover_card == null or cover_card.def == null:
		return {"ok": false, "message": "掩护牌不存在"}

	# 打出掩护的玩家不是攻击目标
	var target_id: StringName = attack_context.get("target_id", &"")
	var cover_player = gs.players.get(cover_player_id)
	if cover_player == null:
		return {"ok": false, "message": "掩护玩家不存在"}

	# 掩护玩家有已设置的武器
	var cover_mech = gs.get_mech_for_player(cover_player_id)
	if cover_mech == null:
		return {"ok": false, "message": "掩护玩家无机甲"}
	var cover_weapon_ids: Array[StringName] = cover_mech.get_weapon_ids()
	if cover_weapon_ids.is_empty():
		return {"ok": false, "message": "掩护玩家无武器"}

	# 被攻击的机甲在掩护玩家武器的范围内
	var attacker_id: StringName = attack_context.get("attacker_id", &"")
	var attacker_mech = gs.mechs.get(attacker_id)
	if attacker_mech and cover_mech:
		var cover_weapon_card = gs.get_card(cover_weapon_ids[0])
		var cover_weapon_range: int = _get_weapon_range(cover_weapon_card)
		var map_cells: Dictionary = gs.map_state.cells if gs.map_state else {}
		if not _RangeCalculator.is_in_weapon_range(cover_mech.position, attacker_mech.position, cover_weapon_range, map_cells):
			return {"ok": false, "message": "攻击者不在掩护武器范围内"}

	# ── 保存掩护牌效果快照 ──
	attack_context["cover_card_effects"] = cover_card.def.effects.duplicate(true)
	attack_context["cover_card_instance"] = cover_card
	attack_context["cover_source_player_id"] = cover_player_id
	attack_context["cover_source_mech_id"] = cover_mech.mech_id
	attack_context["cover_card_id"] = cover_card_id

	# 从手牌移除
	cover_player.action_hand.erase(cover_card_id)

	# 从 EffectRegistry 注销
	if context.effect_registry:
		context.effect_registry.unregister_card(cover_card)

	# 写日志
	gs.write_log(&"cover_played", {
		"attack_id": String(attack_id),
		"cover_card_id": String(cover_card_id),
		"cover_player_id": String(cover_player_id),
	})

	# 保存修改后的 attack_context
	gs.attacks[attack_id] = attack_context

	return {"ok": true, "attack_id": attack_id}


## 结算攻击
## P0-3: 重构为完整多阶段流程
## 防重复触发原则：
##   fire_hook() 只触发 EffectRegistry 中的场上持续效果
##   _resolve_card_effects_snapshot() 只解析 attack_context 中的快照
##   手牌中的行动牌不应被 fire_hook 自动执行
func resolve_attack(attack_id: StringName) -> Dictionary:
	var gs = context.game_state
	var attack_context: Dictionary = gs.attacks.get(attack_id, {})

	if attack_context.is_empty():
		return {"ok": false, "message": "攻击上下文不存在"}

	var attacker_id: StringName = attack_context.get("attacker_id", &"")
	var target_id: StringName = attack_context.get("target_id", &"")
	var attacker = gs.mechs.get(attacker_id)
	var target = gs.mechs.get(target_id)

	# ── 阶段1: 迎击即时效果预结算 ──
	# 在修正窗口前，因为防御+5护甲要在修正窗口生效
	# 识破: NEGATE_ATTACK → attack_context["cancelled"]=true
	# 防御: MODIFY_ARMOR delta=5 duration=THIS_ATTACK → 写入attack_context["temporary_armor_bonus"]+=5
	# 回避/疾行: MOVE_MECH被跳过（异步处理，skip_move=true）
	var response_payload: Dictionary = {
		"attack_id": attack_id,
		"attacker_id": String(attacker_id),
		"target_id": String(target_id),
	}
	_resolve_card_effects_snapshot(attack_id, &"response_card", _EffectConst.HOOK_ATTACK_RESPONSE_WINDOW, response_payload, true)

	# 检查攻击是否被识破取消
	var cancelled: bool = attack_context.get("cancelled", false)
	if cancelled:
		attack_context["result"] = &"negated"
		# 不直接return，走统一的日志、清理、结果返回流程
		# 跳过阶段2-7

	# ── 阶段2: 攻击修正窗口 ──
	if not cancelled:
		var modifier_payload: Dictionary = {
			"attack_id": attack_id,
			"phase": "modifier_window",
		}
		# 场上持续效果
		_fire_hook(_EffectConst.HOOK_ATTACK_MODIFIER_WINDOW, modifier_payload)
		# 攻击牌快照（猛击: MODIFY_ATTACK_POWER delta=4）
		_resolve_card_effects_snapshot(attack_id, &"attack_card", _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW, modifier_payload)
		# 掩护牌快照（掩护: MODIFY_ATTACK_POWER delta=-5）
		_resolve_card_effects_snapshot(attack_id, &"cover_card", _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW, modifier_payload)
		# 迎击牌的 MODIFIER_WINDOW 效果（如果有的话）
		_resolve_card_effects_snapshot(attack_id, &"response_card", _EffectConst.HOOK_ATTACK_MODIFIER_WINDOW, modifier_payload)

	# ── 阶段3: 射程复查 ──
	# 所有移动（回避/疾行/强袭）在UI层已完成
	var hit: bool = false
	if not cancelled and attacker and target:
		var weapon_range: int = int(attack_context.get("range_value", 1))
		var map_cells: Dictionary = gs.map_state.cells if gs.map_state else {}
		if not _RangeCalculator.is_in_weapon_range(attacker.position, target.position, weapon_range, map_cells):
			attack_context["hit"] = false
			hit = false
			# 射程外 → 跳到阶段8
		else:
			hit = true
	elif not cancelled:
		hit = true  # 无法验证时默认命中

	# ── 阶段4: 命中判定 ──
	var damage: int = 0
	var base_markers: int = 0
	var extra_markers: int = 0

	if hit and not cancelled:
		attack_context["hit"] = true

		# 计算伤害: damage = max(0, power - (target_armor + temporary_armor_bonus))
		var attack_power: int = int(attack_context.get("power", 0))
		var target_armor: int = 0
		if target:
			target_armor = target.get_armor()
		var temporary_armor_bonus: int = int(attack_context.get("temporary_armor_bonus", 0))
		damage = max(0, attack_power - (target_armor + temporary_armor_bonus))

		# 计算基础损伤: base_markers = floor(power / 5)
		base_markers = int(attack_context.get("power", 0)) / 5
		attack_context["damage"] = damage
		attack_context["markers"] = base_markers
		attack_context["extra_markers"] = 0

		# 触发命中钩子（场上持续效果）
		var hit_payload: Dictionary = {
			"attack_id": attack_id,
			"attacker_id": String(attacker_id),
			"target_id": String(target_id),
			"hit": true,
		}
		_fire_hook(_EffectConst.HOOK_ATTACK_HIT, hit_payload)

		# 攻击牌快照（破甲: PLACE_DAMAGE_TOKENS → 写入extra_markers+=2; 预判: APPLY_OR_CHECK_LOCKED）
		_resolve_card_effects_snapshot(attack_id, &"attack_card", _EffectConst.HOOK_ATTACK_HIT, hit_payload)
		# 迎击牌快照
		_resolve_card_effects_snapshot(attack_id, &"response_card", _EffectConst.HOOK_ATTACK_HIT, hit_payload)

		# 读取 extra_markers（破甲等效果可能已写入）
		extra_markers = int(attack_context.get("extra_markers", 0))

	# ── 阶段5: 伤害修正窗口 ──
	if hit and not cancelled:
		var damage_modifier_payload: Dictionary = {
			"attack_id": attack_id,
			"target_id": String(target_id),
			"damage": damage,
			"markers": base_markers,
		}
		# 场上持续效果
		_fire_hook(_EffectConst.HOOK_DAMAGE_MODIFIER_WINDOW, damage_modifier_payload)
		# 迎击牌快照（防御: MODIFY_DAMAGE_TOKENS delta=-1）
		_resolve_card_effects_snapshot(attack_id, &"response_card", _EffectConst.HOOK_DAMAGE_MODIFIER_WINDOW, damage_modifier_payload)
		# 攻击牌快照
		_resolve_card_effects_snapshot(attack_id, &"attack_card", _EffectConst.HOOK_DAMAGE_MODIFIER_WINDOW, damage_modifier_payload)

		# 最终 markers = markers(可能被防御-1修改) + extra_markers(破甲+2)
		var final_markers: int = int(attack_context.get("markers", base_markers)) + int(attack_context.get("extra_markers", 0))
		attack_context["markers"] = final_markers

	# ── 阶段6: 损伤放置 ──
	# 损伤放置由 UI 层决定，此处只返回放置参数
	# 有迎击 → 防守方选位置; 无迎击 → 攻击方选位置
	var responded: bool = attack_context.has("response_card_id") and attack_context.get("response_card_id", &"") != &""
	var target_mech_id_for_tokens: StringName = target_id
	var chooser_player_id: StringName = &""
	var final_markers: int = int(attack_context.get("markers", 0))

	if responded:
		chooser_player_id = gs.get_player_for_mech(target_id).player_id if gs.get_player_for_mech(target_id) else &""
	else:
		chooser_player_id = gs.get_player_for_mech(attacker_id).player_id if gs.get_player_for_mech(attacker_id) else &""

	# ── 阶段7: HP扣减 ──
	if hit and not cancelled and target and damage > 0:
		target.current_hp = max(0, target.current_hp - damage)
		if target.current_hp <= 0:
			gs.destroy_mech(target_id, "attack")
			# 不提前return，保证阶段8仍执行

	# ── 阶段8: 攻击结算 ──
	var resolved_payload := {
		"attack_id": attack_id,
		"hit": hit and not cancelled,
		"damage": damage,
		"markers": final_markers,
	}
	# 场上持续效果
	_fire_hook(_EffectConst.HOOK_ATTACK_RESOLVED, resolved_payload)
	# 攻击牌快照（闪击: START_ATTACK_DECLARE_ATTACK → 存入pending）
	_resolve_card_effects_snapshot(attack_id, &"attack_card", _EffectConst.HOOK_ATTACK_RESOLVED, resolved_payload)
	# 迎击牌快照（反击: START_ATTACK_DECLARE_ATTACK → 存入pending）
	_resolve_card_effects_snapshot(attack_id, &"response_card", _EffectConst.HOOK_ATTACK_RESOLVED, resolved_payload)
	# 掩护牌快照
	_resolve_card_effects_snapshot(attack_id, &"cover_card", _EffectConst.HOOK_ATTACK_RESOLVED, resolved_payload)

	# 收集 pending_after_resolve
	var pending_actions: Array = attack_context.get("pending_after_resolve", [])

	# ── 射程外/被识破时也触发 RESOLVED 钩子 ──
	if not hit and not cancelled:
		_fire_hook(_EffectConst.HOOK_ATTACK_MISS, {
			"attack_id": attack_id,
			"miss": true,
		})

	# ── 日志与清理 ──
	if cancelled:
		gs.write_log(&"attack_negated", {"attack_id": String(attack_id)})
	elif not hit:
		gs.write_log(&"attack_miss", {"attack_id": String(attack_id), "reason": "out_of_range"})
	else:
		gs.write_log(&"attack_resolved", {
			"attack_id": String(attack_id),
			"hit": true,
			"damage": damage,
			"markers": final_markers,
		})

	_cleanup_attack(attack_id)

	# ── 阶段9: 返回结果 ──
	var result := {
		"ok": true,
		"hit": hit and not cancelled,
		"cancelled": cancelled,
		"damage": damage,
		"markers": final_markers,
		"target_mech_id_for_tokens": target_mech_id_for_tokens,
		"chooser_player_id": chooser_player_id,
		"pending_actions": pending_actions,
	}
	if cancelled:
		result["result"] = &"negated"
	elif not hit:
		result["reason"] = "out_of_range"
	return result


## ── 内部方法 ──


## 获取武器威力
func _get_weapon_might(weapon_card) -> int:
	if weapon_card and weapon_card.def and weapon_card.def is _EquipmentCardDef:
		return weapon_card.def.might
	return 0


## 获取武器射程
func _get_weapon_range(weapon_card) -> int:
	if weapon_card and weapon_card.def and weapon_card.def is _EquipmentCardDef:
		return weapon_card.def.range_value
	return 1


## 触发效果钩子（通过 EffectEngine）
func _fire_hook(hook_name: StringName, payload: Dictionary = {}) -> void:
	if context.effect_engine:
		context.effect_engine.fire_hook(hook_name, payload)


## 清理攻击上下文
func _cleanup_attack(attack_id: StringName) -> void:
	var gs = context.game_state
	gs.attacks.erase(attack_id)
	if gs.current_attack_id == attack_id:
		gs.current_attack_id = &""


## P0-2: 从效果快照中解析匹配指定hook的所有效果
## 替代原 _resolve_attack_card_effects（只判断PASSIVE mode）
## 快照解析应按 hook + condition + target_rule + cost 全链路判断，支持所有mode
##
## snapshot_key: "attack_card" 或 "response_card" 或 "cover_card"
## hook_name: 只解析匹配此hook的效果
## payload: 传递给 AtomicActionResolver 的上下文
## skip_move: 是否跳过MOVE_MECH动作（异步UI处理时为true）
func _resolve_card_effects_snapshot(attack_id: StringName, snapshot_key: String, hook_name: StringName, payload: Dictionary, skip_move: bool = false) -> void:
	var gs = context.game_state
	var attack_context: Dictionary = gs.attacks.get(attack_id, {})
	var effects: Array = attack_context.get(snapshot_key + "_effects", [])
	var card_instance = attack_context.get(snapshot_key + "_instance")
	if effects.size() == 0 or card_instance == null:
		return

	# P0-1: 注入来源信息到payload（不修改卡牌实例）
	var source_player_key: String = snapshot_key + "_source_player_id"
	var source_mech_key: String = snapshot_key + "_source_mech_id"
	if not payload.has("source_player_id"):
		payload["source_player_id"] = attack_context.get(source_player_key, &"")
	if not payload.has("source_mech_id"):
		payload["source_mech_id"] = attack_context.get(source_mech_key, &"")

	for effect in effects:
		if effect == null:
			continue
		# 按hook匹配，不过滤mode（快照解析应支持所有mode）
		if effect.hook != hook_name:
			continue

		# ConditionChecker检查
		if not _ConditionChecker.check_all(card_instance, payload, effect.conditions):
			continue

		# TargetChecker检查
		if not _TargetChecker.check_all(card_instance, payload, effect.target_rules):
			continue

		# CostChecker检查（optional cost由pending action处理，此处只检查强制cost）
		var has_optional_cost: bool = false
		var mandatory_costs: Array = []
		for cost: Dictionary in effect.costs:
			if cost.get("optional", false):
				has_optional_cost = true
			else:
				mandatory_costs.append(cost)

		if not _CostChecker.can_pay_all(card_instance, payload, mandatory_costs, context):
			continue

		# 支付强制费用
		_CostChecker.pay_all(card_instance, payload, mandatory_costs, context)

		# 如果有optional cost，将整个效果存入pending_actions
		if has_optional_cost:
			if not attack_context.has("pending_after_resolve"):
				attack_context["pending_after_resolve"] = []
			attack_context["pending_after_resolve"].append({
				"effect": effect,
				"source_card_id": attack_context.get(snapshot_key + "_id", attack_context.get(snapshot_key + "_card_id", &"")),
				"source_player_id": attack_context.get(source_player_key, &""),
				"source_mech_id": attack_context.get(source_mech_key, &""),
			})
			continue

		# 执行每个action
		var binding = _EffectBinding.new(card_instance, effect)
		for action: Dictionary in effect.actions:
			var action_type: StringName = action.get("type", &"")
			# 移动效果由UI异步处理
			if skip_move and action_type == &"MOVE_MECH":
				continue
			# P0-4: RESOLVED阶段的START_ATTACK_DECLARE_ATTACK转pending（防递归）
			if hook_name == _EffectConst.HOOK_ATTACK_RESOLVED and action_type == &"START_ATTACK_DECLARE_ATTACK":
				if not attack_context.has("pending_after_resolve"):
					attack_context["pending_after_resolve"] = []
				# 由effect_id决定pending_type
				var pending_type: StringName = &"REPEAT_ATTACK"
				if effect.effect_id == &"discard_action_repeat_same_attack":
					pending_type = &"FLASH_ATTACK"
				elif effect.effect_id == &"counterattack_after_resolution":
					pending_type = &"COUNTERATTACK"
				elif effect.effect_id == &"allow_other_mecha_attack_after_your_attack":
					pending_type = &"JOINT_ATTACK"
				attack_context["pending_after_resolve"].append({
					"type": pending_type,
					"optional": true,
					"source_card_id": attack_context.get(snapshot_key + "_id", attack_context.get(snapshot_key + "_card_id", &"")),
					"source_player_id": attack_context.get(source_player_key, &""),
					"source_mech_id": attack_context.get(source_mech_key, &""),
					"cost": effect.costs,
					"weapon_id": attack_context.get("weapon_id", &""),
					"target_id": attack_context.get("target_id", &""),
				})
				continue
			_AtomicActionResolver.resolve(binding, payload, action, context)

	# 保存修改后的 attack_context（快照解析可能修改了 markers/power 等）
	gs.attacks[attack_id] = attack_context
