// =============================================================================
// 模块：M6-6 敌人系统 - SquadSpawnTester 小队生成测试工具
// 用途：局内按键生成/切换/清除敌人小队（Demo 阶段检阅测试用，非游戏功能）。
// 挂载：MainScene 的 SetUp/GameManager（与 TempCardTest / EnemyMovePreview 同级）。
// 按键：
//   G = 在「鼠标悬停格」生成当前选中小队（锚点=悬停格，被占由 SpawnResolver 螺旋避让）
//   N = 切换到下一个小队（循环），Console 打印当前小队名与成员数
//   K = 清除本工具生成的全部小队成员（只清测试生成，场景原有敌人不动）
// 小队列表：Inspector 可拖拽 EnemySquadData 固定顺序；为空时编辑器下 Start 自动
//   扫描 Assets/Data/Squads 下全部小队资产（按资产路径排序，打包需手动配置）。
// 职责边界：
//   - 只做「测试生成入口」，落地解算全部交给 SpawnResolver（锚点+编队+螺旋避让）；
//   - 与 TempCardTest 同属临时测试工具，Demo 收尾阶段随 TempCardTest 一并移除。
// =============================================================================
using System.Collections.Generic;
using UnityEngine;

public class SquadSpawnTester : MonoBehaviour
{
    [Header("测试小队列表（为空时编辑器自动扫描 Assets/Data/Squads）")]
    [Tooltip("G 键循环生成的小队列表；Inspector 手动拖拽可固定顺序")]
    [SerializeField] private List<EnemySquadData> squads = new List<EnemySquadData>();

    // ======== 运行时状态 ========
    private int _currentIndex = 0;                                   // 当前选中小队下标
    private readonly List<GameObject> _spawned = new List<GameObject>(); // 本工具生成的成员（K 键清除用）
    private Transform _spawnRoot;                                    // 生成容器（层级窗口整洁）
    private HexMover _hexMover;

    private void Start()
    {
        _hexMover = FindObjectOfType<HexMover>();
#if UNITY_EDITOR
        // 列表为空 → 自动扫描小队资产（仅编辑器；Play 模式改动不落盘，每次进 Play 重新扫）
        if (squads.Count == 0)
        {
            ScanSquadAssets();
        }
#endif
        LogCurrentSquad("初始化");
    }

    private void Update()
    {
        if (Input.GetKeyDown(KeyCode.N)) CycleSquad();
        if (Input.GetKeyDown(KeyCode.G)) SpawnCurrentAtMouse();
        if (Input.GetKeyDown(KeyCode.K)) ClearSpawned();
    }

    // ------------------------------------------------------------------
    // N 键：切换小队
    // ------------------------------------------------------------------
    private void CycleSquad()
    {
        if (squads.Count == 0)
        {
            Debug.LogWarning("[SquadTest] 小队列表为空，无法切换");
            return;
        }
        _currentIndex = (_currentIndex + 1) % squads.Count;
        LogCurrentSquad("切换");
    }

    // ------------------------------------------------------------------
    // G 键：在鼠标悬停格生成当前小队
    // ------------------------------------------------------------------
    private void SpawnCurrentAtMouse()
    {
        if (squads.Count == 0)
        {
            Debug.LogWarning("[SquadTest] 小队列表为空，无法生成");
            return;
        }
        if (_hexMover == null) _hexMover = FindObjectOfType<HexMover>();
        if (_hexMover == null)
        {
            Debug.LogWarning("[SquadTest] 场景无 HexMover，无法取鼠标悬停格");
            return;
        }

        // 玩家移动中悬停格是移动前的旧值，不响应防误生成
        if (_hexMover.IsMoving())
        {
            Debug.LogWarning("[SquadTest] 玩家移动中，稍后再按 G");
            return;
        }

        // 锚点 = 鼠标悬停格（HexMover 射线维护；-999 = 鼠标在 UI 上或地图外）
        Vector2Int anchor = _hexMover.CurrentHoverCoord;
        if (anchor.x < 0 || anchor.y < 0)
        {
            Debug.LogWarning("[SquadTest] 鼠标未悬停在任何格子（或悬停在 UI 上），无法确定生成锚点");
            return;
        }

        List<EnemyController> spawned = SpawnResolver.Spawn(squads[_currentIndex], anchor, GetSpawnRoot());
        foreach (EnemyController ctrl in spawned)
        {
            if (ctrl != null) _spawned.Add(ctrl.gameObject);
        }
        Debug.Log($"[SquadTest] 本次生成 {spawned.Count} 名成员，累计 {_spawned.Count} 名（K 键全部清除）");
    }

    // ------------------------------------------------------------------
    // K 键：清除本工具生成的全部成员
    // ------------------------------------------------------------------
    private void ClearSpawned()
    {
        int cleared = 0;
        foreach (GameObject go in _spawned)
        {
            if (go != null)
            {
                Destroy(go); // 含已死亡（SetActive 隐藏）的对象一并销毁
                cleared++;
            }
        }
        _spawned.Clear();
        Debug.Log($"[SquadTest] 已清除测试生成的成员 {cleared} 名（场景原有敌人不受影响）");
    }

    // ------------------------------------------------------------------
    // 内部工具
    // ------------------------------------------------------------------

    /// <summary>取生成容器（懒创建，层级窗口集中管理测试单位）。</summary>
    private Transform GetSpawnRoot()
    {
        if (_spawnRoot == null)
        {
            GameObject go = new GameObject("测试小队生成区");
            _spawnRoot = go.transform;
        }
        return _spawnRoot;
    }

    /// <summary>Console 打印当前选中小队信息。</summary>
    private void LogCurrentSquad(string action)
    {
        if (squads.Count == 0)
        {
            Debug.Log("[SquadTest] 小队列表为空（编辑器下检查 Assets/Data/Squads 是否有小队资产）");
            return;
        }
        EnemySquadData s = squads[_currentIndex];
        Debug.Log($"[SquadTest] {action}：当前小队「{s.squadName}」（{_currentIndex + 1}/{squads.Count}，"
                  + $"编队 {s.formation}，成员 {s.units.Count} 名）→ 按 G 在鼠标悬停格生成");
    }

#if UNITY_EDITOR
    /// <summary>扫描 Assets/Data/Squads 下全部小队资产填入列表（编辑器专用，含右键菜单手动触发）。</summary>
    [ContextMenu("扫描小队资产")]
    private void ScanSquadAssets()
    {
        squads.Clear();
        foreach (string guid in UnityEditor.AssetDatabase.FindAssets("t:EnemySquadData", new[] { "Assets/Data/Squads" }))
        {
            string path = UnityEditor.AssetDatabase.GUIDToAssetPath(guid);
            EnemySquadData squad = UnityEditor.AssetDatabase.LoadAssetAtPath<EnemySquadData>(path);
            if (squad != null) squads.Add(squad);
        }
        Debug.Log($"[SquadTest] 自动扫描到 {squads.Count} 个小队资产（Assets/Data/Squads）");
    }
#endif
}