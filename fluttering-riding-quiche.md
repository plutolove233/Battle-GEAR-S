# 行动牌效果系统全面修复计划

## Context

当前几乎所有行动牌效果逻辑无法正常工作。核心问题不是"效果没有定义"，而是**运行链路断裂**：效果定义存在于GeneratedEffects/GameActions中，但攻击牌/迎击牌打出后从手牌移除，EffectRegistry不再持有其效果；迎击牌效果从未被解析；缺少掩护窗口、伤害修正窗口、pending action机制；AI与玩家使用不同代码路径。`effect_system_reference.xlsx`是当前代码逻辑的提取结果，说明效果定义大多已经实装。修复重点是**打通运行链路**：正确捕获行动牌效果快照、按攻击流程派发Hook、给AtomicActionResolver提供正确payload、把action结果写回attack_context，并处理所有需要玩家/AI选择的异步pending action。

---

## P0-0: 效果链路运行时诊断

**目的**: 修复前先验证当前效果链路是否完整，定位断裂点。

**文件**: `scripts/services/AttackService.gd`, `scripts/effect_core/EffectEngine.gd`, `scripts/effect_core/AtomicActionResolver.gd`

**修改目标**: 添加调试日志，在以下位置打印诊断信息：

1. **游戏启动后**: 在`GameSetupService.setup_tutorial_battle()`末尾，遍历`gs.cards`打印每张行动牌的`card.def.effects.size()`
2. **`AttackService.declare_attack()`**: 打印`attack_card_effects.size()`和每个effect的`effect_id`/`hook`
3. **`AttackService.submit_response()`**: 打印`response_card.def.effects.size()`和每个effect的`effect_id`/`hook`
4. **`EffectEngine._dispatch_hook()`**: 打印`hook_name`和命中的`bindings.size()`，每个binding的`effect.effect_id`/`source_card.instance_id`
5. **`AtomicActionResolver.resolve()`**: 打印`action_type`和`params`
6. **`AtomicActionResolver.resolve()`执行后**: 打印`attack_context`中被修改的字段（`power`, `cancelled`, `markers`等）

**逻辑原因**: 如果`card.def.effects.size() == 0`，说明效果定义没有正确绑定到卡牌；如果fire_hook命中0个binding，说明Hook派发有问题；如果binding命中但action没执行，说明ConditionChecker/TargetChecker/CostChecker拦截了；如果action执行了但attack_context没变，说明action结果写错了位置。

---

## P0-1: 统一卡牌效果快照机制（不修改卡牌实例）

**问题**: 攻击牌/迎击牌打出后从手牌移除，不在EffectRegistry中，效果需从attack_context快照解析。当前仅攻击牌有快照，迎击牌没有。且当前代码修改`attack_card.mech_id = attacker_id`来传递来源信息，会污染卡牌实例状态，影响弃牌/回收/日志/所有权判断。

**文件**: `scripts/services/AttackService.gd`

**修改目标**:

### A. `declare_attack()` 修改

1. **不再修改`attack_card.mech_id`**。改为在attack_context中保存来源信息：
```gdscript
attack_context["attack_source_player_id"] = player.player_id
attack_context["attack_source_mech_id"] = attacker_id
```
**为什么原来的不行**: 修改卡牌实例的mech_id会污染状态——这张牌后面可能被回收、弃牌、重新分配，mech_id会指向错误机甲。

2. 已有的`attack_card_effects`/`attack_card_instance`保留，但使用`duplicate(true)`深拷贝：
```gdscript
attack_context["attack_card_effects"] = attack_card.def.effects.duplicate(true)
attack_context["attack_card_instance"] = attack_card  # 仅供EffectBinding引用
```

### B. `submit_response()` 修改

在`action_hand.erase()`**之前**，保存迎击牌效果快照：

```gdscript
# 在 defender_player.action_hand.erase() 之前
var response_card = gs.get_card(response_card_id)
var response_card_effects: Array = []
if response_card and response_card.def and response_card.def.effects:
    response_card_effects = response_card.def.effects.duplicate(true)

attack_context["response_card_effects"] = response_card_effects
attack_context["response_card_instance"] = response_card
attack_context["response_source_player_id"] = defender_player.player_id
attack_context["response_source_mech_id"] = target_id
attack_context["response_card_id"] = response_card_id
attack_context["response_card_def_id"] = response_card.def.card_id
```

同时检测移动效果参数：
```gdscript
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
```

**为什么原来的不行**: submit_response()只记录response_card_id，从手牌移除后没有保存效果定义，resolve_attack()中无法找到迎击牌的效果来执行。结果就是所有迎击牌（回避/防御/反击/疾行/识破）效果从未被解析。

---

## P0-2: 新增 `_resolve_card_effects_snapshot()` 方法（替代原`_resolve_attack_card_effects`和新增`_resolve_response_card_effects`）

**文件**: `scripts/services/AttackService.gd`

**修改目标**: 新增统一的快照解析方法，替代原来分开的两个方法。不再只判断PASSIVE mode——快照解析应按hook + condition + target_rule + cost全链路判断，支持ACTIVE、CHOOSE_ONE、optional、cost等效果。

**为什么原来的不行**: `_resolve_attack_card_effects()`只判断`String(effect.mode) == "PASSIVE"`，但行动牌效果可能包括ACTIVE模式（如联合的主动效果、回收的主动效果）、CHOOSE_ONE（维修）、optional费用（闪击弃牌）等。简单用PASSIVE过滤会漏掉这些效果。

```gdscript
## 从效果快照中解析匹配指定hook的所有效果
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

    # 注入来源信息到payload（不修改卡牌实例）
    var source_player_key: String = snapshot_key + "_source_player_id"
    var source_mech_key: String = snapshot_key + "_source_mech_id"
    if not payload.has("source_player_id"):
        payload["source_player_id"] = attack_context.get(source_player_key, &"")
    if not payload.has("source_mech_id"):
        payload["source_mech_id"] = attack_context.get(source_mech_key, &"")

    for effect in effects:
        if effect == null: continue
        # 按hook匹配，不过滤mode（快照解析应支持所有mode）
        if effect.hook != hook_name:
            continue

        # ConditionChecker检查
        if not context.condition_checker.check_all(effect.conditions, payload, card_instance):
            continue

        # TargetChecker检查
        if not context.target_checker.check_all(effect.target_rules, payload, card_instance):
            continue

        # CostChecker检查（optional cost由pending action处理，此处只检查强制cost）
        var has_optional_cost: bool = false
        var mandatory_costs: Array = []
        for cost: Dictionary in effect.costs:
            if cost.get("optional", false):
                has_optional_cost = true
            else:
                mandatory_costs.append(cost)

        if not context.cost_checker.can_pay_all(mandatory_costs, payload, card_instance):
            continue

        # 支付强制费用
        context.cost_checker.pay_all(mandatory_costs, payload, card_instance)

        # 如果有optional cost，将整个效果存入pending_actions
        if has_optional_cost:
            if not attack_context.has("pending_after_resolve"):
                attack_context["pending_after_resolve"] = []
            attack_context["pending_after_resolve"].append({
                "effect": effect,
                "source_card_id": attack_context.get(snapshot_key + "_id", &""),
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
            # RESOLVED阶段的START_ATTACK_DECLARE_ATTACK转pending（见P0-4）
            if hook_name == _EffectConst.HOOK_ATTACK_RESOLVED and action_type == &"START_ATTACK_DECLARE_ATTACK":
                if not attack_context.has("pending_after_resolve"):
                    attack_context["pending_after_resolve"] = []
                var pending_type: StringName = action.get("params", {}).get("pending_type", &"REPEAT_ATTACK")
                # 由effect_id或action params决定pending_type
                if effect.effect_id == &"discard_action_repeat_same_attack":
                    pending_type = &"FLASH_ATTACK"
                elif effect.effect_id == &"counterattack_after_resolution":
                    pending_type = &"COUNTERATTACK"
                elif effect.effect_id == &"allow_other_mecha_attack_after_your_attack":
                    pending_type = &"JOINT_ATTACK"
                attack_context["pending_after_resolve"].append({
                    "type": pending_type,
                    "optional": true,
                    "source_card_id": attack_context.get(snapshot_key + "_id", &""),
                    "source_player_id": attack_context.get(source_player_key, &""),
                    "source_mech_id": attack_context.get(source_mech_key, &""),
                    "cost": effect.costs,
                    "weapon_id": attack_context.get("weapon_id", &""),
                    "target_id": attack_context.get("target_id", &""),
                })
                continue
            _AtomicActionResolver.resolve(binding, payload, action, context)
```

**逻辑原因**:
- 不只过滤PASSIVE：快照中的效果可能有ACTIVE模式（如回收、联合的主动部分）
- 支持condition/target/cost全链路：与EffectEngine._try_resolve_binding()保持一致
- optional cost → pending：闪击的"弃1行动牌"是可选费用，不应自动执行
- RESOLVED阶段的START_ATTACK_DECLARE_ATTACK → pending：不能递归调用declare_attack()
- 由effect_id决定pending_type：不同效果对应不同的pending行为（闪击/反击/联合）

---

## P0-3: 重构 `resolve_attack()` 为完整多阶段流程

**文件**: `scripts/services/AttackService.gd`

**修改目标**: 将`resolve_attack()`重构为以下完整阶段顺序。

**防重复触发原则**:
- `fire_hook()` 只触发EffectRegistry中的**场上持续效果**（装备、机师、事件、状态效果）
- `_resolve_card_effects_snapshot("attack_card", ...)` 只解析attack_context中的**攻击牌快照**
- `_resolve_card_effects_snapshot("response_card", ...)` 只解析attack_context中的**迎击牌快照**
- `_resolve_card_effects_snapshot("cover_card", ...)` 只解析attack_context中的**掩护牌快照**
- **手牌中的行动牌不应被fire_hook自动执行**——行动牌是"可选择打出"，不是"自动触发效果"

**为什么原来的不行**: 原resolve_attack()缺少掩护解析、迎击效果解析、伤害修正窗口。攻击牌的MODIFIER_WINDOW效果在declare_attack()中解析（时点错误）。迎击牌效果完全没有解析路径。

**完整阶段顺序**（按推荐调整后的顺序）:

```
resolve_attack(attack_id):

  1. 迎击即时效果预结算（在修正窗口前，因为防御+5护甲要在修正窗口生效）
     - _resolve_card_effects_snapshot("response_card", HOOK_ATTACK_RESPONSE_WINDOW, skip_move=true)
       → 识破: NEGATE_ATTACK → attack_context["cancelled"]=true
       → 识破: STEAL_ACTION_CARD
       → 防御: MODIFY_ARMOR delta=5 duration=THIS_ATTACK → 写入attack_context["temporary_armor_bonus"]+=5
       → 回避/疾行: MOVE_MECH被跳过（异步处理）
     - 检查attack_context["cancelled"]
       → 若true: attack_context["result"]="negated"，跳过阶段2-7，直接到阶段8
       → 不直接return，走统一的日志、清理、结果返回流程

  2. 攻击修正窗口
     - fire_hook(HOOK_ATTACK_MODIFIER_WINDOW)  → 场上持续效果
     - _resolve_card_effects_snapshot("attack_card", HOOK_ATTACK_MODIFIER_WINDOW)
       → 猛击: MODIFY_ATTACK_POWER delta=4 → 写入attack_context["power"]+=4
     - _resolve_card_effects_snapshot("cover_card", HOOK_ATTACK_MODIFIER_WINDOW)
       → 掩护: MODIFY_ATTACK_POWER delta=-5 → 写入attack_context["power"]-=5
     - _resolve_card_effects_snapshot("response_card", HOOK_ATTACK_MODIFIER_WINDOW)
       → 防御的MODIFIER_WINDOW效果（如果有的话）

  3. 射程复查
     - 所有移动（回避/疾行/强袭）在UI层已完成
     - 不在范围内 → attack_context["hit"]=false，跳到阶段8

  4. 命中判定
     - attack_context["hit"] = true
     - 计算伤害: damage = max(0, attack_context["power"] - (target_armor + attack_context.get("temporary_armor_bonus", 0)))
     - 计算基础损伤: base_markers = floor(attack_context["power"] / 5)
     - attack_context["damage"] = damage
     - attack_context["markers"] = base_markers
     - attack_context["extra_markers"] = 0  # 破甲等额外损伤

     - fire_hook(HOOK_ATTACK_HIT)  → 场上持续效果
     - _resolve_card_effects_snapshot("attack_card", HOOK_ATTACK_HIT)
       → 破甲: PLACE_DAMAGE_TOKENS → 写入attack_context["extra_markers"]+=2（不直接放置）
       → 预判: APPLY_OR_CHECK_LOCKED → 施加锁定状态
       → 预判: STEAL_ACTION_CARD → 弃置/获得目标1行动牌
     - _resolve_card_effects_snapshot("response_card", HOOK_ATTACK_HIT)

  5. 伤害修正窗口
     - fire_hook(HOOK_DAMAGE_MODIFIER_WINDOW)  → 场上持续效果
     - _resolve_card_effects_snapshot("response_card", HOOK_DAMAGE_MODIFIER_WINDOW)
       → 防御: MODIFY_DAMAGE_TOKENS delta=-1 → attack_context["markers"] = max(0, markers - 1)
     - 最终 markers = attack_context["markers"] + attack_context["extra_markers"]

  6. 损伤放置
     - 有迎击 → 防守方选位置
     - 无迎击 → 攻击方选位置
     - 逐枚放置，每枚后检查装备是否损坏
     - 返回需要放置信息给UI层（不在此方法内完成放置）

  7. HP扣减
     - target.current_hp -= attack_context["damage"]
     - HP<=0 → destroy_mech（但不提前return，保证阶段8仍执行）
     - **为什么不能提前return**: 规则里攻击命中后既产生损伤也造成伤害，不能因为HP先归零就跳过损伤放置、装备损坏、后续效果（反击/闪击等）

  8. 攻击结算
     - fire_hook(HOOK_ATTACK_RESOLVED)  → 场上持续效果
     - _resolve_card_effects_snapshot("attack_card", HOOK_ATTACK_RESOLVED)
       → 闪击: START_ATTACK_DECLARE_ATTACK → 存入pending（P0-4）
     - _resolve_card_effects_snapshot("response_card", HOOK_ATTACK_RESOLVED)
       → 反击: START_ATTACK_DECLARE_ATTACK → 存入pending（P0-4）
     - 收集attack_context["pending_after_resolve"]

  9. 返回结果
     - 包含 hit/damage/markers/target_mech_id_for_tokens/chooser_player_id/pending_actions
     - 被negated的攻击也走此流程返回，不提前return
```

**阶段顺序逻辑原因**:
- 迎击即时效果（阶段1）在修正窗口（阶段2）前：防御+5护甲是RESPONSE_WINDOW hook但效果是"本次攻击护甲+5"，必须在修正窗口前生效，这样修正窗口计算时临时护甲已在attack_context中
- **不要让防御+5在RESPONSE_WINDOW和MODIFIER_WINDOW重复执行**: 防御的`defend_armor_bonus_5`效果hook是`HOOK_ATTACK_RESPONSE_WINDOW`，只在阶段1解析一次。它写入`attack_context["temporary_armor_bonus"]`，阶段4计算伤害时使用。不在阶段2再次解析。
- 掩护效果在修正窗口解析：掩护-5威力是MODIFIER_WINDOW hook，统一在修正窗口生效
- 射程复查（阶段3）在所有移动完成后：回避/疾行/强袭移动由UI异步处理，在调用resolve_attack()前已完成
- 破甲额外损伤写入`extra_markers`（阶段4）：不直接PLACE_DAMAGE_TOKENS，避免绕过统一的损伤放置方判断和逐枚放置UI
- **markers计算**: `base_markers = floor(power/5)`先算基础值写入attack_context["markers"]，破甲写入attack_context["extra_markers"]，防御-1修改attack_context["markers"]，最终`total_markers = markers + extra_markers`
- **为什么不用temp_values**: 全局`gs.temp_values`没有attack_id作用域，多次攻击时可能读到上一次残留，多个Hook同时修改时可能覆盖

---

## P0-4: pending action 机制

**问题**: 闪击（弃1行动牌再攻）、反击（结算后发动攻击）、联合（允许其他机甲攻击）不能在AtomicActionResolver中直接递归调用declare_attack()，否则UI卡死或重复结算。

**文件**: `scripts/services/AttackService.gd`, `scripts/battle/battle_state.gd`, `scripts/app/app_root.gd`

**修改目标**: 在P0-2的`_resolve_card_effects_snapshot()`中，RESOLVED阶段遇到START_ATTACK_DECLARE_ATTACK时存入pending列表，不直接执行。CARD_PLAYED阶段的普通攻击声明（进攻/猛击等的basic_attack_single）正常执行，不转pending。

**为什么原来的不行**: AtomicActionResolver中START_ATTACK_DECLARE_ATTACK直接调用AttackService.declare_attack()，在RESOLVED阶段会导致递归：resolve_attack() → 解析RESOLVED效果 → declare_attack() → ... → resolve_attack() → ... 这会破坏UI状态机和攻击流程。

**pending action数据结构**:
```gdscript
attack_context["pending_after_resolve"] = [
    {
        "type": "FLASH_ATTACK",        # 由effect_id决定（见P0-2）
        "optional": true,              # 玩家可选择是否发动
        "source_card_id": card_id,
        "source_player_id": player_id,
        "source_mech_id": mech_id,
        "cost": [{"cost_type": "DISCARD_ACTION_CARD", "count": 1}],
        "weapon_id": original_weapon_id,
        "target_id": original_target_id,
    },
    {
        "type": "COUNTERATTACK",
        "optional": true,
        "source_card_id": response_card_id,
        "source_player_id": defender_player_id,
        "source_mech_id": target_mech_id,
        "cost": [],
        "weapon_id": null,             # 需要选择武器
        "target_id": null              # 需要选择目标（默认为攻击者）
    },
    {
        "type": "JOINT_ATTACK",
        "optional": true,
        "source_card_id": card_id,
        "source_player_id": player_id,
        "source_mech_id": mech_id,
        "cost": [],
        "weapon_id": null,
        "target_id": null,
    }
]
```

**防重复/防递归/防状态丢失规则**:
1. 每个attack_id只生成一次pending列表（在RESOLVED阶段末尾一次性收集）
2. pending action必须记录来源卡牌、来源玩家、来源机甲、原weapon_id、原target_id
3. pending action必须记录是否optional
4. 玩家/AI确认发动时先支付cost，再创建**新的attack_id**调用declare_attack()
5. 若费用不足，pending action不可发动
6. pending action处理完后从列表移除
7. 新攻击创建新attack_context，不复用旧的

**BattleState处理**: `resolve_attack()`返回结果中包含`pending_actions`，BattleState检查列表：
- 对玩家：弹出选择面板（是否发动？选择武器/目标？）
- 对AI：自动决策

---

## P0-5: 掩护牌独立流程（不走EffectRegistry自动触发）

**问题**: 掩护是辅助牌，不是被动光环。不能因为手里有掩护，fire_hook就自动减5威力。必须经过"发现→提示→选择→打出→弃牌→快照→修正"流程。

**文件**: `scripts/services/AttackService.gd`, `scripts/battle/battle_state.gd`, `scripts/app/app_root.gd`

**修改目标**:

### A. 掩护合法性校验
- 打出掩护的玩家**不是**攻击目标
- 该玩家手中有掩护牌（action_type="辅助"，hook含ON_ATTACK_DECLARED）
- 掩护玩家有已设置的武器
- 被攻击的机甲在掩护玩家武器的范围内
- 被锁定(CANNOT_RESPOND)不影响掩护（掩护不是迎击）
- 打出后从手牌移除、弃牌、写日志

### B. AttackService — 新增 `submit_cover()` 方法

```gdscript
func submit_cover(attack_id: StringName, cover_card_id: StringName, cover_player_id: StringName) -> Dictionary:
    # ... 合法性校验 ...
    # 保存掩护牌效果快照
    var cover_card = gs.get_card(cover_card_id)
    attack_context["cover_card_effects"] = cover_card.def.effects.duplicate(true)
    attack_context["cover_card_instance"] = cover_card
    attack_context["cover_source_player_id"] = cover_player_id
    attack_context["cover_source_mech_id"] = cover_mech_id  # 掩护玩家的机甲ID
    # 从手牌移除
    var cover_player = gs.players.get(cover_player_id)
    cover_player.action_hand.erase(cover_card_id)
    # 从EffectRegistry注销
    if context.effect_registry:
        context.effect_registry.unregister_card(cover_card)
    # 写日志
    gs.write_log(&"cover_played", {
        "attack_id": String(attack_id),
        "cover_card_id": String(cover_card_id),
        "cover_player_id": String(cover_player_id),
    })
    return {"ok": true, "attack_id": attack_id}
```

### C. BattleState — 掩护检测流程

在`begin_attack()`中，攻击声明完成后（declare_attack()返回awaiting_response之前），检测是否有玩家可以打出掩护：

```gdscript
# 查找可打出掩护的玩家
var cover_candidates = _find_cover_candidates(attack_id)
if cover_candidates.size() > 0:
    if _is_ai_turn():
        # AI自动决策是否掩护
        _ai_decide_cover(attack_id, cover_candidates)
    else:
        # 玩家选择是否掩护
        return {"state": "awaiting_cover_selection", "attack_id": attack_id, "candidates": cover_candidates}
```

### D. app_root — 掩护选择UI

新增掩护选择面板（可复用response_panel的结构）。

**为什么原来的不行**: 掩护牌在action_hand中被EffectRegistry注册，fire_hook(HOOK_ATTACK_DECLARED)会自动触发掩护效果，导致：(1)玩家没选择就自动发动；(2)掩护牌不从手牌弃置；(3)锁定状态判断混乱；(4)多张掩护可能自动叠加。

---

## P0-6: 新增 `HOOK_DAMAGE_MODIFIER_WINDOW`

**文件**: `scripts/services/AttackService.gd`, `scripts/effect_core/EffectConst.gd`, `scripts/effect_core/GameActions.gd`

### A. EffectConst — 新增常量
```gdscript
const HOOK_DAMAGE_MODIFIER_WINDOW: StringName = &"ON_DAMAGE_MODIFIER_WINDOW"
```

### B. resolve_attack() 阶段5 — 触发伤害修正窗口

在命中判定后、损伤放置前（P0-3阶段5）。

### C. GameActions.modify_damage_tokens() — 写回attack_context

**为什么原来的不行**: 当前`MODIFY_DAMAGE_TOKENS`可能写到`damage_contexts`或`temp_values`，但`damage_contexts`当前未被使用，`temp_values`没有attack_id作用域。改为直接写回`attack_context`：

```gdscript
func modify_damage_tokens(params: Dictionary) -> void:
    var delta: int = int(params.get("delta", 0))
    var attack_id = params.get("attack_id", context.game_state.current_attack_id)
    if attack_id != &"" and context.game_state.attacks.has(attack_id):
        var attack = context.game_state.attacks[attack_id]
        var current_markers = int(attack.get("markers", 0))
        attack["markers"] = max(0, current_markers + delta)
        context.game_state.attacks[attack_id] = attack
    # 同时写入temp_values（向后兼容）
    context.game_state.temp_values["modified_markers"] = max(0, int(context.game_state.temp_values.get("modified_markers", 0)) + delta)
```

---

## P0-7: EffectRegistry不能自动执行action_hand中的行动牌效果

**问题**: 仅unregister已打出的牌不够，因为其他手牌仍可能被fire_hook命中。行动牌在action_hand中被注册到EffectRegistry，fire_hook(HOOK_ATTACK_CARD_PLAYED等)会自动触发手牌中的行动牌效果，导致玩家未选择就自动执行。

**文件**: `scripts/effect_core/EffectRegistry.gd`

**修改目标**: 区分automatic_bindings和playable_action_bindings：

```gdscript
# 修改 _should_register() 方法
func _should_register(card, effect) -> bool:
    if card.disabled: return false
    # 行动牌在手牌中不自动注册——它们只能通过"打出"后快照解析
    if card.zone in [&"action_hand", &"equipment_hand"]:
        return false  # 手牌中的行动/装备牌不自动触发
    # 场上持续效果自动注册
    if card.zone in [&"equipment_slot", &"weapon_slot", &"event_slot", &"pilot_slot", &"reserve_slot"]:
        return true
    return false
```

**为什么原来的不行**: 原来action_hand在白名单中，手牌的行动牌会被注册。fire_hook时EffectRegistry会找到这些binding并自动执行。但行动牌是"可选择打出"的，不应该自动触发。这会导致：
1. 手牌中有猛击时，任何fire_hook(HOOK_ATTACK_MODIFIER_WINDOW)都会自动+4威力
2. 手牌中有防御时，任何fire_hook(HOOK_ATTACK_RESPONSE_WINDOW)都会自动+5护甲
3. 与快照解析重复执行同一效果

---

## P1-1: 迎击牌/强袭移动效果异步处理

**问题**: 回避/疾行/识破的移动和强袭的移动都需要玩家选择目标格子，是异步操作。

**文件**: `scripts/ui/attack_flow_controller.gd`, `scripts/battle/battle_state.gd`, `scripts/app/app_root.gd`

### A. AttackFlowController — 新增两个移动状态

```gdscript
const EVADE_MOVEMENT: StringName = &"EVADE_MOVEMENT"
const ASSAULT_MOVEMENT: StringName = &"ASSAULT_MOVEMENT"

var evade_power_fraction: float = 1.0
var evade_use_current_power: bool = false

func enter_evade_movement(attack_id, power_fraction, use_current_power):
    current_state = EVADE_MOVEMENT
    self.attack_id = attack_id
    evade_power_fraction = power_fraction
    evade_use_current_power = use_current_power

func enter_assault_movement(attack_id):
    current_state = ASSAULT_MOVEMENT
    self.attack_id = attack_id
```

### B. BattleState.handle_response() — 返回移动状态

- 迎击牌提交后，检查`attack_context["response_has_movement"]`
- 若true且防守方是玩家 → 返回`{"state": "awaiting_evade_movement"}`
- 若true且防守方是AI → 自动执行移动（远离攻击者），然后继续

### C. BattleState — 强袭移动检测

- 在迎击窗口完成后，检查攻击牌效果快照中是否有`move_current_power_after_response`
- 若有且攻击方是玩家 → 返回`{"state": "awaiting_assault_movement"}`
- 若有且攻击方是AI → 自动执行移动

### D. app_root.gd — 处理移动UI

- EVADE_MOVEMENT: 计算防守方可用移动动力，高亮可达格子，玩家点击后移动，然后resolve_attack()
- ASSAULT_MOVEMENT: 计算攻击方可用移动动力，高亮可达格子，玩家点击后移动，然后resolve_attack()

**为什么原来的不行**: 移动需要在射程复查前完成（规则要求），但resolve_attack()是同步方法。不能在其中阻塞等待玩家选择格子。拆成独立UI状态是最清晰的方式。

---

## P1-2: 辅助牌主动使用链路（CardPlayService）

**文件**: `scripts/services/CardPlayService.gd`, `scripts/app/app_root.gd`

**问题**: 当前`_resolve_support_effects()`直接内联解析效果，部分效果（如聚能CONSUME_NEXT_ATTACK_POWER_BUFF在主阶段没有攻击上下文）会静默失败。

**修改目标**: 重构辅助牌打出流程：

```
CardPlayService.play_action_card(card_id, payload):
  1. 验证（手牌/主阶段/合法性）
  2. 创建support_effects_snapshot = card.def.effects.duplicate(true)
  3. 从手牌移除
  4. EffectRegistry.unregister_card(card)
  5. 注入来源信息到payload（player_id/mech_id）
  6. 遍历snapshot中所有效果，按hook + condition + target + cost解析
     - CHOOSE_ONE → 从payload读chosen_effect_id，若无则返回需要选择的状态
     - 需要武器选择 → 从payload读weapon_id，若无则返回需要选择的状态
     - 需要目标选择 → 从payload读target_mech_id，若无则返回需要选择的状态
  7. 效果执行完成后，弃牌到弃牌堆
  8. 写日志
```

**关键注意**: 觉醒/回收等查弃牌堆的效果，不能误把刚打出的自己当成目标。弃牌顺序：先执行效果（此时牌还在"正在打出"状态），再进入弃牌堆。如果效果需要从弃牌堆查找，应排除当前正在打出的牌。

**app_root.gd补充**:
- 新增`_support_card_needs_weapon()`检测（检查CHOOSE_OWN_WEAPON target_rule）
- 新增`_enter_support_weapon_select()`流程，类似weapon_picker_panel

**暂不移除`_inline_support_fallback()`**，待所有辅助牌通过效果系统测试后再移除。

---

## P2-1: 攻击牌逐张修复

### 强袭
- **问题**: `move_current_power_after_response`在`declare_attack()`的RESPONSE_WINDOW阶段解析，但此时响应窗口还未结束
- **修复**: 在P0-3中，该效果在resolve_attack()阶段1不解析（因为它是攻击牌的RESPONSE_WINDOW效果，但迎击窗口在resolve_attack()之前已经完成）。改为在BattleState层面检测：迎击窗口完成后，检查攻击牌是否有强袭移动效果，若有则进入ASSAULT_MOVEMENT状态（P1-1）
- **为什么原来的不行**: 在declare_attack()中解析RESPONSE_WINDOW效果时，迎击牌还没打出，强袭的"响应后移动"没有意义

### 猛击
- **确认**: `modify_attack_power()`写回`gs.attacks[attack_id]["power"]`（当前已有此逻辑✓）

### 破甲
- **问题**: `PLACE_DAMAGE_TOKENS`在HIT时点执行，可能绕过统一的损伤放置流程
- **修复**: 破甲的额外2枚损伤不直接放置，改为增加`attack_context["extra_markers"]+=2`。最终markers = base_markers + extra_markers
- **为什么不能直接`attack_context["markers"] += 2`**: 因为基础markers = floor(power/5)是在HIT阶段计算的，如果先算markers再+=2，结果正确。但如果顺序不对（先+=2再被floor(power/5)覆盖），就会丢失。用extra_markers独立累加，最终合并，最安全
- **为什么不能直接PLACE_DAMAGE_TOKENS**: 绕过了统一的损伤放置方判断（有迎击时由防守方指定）和逐枚放置UI

### 双连
- **问题**: 1把武器攻击1~2个目标，当前AttackService仅支持单目标
- **修复**: 短期先限制双连只支持单目标（max_targets=1），记录TODO。不做有缺陷的多目标半成品
- **为什么**: 多目标需要独立attack_context各自走掩护/迎击/移动/射程复查/命中/损伤流程，实现复杂度高

### 闪击
- **修复**: 存入pending_actions（P0-4），玩家/AI选择是否弃1行动牌再攻

### 预判
- **确认STEAL_ACTION_CARD语义**: 预判描述是"弃置目标1张行动牌"。需检查GeneratedEffects中是`STEAL_ACTION_CARD(discard=true)`还是`STEAL_ACTION_CARD(discard=false)`。若discard=false，需改为弃置而非获得
- **SET_ATTACK_UNNEGATABLE**: 在CARD_PLAYED时解析✓（通过P0-2的快照解析，在declare_attack()中调用）
- **APPLY_OR_CHECK_LOCKED**: 在HIT时解析✓

---

## P2-2: 迎击牌逐张修复

### 回避/疾行/识破移动
- P1-1 EVADE_MOVEMENT异步流程

### 反击
- counterattack_after_resolution存入pending_actions（P0-4），玩家/AI选择武器和目标后发动
- 反击不消耗攻击次数（不计入mech.attack_count_this_turn，由反击效果本身提供）

### 识破
- nullify_attack设置`attack_context["cancelled"] = true`和`attack_context["result"] = "negated"`
- resolve_attack()阶段1检查cancelled标志：**不直接return**，跳过阶段2-7（命中/伤害/损伤），但仍走阶段8（RESOLVED钩子、日志、清理、结果返回）
- **为什么不能直接return**: 直接return会跳过日志、清理、结果格式化等必要步骤

### 识破无视锁定
**关键顺序**: `ignore_lock`必须在"能否打出迎击牌"的检查**之前**判断
- 错误: 先检查CANNOT_RESPOND→拒绝→永远没机会检查ignore_lock
- 正确: 先检查迎击牌是否有ignore_lock效果→若有则允许打出→若无再检查CANNOT_RESPOND

修改`ResponsePanel._refresh()`:
```gdscript
# 检查锁定时：
var has_ignore_lock: bool = false
for effect in card.def.effects:
    if effect == null: continue
    for action in effect.actions:
        if action is Dictionary and String(action.get("type", "")) == "APPLY_OR_CHECK_LOCKED":
            var action_params = action.get("params", {})
            if action_params.get("ignore_lock", false):
                has_ignore_lock = true

if is_locked and not has_ignore_lock:
    continue  # 被锁定且无无视锁定效果，跳过此牌
# 被锁定但有ignore_lock，仍然显示此牌
```

---

## P2-3: 辅助牌逐张修复

### 维修(二选一)
- CHOOSE_ONE已有UI流程(choice_panel)，确认正常工作

### 聚能(选武器+蓄力)
**问题**: `CONSUME_NEXT_ATTACK_POWER_BUFF`需要攻击上下文，但主阶段没有攻击上下文
**修复**: 聚能改为两步效果：
1. 主阶段执行`APPLY_ENERGY_TO_WEAPON` → 在武器CardInstance的counters中标记`next_attack_power_buff: 4`
2. 下次攻击MODIFIER_WINDOW时，武器效果检查counters中的buff，执行`MODIFY_ATTACK_POWER delta=4`，然后清除counter

需修改GeneratedEffects.gd中聚能的效果定义。**注意**: 如果GeneratedEffects.gd是生成文件，必须修改生成源并重新生成，不要只手改生成物。

### 锁定
**问题**: 当前hook=ATTACK_CARD_PLAYED，但锁定是辅助牌，主阶段打出不应挂在ATTACK_CARD_PLAYED
**修复**:
- hook改为`HOOK_OWNER_MAIN_PHASE`
- 效果：施加CANNOT_RESPOND状态，记录`source_player_id`
- 状态只禁止响应**来源玩家**发动的攻击（检查attack_context["attacker_player_id"]与状态的source_player_id匹配）
- 识破不受锁定影响（P2-2已处理）
- 锁定状态生命周期：
  - 命中后结束：lock_effect_ends_after_target_hit在HIT时检查攻击来源是否匹配
  - 回合结束清理：来源玩家回合结束时，清理该玩家施加的所有THIS_TURN CANNOT_RESPOND状态

**注意**: 需修改GeneratedEffects.gd。如果是生成文件，必须修改生成源并重新生成。

### 掩护
- 独立流程（P0-5），不走EffectRegistry自动触发

### 回忆/回收/补给
- 简单效果，确认GameActions中对应action实现可用

### 折扣
- `SHOP_BUY_MODIFIER`需确认ShopService读取该modifier

### 设陷
- `HOOK_MECH_LEAVING_CELL`触发时机需确认MapService是否在机甲移动时触发此hook

### 联合
- 存入pending_actions（P0-4），玩家/AI选择其他机甲后执行

### 觉醒
- `GAIN_SPECIFIC_CARD`从弃牌堆查找预判/识破，若缺失则fallback_to_choice
- **注意**: 不能把刚打出的觉醒牌自己当成目标——弃牌顺序确保效果先执行再入弃牌堆

---

## P2-4: 损伤放置规则修复

**文件**: `scripts/services/DamageTokenService.gd`, `scripts/ui/damage_placement_panel.gd`

### A. DamageTokenService — 提供查询和执行API，不替玩家决定

```
# 新增/修改方法：
func get_valid_damage_slots(target_id, broken_slots) -> Array[StringName]  # 返回可选槽位列表
func place_one_damage_token(target_id, slot_id) -> void                   # 在指定槽位放1枚
func check_and_handle_equipment_break(target_id, slot_id) -> bool         # 检查并处理装备损坏
```

### B. AI自动放置

使用确定性优先级：有装备部件→有装备武器→空部件→空武器。每放1枚后检查装备损坏，损坏则更新broken_slots。

### C. 玩家逐枚放置

- `DamagePlacementPanel`已有逐枚放置UI
- 每放1枚后调用`check_and_handle_equipment_break()`
- 若装备损坏，`_refresh()`重新计算可选槽位
- 有装备槽位存在时，空槽位不可放置（已有此逻辑✓）

---

## P3: 统一AI和玩家路径

### P3-1: AI迎击使用同一服务

**文件**: `scripts/battle/battle_state.gd`

- `_ai_decide_response()`已调用`submit_response()`，P0修复后效果自动解析
- 添加迎击移动效果自动执行（远离攻击者移动）
- 迎击牌选择策略：识破(ignore_lock检查) > 反击 > 防御 > 疾行 > 回避
- AI打出掩护牌时调用`submit_cover()`

### P3-2: AI辅助牌

**文件**: `scripts/battle/battle_state.gd`

新增`_ai_play_support_cards()`方法，在攻击前执行：
- **合法性检查**: 主阶段、有资源/费用、有合法目标
- 维修：仅当HP<max或有损伤时打，传chosen_effect_id
- 聚能：仅当有可用武器时打，传weapon_id
- 锁定：仅当目标存活时打，传target_mech_id
- 推进/回忆/回收/补给：可打就打
- 调用`CardPlayService.play_action_card()`，传入payload

### P3-3: AI损伤放置

已使用`DamageTokenService`，P2-4修复后自动使用正确规则

### P3-4: AI pending action处理

AI自动决策pending_actions：
- 闪击再攻：若有行动牌可弃，则发动
- 反击：选择最优武器和目标发动
- 联合：选择最有利的目标机甲

---

## 状态清理总表

| 临时状态 | 写入位置 | 清理时机 |
|----------|----------|----------|
| `attack_context["temporary_armor_bonus"]` | 阶段1防御+5 | 攻击结束（attack_context销毁） |
| `attack_context["extra_markers"]` | 阶段4破甲+2 | 攻击结束（attack_context销毁） |
| `attack_context["power"]` (被修改) | 阶段2猛击+4/掩护-5 | 攻击结束（attack_context销毁） |
| `attack_context["cancelled"]` | 阶段1识破无效 | 攻击结束（attack_context销毁） |
| `attack_context["unnegatable"]` | CARD_PLAYED预判 | 攻击结束（attack_context销毁） |
| `attack_context["cover_card_effects"]` | 掩护打出时 | 攻击结束（attack_context销毁） |
| CANNOT_RESPOND状态(source_player_id) | 锁定打出时 | 命中后(HIT)或回合结束(THIS_TURN) |
| 武器counters[next_attack_power_buff] | 聚能打出时 | 下次攻击MODIFIER_WINDOW触发后清除 |
| mech.statuses中duration=THIS_ATTACK | 防御+5护甲等 | 攻击结算后还原（通过MechSlotState临时修改还原） |
| mech.statuses中duration=THIS_TURN | 推进+5动力等 | TurnService.end_turn()清理 |

**关键**: attack_context在_cleanup_attack()时被销毁，所有写入attack_context的临时值自然失效。不会影响武器永久威力、机甲永久护甲等。但如果MODIFY_ARMOR直接修改了MechSlotState的属性，需要在攻击结束后还原——通过status duration=THIS_ATTACK标记，在攻击结算后检查并还原。

---

## GeneratedEffects.gd 修改注意

如果GeneratedEffects.gd是生成文件，不要只手改它。必须：
1. 找到生成源（可能是JSON配置、build script、或Excel）
2. 修改生成源
3. 重新生成GeneratedEffects.gd
4. 改完后重新导出effect_system_reference.xlsx，确认聚能、锁定、预判等语义正确

需修改的效果定义：
- 聚能：从CONSUME_NEXT_ATTACK_POWER_BUFF改为APPLY_ENERGY_TO_WEAPON
- 锁定：hook从HOOK_ATTACK_CARD_PLAYED改为HOOK_OWNER_MAIN_PHASE，添加CHOOSE_ENEMY_MECH target_rule

---

## 修改文件清单（按优先级）

| 文件 | 修改内容 | 优先级 |
|------|----------|--------|
| `scripts/services/AttackService.gd` | P0-0诊断、P0-1快照(不改mech_id)、P0-2新增_resolve_card_effects_snapshot、P0-3重构resolve_attack多阶段、P0-4 pending action、P0-5 submit_cover+掩护窗口、P0-6 HOOK_DAMAGE_MODIFIER_WINDOW | P0 |
| `scripts/effect_core/EffectConst.gd` | P0-6新增HOOK_DAMAGE_MODIFIER_WINDOW常量 | P0 |
| `scripts/effect_core/EffectRegistry.gd` | P0-7 _should_register不再注册action_hand/equipment_hand中的牌 | P0 |
| `scripts/effect_core/GameActions.gd` | P0-6 modify_damage_tokens写回attack_context、P2-1破甲extra_markers | P0+P2 |
| `scripts/effect_core/EffectEngine.gd` | P0-0诊断日志 | P0 |
| `scripts/effect_core/AtomicActionResolver.gd` | P0-0诊断日志 | P0 |
| `scripts/battle/battle_state.gd` | P0-5掩护选择流程、P1-1迎击/强袭移动、P3-1 AI迎击+掩护、P3-2 AI辅助牌、P3-4 AI pending action | P0+P1+P3 |
| `scripts/ui/attack_flow_controller.gd` | P1-1 EVADE_MOVEMENT+ASSAULT_MOVEMENT状态 | P1 |
| `scripts/app/app_root.gd` | P0-5掩护UI、P1-1移动UI、P1-2辅助牌武器选择UI、P2-2识破ignore_lock、pending action UI | P0+P1+P2 |
| `scripts/ui/response_panel.gd` | P2-2识破ignore_lock检测 | P2 |
| `scripts/services/DamageTokenService.gd` | P2-4提供查询API+逐枚放置+装备损坏检查 | P2 |
| `scripts/ui/damage_placement_panel.gd` | P2-4每枚放置后刷新可选槽位 | P2 |
| `scripts/services/CardPlayService.gd` | P1-2重构辅助牌打出流程（快照+异步选择）、暂保留fallback | P1+P2 |
| `scripts/generated_database/GeneratedEffects.gd` | P2-3锁定hook改OWNER_MAIN_PHASE、聚能改为两步效果 | P2 |

---

## 验证方法

### 程序级诊断（P0-0）

1. 启动后打印每张行动牌`card.def.effects.size()`，确认≠0
2. 对每个hook打印命中的`effect_id`和`source_card_id`
3. 对每个AtomicAction打印resolve前后的`attack_context`关键字段
4. 确认fire_hook不会自动触发action_hand中的行动牌

### 单元测试

1. 猛击：攻击前power=X，MODIFIER后attack_context["power"]=X+4
2. 防御：RESPONSE后attack_context["temporary_armor_bonus"]=5，DAMAGE_MODIFIER后attack_context["markers"]-1
3. 破甲：HIT后attack_context["extra_markers"]=2
4. 识破：普通攻击cancelled=true，预判攻击(unnegatable=true)cancelled仍为false
5. 锁定：来源玩家攻击时普通迎击被拒、识破允许；其他来源玩家攻击时可响应
6. 掩护：手里有掩护时不自动触发，仅选择打出后才-5威力并弃牌
7. 临时值清理：攻击结束后防御+5护甲已还原、猛击+4不再影响下次攻击

### 运行现有测试

```bash
Godot --headless --path . -s res://tests/run_tests.gd
```

### 手动测试

1. 每张攻击牌效果（进攻/强袭/猛击/破甲/双连/闪击/预判）
2. 每张迎击牌效果（回避/防御/反击/疾行/识破）
3. 每张辅助牌效果（维修/聚能/推进/掩护/锁定/回忆/回收/补给/折扣/设陷/联合/觉醒）
4. AI迎击/攻击/辅助与玩家使用同一套服务方法
5. 消息日志正确显示所有效果触发信息（在服务层写日志，不只在UI层）
