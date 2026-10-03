# Card-and-Dice 参考工程

本目录是团队成员在 Unity 上做的卡牌构筑 Roguelike 工程《代号：卡牌与骰子》的一份**可运行的裁剪版**。

放在这里的原因：两个项目玩法骨架相近（卡牌构筑、局内局外两层状态、六边形地图），很多算法与数据模型可以改着用，不必从零写一遍。

## 怎么跑起来

1. 用 Unity Hub 打开本目录，编辑器版本 **2022.3.62f1c1**（工程里 `ProjectSettings/ProjectVersion.txt` 写的就是这个）
2. 首次打开会导入资源并编译脚本，需要几分钟
3. 构建场景列表里有两个场景，按顺序为 `HideoutScene`（藏身处）和 `TutorialScene`（新手教程）
4. 打开 `Assets/Scenes/TutorialScene.unity`，直接播放

## 目录内容

```
Assets/Scripts/          222 个 C# 脚本，49726 行
Assets/Scenes/           三个场景（教程、藏身处、卡牌编辑器）
Assets/Data/             教程用到的卡牌、敌人、小队、事件数据
Assets/Prefabs/          预制体
Assets/Resources/        运行时加载的配置资产
docs/可复用代码清单.md     按本项目的 PRG 编号组织的复用清单
docs/移植注意事项.md       Unity/C# 到 Godot/GDScript 的对应关系与耦合清理项
```

`reference/.gdignore` 让 Godot 跳过整个参考目录，这些 Unity 资源不会被我们的引擎扫描。

## 裁剪掉了什么

为了控制体积和避免泄露设计，本目录**只保留了新手教程这条线**：

| 保留 | 移除 |
| --- | --- |
| 敌人 3 个（史莱姆、哥布林、木桩） | 荒野敌人 43 个 |
| 卡牌 9 张 | 荒野卡牌 153 张 |
| 小队 3 组 | 荒野小队 27 组 |
| 事件 6 个 | 生态专属事件 28 个 |
| `TutorialScene` / `HideoutScene` / `CardEditor` | `MainScene`（16.5 MB）、`FogTownScene` |

策划案、剧情大纲、数值表、美术源文件都没有放进来。

保留的资产之间**没有断裂引用**，已逐条核对过 GUID。

## 字体说明

`Assets/TextMesh Pro/Fonts/msyh.ttc` 是微软雅黑。带上它是为了让中文正常显示，但**在公开仓库分发这个字体存在版权风险**。如果在意，可以自行替换成开源中文字体（思源黑体、Noto Sans SC 等），替换后需要在 Unity 里重新烘焙 TMP 的 SDF 字体资产。

## 可复用点

骨架相近，所以下面这些可以直接改着用：

- **六边形坐标数学**：`Assets/Scripts/EnemySystem/HexCoord.cs` 用立方坐标做内部运算、偏移坐标做存储，是最值得先看的文件
- **效果与 buff 系统**：`EffectSystem/` 四个文件，抽象基类加十一个具体效果，含层数与回合钩子
- **动作与反应框架**：`ActionSystem/`，把一切游戏行为抽象成 `GameAction` 交给统一执行器
- **卡牌数据模型**：`CardSystem/`，静态数据 `CardData` 与运行时实例 `Card` 分离
- **局外存档**：`Meta/MetaWallet.cs` 与 `SaveSlots.cs`
- **视野与连通判定**：`ExplorationSystem/VisionSystem.cs`、`Map/EncounterZone.cs`
- **格子占位管理**：`Game/UnitOccupancy.cs`

完整清单见 [docs/可复用代码清单.md](docs/可复用代码清单.md)。

## 怎么用

1. 先读 [docs/可复用代码清单.md](docs/可复用代码清单.md)，按我们自己的 PRG 编号找到对应条目
2. 再读 [docs/移植注意事项.md](docs/移植注意事项.md)，里面列了必须改掉的耦合写法
3. 然后才去看具体代码

**不要直接复制粘贴。** 源码是 Unity + C#，我们是 Godot + GDScript，算法可以翻译，写法和引擎 API 都要换。注意事项那份文档里逐条写了要改什么。

## 技术栈对照

| | 本参考 | 本项目 |
| --- | --- | --- |
| 引擎 | Unity 2022.3 | Godot 4.7 |
| 语言 | C# | GDScript |
| 数据资源 | `ScriptableObject` | `Resource`（`.tres`） |
| 补间 | DOTween | `Tween` |
| UI | UGUI + TextMeshPro | `Control` + 主题 |

## 来源

原工程仓库：`Ch3N-9/Card-and-Dice`（私有，完整版）。
