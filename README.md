# Hearth Smoother v0.10.25（实验版）

Steam 创意工坊：[订阅与详情](https://steamcommunity.com/sharedfiles/filedetails/?id=3821022445)

针对 Stonehearth 高人口、物品与仓库较多时的部分模拟尖峰和搬运等待问题，整合一组性能优化与错误防护。

## 包含内容

- 分批派发适用的 AI 通知，减少同一时刻集中处理；优化定时回调分发的重复开销。
- 将仓库初始化、部分搬运扫描和农田日照查询分散处理。
- 优化寻路外围的回调与初次搜索启动时机；保持原生寻路算法、可达性检查和重试规则。
- 等待可达性时，补充角色或目标移动后的事件唤醒。
- 暂时跳过其他角色手持的搬运目标；目标被拿走时重新选择，放下后重新通知派工，保留正在执行搬运者的正常持物流程。
- 修复部分监听与订阅的清理，并减少转职界面重复重建、过期回调与动画干扰。
- 为界面消息回调异常增加隔离和有界日志，帮助后续消息继续处理。

## 适用范围与兼容

已验证环境：Stonehearth release949 x64 + ACE 0.9.6.21b。仍为实验版，其他版本及模组组合尚未验证。关键 Lua 补丁检查源码来源、行号或函数身份；不匹配时跳过并报告，不保证所有模块都能生效。

仅保留一份 Hearth Smoother：从手动安装切换到创意工坊时，请先移走旧的同名目录或 .smod，避免重复加载。其他模组若覆盖相同函数，可能导致相关优化跳过或冲突。本模组覆盖 `radiant/js/radiant/object.js`；与覆盖同一资源的模组可能冲突。

启用或移除后，请完整退出游戏并重新启动。修改模组组合前请备份存档。性能效果随存档、硬件和模组组合变化；不承诺固定 FPS 提升，也不宣称解决所有闲置或长期卡顿。曾报告的“居民与时间正常但整个 UI 无法点击”尚未复现，不能视为已根治。

主动耗时采集默认关闭；只读诊断需主动调用。不会以任务数量增长为理由自动删除任务。

## v0.10.25 更新

在移动事件唤醒基础上，增加手持目标筛选、候选释放与放下后的派工通知，避免工人持续考虑其他角色正在使用的物品；保留累计优化与 UI 修复。

## English

Experimental performance and restocking fixes for Stonehearth. Includes AI notification batching, timer dispatch overhead reductions, sliced stockpile initialization and sunlight work, pathfinding launch/callback improvements, movement-triggered reachability checks, carried-item restocking guards, and UI subscription/lifecycle fixes.

Tested with release949 x64 and ACE 0.9.6.21b. Source-checked Lua patches may skip unsupported code. Install only one copy. Mods overriding the same functions or `radiant/js/radiant/object.js` may conflict. Fully restart the game after changing mods. No fixed FPS gain or complete long-term freeze cure is claimed; the reported whole-UI click lockup has not been reproduced.


