using UnityEngine;
using System.Collections;

public class CameraController : MonoBehaviour
{
    public static CameraController Instance;

    /// <summary>★2026-09-12 教学：玩家操作了镜头（WASD 平移或滚轮缩放）时广播（TutorialDirector 订阅）。</summary>
    public static event System.Action OnPlayerOperatedCamera;

    [Header("教学运镜（TutorialDirector 专用）")]
    [Tooltip("教学运镜期间屏蔽玩家的 WASD / 滚轮输入")]
    [SerializeField] private bool tutorialCameraLock = false;
    [Tooltip("教学运镜「恢复默认缩放」使用的高度（突袭场景取景高度）")]
    [SerializeField] public float tutorialDefaultHeight = 12f;
    [Tooltip("教学运镜默认飞行时长（秒）")]
    [SerializeField] public float tutorialFlyDuration = 1.6f;
    private Coroutine _tutorialFly;

    [Header("目标引用")]
    [SerializeField] private Transform player;

    [Header("视角参数")]
    [SerializeField] private float cameraAngle = 70f;
    [SerializeField] private float followSpeed = 8f;
    [SerializeField] private float moveSpeed = 15f;

    [Header("缩放设置")]
    [SerializeField] private float minHeight = 5f;
    [SerializeField] private float maxHeight = 25f;
    [SerializeField] private float zoomSensitivity = 15f;
    [SerializeField] private float zoomSmoothTime = 0.12f;

    [Header("构图")]
    [Tooltip("竖切舒适区：玩家视口 X 在此范围内只平移跟随，不把镜头拉回正中")]
    [SerializeField] private float comfortMinX = 0.2f;
    [SerializeField] private float comfortMaxX = 0.8f;
    [Tooltip("缩到最远时，对准点相对玩家再往屏幕下方偏多少（世界 -Z）")]
    [SerializeField] private float zoomOutLookDown = 1.6f;

    private Vector3 targetPosition;
    private float targetHeight;
    private Vector3 currentVelocity;
    private Vector3 followOffset;
    private bool isFollowingPlayer;

    private void Start()
    {
        Instance = this;
        transform.rotation = Quaternion.Euler(cameraAngle, 0, 0);
        targetHeight = transform.position.y;

        if (player != null)
        {
            followOffset = new Vector3(0f, 0f, -LookAhead(targetHeight));
            targetPosition = PlayerFramedPosition();
            transform.position = targetPosition;
        }
        else
        {
            targetPosition = transform.position;
        }
    }

    private void LateUpdate()
    {
        HandleZoom();
        HandleInputAndFollow();
        transform.position = Vector3.SmoothDamp(transform.position, targetPosition, ref currentVelocity, zoomSmoothTime);
        transform.rotation = Quaternion.Euler(cameraAngle, 0, 0);
    }

    private void HandleZoom()
    {
        if (tutorialCameraLock) return;
        if (IsAnyBlockingUIUp()) return;     // ★2026-09-11：卡包/背包/装填等模态界面打开时，滚轮不缩放地图
        float scroll = Input.GetAxis("Mouse ScrollWheel");
        if (Mathf.Abs(scroll) < 0.01f) return;

        targetHeight = Mathf.Clamp(targetHeight - scroll * zoomSensitivity, minHeight, maxHeight);
        targetPosition.y = targetHeight;
        followOffset.z = -LookAhead(targetHeight);
        if (player != null && isFollowingPlayer)
        {
            targetPosition.z = player.position.z + followOffset.z;
        }
        OnPlayerOperatedCamera?.Invoke();    // ★教学：玩家缩放了镜头
    }

    /// <summary>★2026-09-11：任意模态界面（背包 / 卡包 / 装填）打开时返回 true，用于暂停地图滚轮缩放。
    /// ★2026-09-14：开发者面板（F9）打开时同样暂停。</summary>
    static bool IsAnyBlockingUIUp()
    {
        if (Interactions.DevPanelOpen) return true;
        if (InventoryUI.IsOpen) return true;
        if (LoadoutUI.IsOpen) return true;
        if (CardPackUI.Instance != null && CardPackUI.Instance.IsOpen) return true;
        return false;
    }

    private void HandleInputAndFollow()
    {
        // ★教学运镜期间：屏蔽玩家 WASD 与跟随，交给 TutorialFlyRoutine
        if (tutorialCameraLock) return;

        // ★2026-09-14 开发者面板（F9）打开期间：WASD 平移镜头一并让路
        if (Interactions.DevPanelOpen) return;

        float h = Input.GetAxis("Horizontal");
        float v = Input.GetAxis("Vertical");

        if (Mathf.Abs(h) > 0.1f || Mathf.Abs(v) > 0.1f)
        {
            targetPosition += new Vector3(h, 0, v) * moveSpeed * Time.deltaTime;
            if (player != null)
            {
                followOffset.x = targetPosition.x - player.position.x;
            }
            OnPlayerOperatedCamera?.Invoke();    // ★教学：玩家平移了镜头
        }

        if (player == null || !isFollowingPlayer) return;

        followOffset.z = -LookAhead(targetHeight);
        Vector3 desired = new Vector3(
            player.position.x + followOffset.x,
            targetHeight,
            player.position.z + followOffset.z);

        if (!IsPlayerInComfortBand())
        {
            desired.x = player.position.x;
            followOffset.x = 0f;
        }

        targetPosition = Vector3.Lerp(targetPosition, desired, followSpeed * Time.deltaTime);
    }

    float LookAhead(float height)
    {
        float angle = Mathf.Clamp(cameraAngle, 1f, 89f) * Mathf.Deg2Rad;
        float t = Mathf.InverseLerp(minHeight, maxHeight, height);
        return height / Mathf.Tan(angle) + t * zoomOutLookDown;
    }

    Vector3 PlayerFramedPosition()
    {
        return new Vector3(player.position.x + followOffset.x, targetHeight, player.position.z + followOffset.z);
    }

    bool IsPlayerInComfortBand()
    {
        Camera cam = Camera.main;
        if (cam == null) return true;
        Vector3 vp = cam.WorldToViewportPoint(player.position);
        return vp.z > 0f && vp.x >= comfortMinX && vp.x <= comfortMaxX;
    }

    /// <summary>开始跟随：只跟玩家平移，不把镜头拽到正中。</summary>
    public void StartFollowingPlayer()
    {
        isFollowingPlayer = true;
        if (player == null) return;
        followOffset.x = targetPosition.x - player.position.x;
        followOffset.z = -LookAhead(targetHeight);
    }

    public void StopFollowingPlayer()
    {
        isFollowingPlayer = false;
        if (player == null) return;
        followOffset.x = targetPosition.x - player.position.x;
        followOffset.z = -LookAhead(targetHeight);
    }

    // ==================================================================
    // ★2026-09-12 教学运镜 API（TutorialDirector 专用）
    // ==================================================================

    /// <summary>
    /// 缓慢把镜头中心飞到 worldFocus（世界坐标，通常是某地图格）并把高度恢复到
    /// tutorialDefaultHeight（默认缩放）。期间屏蔽玩家输入，结束后停在原地
    /// （StopFollowingPlayer 状态），由 TutorialResumeFollow 交还跟随。
    /// </summary>
    public void TutorialFlyTo(Vector3 worldFocus, float duration = 0f)
    {
        if (duration <= 0f) duration = tutorialFlyDuration;
        StopFollowingPlayer();
        tutorialCameraLock = true;
        if (_tutorialFly != null) StopCoroutine(_tutorialFly);
        _tutorialFly = StartCoroutine(TutorialFlyRoutine(worldFocus, duration));
    }

    private IEnumerator TutorialFlyRoutine(Vector3 worldFocus, float duration)
    {
        float h = Mathf.Clamp(tutorialDefaultHeight, minHeight, maxHeight);
        Vector3 start = targetPosition;
        float startH = targetHeight;
        // ★口径对齐跟随模式：相机放在目标「身后」（-LookAhead），视线才落在 worldFocus 上
        Vector3 end = new Vector3(worldFocus.x, h, worldFocus.z - LookAhead(h));
        float t = 0f;
        while (t < 1f)
        {
            t += Time.deltaTime / Mathf.Max(0.01f, duration);
            float e = Mathf.SmoothStep(0f, 1f, Mathf.Clamp01(t));
            targetHeight = Mathf.Lerp(startH, h, e);
            targetPosition = Vector3.Lerp(start, end, e);
            yield return null;
        }
        _tutorialFly = null;
        // ★运镜结束立即交还镜头控制（WASD/滚轮可用），但保持「不跟随玩家」，
        //   直到 TutorialResumeFollow 被调用 —— 教学锁（TutorialLockInput）从不限制镜头。
        tutorialCameraLock = false;
    }

    /// <summary>教学运镜结束：解除输入屏蔽并恢复跟随玩家（镜头平滑滑回）。</summary>
    public void TutorialResumeFollow()
    {
        tutorialCameraLock = false;
        StartFollowingPlayer();
    }
}
