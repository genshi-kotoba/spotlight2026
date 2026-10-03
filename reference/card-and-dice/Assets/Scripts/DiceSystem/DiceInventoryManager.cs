// =============================================================================
// 模块：DiceInventoryManager 战斗骰子库存管理器
// 用途：战斗骰子"子弹"定位的资源出入口（公式 F2.2：消耗型资源）。
// 设计依据：《总策划案》4.4 战斗骰子获取与管理 + 《公式文档》F2.2/F4.5
//          spec §6（装填 = 纯配置，抽到卡时扣骰）、§13（战斗骰子链路接背包）
//
// ★M7 背包系统已实装（2026-09-08）：三个方法改为查询/扣减背包骰子分区，
//   调用方（DicePayment）零改动——即本文件头 2026-08-17 预留的完工路径。
// ★临时劣质骰（tempInferiorDice）：战斗骰子耗尽时的保底骰，无限量、不占背包、
//   不可搜刮/带回/成长（策划案 §126/§138/§176）。消耗与返还一律跳过它。
// ★F4.5 智力免耗仍未实装（与实装前一致）；未来落点是 DicePayment.PayOnDraw。
// =============================================================================
using UnityEngine;

/// <summary>
/// 战斗骰子库存管理器单例。
/// 挂载位置：MainScene 的 SetUp/GameManager（与 CardExecutor/TurnManager 共存）。
/// </summary>
public class DiceInventoryManager : MonoBehaviour
{
    // ======== 单例 ========
    public static DiceInventoryManager Instance { get; private set; }

    /// <summary>调试开关：true = 无限库存、不扣数量（保留封存，接背包后正常为 false）</summary>
    [Header("调试")]
    [Tooltip("Demo 无限库存：true = 消耗不扣数量。已由构建器 Tools/背包/3 置为 false")]
    [SerializeField] private bool _unlimitedForDemo = true;

    [Header("保底骰")]
    [Tooltip("临时劣质骰（Assets/Data/Dice/临时劣质骰.asset）：战斗骰子不足时无限量顶替，不入背包、不返还")]
    [SerializeField] private DiceData tempInferiorDice;

    /// <summary>临时劣质骰模板（DicePayment 兜底时取用）。可能为 null（未连线）。</summary>
    public DiceData TempInferiorDice => tempInferiorDice;

    private void Awake()
    {
        if (Instance != null && Instance != this)
        {
            Destroy(gameObject);
            return;
        }
        Instance = this;
    }

    private void OnDestroy()
    {
        if (Instance == this) Instance = null;
    }

    /// <summary>该骰子当前可用数量。临时劣质骰恒为无限。</summary>
    public int GetAvailableCount(DiceData dice)
    {
        if (dice == null) return int.MaxValue;
        if (_unlimitedForDemo || dice == tempInferiorDice) return int.MaxValue;
        if (InventoryManager.Instance == null)
        {
            Debug.LogWarning("[DiceInventory] 场景中没有 InventoryManager，骰子库存按 0 计");
            return 0;
        }
        return InventoryManager.Instance.CountDice(dice);
    }

    /// <summary>
    /// 消耗一颗战斗骰子（DicePayment 在抽到卡时逐颗调用）。
    /// </summary>
    /// <returns>true = 消耗成功；false = 库存不足（调用方改用临时劣质骰兜底）</returns>
    public bool TryConsume(DiceData dice)
    {
        if (dice == null) return false;
        if (_unlimitedForDemo || dice == tempInferiorDice)
        {
            Debug.Log($"[DiceInventory] 消耗 {dice.diceName}（不扣背包数量）");
            return true;
        }

        if (InventoryManager.Instance == null)
        {
            Debug.LogWarning("[DiceInventory] 场景中没有 InventoryManager，无法扣骰");
            return false;
        }

        int removed = InventoryManager.Instance.RemoveDice(dice, 1);
        if (removed <= 0)
        {
            Debug.Log($"[DiceInventory] {dice.diceName} 库存不足（剩 0），需临时劣质骰兜底");
            return false;
        }

        Debug.Log($"[DiceInventory] 消耗 {dice.diceName} 1 颗，剩 {InventoryManager.Instance.CountDice(dice)}");
        return true;
    }

    /// <summary>返还一颗战斗骰子（未打出的手牌弃置时由 DicePayment 调用）。</summary>
    public void Return(DiceData dice)
    {
        if (dice == null || _unlimitedForDemo || dice == tempInferiorDice) return;

        if (InventoryManager.Instance == null)
        {
            Debug.LogWarning("[DiceInventory] 场景中没有 InventoryManager，骰子无法返还");
            return;
        }

        if (InventoryManager.Instance.AddDice(dice, 1))
        {
            Debug.Log($"[DiceInventory] 返还 {dice.diceName} 1 颗，现有 {InventoryManager.Instance.CountDice(dice)}");
        }
    }
}
