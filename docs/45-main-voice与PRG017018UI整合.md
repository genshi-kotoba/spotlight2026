# main(voice) 与 PRG-017-018 UI 整合

目标为当前 `spotlight2026-main`，来源为同级 `spotlight2026-main(voice)` 与 `spotlight2026-prg-017-018-ui`。两个来源的有效内容一致，因此只提取一次共同增量，并以已经整合怪物意图、第四层、三战位、奖励、附魔和手机版适配的当前 main 为基线处理冲突。

## 合入内容

- 手牌拖出时收拢牌扇并平滑补位，拖回手牌区时重新展开牌扇并为拖动牌保留空位。
- 出牌区卡牌可以拖回手牌；手牌拖到非手牌区、非出牌区的空白位置时等同于点击出牌。
- 出牌区拖拽期间保留 0.75 透明虚影；入场动画不会把虚影误写回不透明。
- 拖拽时抑制悬停放大，松手归位后也不会立即误触发一次悬停。
- 点击手牌改为即时编排；抽牌、弃牌和结算进入弃牌堆仍使用原有移动动画。
- Windows 与 Android 的新版 Wwise `Init`、`SFX` SoundBank 及元数据已同步；按钮和动态奖励控件的音频绑定统一使用去重连接，避免弹窗重建后重复连接信号。
- 删除已经没有运行时引用的旧 `enemy_companion_view`；正式战斗继续使用 `EnemyRack` / `EnemySlot` 三战位系统。

## 主线与手机版保留

- 不覆盖当前 main 的怪物意图、多次行动、第四层、地图预加载、区域名称、奖励、附魔、存档及其他玩法数据。
- 手机端保留点击寻路、二次点击结点交互、长按悬停、触屏拖拽、放大布局、安全区、地图设置按钮和独立存档规则。
- 桌面与 Android 均落入相同的战斗交互逻辑；两端平台专用布局、背包容量与输入适配继续分别维护。
- 旧的“点击手牌飞入出牌区”测试已改为即时编排断言；拖拽测试覆盖拖入、拖回、开扇、收扇、空白松手及悬停抑制。

## 验证

- 双端通过 `battle_hand_input_selftest`、`battle_animation_selftest`、`battle_defaults_selftest`、`ui_optimization_merge_selftest`、`monster_multi_action_selftest`、`new_version_merge_selftest`。
- 双端 `battle_rewards_selftest` 已按当前首抽数与各端背包容量修正旧断言并全部通过；物品菜单按按钮文本验证，不依赖手机版不同的节点位置。
- Android 额外通过 `mobile_adaptation_selftest`。
- Windows/Android SoundBank 已进行文件哈希一致性核对。Wwise 运行时仍会报告来源媒体库自身缺少部分 selected media；该警告不是本次 UI 合并产生的脚本错误。

本次只完成工作区整合，没有提交或推送 GitHub。Android 已做工程内回归，但未进行实体手机安装与触屏真机验收。
