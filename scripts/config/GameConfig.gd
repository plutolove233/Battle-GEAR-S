## GameConfig.gd — 游戏常量配置
##
## 集中管理所有游戏规则常量，避免硬编码散落各处。
## 数值来源：机斗战甲规则书。
class_name GameConfig
extends RefCounted


## ── 初始资源 ──

## 初始金币
const INITIAL_GOLD: int = 15

## 每回合获得金币
const GOLD_PER_TURN: int = 2


## ── 抽牌 ──

## 每回合抽行动牌数
const DRAW_ACTION_PER_TURN: int = 2

## 每回合抽装备牌数
const DRAW_EQUIPMENT_PER_TURN: int = 1

## 行动牌手牌上限（默认，机师牌可修改）
const DEFAULT_ACTION_HAND_LIMIT: int = 5

## 花金币抽行动牌费用
const PAID_DRAW_ACTION_COST: int = 2

## 花金币抽1张行动牌
const PAID_DRAW_ACTION_COUNT: int = 1


## ── 攻击 ──

## 默认每回合攻击次数上限（机师牌可修改）
const DEFAULT_ATTACK_LIMIT: int = 1

## 损伤标记阈值：每5点攻击力产生1枚损伤标记
const DAMAGE_TOKEN_PER_POWER: int = 5


## ── 商店 ──

## 商店普通装备槽数
const SHOP_NORMAL_SLOTS: int = 3

## 刷新商店费用（每回合1次）
const SHOP_REFRESH_COST: int = 3

## 查看隐藏高级装备费用
const SHOP_REVEAL_COST: int = 2

## 直接购买隐藏高级装备费用
const SHOP_BUY_HIDDEN_COST: int = 10


## ── 地图 ──

## 默认地图宽度（列数）
const DEFAULT_MAP_COLS: int = 24

## 默认地图高度（行数）
const DEFAULT_MAP_ROWS: int = 8

## 绿色格子数量（移动/攻击范围消耗+1，BFS 地形感知）
const GREEN_TILE_COUNT: int = 16

## 红色格子数量（不可进入，攻击范围需绕行）
const RED_TILE_COUNT: int = 16

## 金币标记点数量（开局生成金币标记，后续不刷新）
const GOLD_MARKER_POINT_COUNT: int = 8

## 事件标记点数量（所有事件标记消失后重生，被占据的点一次性跳过）
const EVENT_MARKER_POINT_COUNT: int = 8

## 金币标记投骰面数
const GOLD_MARKER_D6: int = 6

## 金币标记投骰收益映射：1-3 -> 3 金币、4-5 -> 4 金币、6 -> 6 金币
static func gold_marker_payout(roll: int) -> int:
	if roll <= 3:
		return 3
	elif roll <= 5:
		return 4
	else:
		return 6

## 陷阱爆炸范围（hex距离；陷阱自身格 + 此距离内的相邻格）
const TRAP_BLAST_RANGE: int = 1

## 陷阱爆炸：每个参与爆炸的陷阱对范围内每个机甲造成的HP伤害
const TRAP_BLAST_DAMAGE: int = 2

## 陷阱爆炸：每个参与爆炸的陷阱对范围内每个机甲设置的损伤标记数
const TRAP_BLAST_TOKENS: int = 2


## ── 胜利 ──

## 最大回合数（超过则按HP判定）
const MAX_TURNS: int = 30


## ── 装备卖出 ──

## 按稀有度的卖出价格
const SELL_PRICE_BY_RARITY: Dictionary = {
	&"N": 1,
	&"R": 2,
	&"SR": 3,
	&"SSR": 5,
}

## 每回合卖出装备的最大次数
const SELL_EQUIPMENT_LIMIT_PER_TURN: int = 2
