// =============================================================================
// 模块：M2 敌人系统 - EnemyHPBar（敌人头顶血条 UI）
// 用途：在敌人头顶显示 HP 进度条，订阅 EnemyController.OnHPChanged 自动刷新
// 设计依据：《开发计划》M2 任务清单：制作 EnemyHPBar.cs
// 实现方式：World Space Canvas + Slider（最简方案，便于团队理解）
// 注：血条 Canvas 作为敌人预制体的子对象，跟随移动（Demo 不移动但保留结构）
// =============================================================================
using UnityEngine;
using UnityEngine.UI;

/// <summary>
/// 敌人头顶血条。挂在敌人预制体的子 Canvas 上。
/// </summary>
[RequireComponent(typeof(Canvas))]
public class EnemyHPBar : MonoBehaviour
{
    [Header("UI 引用")]
    [Tooltip("血条 Slider（必须填，value 范围 0~1）")]
    [SerializeField] private Slider hpSlider;

    [Tooltip("HP 文本（可空，显示 'currentHP/maxHP'）")]
    [SerializeField] private UnityEngine.UI.Text hpText;

    [Header("跟随设置")]
    [Tooltip("血条向前倾斜角度（X 轴旋转，单位度）。摄像机俯视角 70° 时建议 60°~70°，让血条平面正对斜俯视视线。")]
    [SerializeField] [Range(0f, 90f)] private float pitchAngle = 70f;

    [Tooltip("血条水平朝向（Y 轴旋转，单位度）。调整让血条正面朝向摄像机所在方向。0°=面朝 +Z，180°=面朝 -Z，90°=面朝 +X。")]
    [SerializeField] [Range(0f, 360f)] private float yawAngle = 0f;

    [Tooltip("是否每帧自动面向摄像机（Billboard）。勾上会覆盖上面两个角度。")]
    [SerializeField] private bool faceCamera = false;

    // -------- 内部引用 --------
    private EnemyController enemyController;
    private Camera mainCamera;

    /// <summary>★2026-09-17 晚三修：血条沿 UI 平面（屏幕正下方）的下移量（世界单位；倾斜面上 1 单位≈58.6px，0.08≈4.7px）。与立绘脚底下滑同一口径，微调改这个数。</summary>
    private const float BarUiDownSlide = 0.08f;

    private void Awake()
    {
        mainCamera = Camera.main;

        // ★2026-08-18：血条纯显示，禁用旗下所有 Graphic 的射线检测。
        // World Space Canvas 的 Image/Text 默认 raycastTarget=true，
        // 会被 EventSystem.IsPointerOverGameObject() 判为"鼠标在 UI 上"，
        // 挡住 HexMover 的格子悬停高亮/点击移动（血条悬在敌人上方时最明显）。
        // 放在所有 early return 之前，保证任何路径都执行。
        DisableRaycastTargets();

        // 向上查找 EnemyController（HPBar 是敌人子对象）
        enemyController = GetComponentInParent<EnemyController>();
        if (enemyController == null)
        {
            enemyController = FindObjectOfType<EnemyController>();
            Debug.LogWarning($"[EnemyHPBar] {gameObject.name} 未在父级找到 EnemyController，使用场景首个（可能不准）");
        }

        // ★2026-09-17 贴图放大（默认高 1.0→1.6）：血条锚点随立绘高度等比上移，
        // 覆盖预制体里烘焙的旧位置（H=1.4 时 →0.008）；同晚用户要求贴图/血条整体下移，
        // 常数随之由 -0.22 降到 -0.30（血条比立绘放大时更低）。
        // ★2026-09-17 晚二修：用户要求「相对 UI 再向下一点」——血条画布与立绘同倾角
        // （pitch=pitchAngle），沿平面下滑 BarUiDownSlide（-倾斜上方向 = 屏幕正下方）。
        if (enemyController != null)
        {
            Vector3 p = transform.localPosition;
            Vector3 uiDown = -(Quaternion.Euler(pitchAngle, 0f, 0f) * Vector3.up) * BarUiDownSlide;
            transform.localPosition = new Vector3(
                p.x + uiDown.x,
                enemyController.BarAnchorLocalY + uiDown.y,
                p.z + uiDown.z);
        }

        if (hpSlider == null)
        {
            Debug.LogError($"[EnemyHPBar] {gameObject.name} 未指定 hpSlider！血条无法显示");
            return;
        }

        // 在 Awake 阶段应用固定角度（如果不使用 Billboard 模式）
        ApplyFixedAngle();
    }

    /// <summary>
    /// 应用固定的倾斜角度和水平朝向。
    /// 这样设置一次就够了，不需要每帧更新；用户可以在 Inspector 修改 pitchAngle / yawAngle
    /// 后在 Edit Mode Context Menu 重应用（见下方调试方法）。
    /// </summary>
    private void ApplyFixedAngle()
    {
        if (faceCamera) return; // Billboard 模式下由 LateUpdate 控制

        // 欧拉角：X = pitch 倾斜，Y = yaw 朝向，Z = 0
        transform.localEulerAngles = new Vector3(pitchAngle, yawAngle, 0f);
    }

    /// <summary>
    /// 递归禁用血条下所有 Graphic（Image/Text/Slider 子件）的 raycastTarget。
    /// 血条不需要接收点击/悬停，关掉后不参与 UGUI 射线，
    /// 鼠标扫过血条时不再拦截 HexMover 的格子高亮与移动点击。
    /// </summary>
    private void DisableRaycastTargets()
    {
        foreach (var graphic in GetComponentsInChildren<Graphic>(true))
        {
            graphic.raycastTarget = false;
        }
    }

    private void OnEnable()
    {
        if (enemyController != null)
        {
            enemyController.OnHPChanged += HandleHPChanged;
            enemyController.OnEnemyDied += HandleEnemyDied; // 死亡时隐藏血条
        }
    }

    private void OnDisable()
    {
        if (enemyController != null)
        {
            enemyController.OnHPChanged -= HandleHPChanged;
            enemyController.OnEnemyDied -= HandleEnemyDied;
        }
    }

    private void Start()
    {
        // 初始刷新一次（显示满血）
        if (enemyController != null)
        {
            RefreshBar(enemyController.CurrentHP, enemyController.MaxHP);
        }
    }

    private void LateUpdate()
    {
        // 只有 Billboard 模式（faceCamera=true）才每帧更新朝向
        if (!faceCamera) return;
        if (mainCamera == null) mainCamera = Camera.main;
        if (mainCamera == null) return;

        transform.LookAt(mainCamera.transform.position);
    }

    // ------------------------------------------------------------------
    // 调试/编辑辅助（Inspector 右键组件可调）
    // ------------------------------------------------------------------

    /// <summary>
    /// 编辑模式手动调用：把 pitchAngle / yawAngle 的当前值应用到 GameObject 的旋转上。
    /// 用法：在 Inspector 改完数字后右键组件 → "调试：应用固定角度"
    /// </summary>
    [ContextMenu("调试：应用固定角度")]
    private void Debug_ApplyFixedAngle()
    {
        ApplyFixedAngle();
        Debug.Log($"[EnemyHPBar] 已应用固定角度：pitch={pitchAngle}°, yaw={yawAngle}° → 实际 {transform.localEulerAngles}");
    }

    /// <summary>
    /// 编辑模式自动匹配：根据当前主摄像机俯视角自动填 pitchAngle（让血条平面正对视线）
    /// </summary>
    [ContextMenu("调试：自动匹配摄像机俯视角")]
    private void Debug_MatchCameraPitch()
    {
        Camera cam = mainCamera != null ? mainCamera : Camera.main;
        if (cam == null) return;
        // 血条平面法线需要与摄像机 forward 近似反向 → pitch 约等于摄像机俯视角
        pitchAngle = cam.transform.eulerAngles.x;
        // 自动推水平朝向：让血条正面朝向摄像机 XZ 方向
        Vector3 camPos = cam.transform.position;
        Vector3 barPos = transform.position;
        Vector2 dir = new Vector2(barPos.x - camPos.x, barPos.z - camPos.z);
        float yaw = Mathf.Atan2(dir.x, dir.y) * Mathf.Rad2Deg; // Atan2(X, Z) 得到相对 +Z 的水平角
        yawAngle = (yaw + 360f) % 360f; // 归一化 0~360
        ApplyFixedAngle();
        Debug.Log($"[EnemyHPBar] 已匹配摄像机：pitch={pitchAngle}°, yaw={yawAngle}° → 实际 {transform.localEulerAngles}");
    }

    // ------------------------------------------------------------------
    // 事件处理
    // ------------------------------------------------------------------
    private void HandleHPChanged(int currentHP, int damageDealt, int rawDamage)
    {
        RefreshBar(currentHP, enemyController.MaxHP);
    }

    private void HandleEnemyDied(EnemyController controller)
    {
        // 死亡时隐藏血条（敌人对象已 SetActive(false)，这里仅兜底）
        if (hpSlider != null) hpSlider.gameObject.SetActive(false);
        if (hpText != null) hpText.gameObject.SetActive(false);
    }

    // ------------------------------------------------------------------
    // 刷新显示
    // ------------------------------------------------------------------
    private void RefreshBar(int currentHP, int maxHP)
    {
        if (hpSlider == null) return;

        // 防止除零
        float ratio = maxHP > 0 ? (float)currentHP / maxHP : 0f;
        hpSlider.value = Mathf.Clamp01(ratio);

        if (hpText != null)
        {
            hpText.text = $"{currentHP}/{maxHP}";
        }
    }
}
