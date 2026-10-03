using UnityEngine;

/// <summary>
/// M5a 临时测试脚本（测试快捷键）：
///   - C 键：抽 1 张牌（★用户 2026-08-18：右键抽牌改为 C 键——右键让给"取消当前卡牌动作"）
///   - X 键：能量 +1（★用户 2026-08-19 新增，调试用；★2026-09-14 起受能量上限 energyMax 约束）
/// 测试完毕后删除。不依赖 TurnManager，直接调 CardPileManager / EnergyPointDisplay。
/// </summary>
public class TempCardTest : MonoBehaviour
{
    private void Update()
    {
        // C 键：抽 1 张牌到手牌
        if (Input.GetKeyDown(KeyCode.C))
        {
            if (CardPileManager.Instance != null && CardPileManager.Instance.Hand.Count < CardPileManager.Instance.HandLimit)
            {
                CardPileManager.Instance.DrawCards(1);
                HandUIController.Instance?.RefreshHandLayout();
                Debug.Log($"[TempTest] 抽牌后：手牌 {CardPileManager.Instance.Hand.Count}，抽牌堆 {CardPileManager.Instance.DrawPile.Count}，弃牌堆 {CardPileManager.Instance.DiscardPile.Count}");
            }
        }

        // X 键：能量 +1（绕过整备，直接调 EnergyPointDisplay 权威值；受能量上限约束）
        if (Input.GetKeyDown(KeyCode.X))
        {
            EnergyPointDisplay energyDisplay = FindObjectOfType<EnergyPointDisplay>();
            if (energyDisplay != null)
            {
                int gained = energyDisplay.AddEnergy(1);
                Debug.Log($"[TempTest] 能量 +{gained}，当前 {energyDisplay.CurrentEnergy}/{energyDisplay.EnergyMax}");
            }
        }
    }
}
