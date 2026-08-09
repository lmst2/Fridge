# Factorio Lua 引擎实测笔记(Cold Chain Logistics 重构期间的调研成果)

本文档记录 2026-07 ~ 2026-08 重构期间对 Factorio 2.1 headless 引擎做的全部
实测调研。所有数字都来自真实 headless 基准(LuaProfiler / collectgarbage
采样 / 引擎逐 tick 计时),硬件为共享 Xeon E5-2697v2,绝对值会因机器而异,
**相对关系和结论是可迁移的**。测量方法见文末。

---

## 1. API 分配价目表(最重要、最反直觉的一张表)

用"循环 1000 次、前后读 `collectgarbage("count")`"直接测出。**分配本身
几乎不花时间——账单由 GC 延后开在别的 tick 头上**,所以任何 µs 级计时都
看不见它,这是它最危险的地方。

| 操作 | 每次分配 | 说明 |
|---|---|---|
| 读数字/字符串/布尔属性(`spoil_tick`、`name`、`valid`、`energy`、`spoil_percent`) | **0 字节** | 字符串是内部驻留的,读已有名字不分配 |
| 读**返回对象**的属性(`stack.quality`、`stack.prototype`) | **~60 字节** | 每次读都铸造全新 userdata 包装 |
| 索引库存(`inv[i]`) | **~56 字节** | 同上,每次一个新 LuaItemStack |
| **方法查找**(`inv.is_empty`,仅取值、未调用) | **~88 字节** | 每次查找铸造一个新闭包 |
| 调用已缓存的方法闭包 | **0 字节** | 闭包绑定对象,可长期缓存复用 |
| 写属性(`stack.spoil_tick = v`) | ~0 字节 | 同值写**不会**被引擎短路,写就是写 |

推论:
- 热路径上"顺手读一下 quality"这类代码,审查时和免费的 `spoil_tick`
  长得一模一样,实际每格 60 字节——本项目最大尖峰的根源就是它。
- 方法要么缓存闭包,要么缓存持有者(如 LuaInventory)并接受每次查找 88B。
- 句柄(LuaItemStack / LuaInventory)在底层对象存活期间一直有效,可以
  放在模块表里跨 tick 复用;`unit_number` 永不复用,适合做缓存键。
  **句柄绝不能进 `storage`**(存档序列化不允许函数/userdata)。

## 2. 每操作耗时(µs,本机)

| 操作 | 耗时 | 备注 |
|---|---|---|
| `inv[i]` 创建 | ~0.89/格 | 走位成本的 ~40% + 全部 GC churn |
| 读 spoil_tick(含 valid_for_read) | ~1.57/格 | |
| 融合读+写(现 walk) | ~2.31/格(无句柄缓存)/ **~1.04**(缓存) | |
| 只读(缓存句柄) | ~0.51/格 | |
| 先读一遍再写一遍(拆两 pass) | ~3.65/格 | 比融合贵 60%:第二遍重付 inv[i] |
| `get_item_count()` | ~1.7/箱 | 容器级观测比逐格便宜 45×~3 个量级 |
| `is_empty()` | ~2.2/箱 | |
| `get_contents()` | 4~16/箱 | 返回表,有 GC 抖动;只该给需要构成的场合用 |
| 随机格 vs 连续格访问 | **无差别**(1.87 vs 2.09) | 无局部性惩罚;成本严格 ∝ 触碰格数 |
| 跨容器访问 | +2.3/格 | entity 解引用 + get_inventory;按容器分组 |
| 经过 min-heap 调度机器的一次访问 | ~25 固定开销 | pop/dispatch/记账/重排;cost=1 的轻活别走重机器(本项目探针因此改用平面环+游标) |

Lua 5.2 无 JIT:每格一次函数调用实测占循环成本 39% → 热循环值得内联。

## 3. GC 行为模型(尖峰的完整因果链)

- **轮次频率 ∝ 分配速率**;**单轮暂停 ∝ 常驻活对象集 + 该轮攒下的垃圾量**。
- 分配模式逐 tick 确定 → GC 轮次边界**准确定性**地落在同一批 tick 上
  ("周期性尖峰"的来源;两次同长运行 worst-tick 列表逐位重合)。
- 暂停一部分落在 `scriptUpdate`(mod 上下文内分配触发的步进),引擎自己
  每 tick 也在步进(基准计时的 `luaGarbageIncremental` 独立列)。看玩家
  体感要看 **wholeUpdate** 列。
- **手动 `collectgarbage("step", N)` 每 tick 调用是反效果**:收集器空闲时
  它不停开启新周期,超帧 tick 数实测涨 3~18 倍,均值也变差。引擎自己的
  节奏是对的,别抢方向盘。
- 常驻/流失的权衡实测:保留 9.6 万句柄(19MB 常驻)= 稀疏大暂停;不保留
  = 每走位重造句柄 → 频繁中暂停 + 均值 +50%。**两头都要压**:保留句柄
  (省时间)+ 把稳态分配压到零(省 GC)= 均值与尖峰同时崩掉
  (本项目终态:wholeUpdate max 124.6 → 15.97ms)。

### 尖峰定位方法论(可复用)

1. **时长阶梯**(600/1800/5400):avg 平 + max 随时长涨 = 稀有重尾事件。
2. **同长度双跑**:worst-tick 落点重合 → 确定性(模拟或 GC 周期);
   漂移 → 环境噪声。这是唯一可靠的判别,单独的阶梯区分不了。
3. **三列拆分**:scriptUpdate / luaGarbageIncremental / wholeUpdate 分开
   看 max 与落点配对。
4. **堆斜率**:`collectgarbage("count")` 每 100 tick 采样,锯齿幅度 =
   每轮垃圾量,斜率 = 流失速率。
5. **分阶段归因**:热路径各阶段前后采样 count 差值累加,直接指认分配者。
6. **显微价目**:孤立操作循环 1000 次测每操作字节数(见第 1 节)。

## 4. 腐坏系统的引擎事实

- `spoil_tick` 是**绝对到期 tick**,引擎从不改写它;只有脚本写入或格子
  内容变化(合并栈加权平均/换物)才变。写入小于当前 tick → 立即腐坏;
  写入超过 `now + 完整寿命` → **报错**(留 FRESHNESS_MARGIN 余量)。
- `spoil_percent` 可读写,读取免费。**关键公式**:
  `完整寿命 = 剩余寿命 / (1 − spoil_percent)`,跨全部品质与 mod 实测
  误差 ±0.000 —— 用它可以完全绕开 prototype/quality 读取(各 60B/次)。
- **香草 Space Age 的品质就会缩放保质期**(uncommon 1.3×…legendary 2.5×,
  bioflux 432000 → 1080000)。"品质不改保质期"是错误假设——任何据此做的
  快/慢路径切换,慢路径在所有 SA 局全程运行。
- 香草最短寿命物品:iron-bacteria,3600 tick(1 分钟)。品质乘数最小值
  为 1(没有更短的方向)。
- `LuaInventory` **零**腐坏成员;**没有**实体库存变更事件(只有玩家背包
  系列);infinity-chest 的"生成物品不腐坏"是硬编码、借不上力;
  `spoil_to_trigger_result` 在腐坏瞬间才发事件(尸检,救不了);
  `LuaEntity.frozen` 只读。**逐格改写 spoil_tick 是唯一保鲜机制。**

## 5. 实体与电力的行为细节

- **EEI 类实体出生自带 ~37.5MJ**(输入流限制的一次注入量):
  - 脚本写 `e.energy = electric_buffer_size` 实际只落 ~37.5MJ,~225 tick
    漏光——测试台架必须周期性补满,否则默默测的是断电路径;
  - 新建的电力代理在有电网时 1~2 tick 就越过阈值,无电网也能靠出生电量
    撑 ~200 tick——"新建筑先断电"类假设要先实测。
- 现代机械臂**目的地满时不抓取**(空手 waiting_for_space)——制造"手持
  卡死"需要动态陷阱:等它抓到手再灌满目的地。
- `surface.name` 可写(平台表面也可),触发 `on_surface_renamed`;
  **`game.delete_surface` 不触发任何实体死亡事件**——按 surface.name 键控
  的任何状态都要处理改名(双向清缓存)与无事件消失(靠访问期校验自愈)。
- 蓝图整贴/脚本批量建/`on_configuration_changed` 重扫都会在单 tick 挤入
  大量注册——所有批量到达路径需要统一错峰。

## 6. Headless 测试基建的坑与技法

- `helpers.create_profiler()`(2.0 起从 game.* 迁到 helpers)。
- `--benchmark` 下 `game.auto_save` **不落盘**;要产出中途存档用
  `--start-server`(需完整 server-settings.json + `auto_pause:false`,
  且 write-dir 的 `saves/` 目录必须预先存在)+ `game.server_save`。
- 基准打出的 **checksum 覆盖整个游戏态(含 storage)** —— 是"逐位等价"
  证明的终极工具;但注意:**用与建档不同的 mod 列表加载会触发
  on_configuration_changed(mod 移除也算配置变化)** ——"纯加载基准"很可能
  实际测的是重建路径。
- 探针 mod 不能写其他 mod 的设置(owning mod 限制)、读不了其他 mod 的
  storage;跨 mod 验证只能靠可观察行为(物品寿命轨迹等)。
- 本项目发布校验会把 mod 的任何 `log()` 行当错误 —— 正式代码零日志。
- 台架技法:压舱物钉全局周期(传奇仓库 500 格/个);哨兵栈跳变探测访问
  相位后再"最坏时机"注入;LCG 造确定性随机;新鲜物品 spoil_tick 只能
  往小写(-1 合法,+1 报错);grep 过滤器要与探针前缀严格核对(害过两次);
  bash `set -e` 下循环内的 `[ -f x ] && ...` 短路失败会杀掉整个脚本。

## 7. 由以上事实塑造的本项目架构决策(为什么长这样)

- 走位 = 单遍融合(读写拆开贵 60%),同遍产出刷新+deadline+计费;
- 句柄双缓存(LuaItemStack + LuaInventory),按 entry.key 键控,walk 内
  惰性建(创建量=实际走到的格数,计费自洽),生命周期三处闭合
  (移除/改名双向/重建 init_cache);
- 上限用 spoil_percent 推导,无 prototype/quality 读取,无品质缓存;
- 探针(cost=1)住平面环 + 游标,不进 min-heap(省 ~25µs/次固定税);
- 调度器纯 Lua 零库存 API;正确性只骑无条件心跳,探针只是延迟优化。
