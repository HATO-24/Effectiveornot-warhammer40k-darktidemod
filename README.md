# Effective or not — Warhammer 40,000: Darktide mod

在准星旁实时显示：**你瞄准的敌人是什么护甲类型**，以及**你手持的武器对这个敌人能否有效造成伤害、该打哪个部位**。

- 普通近战武器：轻击 / 重击分别判定；长按蓄力时自动切换到重击判定
- 带特殊模式的武器（动力剑、圣物剑、链锯类、电弧类、动力锤、粉碎者）：额外预览开启特殊模式后的判定
- 每行显示"这一击打这个敌人**哪个部位最有效**"（判定 + 倍率 + 部位名）
- 伤害数字按有效性着色（只给无效/削弱的命中上色）

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
