// =============================================================================
// 模块：M7 战斗结算 - 远征物资账本 ExpeditionWallet【已退役】
// 用途：当局材料 / 骰子 / 灵魂三个计数。Sprint 1 最小实现，不做格子背包。
// 设计依据：《项目现状与后续规划.md》Sprint 1；总策划案终极版 §6.1 / C2
// 挂载：MainScene SetUp/GameManager
//
// ★2026-09-08 退役（spec §13）：材料/骰子/灵魂改由 InventoryManager（五分区背包）、
//   CorpseSpawner（敌人掉落进遗物袋）与 SoulLantern（灵魂入魂灯）承担。
//   全项目已无写入方与读取方；按「封存旧流程」保留本类，不再参与任何结算。
// =============================================================================
using System;
using UnityEngine;

/// <summary>
/// 当局远征物资账本。跨探索↔战斗持续，撤离兑现前不清零。
/// </summary>
public class ExpeditionWallet : MonoBehaviour
{
    public static ExpeditionWallet Instance { get; private set; }

    [Header("当局计数（运行时）")]
    [SerializeField] private int materials;
    [SerializeField] private int dice;
    [SerializeField] private int souls;

    public int Materials => materials;
    public int Dice => dice;
    public int Souls => souls;

    /// <summary>任一计数变化时广播，供顶栏可选刷新。</summary>
    public event Action OnChanged;

    private void Awake()
    {
        if (Instance != null && Instance != this)
        {
            Destroy(this);
            return;
        }
        Instance = this;
    }

    private void OnDestroy()
    {
        if (Instance == this) Instance = null;
    }

    public void AddNamed(string itemName, int amount)
    {
        if (amount <= 0) return;
        string name = itemName ?? string.Empty;
        if (name.Contains("灵魂"))
        {
            souls += amount;
        }
        else if (name.Contains("骰"))
        {
            dice += amount;
        }
        else
        {
            materials += amount;
        }
        Debug.Log($"[远征] 获得 {itemName} ×{amount} → 材料 {materials} / 骰子 {dice} / 灵魂 {souls}");
        OnChanged?.Invoke();
    }

    public void Clear()
    {
        materials = 0;
        dice = 0;
        souls = 0;
        OnChanged?.Invoke();
    }
}
