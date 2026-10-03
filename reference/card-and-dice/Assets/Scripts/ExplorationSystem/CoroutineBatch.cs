// =============================================================================
// 同时跑多条协程，等全部结束后再继续（探索巡逻整队齐步走）。
// =============================================================================
using System;
using System.Collections;
using System.Collections.Generic;
using UnityEngine;

public static class CoroutineBatch
{
    public static IEnumerator WhenAll(MonoBehaviour host, List<IEnumerator> jobs)
    {
        if (host == null || jobs == null || jobs.Count == 0) yield break;

        int remaining = 0;
        foreach (IEnumerator job in jobs)
        {
            if (job == null) continue;
            remaining++;
            host.StartCoroutine(RunOne(job, () => remaining--));
        }

        while (remaining > 0) yield return null;
    }

    static IEnumerator RunOne(IEnumerator job, Action onDone)
    {
        yield return job;
        onDone();
    }
}
