# 《机斗战甲》Godot 逻辑代码包说明书 v0.0.3

> 本文档写给第一次接触本项目的人。即使你不了解这套代码，也可以通过本文理解：这款游戏大概怎么玩、代码按什么逻辑运行、每个文件负责什么、Godot 中如何接入、以后如何继续开发。

---

## 0. 当前版本说明

当前代码包版本：**v0.0.3**

本版本已经包含：

- 卡牌数据结构：装备牌、行动牌、事件牌、机师牌、机甲框架。
- 通用效果系统：`CardEffect`、`EffectRegistry`、`EffectEngine`。
- Hook 机制：流程型 Hook + 结果型 Hook。
- 原子动作系统：`AtomicActionResolver` + `GameActions`。
- 全牌数据库生成器：由 `.gd` 文件生成所有 `CardDef` 与 `CardEffect`。
- 牌堆构建器：行动牌堆、装备牌堆、高级装备牌堆、机师牌堆、事件牌堆。
- 游戏流程服务：回合、轮次、攻击、设置装备/事件、牌堆、商店、地图、胜负。
- v0.0.3 新增重点：
  - 补全 `GameState.gd` 底层查询与修改方法。
  - 增加 `DamageTokenService.gd`，细化损伤逐个放置逻辑。
  - 增加 `EquipmentBreakService.gd`，细化装备破坏与替换逻辑。
  - 增加 `AttackRuleChecker.gd`，细化攻击合法性检查。

仍需注意：

- 这是一套**逻辑层代码包**，不是完整 UI 游戏。
- 没有包含正式美术、按钮、场景、手牌 UI、地图 UI。
- 没有在 Godot 编辑器中实机编译运行过，导入工程后需要按报错继续修正。
- 全牌 Effect 已经生成成数据，但复杂牌效仍可能需要继续补具体 `Condition`、`Target`、`Cost`、`Action` 逻辑。

---

## 1. 游戏规则的最简理解

《机斗战甲》是一款机甲题材的卡牌 + 棋盘战斗游戏。

玩家控制一台机甲，在地图上移动、设置装备、使用行动牌、发动攻击、触发事件，直到敌方机甲被毁灭。

游戏中的核心对象有：

| 概念 | 通俗理解 | 代码里对应 |
|---|---|---|
| 玩家 | 操作机甲的人 | `PlayerState` |
| 机甲 | 玩家控制的战斗主体 | `MechState` |
| 机甲框架 | 机甲的基础面板和装备槽 | `MechFrameDef` |
| 装备牌 | 装在机甲上的部件或武器 | `EquipmentCardDef` |
| 行动牌 | 攻击、迎击、辅助行动 | `ActionCardDef` |
| 事件牌 | 带计时的特殊效果 | `EventCardDef` |
| 机师牌 | 决定攻击次数、行动牌上限和技能 | `PilotCardDef` |
| 效果 | 卡牌上的技能/能力 | `CardEffect` |
| Hook | 游戏流程中的触发时机 | `EffectConst.HOOK_XXX` |
| 原子动作 | 效果最终执行的最小操作 | `GameActions` 方法 |

游戏流程大致是：

```text
游戏开始
  ↓
选择机甲框架、设置机师、设置初始装备、抽初始行动牌
  ↓
按行动顺序开始回合
  ↓
回合开始：抽牌、获得金币、回复动力
  ↓
主阶段：移动、打行动牌、设置装备、买卖商店牌、使用主动效果
  ↓
攻击：打攻击牌，选择武器和目标，进入攻击结算
  ↓
回合结束：事件计时、弃超上限行动牌、弃未设置装备
  ↓
下一个玩家
  ↓
直到胜负条件达成
```

---

## 2. 代码设计总原则

本项目最重要的设计原则是：

```text
不要给每个角色、每件装备、每张事件牌单独写一套函数。
所有牌的能力都统一写成 CardEffect。
```

也就是说，不写这种代码：

```gdscript
func activate_claude_skill():
    pass

func activate_some_weapon_skill():
    pass
```

而是写成：

```gdscript
claude.effects = [
    EFFECT_REMOTE_WEAPON_RANGE_PLUS_1,
    EFFECT_PLAY_ACTION_AS_CHARGE
]
```

统一执行流程是：

```text
Service 推动游戏流程
  ↓
Service 或 Action 发出 Hook
  ↓
EffectEngine 找到监听这个 Hook 的 CardEffect
  ↓
ConditionChecker 判断触发条件
  ↓
TargetChecker 判断目标是否合法
  ↓
CostChecker 判断并支付费用
  ↓
AtomicActionResolver 分发原子动作
  ↓
GameActions 修改 GameState
  ↓
GameActions 必要时继续发出结果型 Hook
```

一句话理解：

```text
Service 决定游戏走到哪一步；Hook 通知效果现在是什么时机；Effect 判断自己能不能发动；Action 真正修改游戏状态。
```

---

## 3. Service、Hook、Effect、Action 的关系

### 3.1 Service 是什么？

`Service` 是游戏规则流程的执行者。

比如：

| Service | 负责什么 |
|---|---|
| `TurnService` | 回合开始、回合结束 |
| `RoundService` | 玩家顺序、轮次变化 |
| `AttackService` | 攻击宣言、攻击响应、命中结算 |
| `CardPlayService` | 打出行动牌 |
| `CardSetService` | 设置装备、设置事件 |
| `DeckService` | 抽牌、弃牌、牌堆移动 |
| `ShopService` | 商店初始化、购买、刷新 |
| `MapService` | 地图移动 |
| `MarkerService` | 金币、事件、陷阱标记 |
| `VictoryService` | 胜负判断 |

Service 不应该写具体卡牌效果。它只负责流程。

### 3.2 Hook 是什么？

Hook 是“流程走到这里了”的通知点。

比如：

```gdscript
EffectEngine.fire_hook(EffectConst.HOOK_TURN_START, {
    "player_id": player_id,
    "mech_id": mech_id
})
```

意思是：

```text
现在进入回合开始时机，所有监听 ON_TURN_START 的效果都可以检查是否发动。
```

### 3.3 Effect 是什么？

`CardEffect` 是卡牌上的可拆卸效果组件。

它包括：

| 字段 | 含义 |
|---|---|
| `effect_id` | 效果唯一 ID |
| `mode` | 主动 / 被动 / 静态 |
| `hook` | 监听哪个 Hook |
| `conditions` | 触发条件 |
| `target_rules` | 目标规则 |
| `costs` | 费用 |
| `actions` | 最终执行的原子动作 |
| `priority` | 结算优先级 |
| `once_per_turn_key` | 每回合一次限制 |

### 3.4 Action 是什么？

Action 是效果真正执行的最小操作。

比如：

| Action | 作用 |
|---|---|
| `DRAW_ACTION` | 抽行动牌 |
| `DRAW_EQUIPMENT` | 抽装备牌 |
| `GAIN_GOLD` | 获得金币 |
| `MODIFY_ATTACK_POWER` | 修改攻击威力 |
| `MODIFY_ATTACK_RANGE` | 修改攻击范围 |
| `DEAL_DAMAGE` | 造成生命伤害 |
| `PLACE_DAMAGE_TOKENS` | 放置损伤 |
| `ADD_STATUS` | 添加状态 |
| `PLAY_AS_CARD` | 将一张牌当作另一张虚拟牌使用 |

---

## 4. Hook 分为两类

### 4.1 流程型 Hook

流程型 Hook 一般由 Service 发出。

例如：

```text
ON_TURN_START
ON_TURN_END
ON_ATTACK_DECLARED
ON_ATTACK_RESPONSE_WINDOW
ON_ATTACK_MODIFIER_WINDOW
ON_ATTACK_HIT
ON_ATTACK_MISS
ON_ATTACK_RESOLVED
```

它们表示游戏进入了某个结算阶段。

### 4.2 结果型 Hook

结果型 Hook 一般由 `GameActions` 或底层服务在状态改变后发出。

例如：

```text
ON_CARD_DRAWN
ON_ACTION_CARD_DRAWN
ON_CARD_DISCARDED
ON_GOLD_GAINED
ON_GOLD_CHANGED
ON_DAMAGE_DEALT
ON_BEFORE_DAMAGE_TOKEN_PLACED
ON_AFTER_DAMAGE_TOKEN_PLACED
ON_EQUIPMENT_BROKEN
ON_MECH_DESTROYED
```

它们表示某个结果已经发生。

举例：

```text
TurnService 发 ON_TURN_START
  ↓
某个 Effect 触发 DRAW_ACTION
  ↓
GameActions.draw_action_cards() 抽牌
  ↓
抽牌完成后发 ON_CARD_DRAWN
  ↓
另一个 Effect 可能监听 ON_CARD_DRAWN 并继续触发
```

所以 Hook 不是 Service 专属，Action 也可以触发 Hook。

---

## 5. 目录结构说明

将代码包中的 `scripts/` 目录复制到 Godot 工程的：

```text
res://scripts/
```

目录含义如下：

```text
scripts/
  card_defs/             卡牌静态数据结构
  config/                游戏配置
  effect_core/           Effect / Hook / 原子动作核心系统
  example_data/          克劳德、聚能等示例数据
  generated_database/    自动生成的全牌数据库
  runtime/               游戏运行时状态
  services/              游戏流程与规则服务
```

### 5.1 `card_defs/`

这里定义所有卡牌的静态数据结构。

| 文件 | 作用 |
|---|---|
| `CardDef.gd` | 所有卡牌的基类 |
| `EquipmentCardDef.gd` | 装备牌，分部件和武器 |
| `ActionCardDef.gd` | 行动牌，分攻击、迎击、辅助 |
| `EventCardDef.gd` | 事件牌，包含计时字段 |
| `PilotCardDef.gd` | 机师牌，包含攻击次数、行动牌上限、职位等 |
| `MechFrameDef.gd` | 机甲框架，包含生命和槽位 |
| `MechSlotDef.gd` | 机甲槽位定义 |

### 5.2 `effect_core/`

这里是卡牌效果系统的核心。

| 文件 | 作用 |
|---|---|
| `EffectConst.gd` | 所有 Hook 常量、模式常量 |
| `CardEffect.gd` | 效果数据结构 |
| `EffectBinding.gd` | 把效果和来源牌绑定 |
| `EffectRegistry.gd` | 登记当前场上有效的效果 |
| `EffectEngine.gd` | Hook 分发和主动效果执行 |
| `ConditionChecker.gd` | 判断效果触发条件 |
| `TargetChecker.gd` | 判断目标是否合法 |
| `CostChecker.gd` | 判断并支付费用 |
| `AtomicActionResolver.gd` | 把动作字典分发到具体函数 |
| `GameActions.gd` | 真正修改游戏状态 |

### 5.3 `runtime/`

这里保存游戏运行时状态。

| 文件 | 作用 |
|---|---|
| `GameState.gd` | 全局游戏状态和底层查询方法 |
| `PlayerState.gd` | 玩家状态，金币、手牌、本回合限制 |
| `MechState.gd` | 机甲状态，生命、动力、槽位、状态 |
| `MechSlotState.gd` | 机甲某个槽位的运行时状态 |
| `CardInstance.gd` | 卡牌实例，记录位置、控制者、损伤等 |
| `DeckState.gd` | 牌堆状态 |
| `ShopState.gd` | 商店状态 |
| `MapState.gd` | 地图状态 |
| `MapCellState.gd` | 地图格子状态 |
| `MapMarkerState.gd` | 地图标记状态 |

### 5.4 `services/`

这里是规则流程服务。

| 文件 | 作用 |
|---|---|
| `GameFlowService.gd` | 游戏总流程入口 |
| `GameSetupService.gd` | 游戏初始化 |
| `TurnService.gd` | 回合开始和回合结束 |
| `RoundService.gd` | 轮次和行动顺序 |
| `PlayerActionService.gd` | 玩家主阶段操作分发 |
| `CardPlayService.gd` | 打出行动牌 |
| `CardSetService.gd` | 设置装备和事件 |
| `AttackService.gd` | 攻击流程 |
| `AttackRuleChecker.gd` | 攻击合法性检查 |
| `DamageTokenService.gd` | 损伤逐个放置 |
| `EquipmentBreakService.gd` | 装备破坏与替换 |
| `DeckService.gd` | 抽牌、弃牌、牌堆移动 |
| `DeckBuildService.gd` | 根据数据库构建牌堆 |
| `EventTimerService.gd` | 事件计时 |
| `ShopService.gd` | 商店流程 |
| `MapService.gd` | 地图移动 |
| `MarkerService.gd` | 地图标记触发 |
| `VictoryService.gd` | 胜负判断 |

### 5.5 `generated_database/`

这里是从牌表生成的全牌数据库。

| 文件 | 作用 |
|---|---|
| `GeneratedEffects.gd` | 生成所有 `CardEffect` |
| `GeneratedCardRows.gd` | 生成所有卡牌原始行数据 |
| `CardDatabaseLoader.gd` | 把原始数据转换成具体 `CardDef` |
| `CardDatabase.gd` | 对外提供统一数据库加载入口 |
| `database_build_report.json` | 生成统计报告 |
| `card_rows_debug.json` | 调试用原始数据 |

---

## 6. Godot Autoload 配置

打开 Godot：

```text
Project → Project Settings → Autoload
```

建议添加以下 Autoload。名字必须尽量和左边一致，因为代码里按这些名字调用。

```text
GameConfig              res://scripts/config/GameConfig.gd
GameState               res://scripts/runtime/GameState.gd
EffectRegistry          res://scripts/effect_core/EffectRegistry.gd
EffectEngine            res://scripts/effect_core/EffectEngine.gd
GameActions             res://scripts/effect_core/GameActions.gd
CardDatabase            res://scripts/generated_database/CardDatabase.gd
DeckService             res://scripts/services/DeckService.gd
DeckBuildService        res://scripts/services/DeckBuildService.gd
GameSetupService        res://scripts/services/GameSetupService.gd
GameFlowService         res://scripts/services/GameFlowService.gd
TurnService             res://scripts/services/TurnService.gd
RoundService            res://scripts/services/RoundService.gd
PlayerActionService     res://scripts/services/PlayerActionService.gd
CardPlayService         res://scripts/services/CardPlayService.gd
CardSetService          res://scripts/services/CardSetService.gd
AttackService           res://scripts/services/AttackService.gd
AttackRuleChecker       res://scripts/services/AttackRuleChecker.gd
DamageTokenService      res://scripts/services/DamageTokenService.gd
EquipmentBreakService   res://scripts/services/EquipmentBreakService.gd
EventTimerService       res://scripts/services/EventTimerService.gd
ShopService             res://scripts/services/ShopService.gd
MapService              res://scripts/services/MapService.gd
MarkerService           res://scripts/services/MarkerService.gd
VictoryService          res://scripts/services/VictoryService.gd
```

如果你不想全部设为 Autoload，也可以自己在场景中实例化这些服务，但需要把所有调用改成实例引用。对新手来说，建议先全部 Autoload。

---

## 7. 第一次启动应该怎么写

在一个测试场景脚本里，可以先这样写：

```gdscript
extends Node

func _ready() -> void:
    # 1. 清空运行时状态，但保留静态卡牌数据库的位置
    GameState.reset_all(false)

    # 2. 加载所有 CardDef 和 CardEffect
    CardDatabase.load_all()

    # 3. 根据卡牌数据库构建运行时牌堆
    DeckBuildService.build_all_decks_from_card_database()

    # 4. 这里后续再创建玩家、机甲、地图、测试战斗
    print("Card count = ", GameState.card_database.size())
    print("Action deck count = ", GameState.deck_state.action_deck.size())
    print("Equipment deck count = ", GameState.deck_state.equipment_deck.size())
```

如果这一步能打印出卡牌数量和牌堆数量，说明数据库加载链路基本成功。

---

## 8. 全牌数据库如何工作

本项目没有给每张牌单独写一个 `.tres` 文件，而是用 `.gd` 生成数据库。

原因：

```text
牌和效果数量很多。
如果每张牌一个 .tres，后续批量修改、重新导表、版本管理会很麻烦。
```

当前做法：

```text
GeneratedCardRows.gd
  ↓
保存所有卡牌原始行数据

GeneratedEffects.gd
  ↓
保存所有 CardEffect 数据

CardDatabaseLoader.gd
  ↓
把原始数据变成 EquipmentCardDef / ActionCardDef / EventCardDef / PilotCardDef / MechFrameDef

CardDatabase.gd
  ↓
统一加载并写入 GameState.card_database
```

加载后可以通过：

```gdscript
var card_def = GameState.card_database[&"某个 card_id"]
```

获取静态卡牌定义。

---

## 9. CardDef 和 CardInstance 的区别

这是新手最容易混淆的地方。

### 9.1 CardDef 是牌面定义

`CardDef` 表示一张牌“长什么样”。

它包括：

```text
牌名
类型
稀有度
阵营
数值
标签
效果列表
```

同一张牌的所有复制品共用同一个 `CardDef`。

### 9.2 CardInstance 是游戏中的实体牌

`CardInstance` 表示游戏里实际存在的一张牌。

它包括：

```text
这张牌属于谁
现在在哪个区域
是否设置到机甲上
是否背面朝上
有多少损伤
是否失效
```

比如同一张“光束步枪”有 3 张复制品：

```text
它们共用一个 EquipmentCardDef
但会生成 3 个 CardInstance
每个 CardInstance 有自己的 instance_id 和状态
```

---

## 10. EffectRegistry 如何工作

`EffectRegistry` 负责登记“当前场上哪些效果有效”。

牌在牌库、弃牌堆时，通常不生效。

牌进入以下区域后才会登记效果：

```text
pilot_slot      机师区
equipment_slot  装备区
event_slot      事件区
frame_slot      机甲框架区
hand            手牌区，通常只登记主动效果
```

当一张牌进入场上：

```gdscript
EffectRegistry.register_card(card_instance)
```

当一张牌离场：

```gdscript
EffectRegistry.unregister_card(card_instance)
```

当一张牌换区域：

```gdscript
EffectRegistry.refresh_card(card_instance)
```

这样做的好处是：

```text
EffectEngine 不需要每次全局扫描所有卡牌。
它只要问 EffectRegistry：当前有哪些效果监听这个 Hook？
```

---

## 11. EffectEngine 执行流程

当某个 Hook 被触发时：

```gdscript
EffectEngine.fire_hook(EffectConst.HOOK_ATTACK_MODIFIER_WINDOW, payload)
```

内部流程是：

```text
1. 把 Hook 和 payload 放入 hook_queue
2. 如果当前没有正在结算的 Hook，则开始处理队列
3. 从 EffectRegistry 取出监听该 Hook 的 EffectBinding
4. 按 priority 排序
5. 逐个检查：
   - 是否主动效果却被自动触发
   - Condition 是否满足
   - Target 是否合法
   - Cost 是否能支付
   - once_per_turn 是否已经用过
6. 支付费用
7. 执行 actions
8. 标记每回合一次
9. 发出 effect_resolved 信号
```

`hook_queue` 的作用是防止连锁效果结算混乱。

例如：

```text
A Hook 触发了一个抽牌效果
抽牌又触发 ON_CARD_DRAWN
ON_CARD_DRAWN 不会立刻插队，而是进入队列
等当前 Hook 处理完，再处理下一个 Hook
```

---

## 12. 回合流程详解

回合由 `TurnService` 控制。

### 12.1 回合开始

入口：

```gdscript
TurnService.start_turn(player_id)
```

流程：

```text
1. 设置当前玩家 active_player_id
2. phase = TURN_START
3. turn_no +1
4. 如果是一号位玩家，检查地图标记刷新
5. 重置本回合 once_per_turn
6. 重置本回合计数器
7. 发 ON_TURN_START
8. 抽 2 张行动牌
9. 抽 1 张装备牌
10. 获得 2 金币
11. 回复机甲动力
12. phase = MAIN
13. 发 ON_MAIN_PHASE_START
```

### 12.2 主阶段

主阶段由 `PlayerActionService.execute_command()` 接收玩家操作。

支持的命令包括：

```text
MOVE                  移动
PLAY_ACTION_CARD      打出行动牌
USE_ACTIVE_EFFECT     使用主动效果
SET_EQUIPMENT         设置装备
SELL_EQUIPMENT        卖出装备
BUY_SHOP_CARD         购买商店牌
BUY_HIDDEN_ADVANCED   直接买隐藏高级装备
REVEAL_HIDDEN_ADVANCED 查看隐藏高级装备
REFRESH_SHOP          刷新商店
PAID_DRAW_ACTION      花 2 金币抽 1 张行动牌
END_TURN              结束回合
```

### 12.3 回合结束

入口：

```gdscript
TurnService.end_turn(player_id)
```

流程：

```text
1. phase = TURN_END
2. 发 ON_TURN_END
3. 当前机甲事件牌计时 -1
4. 事件计时归 0 则触发 ON_EVENT_TIMER_ZERO
5. 弃置超出行动牌上限的行动牌
6. 弃置未设置的装备牌
7. 清理 THIS_TURN 状态
8. 胜负检查
9. 进入下一名玩家
```

---

## 13. 攻击流程详解

攻击由 `AttackService` 控制，合法性由 `AttackRuleChecker` 检查。

入口：

```gdscript
AttackService.declare_attack(attacker_id, target_id, weapon_id, attack_card_id)
```

完整流程：

```text
1. AttackRuleChecker.can_declare_attack()
2. 检查失败则发 ON_ATTACK_DECLARATION_FAILED，攻击结束
3. 创建 attack_context
4. 消耗本回合攻击次数
5. 发 ON_ATTACK_CARD_PLAYED
6. 发 ON_ATTACK_DECLARED
7. 如果攻击被效果取消，则结束
8. 发 ON_ATTACK_RESPONSE_WINDOW
9. 如果攻击被效果取消，则结束
10. 发 ON_ATTACK_MODIFIER_WINDOW
11. 判断目标是否仍在范围内
12. 不在范围内：ON_ATTACK_MISS → ON_ATTACK_RESOLVED
13. 在范围内：ON_ATTACK_HIT
14. 如果目标是陷阱标记，则触发陷阱爆炸
15. 如果目标是机甲，则计算生命伤害与损伤数量
16. 发 ON_DAMAGE_MODIFIER_WINDOW
17. GameActions.deal_damage()
18. GameActions.place_damage_tokens()
19. 发 ON_ATTACK_RESOLVED
```

### 13.1 攻击前会检查什么？

`AttackRuleChecker.can_declare_attack()` 会检查：

```text
攻击者是否存在
攻击者是否已经毁灭
是否当前玩家
是否主阶段
攻击者是否不能攻击
本回合是否还有攻击次数
攻击牌是否存在
攻击牌是否是 ActionCardDef
攻击牌是否为 ATTACK 类型
攻击牌是否在行动牌手牌
武器是否存在
武器是否属于攻击者
武器是否在武器区
武器是否未损坏
武器标签是否满足攻击牌要求
目标是否可攻击
```

### 13.2 攻击上下文 attack_context

攻击开始后会创建：

```gdscript
GameState.attacks[attack_id] = {
    "attack_id": attack_id,
    "attacker_id": attacker_id,
    "target_id": target_id,
    "weapon_id": weapon_id,
    "attack_card_id": attack_card_id,
    "power": weapon.def.might,
    "range_value": weapon.def.range_value,
    "hit": false,
    "cancelled": false,
    "responded_by_target": false,
    "damage_token_chooser": attacker_owner,
    "modifiers": []
}
```

后续所有攻击修正，比如威力 +4、范围 +1，都改这个上下文。

---

## 14. 损伤系统详解

损伤系统由 `DamageTokenService` 处理。

入口：

```gdscript
DamageTokenService.place_damage_tokens(params)
```

或者通过：

```gdscript
GameActions.place_damage_tokens(params)
```

最终也会转到 `DamageTokenService`。

### 14.1 损伤放置规则

当前实现遵守以下逻辑：

```text
1. 损伤逐个放置，不是一次性全部放。
2. 每一枚损伤放置前，发 ON_BEFORE_DAMAGE_TOKEN_PLACED。
3. 如果某效果把 prevented 设为 true，则这一枚损伤不放置。
4. 选择损伤区域。
5. 优先选择有装备的区域。
6. 陷阱等来源可以 prefer_part_slot，优先部件装备区域。
7. 如果没有任何装备区域可放，则允许放到部件/武器/备用区域，形成区域损伤。
8. 放置后增加区域 region_damage_tokens。
9. 如果该区域有装备，也增加装备自身 damage_tokens。
10. 放置后发 ON_AFTER_DAMAGE_TOKEN_PLACED。
11. 如果装备 damage_tokens >= durability，则触发装备破坏。
```

### 14.2 为什么有装备损伤和区域损伤？

规则里有一个重要点：装备被弃置后，损伤会保留在区域上。

所以代码里同时记录：

| 位置 | 字段 | 含义 |
|---|---|---|
| `CardInstance` | `damage_tokens` | 这张装备牌自己吃了多少损伤 |
| `MechSlotState` | `region_damage_tokens` | 这个机甲区域保留了多少损伤 |

当装备破坏后：

```text
装备牌进入弃牌堆
但 MechSlotState.region_damage_tokens 不清空
```

当设置新装备替换旧装备时：

```text
弃置旧装备
移除旧装备耐久数量的区域损伤
再设置新装备
```

这个逻辑在 `EquipmentBreakService.replace_equipment_with_new_card()` 中处理。

---

## 15. 装备破坏与替换

装备破坏由 `EquipmentBreakService` 处理。

### 15.1 装备破坏

入口：

```gdscript
EquipmentBreakService.check_equipment_broken(mech_id, slot_id, source)
```

如果：

```text
装备 damage_tokens >= 装备 durability
```

则：

```text
1. 发 ON_EQUIPMENT_BROKEN
2. 调用 break_equipment()
3. 装备进入弃牌堆
4. 区域损伤保留
```

### 15.2 设置新装备替换旧装备

入口：

```gdscript
EquipmentBreakService.replace_equipment_with_new_card(
    player_id,
    mech_id,
    new_card_id,
    slot_id,
    face_down
)
```

流程：

```text
1. GameState.can_set_card_to_slot() 检查是否合法
2. 如果原槽位有旧装备：
   - 记录旧装备耐久
   - 弃置旧装备
   - 移除旧装备耐久数量的区域损伤
3. 设置新装备到槽位
4. 从玩家装备手牌移除新装备
5. 发 ON_EQUIPMENT_REPLACED_OR_SET
```

---

## 16. 事件牌计时

事件牌由 `EventTimerService` 处理计时。

每个玩家回合结束时，当前机甲事件区的事件牌计时 -1。

流程：

```text
TurnService.end_turn()
  ↓
EventTimerService.tick_event_timer_on_turn_end(mech_id)
  ↓
事件牌 timer -= 1
  ↓
ON_EVENT_TIMER_TICK
  ↓
如果 timer <= 0：
    ON_EVENT_TIMER_ZERO
    如果事件配置 discard_when_timer_zero，则弃置事件牌
```

---

## 17. 牌堆和商店

### 17.1 牌堆类型

`DeckState` 包含：

```text
action_deck               行动牌堆
equipment_deck            普通装备牌堆
advanced_equipment_deck   高级装备牌堆
pilot_deck                机师牌堆
event_deck                事件牌堆
discard_pile              弃牌堆
```

### 17.2 抽牌

抽牌走：

```gdscript
GameActions.draw_action_cards(player_id, count, reason)
GameActions.draw_equipment_cards(player_id, count, reason)
```

内部会调用 `DeckService.draw_from_deck()`。

抽到牌后会发 Hook：

```text
ON_CARD_DRAWN
ON_ACTION_CARD_DRAWN
ON_EQUIPMENT_CARD_DRAWN
ON_DRAW_FINISHED
```

### 17.3 商店

商店状态在 `ShopState` 中。

商店包含：

```text
3 张普通装备
1 张高级装备
1 张隐藏高级装备
```

商店服务在 `ShopService.gd` 中，负责：

```text
初始化商店
购买普通/高级装备
花 10 金币直接买隐藏高级装备
花 2 金币查看隐藏高级装备
花 2 金币刷新商店
商店补牌
```

---

## 18. 地图和标记

地图相关代码在：

```text
MapState.gd
MapCellState.gd
MapMarkerState.gd
MapService.gd
MarkerService.gd
```

地图格子有三类：

| 地形 | 移动消耗 |
|---|---|
| `NORMAL` | 1 动力 |
| `GREEN` | 2 动力 |
| `RED` | 不可进入 |

地图标记有三类：

| 标记 | 效果 |
|---|---|
| `GOLD` | 投骰获得金币 |
| `EVENT` | 翻开事件牌并设置 |
| `TRAP` | 触发爆炸，中心和相邻 1 格机甲受伤和损伤 |

移动入口：

```gdscript
MapService.move_mech_to_adjacent_cell(mech_id, target_cell_id)
```

成功移动后会：

```text
消耗动力
更新位置
发 ON_MECH_MOVED
触发目标格地图标记
检查胜负
```

---

## 19. 胜负逻辑

胜负判断在 `VictoryService.gd`。

当前默认逻辑是：

```text
如果存活机甲的玩家数量 <= 1，则游戏结束。
```

代码入口：

```gdscript
VictoryService.check_victory()
```

机甲毁灭入口：

```gdscript
GameState.destroy_mech(mech_id, source)
```

会发出：

```text
ON_MECH_DESTROYED
ON_GAME_OVER
```

如果后续要做联邦 vs 帝国组队模式，需要增加 `TeamService` 或阵营关系表。

---

## 20. 克劳德示例：完整理解 Effect 流程

克劳德身上有两个效果：

```text
1. 使用远程武器攻击时，范围 +1
2. 每回合 1 次，可以将 1 张行动牌当作“聚能”使用
```

代码里不是写 `activate_claude_skill()`，而是：

```gdscript
claude.effects = [
    EFFECT_REMOTE_WEAPON_RANGE_PLUS_1,
    EFFECT_PLAY_ACTION_AS_CHARGE
]
```

### 20.1 使用主动效果：行动牌当聚能

玩家点击克劳德主动效果时：

```gdscript
EffectEngine.use_active_effect(
    &"CARD_INSTANCE_CLAUDE_001",
    &"EFFECT_PLAY_ACTION_AS_CHARGE",
    {
        "selected_action_card_id": &"CARD_INSTANCE_ACTION_023",
        "target_weapon_id": &"CARD_INSTANCE_WEAPON_REMOTE_001"
    }
)
```

流程：

```text
找到克劳德身上的 EFFECT_PLAY_ACTION_AS_CHARGE
  ↓
检查是否主阶段
  ↓
检查选择的行动牌是否在手牌
  ↓
检查目标是否是我方武器
  ↓
检查每回合一次是否已用
  ↓
支付费用：弃置那张行动牌
  ↓
执行 PLAY_AS_CARD
  ↓
生成虚拟 ACTION_CHARGE
  ↓
ACTION_CHARGE 给目标武器挂 NEXT_ATTACK_POWER_BUFF
```

### 20.2 使用远程武器攻击

攻击时：

```gdscript
AttackService.declare_attack(attacker_id, target_id, weapon_id, attack_card_id)
```

进入：

```text
ON_ATTACK_MODIFIER_WINDOW
```

这时两个效果会生效：

```text
聚能状态：本次攻击威力 +4
克劳德效果：如果武器有“远程武器”标签，本次攻击范围 +1
```

然后再判断目标是否在范围内。

---

## 21. 添加一张新牌应该怎么做

### 21.1 添加普通装备牌

```gdscript
var card := EquipmentCardDef.new()
card.card_id = &"EQ_EXAMPLE"
card.display_name = "测试装备"
card.card_kind = &"equipment"
card.equipment_kind = "WEAPON"
card.weapon_kind = "RANGED"
card.tags = [&"装备牌", &"武器装备", &"远程武器"]
card.might = 8
card.range_value = 4
card.durability = 3
card.gold = 5
card.effects = []
```

### 21.2 添加一个新 Effect

```gdscript
var effect := CardEffect.new()
effect.effect_id = &"EFFECT_EXAMPLE_RANGE_PLUS_1"
effect.display_name = "远程武器范围+1"
effect.mode = EffectConst.MODE_PASSIVE
effect.hook = EffectConst.HOOK_ATTACK_MODIFIER_WINDOW
effect.priority = 100
effect.conditions = [
    {"op": "SOURCE_OWNER_IS_ATTACKER"},
    {
        "op": "PAYLOAD_WEAPON_HAS_TAG",
        "weapon_id": "$payload.weapon_id",
        "tag": &"远程武器"
    }
]
effect.actions = [
    {
        "type": "MODIFY_ATTACK_RANGE",
        "params": {
            "attack_id": "$payload.attack_id",
            "delta": 1,
            "duration": "THIS_ATTACK"
        }
    }
]
```

然后挂到牌上：

```gdscript
card.effects = [effect]
```

### 21.3 添加新的 Condition / Target / Cost / Action

如果现有字典不支持某种效果，就需要扩展：

| 想扩展什么 | 改哪个文件 |
|---|---|
| 新触发条件 | `ConditionChecker.gd` |
| 新目标规则 | `TargetChecker.gd` |
| 新费用类型 | `CostChecker.gd` |
| 新原子动作 | `AtomicActionResolver.gd` + `GameActions.gd` |

---

## 22. 调试建议

### 22.1 先测试数据库

```gdscript
CardDatabase.load_all()
print(GameState.card_database.size())
```

如果这里失败，先不要测战斗。

### 22.2 再测试牌堆

```gdscript
DeckBuildService.build_all_decks_from_card_database()
print(GameState.deck_state.action_deck.size())
print(GameState.deck_state.equipment_deck.size())
```

### 22.3 再测试一个最小战斗

建议先只测试：

```text
两个玩家
两个机甲
玩家 1 有克劳德
玩家 1 有一把远程武器
玩家 1 有一张可被当作聚能的行动牌
玩家 1 有一张攻击牌
玩家 1 使用聚能
玩家 1 攻击玩家 2
```

不要一开始就导入完整 UI。

### 22.4 调试 Hook

可以连接 `EffectEngine` 的信号：

```gdscript
func _ready() -> void:
    EffectEngine.hook_fired.connect(_on_hook_fired)
    EffectEngine.effect_resolved.connect(_on_effect_resolved)
    EffectEngine.effect_failed.connect(_on_effect_failed)

func _on_hook_fired(hook: StringName, payload: Dictionary) -> void:
    print("HOOK: ", hook, " payload=", payload)

func _on_effect_resolved(effect_id: StringName, source_instance_id: StringName) -> void:
    print("EFFECT OK: ", effect_id, " source=", source_instance_id)

func _on_effect_failed(effect_id: StringName, source_instance_id: StringName, reason: String) -> void:
    print("EFFECT FAILED: ", effect_id, " reason=", reason)
```

这样能看到每一步是哪个 Hook、哪个 Effect 在执行。

---

## 23. 常见错误和排查

### 23.1 报错：找不到某个 Autoload

原因：没有在 Project Settings → Autoload 里添加对应脚本，或者名字和代码里用的不一致。

处理：按本文第 6 节逐个添加。

### 23.2 效果不触发

检查顺序：

```text
1. 牌是否已经进入正确区域？
2. 牌是否调用了 EffectRegistry.register_card() 或 refresh_card()？
3. Effect 的 hook 是否和当前触发的 Hook 一致？
4. Condition 是否满足？
5. Target 是否合法？
6. Cost 是否能支付？
7. once_per_turn 是否已经用过？
```

### 23.3 攻击失败

查看：

```gdscript
AttackRuleChecker.last_error
AttackService.last_attack_error
```

常见原因：

```text
不是当前玩家
不是主阶段
攻击牌不在手牌
攻击牌不是 ATTACK 类型
本回合攻击次数用完
武器不在 weapon_1 / weapon_2 区
武器不是自己的
目标不可攻击
```

### 23.4 损伤没放到想要的区域

当前没有 UI 选择损伤区域，`DamageTokenService.choose_damage_slot()` 会默认选择候选列表第一个。

后续接 UI 时，需要替换这里：

```gdscript
# 当前默认策略
return candidates[0]
```

改成玩家选择。

### 23.5 装备破坏后损伤没有消失

这是规则要求，不是 bug。

装备被破坏时：

```text
装备弃置
区域损伤保留
```

只有设置新装备替换旧装备时，才会按旧装备耐久移除区域损伤。

---

## 24. 当前最建议的下一步开发顺序

### v0.0.4：最小可运行测试场景

目标：让克劳德测试链路在 Godot 控制台真实跑通。

要做：

```text
1. 新建 TestBattleScene.tscn
2. 新建 TestBattleScene.gd
3. 初始化数据库和牌堆
4. 手工创建两个玩家、两个机甲
5. 给玩家 1 设置克劳德和远程武器
6. 给玩家 1 手牌添加行动牌和攻击牌
7. 调用克劳德主动 Effect
8. 调用 AttackService.declare_attack()
9. 打印攻击上下文、伤害、损伤、装备状态
```

### v0.0.5：数据库校验器

新增：

```text
CardDatabaseValidator.gd
```

检查：

```text
重复 card_id
重复 effect_id
未知 Hook
未知 Condition op
未知 Target op
未知 Cost type
未知 Action type
牌没有合法类型
装备数值异常
事件计时异常
机甲框架槽位缺失
```

### v0.0.6：地图和商店测试

目标：跑通移动、金币标记、事件标记、陷阱、商店购买和刷新。

### v0.0.7：基础 UI 原型

先做最基础的：

```text
手牌列表
机甲槽位列表
地图格子按钮
商店列表
日志窗口
```

---

## 25. 最后总结

这套代码的核心不是“某个角色怎么写”，而是：

```text
所有牌都是数据。
所有技能都是 CardEffect。
所有时机都靠 Hook 通知。
所有实际修改都走 GameActions。
所有复杂流程由 Service 管理。
```

最重要的运行链是：

```text
Service / GameActions
  ↓
EffectEngine.fire_hook()
  ↓
EffectRegistry 找到监听者
  ↓
Condition / Target / Cost 判定
  ↓
AtomicActionResolver
  ↓
GameActions
  ↓
GameState 改变
```

只要理解这条链，就能看懂大部分代码。

当前 v0.0.3 已经具备逻辑开发基础，下一步应该先做测试场景，而不是马上做完整 UI。
