# Effective or not — Warhammer 40,000: Darktide mod

在准星旁实时显示：**你瞄准的敌人是谁**、**它是什么护甲**，以及**你手持的武器该打它哪里、打出多少伤害**。

```
血痂重锤兵 · 头部 硬壳装甲 · 躯干 防弹装甲
> 轻击   头部 x0.35  ·  躯干 x0.69
  重击   头部 x0.42  ·  躯干 x0.69
  特殊   头部 x0.88  ·  躯干 x1.33
属性   弱点 +25%  ·  暴击 20.0%  x1.00
```

- 表头 = 敌人名字 + **各可瞄部位的护甲**
- **每行列出每个可瞄部位各自的倍率**，顺序与表头一致，可直接纵向对比
- 行颜色取自**最好的那个部位**（回答"这一击有没有能打的地方"）
- **倍率 = 破甲表 × 敌人的部位伤害倍率 × 你的实时加成**
  - **部位伤害倍率**（`breed.hitzone_damage_multiplier`，按 melee/ranged 分表）是个大因子：猎犬近战全身 ×3、尾巴 ×5；装甲猎犬尾巴 ×5；腐化行尸的腿远程只有 ×0.2
  - 撕裂按文档规则加到破甲倍率上（超 100% 部分按 ¼），弱点部位再乘弱点/灵巧加成
- **属性行**实时显示当前生效的加成（撕裂／弱点／暴击）；`暴击 20.0% x1.00` 里的 `x1.00` 是暴击**伤害倍率**（基准 1.00 = 无加成），**只显示不折进倍率**
- 伤害数字按有效性着色（只给无效/削弱的命中上色）

> **边界**：暴击只显示、不折进倍率（概率事件）；弱点/灵巧那一段是**模型**而非官方公式，通过命中日志（预测值 vs 游戏实际伤害与弱点标记）在实机上校准。命中日志自动写入 `mods\WeaponEffectiveness\wepcheck.log`，无需任何命令。

## 当前状态

**最优部位版**。不再解析"准星正对的部位"（该映射在实机上反复失败，已放弃），改为用已验证的 breed 部位数据反向回答"该打哪里"。远程武器不显示攻击行。「当前动作」行已移除。崩溃修复（玩家访问、伤害数字坐标、本地化）全部保留。

## 安装

1. 把本仓库放进游戏目录的 `mods\` 下（文件夹名保持 `WeaponEffectiveness`）
2. 在 `mods\mod_load_order.txt` 里加一行 `WeaponEffectiveness`
3. 依赖 [Darktide Mod Framework (DMF)](https://www.nexusmods.com/warhammer40kdarktide/mods/3)

## 游戏内命令

| 命令 | 作用 |
|---|---|
| `/wepcheckstate` | 输出当前指示器看到的一切（武器、动作、瞄准目标、部位解析、输入、玩家） |
| `/wepcheck` | 把完整诊断导出为 `wepcheck_dump.json` |

部位解析的每次变化会追加到 `wepcheck.log`，排查显示问题时发这个文件最方便。

## 仓库结构

```
├── WeaponEffectiveness.mod        DMF 入口
├── scripts/mods/WeaponEffectiveness/
│   ├── WeaponEffectiveness.lua    主脚本（状态机 + 刷新循环 + 命令）
│   ├── WeaponEffectiveness_data.lua        选项定义
│   ├── WeaponEffectiveness_localization.lua 文本（en / zh-cn / zh-tw）
│   ├── hud/                       准星旁的 HUD 元素
│   ├── markers/                   伤害数字的世界标记
│   └── modules/
│       ├── armor.lua              护甲倍率表、判定阈值、部位枚举与最优部位
│       ├── weapon_profiles.lua    轻/重击链、特殊模式、伤害档解析
│       ├── target.lua             瞄准射线 → 敌人 → 部位 → 护甲
│       ├── hit_verdict.lua        命中钩子（实际造成的伤害）
│       ├── hit_marker.lua         命中数字着色
│       ├── input_state.lua        长按/点按输入读取
│       ├── local_player.lua       安全的玩家访问（防原生崩溃）
│       └── diagnostics.lua        /wepcheck 导出
└── tests/                         离线验证套件（见 tests/README.md）
```

## 开发约定

- 每个修复必须带测试，跑通 `tests/` 全部脚本才提交（详见 [tests/README.md](tests/README.md)）
- 引擎 API 只信**实机验证过的用法**（引用出处写在代码注释里）
- 模组文本一律走 `mod:localize`；只有原版 `loc_*` 键才进游戏 `Localize`

## 许可

MIT
