// =============================================================================
// 模块：探索系统 - ExpeditionMapRouter 出征路由（选场景 + 烘地图）
// 用途：把「本局去哪张图」收口在这一个地方，分两步：
//
//   ① 【选场景】ResolveSceneName() —— 所有「出击」入口都问这里，调用点不自己写场景名
//        · 教学未完成 → TutorialScene（教程图；40×13，编辑期已烘焙进场景）
//        · 教学已完成 → FogTownScene （雾镇  ；80×50，进图时从 raid_town.txt 现烘）
//
//   ② 【烘地图】Route() —— 进入突袭场景后，把该场景该有的地图烘出来 + 把玩家摆到出生点
//        · TutorialScene：什么都不做（教程图就在场景里，零风险）
//        · FogTownScene ：从 raid_town.txt 现烘 80×50 + 摆出生点
//
// ★2026-09-15 场景拆分（用户拍板：雾镇独立成场景）：
//   此前教程图与雾镇图【共用 RaidScene】，靠 MapLayoutBuilder.tutorialMap 开关区分身份，
//   于是「选图」只能表现为「进场时销毁教程图、再重烘雾镇图」——两张图互相牵制，
//   而且编辑器里打开场景永远只看到教程图。拆开后一场景 = 一张图，身份由场景本身决定。
//
// 时序（关键，别改）：
//   Route() 挂在 SceneManager.sceneLoaded 上，在「场景 Awake 之后、Start 之前」执行，因此
//     ① 早于 HexMover.Start —— 它向下射线取当前格，玩家必须已经站到出生点上；
//     ② 早于 ExpeditionEncounterBootstrap.Start —— 它拿 layoutFile.name 当 mapId
//        过滤固定巡逻(SquadPatrols)与随机遭遇表(EncounterTables)；
//     ③ 早于 TerrainManager.Start —— BuildFromLayout 已把 terrainGrid 填满，
//        于是它跳过「默认全图平原」那一遍。
//
// 边界与未做：
//   · 只认 TutorialScene / FogTownScene；其它场景（藏身处 / 旧测试场）一律不介入。
//   · FogTownScene 的地图【刻意不烘进场景】：改地图 = 改 txt，场景文件保持 ~300KB。
//     代价是进图要现烘一次（实测 80×50 约 330ms；合并网格重构前是 750ms）。
//   · ★2026-09-15 随机荒野已接线（怪物未做，先打通图）：出击 → 复用 FogTownScene，
//     Route() 调 WastelandGenerator 现生成布局，装进运行期 TextAsset（name="wasteland"）。
//     mapId 机制零改动；剧情雾镇图由 useRandomWasteland 开关保留。
//   · 开机路由（2026-09-16 拍板）：「打开游戏」= 藏身处 —— 构建靠 Build Settings
//     level0（HideoutScene），编辑器 Play 靠 PlayStartScene 钉住；「出击」才走
//     ResolveSceneName() 按教学进度选图。老的「启动直接进教程图」口径作废。
// =============================================================================
using UnityEngine;
using UnityEngine.SceneManagement;

[DefaultExecutionOrder(-1000)]
public class ExpeditionMapRouter : MonoBehaviour
{
    /// <summary>剧情突袭图（雾镇）的 Resources 路径 —— 对应 `Assets/Resources/Maps/raid_town.txt`。</summary>
    public const string RAID_MAP_PATH = "Maps/raid_town";
    /// <summary>剧情突袭图的 TextAsset 名（= 文件名，用于幂等判断与 mapId 过滤）。</summary>
    public const string RAID_MAP_NAME = "raid_town";

    /// <summary>
    /// ★2026-09-15 随机荒野接线：出击 → 程序化生成的随机图（WastelandGenerator）。
    /// mapId 合成为 "wasteland" —— SquadPatrols / EncounterTables 的过滤机制照常工作：
    /// ★2026-09-16 起查表带群系（三级：(图,群系)→(图,通用)→(通用,通用)），
    ///   7 张群系表未建档（D1=B，等 T16）→ 当前落通用兜底 `遭遇表_默认`（哥布林/史莱姆占位）。
    /// </summary>
    public const string WASTELAND_MAP_ID = "wasteland";
    /// <summary>
    /// 出击去哪张图的开关（真·随机荒野 / 剧情雾镇）。运行时可切，方便对照验收：
    ///   true  = 出击进随机荒野（默认，2026-09-15 用户拍板：怪物未做，先打通随机图）
    ///   false = 出击进剧情雾镇图（raid_town.txt，原行为）
    /// </summary>
    public static bool useRandomWasteland = true;

    // ------------------------------------------------------------------
    // ① 选场景
    // ------------------------------------------------------------------

    /// <summary>
    /// 本局该进哪个场景。所有「出击」入口（藏身处出击按钮 / 开发者面板）都问这里。
    /// ★选图规则只保留这一份 —— 散落到调用点就会再次出现「点出击进的还是教程图」。
    /// </summary>
    public static string ResolveSceneName()
    {
        if (TutorialProgress.IsTutorialPending) return MetaWallet.TUTORIAL_SCENE;
        // ★2026-09-15 随机荒野接线：随机图复用 FogTownScene 承载（场景 = "突袭图"容器），
        //   进图后由 Route() 现生成布局（见下）。剧情雾镇图由 useRandomWasteland 开关保留。
        return MetaWallet.FOGTOWN_SCENE;
    }

    // ------------------------------------------------------------------
    // ② 烘地图
    // ------------------------------------------------------------------

    // -------- 自动挂载（同 TutorialDirector 范式：不往场景里挂任何东西） --------
    [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
    private static void AutoStart()
    {
        SceneManager.sceneLoaded -= OnSceneLoaded;   // 幂等：域重载后避免重复订阅
        SceneManager.sceneLoaded += OnSceneLoaded;
        Route();                                     // 覆盖「直接从突袭场景启动 Play」
    }

    private static void OnSceneLoaded(Scene scene, LoadSceneMode mode) => Route();

    private static void Route()
    {
        Scene active = SceneManager.GetActiveScene();

        // 教程场景：地图是编辑期烘焙进场景的那份 —— 一个字节都不用动。
        if (active.name == MetaWallet.TUTORIAL_SCENE) return;

        // 非突袭场景（藏身处 / 旧测试场）：不介入。
        if (active.name != MetaWallet.FOGTOWN_SCENE) return;

        MapLayoutBuilder builder = Object.FindObjectOfType<MapLayoutBuilder>();
        if (builder == null)
        {
            Debug.LogWarning("[地图路由] 雾镇场景里找不到 MapLayoutBuilder，跳过烘图。");
            return;
        }

        // 幂等：AutoStart 与 sceneLoaded 对「第一个场景」可能各触发一次。
        //   判据是「本场景实例里是否已经烘出格子」—— 不能用 layoutFile 判断：
        //   雾镇场景的 layoutFile 现在是序列化好的 raid_town，开局就成立，拿它当判据会永远跳过烘焙。
        if (builder.mapGrid != null && builder.mapGrid.HasHexTiles()) return;

        // ---- ★2026-09-15 随机荒野：出击 → WastelandGenerator 现生成一张图 ----
        // 产出与手写 txt 完全同构的 ASCII 行（下游 MapLayoutBuilder 零改动），
        // 装进运行期 TextAsset 并命名 "wasteland" → mapId 机制照常（巡逻/遭遇表按它过滤）。
        if (useRandomWasteland)
        {
            int seed = UnityEngine.Random.Range(1, int.MaxValue);
            WastelandGenerator.WastelandLayout gen =
                WastelandGenerator.Generate(seed, new WastelandGenerator.Settings());

            TextAsset generated = new TextAsset(gen.ToText());
            generated.name = WASTELAND_MAP_ID;
            builder.layoutFile = generated;

            builder.tutorialMap = false;
            builder.BuildFromLayout();      // 重建 Map / Map1（尺寸、地形、节点全部按文本重刷）

            // ★2026-09-16 本局上下文交接：群系图 / 巡逻锚点交棒给 ExpeditionEncounterBootstrap
            //   （遭遇区按群系取表 + 野外巡逻一路都读它）。必须在 Bootstrap.Start 之前 ——
            //   Route 在 sceneLoaded 时机执行，早于 Start，满足。
            WastelandRunContext.Set(gen);

            // ★荒野事件投放（design §3.1）：生成完地图、玩家入场前，把 22 个事件格铺上事件
            WildernessEventPlacer.PlaceAll(builder, gen, gen.seed);

            // ★荒野宝箱投放（2026-09-16）：把 'C'/'c' 格填上本群系的箱材
            //   （族材三件套的第三件 —— 前两件由怪掉，这件只出在箱子里）
            WildernessChestPlacer.PlaceAll(builder, gen, gen.seed);

            Vector2Int spawnW = PlacePlayerAtSpawn(builder);
            string biomes = string.Join("/",
                System.Array.ConvertAll(gen.drawnBiomes, b => WastelandGenerator.Def(b).displayName));
            Debug.Log($"[地图路由] 随机荒野 seed={seed}（mapId={WASTELAND_MAP_ID}）：" +
                      $"{builder.gridSize.x}×{builder.gridSize.y} 格，主群系={WastelandGenerator.Def(gen.mainBiome).displayName}，" +
                      $"抽中=[{biomes}]，Boss 位={(gen.hasBoss ? $"有({gen.bossPos.x},{gen.bossPos.y})" : "未落成")}，" +
                      $"出生点 Hex_{spawnW.x}_{spawnW.y}");
            return;
        }

        // 布局来源：场景里配好的那份；万一被清空则回落到 Resources 里的雾镇图。
        // ★2026-09-16 手写图无群系上下文 → 清掉上一局的荒野残留（消费方据此退回旧行为）。
        WastelandRunContext.Clear();
        if (builder.layoutFile == null)
        {
            TextAsset raid = Resources.Load<TextAsset>(RAID_MAP_PATH);
            if (raid == null)
            {
                Debug.LogError($"[地图路由] 雾镇场景没配 layoutFile，且找不到 Resources/{RAID_MAP_PATH}.txt —— 地图会是空的。");
                return;
            }
            builder.layoutFile = raid;
        }

        builder.tutorialMap = false;
        builder.BuildFromLayout();      // 重建 Map / Map1（尺寸、地形、节点全部按文本重刷）

        Vector2Int spawn = PlacePlayerAtSpawn(builder);
        Debug.Log($"[地图路由] 雾镇「{builder.layoutFile.name}」：{builder.gridSize.x}×{builder.gridSize.y} 格，" +
                  $"出生点/撤离点 Hex_{spawn.x}_{spawn.y}");
    }

    /// <summary>
    /// 把玩家摆到出生点格（= 家 = 撤离点）。必须早于 HexMover.Start 的向下射线取格。
    /// 只改 X/Z、保留原 Y —— 两张图的格子都在同一水平面上，Y 偏移不需要动，
    /// 这样掉落/相机跟随等任何依赖玩家高度差的东西都不受影响。
    /// </summary>
    private static Vector2Int PlacePlayerAtSpawn(MapLayoutBuilder builder)
    {
        if (!builder.hasSpawn)
        {
            Debug.LogError("[地图路由] 雾镇图里没有出生点（缺 'S' 字符），玩家位置保持不变。");
            return builder.spawnCoord;
        }

        HexMover mover = Object.FindObjectOfType<HexMover>();
        if (mover == null)
        {
            Debug.LogWarning("[地图路由] 场景里找不到 HexMover（玩家），无法摆位。");
            return builder.spawnCoord;
        }
        if (builder.mapGrid == null)
        {
            Debug.LogWarning("[地图路由] MapLayoutBuilder.mapGrid 未指定，无法解析出生点世界坐标。");
            return builder.spawnCoord;
        }

        Vector2Int c = builder.spawnCoord;
        Transform tile = builder.mapGrid.transform.Find($"Hex_{c.x}_{c.y}");
        if (tile == null)
        {
            Debug.LogWarning($"[地图路由] 找不到 Map/Hex_{c.x}_{c.y}（出生点格），玩家位置保持不变。");
            return c;
        }

        Vector3 p = mover.transform.position;
        mover.transform.position = new Vector3(tile.position.x, p.y, tile.position.z);
        return c;
    }
}
