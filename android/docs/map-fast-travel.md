# M 地图与节点传送

## 玩家规则

- 大地图按 `M` 或点击右上角小地图打开地图页。左键点击亮起的节点，立即到达节点旁的安全格；到达后仍按 `E` 手动交互。
- 支持未完成、尚未交互和已完成节点。资格是“节点已显示，且存在当前可通行的已知路线”，不要求事先走到节点旁。
- 战斗、精英、商店、宝箱、残堆、随机事件和 Boss 使用不同文字图标及颜色。未开启随机事件保留问号；开启后显示名称首字，悬停显示完整名称。已完成节点带绿色小标记，路线关口带橙色标记。
- 按住左键拖动平移，滚轮缩放；拖动不会触发传送。按钮可定位主角、恢复全图。地图页打开时外层角色移动及地图缩放暂停。
- 不可穿越未完成关口，不可传送到未揭示节点或未揭示地块。正在处理战斗、奖励或其他节点请求时拒绝传送。无安全落点的节点可查看但不能点击传送。

“前一格”指节点相邻且角色可站立的格子，不是固定屏幕上方。先选节点中心的六个相邻格；对于中心被关闭的多格关口包围的情况，允许落在关口占地外一格。始终在既有交互距离内。候选按当前角色到候选的已知开放路线距离排序，同距离按 q、r 排序。落点不占用节点中心，也不在关闭的关口或碰撞体内。

## 分层接口

### `systems/map/flat_2d/map_fast_travel.gd`

```gdscript
const FastTravel = preload("res://systems/map/flat_2d/map_fast_travel.gd")

# 地图页打开时获取全部可见节点的状态。一次 reachability + 一次 BFS。
var options: Dictionary = FastTravel.options(session)

# 预览无副作用；确认时必须重新校验，不能直接使用 UI 缓存的落点。
var result: Dictionary = FastTravel.preview(session, node_id, map_id, fingerprint)
var result_after_move: Dictionary = FastTravel.travel(session, node_id, map_id, fingerprint)
```

`session` 使用现有地图会话。成功结果有 `ok`、`reason`、`node_id`、`map_id`、`fingerprint`、`coord: [q,r]`、`actor_plane: [x,y]`、`marker_coord: [q,r]`。失败结果不返回落点；只有已公开节点可附带已知的标记位置。`options` 以节点 ID 为键。

`travel` 只设置会话的 `actor_plane`、`motion_path`。不处理存档、镜头、视效或业务，不调用节点请求、揭雾、完成或奖励接口，不读取随机流。空 `map_id/fingerprint` 可供内部演示调用；交互 UI 必须传入打开地图时的两者，拒绝陈旧请求。

拒绝原因：`pending_request`、`node_unavailable`、`no_safe_landing`、`map_changed`、`fingerprint_changed`、`invalid_session`。界面附加 `presentation_pending` 用于本层视效仍在准备时。

### `ui/world_map/map_viewer.gd`

保留 `set_map(view, radius)`、`set_actor(plane)`、`clear_actor()`。新增：

```gdscript
signal fast_travel_requested(node_id: String, map_id: String, fingerprint: String)
func set_travel_options(map_id: String, fingerprint: String, options: Dictionary) -> void
func show_feedback(message: String) -> void
static func reason_text(result: Dictionary) -> String
```

只输入 `session.get_view()` 的公开视图，不传原始完整快照。渲染不访问节点内容 ID。独立 SubViewport 按地图/镜头变化更新，标记层可见时 20 Hz 重绘；没有每帧路径搜索。没有提供传送选项和信号接线的战斗地图仍仅供查看。

### 地图宿主与正式存档

`MapDemo._on_map_fast_travel` 先预检并关闭菜单，播放短过渡；在起步段结束时通过 `_commit_fast_travel` 重新校验落点、保存、同步角色和高度、更新跟随镜头、发布一次 `MapEvents.player_cell_entered(map_id, coord)` 和 `map_state_changed`。同步回调导致切图时停止处理旧会话。保留原有事件总线，不增加强制新信号。

宿主可覆写三个钩子：

- `_fast_travel_ready() -> bool`：本层是否具备显示条件。2.5D 入口使用现有 `is_map_ready()`。
- `_persist_fast_travel(previous_state) -> Error`：正式入口使用 `SaveGateway.save_current()`；失败时恢复地图运行缓存和会话位置/运动路径，不发布到达通知，过渡收尾后重新打开地图显示错误。
- `_after_fast_travel()`：2.5D 清空跨地图位移的动画历史，通过现有高度采样放置角色。不会重建地形、光照或迷雾。

保存成功后才发布可见位置。落点进入既有地图检查点；无需增加存档字段或修改种子接口。传送不增加访问次数，不重置领取状态，也不消耗种子序列。旧存档沿用原加载过程。

## 短过渡表现

`ui/world_map/flat_2d/map_fast_travel_effect.gd` 只负责 CanvasLayer 表现：起步 0.12 秒、落地 0.20 秒，总计约 0.32 秒，另加同步保存的实际耗时。人物当前帧的透明轮廓生成暖金残影，搭配方向动线、短暗转和落地扩散环。直接复用已载入纹理，不抓取屏幕、不生成新的光照或迷雾资源，不调用随机数。

- 起步期间人物位置保持原处，在暗转最深时执行正式移动和保存；落地段从新的角色投影位置展开。
- 过渡期间归零遗留移动速度、跳过移动物理帧，拦截重复传送、菜单、交互及缩放输入。结束后恢复传送前的暂停/焦点规则。
- 保存失败时留在原位置，收尾后重新打开 M 地图显示错误。中途换图通过 `load_map` 取消旧过渡，释放场景时绑定 Tween 和输入遮罩随宿主一起释放。
- `_fast_travel_portrait() -> Dictionary` 是宿主的纯显示钩子，返回屏幕坐标的 `feet`、`body`，可选 `texture` 和 `rect`。2.5D 使用当前动画帧及实际高度投影；平面圆形角色使用动线与扩散环，无额外人物素材依赖。
- 这是点击请求后的异步表现；业务完成仍以原来的到达事件和状态事件为准，不能把 `_on_map_fast_travel` 返回当作已到达。

## 参考与边界

参考《超时空方舟》展开地图、点击地图元素传送的交互。公开玩家指南记录了展开小地图上的闪光位置传送：[Steam 玩家指南](https://steamcommunity.com/sharedfiles/filedetails/?id=2338979264)。本项目采用上面的“已知且可达、落在节点前”规则；未声称逐条复刻参考游戏的全部规则。

原生验收脚本和截图在工作区 `output/map-fast-travel-20261020/verification/`，不属于产品提交。此功能未修改地图生成、墙体、高度、迷雾材质、角色照明或音频实现。
