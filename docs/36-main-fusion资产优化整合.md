# main(fusion) 资产优化整合

日期：2026-10-20。来源 `D:/聚光灯/spotlight2026-main(fusion)`，目标 `D:/聚光灯/spotlight2026-main`。来源无 Git 历史，本次采用逐文件差异检查、定向合并，不以整目录覆盖 main；未提交或上传 GitHub。

## 已合入

- 分层地图主题：第一层保持 ENV-005；第二层 ENV-006；第三层 ENV-007 白色。紫色、大理石主题及第四层外观仅登记，不开放第四层玩法。
- 地图材质目录、石块轮廓、网格批次、异步几何和动态角色阴影使用所属楼层图集。缓存身份包含主题、图集和目录签名；共享图集使用弱引用，活跃批次持有资源。
- 第二层战斗默认蓝调差分，第三层默认 `ENV_003_01.PNG`，保留原版和其他差分供配置选择。
- EVBG-003、005、007 替换占位，EVBG-013 用于商店并加入节点预加载。
- 十二种事件地图节点图、未知事件问号、精英节点图。未开启事件继续隐藏身份。
- UI-006 金色返回／关闭按钮，接入图鉴、详情、战斗牌堆和背包；背包关闭按钮继续遵守开包选择锁与悬置规则。

主要配置入口：`data/config/relief_2d/art_themes.json`、`data/config/battle_backgrounds.json`。素材说明见文档 32《新增场景与地图资产接入》，战场差分见文档 21。

## 以 main 为准的部分

来源中部分系统早于 main，未合入会回退功能的旧实现：三存档、旧附魔／奖励、旧加载提示、旧图鉴属性、旧卡面与事件布局。

保留单存档与启动校验修复、正式附魔和附魔书、奖励弹簧动画与悬置、退役残片过滤、图鉴隐藏属性、抽牌和离手动画、中央加载遮罩、事件全屏无框背景及右侧按钮、最新卡牌文字边界适配。规则引擎、事件队列、战斗状态机、玩法随机流与存档格式均不因本次美术合并改变。

## 验证

Godot 4.7.2 资源导入通过。以下场景完成回归：

- `fusion_assets_selftest`：全部主题目录／UV尺寸、共享图集、缓存身份、事件保密、实际第二／三层网格、随机流不变；另以实际 D3D12 渲染截图检查。
- `battle_environment_selftest`：四层默认背景、差分预览、越界回退、独立战斗显示；无窗口和实际图形模式均通过。
- `world_encounters_selftest`：真实地图节点进入战斗、读档继续、胜利领奖返回、三层 Boss 推进、第四层仍不开放、败北回菜单。
- `fusion_optimization_selftest`、`scene_preload_selftest`：地图一次绑定、冷恢复、预加载隔离与热加载。
- `shop_enchantments_selftest`：新商店背景、购买／附魔事务、保存失败回滚、同店冷恢复；实际图形模式也通过。
- `reward_choice_animation_selftest`、`enchantment_book_selftest`：奖励展开、悬置与只读查看、新关闭按钮选择锁、正式附魔二级选牌。
- `random_event_flow_selftest`、`text_catalog_selftest`、`card_text_bounds_selftest`、`battle_animation_selftest`：main 原功能回归。
- `save_crash_recovery_selftest`：本轮玩家存档的隔离副本继续、新建、保存、重读；实际图形模式均通过，正式存档不写入。

旧地图战斗测试在抽牌动画完成前立即出牌／清怪会触发输入锁或开局结果确认，因此补充等待真实开局与表现完成；未为测试改动战斗业务规则。无窗口地图测试的 Godot dummy 渲染器会输出 `texture_2d_initialize: Parameter t is null`，实际图形模式的资产、商店、背景和存档测试未出现该错误。

截图与日志位于 `.godot/fusion20261020-*`，商店截图位于本轮 `.godot/shop-enchant-*` 测试目录。

## 备份

本轮修改前的源码、替换素材及玩家存档副本：`.godot/fusion-merge-backup-20261020-004407/`。来源工程保持不变；原有 main 未提交改动保留。正式 `game.json` 和 `game.json.bak` 在合并前后 SHA-256 均为 `D0890F16DD9D3BBD2C101380EF17D25FF6C2B1F377546F3E9981BA6FE1B96C5A`。

该目录位于本机 Godot 缓存目录，不是 Git 中的永久备份；需要长期留存时应单独归档。
