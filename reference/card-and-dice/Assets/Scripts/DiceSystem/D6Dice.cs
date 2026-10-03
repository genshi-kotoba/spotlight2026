using UnityEngine;

public class D6Dice : MonoBehaviour
{
    [Header("骰子设置")]
    public float rollForce = 10f;
    public float rollTorque = 5f;
    
    private Rigidbody rb;
    private bool isRolling = false;
    private int currentValue = 1;
    private bool isCheckingStability = false; // 防止重复启动稳定性检查协程
    
    // 骰子六个面的法线方向
    private Vector3[] faceNormals = new Vector3[]
    {
        Vector3.up,    // 1点 (顶部)
        Vector3.right,   // 2点 (右侧)
        Vector3.forward, // 3点 (前方)
        Vector3.back,    // 4点 (后方)
        Vector3.left,    // 5点 (左侧)
        Vector3.down     // 6点 (底部)
    };
    
    private void Start()
    {
        rb = GetComponent<Rigidbody>();
        if (rb != null)
        {
            rb.useGravity = true;
            rb.constraints = RigidbodyConstraints.None;
        }
    }
    
    private void Update()
    {
        // 检查骰子是否正在滚动
        if (rb != null && (rb.velocity.magnitude > 0.1f || rb.angularVelocity.magnitude > 0.1f))
        {
            if (!isRolling)
            {
                isRolling = true;
                isCheckingStability = false; // 重置稳定性检查标志
            }
        }
        // 检查骰子是否停止滚动
        else if (isRolling && !isCheckingStability)
        {
            isCheckingStability = true;
            // 等待一小段时间，确保骰子完全稳定
            StartCoroutine(WaitForFullStability());
        }
    }
    
    /// <summary>
    /// 等待骰子完全稳定
    /// </summary>
    private System.Collections.IEnumerator WaitForFullStability()
    {
        // 等待一小段时间，确保骰子完全稳定
        yield return new WaitForSeconds(0.5f);
        
        // 再次检查骰子是否真的稳定
        if (rb != null && (rb.velocity.magnitude < 0.1f && rb.angularVelocity.magnitude < 0.1f))
        {
            // 确定点数
            DetermineValue();
            // 立即设置为非滚动状态，确保DiceDragHandler能够及时获取点数
            isRolling = false;
        }
        else
        {
            // 如果骰子仍然不稳定，重置标志，允许再次检查
            isCheckingStability = false;
        }
    }
    
    /// <summary>
    /// 确定骰子的点数
    /// </summary>
    private void DetermineValue()
    {
        // 正常计算点数
        float maxDot = -1;
        int value = 1;
        
        // 检查哪个面朝上
        for (int i = 0; i < 6; i++)
        {
            // 计算面的法线在世界坐标系中的方向
            Vector3 worldNormal = transform.TransformDirection(faceNormals[i]);
            // 计算与世界坐标系向上方向的点积
            float dot = Vector3.Dot(Vector3.up, worldNormal);
            if (dot > maxDot)
            {
                maxDot = dot;
                value = i + 1;
            }
        }
        
        currentValue = value;
        
        // 开始下沉和消失的协程
        StartCoroutine(SinkAndDisappear());
    }
    
    /// <summary>
    /// 骰子下沉并消失
    /// </summary>
    private System.Collections.IEnumerator SinkAndDisappear()
    {
        // 等待2秒
        yield return new WaitForSeconds(2f);
        
        // 下沉动画
        float sinkDuration = 1f;
        float elapsedTime = 0f;
        Vector3 startPosition = transform.position;
        Vector3 endPosition = startPosition - new Vector3(0, 1f, 0); // 下沉1单位
        
        while (elapsedTime < sinkDuration)
        {
            elapsedTime += Time.deltaTime;
            float t = elapsedTime / sinkDuration;
            transform.position = Vector3.Lerp(startPosition, endPosition, t);
            yield return null;
        }
        
        // 销毁骰子
        Destroy(gameObject);
    }
    

    
    /// <summary>
    /// 获取当前骰子的点数
    /// </summary>
    public int GetValue()
    {
        return currentValue;
    }
    
    /// <summary>
    /// 检查骰子是否正在滚动
    /// </summary>
    public bool IsRolling()
    {
        return isRolling;
    }
    
    /// <summary>
    /// 设置骰子的滚动状态
    /// </summary>
    public void SetRolling(bool rolling)
    {
        isRolling = rolling;
    }
}