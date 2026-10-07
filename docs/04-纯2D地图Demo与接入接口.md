# 纯 2D 地图 Demo 与接入接口

基线：main `811e415`。入口 `ui/world_map/flat_2d/map_demo.tscn`，在 Godot 4.7.2 中打开项目后 F6 运行此场景，或 F5 运行当前默认入口。旧 3D demo 保留在 `systems/map/map_demo.tscn`，可以单独 F6 运行；本模块不使用它的高度通行判断，也不影响并行的 2.5D 实现。

## 当前功能与边界

- 圆形角色，WASD/方向键，或按住鼠标左键持续朝指针方向移动；斜向等速。键盘输入优先，鼠标指向角色附近的 12 像素内停止。松开左键、移到 HUD、暂停、失焦、进入节点或加载地图时停止鼠标移动；从 HUD 按下不会启动移动。
- 圆形连续碰撞检测并沿墙面滑动，包括斜边和圆角；正面撞墙及凹角会停止。墙体、图外、未完成关口均阻挡整个圆形。碰撞只缓存可通行区的外边界，开放格子之间没有碰撞接缝。
- 逻辑固定物理步更新，角色沿本步碰撞安全路径逐渲染帧插值；相机与缩略图跟随同一渲染位置，逻辑通知/存档使用当前物理位置。加载、恢复和节点请求重置插值历史，避免跳图拖影。Camera2D 始终以角色为中心，无透视、旋转、相机跟随延迟或边缘限位。默认 400% 表示“全地图适配窗口的比例 × 4”，横纵等比；窗口变化后保持该比例。滚轮范围 50%–1600%，按钮恢复 400%。角色和格子共用此比例。
- 右上总地图显示地图轮廓、已知节点、青色角色标记与当前可视范围。未知格统一为雾色，未知节点与墙体类别不提前显示。缩略图无传送功能。
- E/按钮请求最近的可交互节点，并用浅黄色目标圈及底栏文字明确显示当前目标。靠近另一个节点会自动更新，E 触发时再次校验。Tab 在多个附近节点中切换并暂时保留选择；移动超过 0.25 平面单位或目标失效后恢复最近目标。节点只有普通战斗、精英战斗、商店、Boss、随机事件五类；治疗/锻造/炼金使用事件子类型 `event_kind`。
- 未清的普通/精英路线关口阻挡其占地；成功结算只开放对应关口和后方可达区域，界面提示新揭开的格数。普通非关口战斗完成不揭开另一个关口的区域。精英身份不意味着关口。Boss 完成不会自动完成其他节点或强制换层。
- Esc 暂停；离开应用窗口自动暂停；移速 0.25×–4×。节点待回传时移动暂停。取消/失败保留未完成状态。

**当前地图是此前批准的 v8.5 平面生成结果快照**（seed `516e6b84508e2ac3cfe5b9ba0c68fe25`，walk，小轮廓，最多六处一段过渡，214 格/13 节点）。本次移植地图运行与团队接口，没有把网页生成器搬入 Godot。更换 seed 文本不会重新生成地形。以后生成器输出同一协议即可替换快照。默认节点窗口的“模拟完成”只用于接入演示，不是正式战斗/奖励/商店实现。

## 分层与坐标

| 文件 | 责任 |
| --- | --- |
| `systems/map/flat_2d/planar_map_session.gd` | 纯 RefCounted 平面数据、碰撞、迷雾、关口、节点请求/回传、状态恢复 |
| `ui/world_map/flat_2d/map_demo.gd` | 装配输入、圆形角色、相机、HUD、全局信号；不实现战斗或奖励 |
| `ui/world_map/flat_2d/map_view.gd` / `map_minimap.gd` | 静态绘制及总地图；与逻辑共用一份已知/完成状态 |
| `core/signals/map_events.gd` | `MapEvents` Autoload，跨模块接入通道 |
| `data/config/flat_2d/demo_map.json` | 无高度的冻结地图样本 |
| `data/config/flat_2d/demo_settings.json` | 像素格子半径、默认比例和移动速度 |

格子采用原项目 `HexCoord` 的平顶六边形轴向坐标 `Vector2i(q,r)`。连续平面位置使用 `HexCoord.to_plane(coord, 1.0)`，**单位为六边形外接圆半径**。碰撞半径 0.18，默认速度 2.1 单位/秒；渲染再乘 `cell_radius_px=60`。相机缩放不改变物理速度、碰撞或逻辑坐标。输入使用 `map2d_*` 命名空间，不覆盖团队已有输入动作。

协议与保存状态没有 `height`、`level`、`wall_height`、坡度或 3D 位置。导入按白名单提取平面字段，未知装饰字段丢弃；不把“高度设为 0”作为接入条件。

## 地图输入 v1

生成器/局内装配器提供 Dictionary（可来自 JSON）：

```gdscript
var snapshot = {
    "schema_version": 1,
    "map_id": "run-001:floor-1", # 当前地图实例稳定 ID
    "seed": "seed-text",       # 来源元数据，不是生成器调用
    "floor_index": 1,
    "spawn": [0, 0],
    "cells": [
        {"q": 0, "r": 0, "terrain": "ground"},
        {"q": 0, "r": 1, "terrain": "ground"},
        {"q": 1, "r": 0, "terrain": "wall"}
    ],
    "nodes": [{
        "id": "event-1", "type": "event", "coord": [0, 1],
        "footprint": [[0, 1]], "is_route_gate": false,
        "revisitable": false, "unlock_gates": [],
        "event_kind": "heal", "content_id": "heal-pool-1"
    }]
}
MapEvents.map_load_requested.emit(snapshot, {})
```

`cells` 非空，上限 10,000 格；q/r 是整数。坐标和节点 ID 唯一；terrain 仅 `ground`/`wall`。spawn 必须为开放地面。footprint 只含已存在、无重复、未被其他节点占用的地面格，中心必须在 footprint 内。关口只能是 battle/elite；`unlock_gates` 只能引用已有关口，不允许自身引用。它表示“这些关口尚未完成时隐藏此节点”，不会替玩家完成关口。地图生成器仍负责最终连通性、配额与无绕行等生成质量。

需要知道加载成败时调用场景公开 `load_map(snapshot, saved_state={}) -> bool`；信号方式失败不会发 `map_loaded`，界面显示拒绝原因。失败原子保留旧地图。UI `load_map` 清理旧地图的选择/暂停/节点窗口，已有旧请求后续回调会被新状态拒绝。局内调度器应先关闭旧业务场景再换地图。

## 节点模块接入

正式使用时在场景 Inspector 将 `demo_interactions_enabled` 设为 false。连接信号必须在玩家交互前完成；一次请求只交给一个业务路由器，路由器按 type 分发给战斗、商店或事件模块。

```gdscript
func _ready() -> void:
    MapEvents.node_interaction_requested.connect(_on_node_requested)

func _on_node_requested(request: Dictionary) -> void:
    # 保留整个 request（尤其 request_id）；打开对应业务界面。
    # request.type / event_kind / content_id 用于分发和内容选择。
    # 完成后由模块调用 finish_node，不能在地图请求时自动发胜利。
    open_encounter(request)

func finish_node(request: Dictionary, won: bool) -> void:
    MapEvents.node_result_submitted.emit({
        "request_id": request.request_id,
        "status": "completed" if won else "failed"
    })
```

请求字段：`request_id`、`map_id`、`seed`、`floor_index`、`node_id`、`type`、`event_kind`、`content_id`、`is_route_gate`、`visit_index`。`visit_index` 从 0 开始，仅成功 completed 后加一；取消/失败重试仍用同一次访问序号。不可重访节点完成后不再请求；可重访节点再次请求使用下一个 visit_index。

同步信号回调可以切换地图；完成通知与 Boss 通知始终使用原 request 的 map_id，不会被新地图身份覆盖。

结果只接受当前 pending 的 request_id 和 `completed`/`cancelled`/`failed` 三种状态；重复、旧地图、错 ID、非法状态拒绝且不改变节点。`request_id` 是临时回调关联值，**禁止作为种子地址**。模拟窗口与正式业务模块不可同时处理同一请求。

| MapEvents 信号 | 用途 |
| --- | --- |
| `map_load_requested(snapshot, saved_state)` | 局内装配请求加载地图，saved_state 可为 {} |
| `map_loaded(map_id, seed)` | 成功加载通知 |
| `player_cell_entered(map_id, coordinate)` | 初始位置及跨格通知；不是逐像素通知 |
| `node_interaction_requested(request)` | 请求进入业务节点；地图等待回传 |
| `node_interaction_restored(request)` | 恢复待结算业务的回调重新关联通知；不是新的访问 |
| `node_result_submitted(result)` | 业务模块提交结果 |
| `node_interaction_resolved(request_id, node_id, status)` | 地图接受结果后的确认，可关闭业务界面 |
| `map_state_changed(map_id, saved_state)` | 加载、跨格、请求和结果后的状态快照；不是磁盘自动存档 |
| `boss_cleared(map_id, node_id)` | Boss 结算成功；上层决定换层时机，地图继续允许探索 |

纯逻辑可脱离 UI 使用：`load_map`、`get_snapshot`、`get_view`、`move_actor`、`can_stand`、`nearby_nodes`、`request_node`、`resolve_request`、`capture_state`、`restore_state`。返回的 snapshot/view/request/state 是拷贝；内部集合不要直接改。`move_actor(displacement)` 接收本帧**位移**，不是速度或 delta；调用者负责暂停，pending 时逻辑也会拒绝移动。超长单次位移限制为 12 单位，防止无界循环。返回实际逻辑位置；`motion_path: Array[Vector2]` 是最近一次位移的安全折线路径，仅供渲染插值，不是寻路结果，也不进入存档/RNG地址。调用者需要固定物理步更新，同一逻辑步内不要为渲染再次调用 `move_actor`。

## 状态与种子兼容

`map_demo.capture_state()` 返回 v1：map_id、地图内容 SHA-256 fingerprint、连续 actor_plane、known、completed、visits、pending。保存时把它与静态地图 snapshot、局内其他业务状态及 SeedService 的运行快照一起保存；没有本模块单独的全局 RNG。每帧读保存接口得到当前位置，不应把跨格通知当成逐帧存档。恢复时 `load_map(snapshot, state)`；版本/地图不一致、未知 ID、非法位置或不匹配的 pending 会整体拒绝。

待结算节点恢复会生成新的 request_id，并发出 `node_interaction_restored(request)`；**不重新发起业务请求、不增加访问次数**。局内调度器同时恢复对应业务模块，并将已恢复的业务状态重新绑定到此新请求。旧回调被拒绝；不要把恢复通知当作再次抽取内容或重新开战的命令。若无法恢复业务，应使用新 request_id 回传 cancelled，而非默默把节点标记完成。当前没有探索卷轴/任意揭雾接口，恢复的 known 必须与从出生点及已完成关口重建的可达地形和相邻边界完全一致。

最新 main 尚无未合并的 seed PR #1。此模块没有复制、初始化或重置 SeedService；“重开本图”仅重置局部探索/节点状态。以后地图生成器由局内调度器传入其 SeedRegistry 的 `map.layout` / `map.nodes` 等稳定流；业务内容按 seed 手册使用 floor_index、稳定 node_id、visit_index 等地址。UI 绘制、移动、暂停、缩放不抽随机数；不能因为切换地图界面调用 begin_run，也不能用 Godot 实例 ID 当 RNG 地址。

## 本地原生预览打包

普通队友只需打开源码项目运行场景，无需 macOS 专用工具。需要独立 macOS demo 时，用已安装的同版本官方模板：

```sh
python3 tools/map_flat_2d/build_native.py \
  --godot /path/to/Godot \
  --template /path/to/export_templates/4.7.2.stable/macos.zip \
  --output /absolute/path/to/flat-demo-output
```

打包仅白名单平面代码/JSON，原生预览使用 Compatibility 渲染和 1280×800 可调整窗口；源码保留 main 的 Mobile 渲染及原场景配置。工具不下载模板、不签名、不发布、不启动应用。预览包用于本轮验收，最终跨平台构建和正式内容接入由团队工程统一处理。

## 移动实现参考

使用局部圆形扫掠/碰撞法线投影实现俯视移动的墙面滑动；原理参考 Godot 官方 [CharacterBody2D](https://docs.godotengine.org/en/stable/classes/class_characterbody2d.html)。这里保留纯平面 Session，未引入引擎物理世界依赖。逐帧位置插值依据官方 [固定步插值说明](https://docs.godotengine.org/en/stable/tutorials/physics/interpolation/physics_interpolation_introduction.html)，采用独立的安全运动路径，未改动项目全局物理插值设置。
