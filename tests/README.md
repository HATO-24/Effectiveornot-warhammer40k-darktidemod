# WeaponEffectiveness 验证套件

这套脚本在**游戏外**验证 mod 的核心逻辑，跑在真实的游戏数据上（905 个伤害档、59 个 breed、1195 个部位槽）。所有路径相对本目录解析，任何机器 checkout 后都能直接跑。

## 依赖

```powershell
npm install   # fengari (Lua 5.3 虚拟机) + luaparse (Lua 语法解析)
```

Node 与 Python 任选本机版本。

## 运行全部

```powershell
# 语法检查（Lua 5.1 + 5.3 两种语法都要能解析；游戏是 LuaJIT/5.1 风味，测试机是 5.3）
node check-lua-both.js ..        # <repo 根>
node check-globals2.js ..        # 词法作用域感知的未解析全局名检查

# 真实数据全量验证
node run_armor_tests.js          # armor.lua × 905 伤害档
node run_breed_tests.js          # armor.lua × 59 breed / 1195 actor 槽 / 664 部位查表
node dsh_zonevocab.js            # 引擎部位名词汇 vs hitzone_armor_override 键名

# 模块级断言
node run_target_tests.js         # 瞄准→射线→部位→护甲的整条解析链
node run_weapon_tests.js         # 轻/重击链、特殊模式、攻击方式枚举
node run_input_tests.js          # 输入读取双路径（长按/点按）
node run_localplayer_tests.js    # 无玩家时的安全访问（曾导致真实崩溃）
node run_marker_tests.js         # 命中数字的世界坐标（Vector3Box 曾导致真实崩溃）

# UI 不变量（文本键、mod.localize、行结构、选项本地化、% 格式安全）
python dsh_uicheck.py
```

## 数据来源

- `bundles/profiles_bundle.lua`、`bundles/breeds_bundle.lua` 由游戏内 `DshProbe` 导出后离线生成。
- 重新生成：用 `tools/DshProbe`（放到 `mods\` 下启用，进游戏敲 `/dshprobe core`），再用 `tools/lua_dump_parser.py` / `tools/breeds_bundle.py` 把 `out\*.json` 转成 bundle。

## 曾抓到的真实 bug（每个都有对应的断言锁着）

1. 远程伤害档按距离分档（`armor_damage_modifier_ranged.near/far`）
2. `targets` 按顺劈序号分键、各序号倍率不一致
3. 轻击/重击共用 `action_one_hold`、只差 `value`（蓄力判定曾完全失效）
4. `Unit.actor` 收索引不收名字（部位解析曾全部落空）
5. `HitZone.get_name` 会返回 `afro`（无覆盖值的部位名，曾把读数钉死在全身护甲）
6. 玩家未生成时调用 `Managers.player:local_player`（原生空指针崩溃）
7. `Vector3Box` 的 `__index` 是 Vector3 的 C `__index`（索引它直接抛错）
8. 模组文本必须走 `mod:localize`；游戏 `Localize` 只认 `loc_*`
9. DMF 把本地化字符串当 `string.format` 模板（裸 `%` 会加载失败）
