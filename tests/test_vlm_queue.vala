// VLMQueueManager 单元测试
// 验证:
//   - C-2: bg_threads 跨线程访问加锁
//   - C-3: 用 Thread.self 替代闭包捕获 thread 变量
//   - wait_for_completion 阻塞语义
//   - 基本队列/并发/暂停/取消行为
//
// 注意: 真实 executor 模式 (参考 vlm_task_runner.vala):
//   1. 在 worker 线程上执行实际工作
//   2. 通过 Idle.add 在主线程上发射 manager.task_completed (path, md, status, from_cache)
//   3. 调用 manager.notify_finished (path) 释放并发槽
// 测试用 executor 必须遵循同样模式。

using GLib;
using Gee;

int pass_count = 0;
int fail_count = 0;

void pass (string desc) { print ("PASS: %s\n", desc); pass_count++; }
void fail (string desc, string detail = "") {
    print ("FAIL: %s%s%s\n", desc, detail.length > 0 ? " - " : "", detail);
    fail_count++;
}

void assert_true (string desc, bool cond) {
    if (cond) pass (desc);
    else fail (desc);
}

void assert_eq_int (string desc, int expected, int actual) {
    if (expected == actual) pass (desc);
    else fail (desc, @"期望 $expected, 实际 $actual");
}

// 等待 main loop 把 Idle 回调跑完
void pump_loop (uint ms = 200) {
    var loop = new MainLoop ();
    Timeout.add_once (ms, () => loop.quit ());
    loop.run ();
}

// 模拟立即完成的 executor: 在 Idle 上发 task_completed, 然后释放槽
void immediate_executor (string path, VLMQueueManager m) {
    Idle.add (() => {
        m.task_completed (path, "md-for-" + path, PreprocessStatus.COMPLETED, false);
        return Source.REMOVE;
    });
    m.notify_finished (path);
}

// ─── 测试 1: 基本执行流程 ──────────────────────────────────────
void test_basic_execution () {
    print ("\n=== test_basic_execution ===\n");
    var mgr = new VLMQueueManager ();
    var completed_paths = new ArrayList<string> ();

    mgr.task_completed.connect ((path, content, status, from_cache) => {
        completed_paths.add (path);
    });

    mgr.executor = immediate_executor;

    mgr.enqueue ("/file1");
    mgr.enqueue ("/file2");
    mgr.enqueue ("/file3");

    // 等待 Idle 回调执行
    pump_loop (500);

    assert_eq_int ("3 个任务全部完成", 3, completed_paths.size);
    assert_true ("has_tasks() 返回 false", !mgr.has_tasks ());
}

// ─── 测试 2: 重复入队忽略 ──────────────────────────────────────
void test_duplicate_enqueue_ignored () {
    print ("\n=== test_duplicate_enqueue_ignored ===\n");
    var mgr = new VLMQueueManager ();
    var completed_count = 0;

    mgr.task_completed.connect ((path, content, status, from_cache) => {
        completed_count++;
    });

    mgr.executor = immediate_executor;

    mgr.enqueue ("/dup");
    mgr.enqueue ("/dup");
    mgr.enqueue ("/dup");

    pump_loop (300);

    assert_eq_int ("重复入队只执行 1 次", 1, completed_count);
}

// ─── 测试 3: 并发上限 ──────────────────────────────────────────
void test_max_concurrency () {
    print ("\n=== test_max_concurrency ===\n");
    var mgr = new VLMQueueManager ();
    mgr.max_concurrency = 2;

    int max_active_seen = 0;
    int current_active = 0;
    var lock = Mutex ();

    mgr.executor = (path, m) => {
        lock.lock ();
        current_active++;
        if (current_active > max_active_seen) max_active_seen = current_active;
        lock.unlock ();

        Thread.usleep (50 * 1000); // 50ms

        lock.lock ();
        current_active--;
        lock.unlock ();

        Idle.add (() => {
            m.task_completed (path, "md", PreprocessStatus.COMPLETED, false);
            return Source.REMOVE;
        });
        m.notify_finished (path);
    };

    for (int i = 0; i < 6; i++) {
        mgr.enqueue (@"/file$i");
    }

    int observed_completion = 0;
    mgr.task_completed.connect ((p, c, s, f) => observed_completion++);

    pump_loop (1000);

    assert_eq_int ("6 个任务全部完成 (信号计数)", 6, observed_completion);
    assert_true ("并发不超过 max=2", max_active_seen <= 2);
    print ("  最大并发观测值: %d\n", max_active_seen);
}

// ─── 测试 4: wait_for_completion 等待活动任务 ─────────────────
void test_wait_for_completion () {
    print ("\n=== test_wait_for_completion ===\n");
    var mgr = new VLMQueueManager ();
    mgr.max_concurrency = 1;

    int completed = 0;
    mgr.executor = (path, m) => {
        Thread.usleep (100 * 1000); // 100ms
        Idle.add (() => {
            m.task_completed (path, "md", PreprocessStatus.COMPLETED, false);
            return Source.REMOVE;
        });
        m.notify_finished (path);
    };

    mgr.task_completed.connect ((path, content, status, from_cache) => {
        completed++;
    });

    mgr.enqueue ("/slow1");
    mgr.enqueue ("/slow2");
    // 此时一个活动, 一个 pending

    // 旧实现: wait_for_completion 用纯 Thread.usleep 阻塞主循环, Idle 回调
    // 无法执行, active_set 永不清空, 必然超时 (5s 浪费).
    // 新实现: 循环中调用 MainContext.iteration(false) 处理 Idle 回调,
    // 任务完成后立即返回.
    var start_time = get_monotonic_time ();
    mgr.wait_for_completion (5000);
    var elapsed_ms = (get_monotonic_time () - start_time) / 1000;

    // 还需要 pump loop 让剩余的 Idle 回调跑完 (task_completed 信号)
    pump_loop (300);

    assert_eq_int ("wait_for_completion 后所有任务完成", 2, completed);
    assert_true ("无活动任务", !mgr.has_tasks ());
    // 2 个 100ms 任务串行, 应在 ~200-500ms 内完成, 远小于 5000ms 超时
    assert_true ("wait_for_completion 未超时 (快速返回)", elapsed_ms < 2000);
    print ("  实际等待: %ldms\n", (long) elapsed_ms);
}

// ─── 测试 5: wait_for_completion 超时 ─────────────────────────
void test_wait_for_completion_timeout () {
    print ("\n=== test_wait_for_completion_timeout ===\n");
    var mgr = new VLMQueueManager ();
    mgr.max_concurrency = 1;

    // 这个 executor 故意不调用 notify_finished, 模拟卡死
    mgr.executor = (path, m) => {
        // 不通知完成, 让 wait_for_completion 超时
        Thread.usleep (2000 * 1000); // 2 秒
        // 测试结束后才通知, 避免线程泄漏
        Idle.add (() => {
            m.task_completed (path, "md", PreprocessStatus.COMPLETED, false);
            return Source.REMOVE;
        });
        m.notify_finished (path);
    };

    mgr.enqueue ("/stuck");

    // 等待任务进入 active 状态
    pump_loop (100);

    var start_time = get_monotonic_time ();
    mgr.wait_for_completion (300); // 300ms 超时
    var elapsed_ms = (get_monotonic_time () - start_time) / 1000;

    assert_true ("wait_for_completion 在超时后返回", elapsed_ms >= 250);
    print ("  实际等待: %ldms\n", (long) elapsed_ms);

    // 等待卡死线程真正完成, 避免泄漏
    pump_loop (2500);
}

// ─── 测试 6: cancel 清空 pending ──────────────────────────────
void test_cancel_clears_pending () {
    print ("\n=== test_cancel_clears_pending ===\n");
    var mgr = new VLMQueueManager ();
    mgr.max_concurrency = 1;

    var started_paths = new ArrayList<string> ();
    var lock = Mutex ();

    mgr.executor = (path, m) => {
        lock.lock ();
        started_paths.add (path);
        lock.unlock ();
        Thread.usleep (100 * 1000);
        Idle.add (() => {
            m.task_completed (path, "md", PreprocessStatus.COMPLETED, false);
            return Source.REMOVE;
        });
        m.notify_finished (path);
    };

    mgr.enqueue ("/a");
    mgr.enqueue ("/b");
    mgr.enqueue ("/c");
    mgr.enqueue ("/d");

    pump_loop (50); // 让第一个开始执行
    mgr.cancel ();

    pump_loop (500);

    // 验证: 启动的不超过 max_concurrency + 1 (cancel 之前的)
    assert_true ("cancel 后无更多任务启动 (启动数 <= 2)", started_paths.size <= 2);
    print ("  实际启动: %d\n", started_paths.size);
}

// ─── 测试 7: pause/resume 行为 ────────────────────────────────
void test_pause_resume () {
    print ("\n=== test_pause_resume ===\n");
    var mgr = new VLMQueueManager ();
    mgr.max_concurrency = 1;

    int completed = 0;
    mgr.executor = (path, m) => {
        Thread.usleep (20 * 1000);
        Idle.add (() => {
            m.task_completed (path, "md", PreprocessStatus.COMPLETED, false);
            return Source.REMOVE;
        });
        m.notify_finished (path);
    };
    mgr.task_completed.connect ((path, content, status, from_cache) => {
        completed++;
    });

    mgr.enqueue ("/p1");
    mgr.pause ();
    mgr.enqueue ("/p2");
    mgr.enqueue ("/p3");

    pump_loop (200);
    // pause 后只能跑第一个
    assert_eq_int ("pause 后只完成第 1 个", 1, completed);

    mgr.resume ();
    pump_loop (500);
    assert_eq_int ("resume 后全部完成", 3, completed);
}

// ─── 测试 8: has_tasks 语义 ────────────────────────────────────
void test_has_tasks () {
    print ("\n=== test_has_tasks ===\n");
    var mgr = new VLMQueueManager ();
    assert_true ("初始无任务", !mgr.has_tasks ());

    mgr.executor = immediate_executor;
    mgr.enqueue ("/x");
    assert_true ("入队后有任务", mgr.has_tasks ());

    pump_loop (300);
    assert_true ("完成后无任务", !mgr.has_tasks ());
}

// ─── 测试 9: check_cancelled 反应 ─────────────────────────────
void test_check_cancelled () {
    print ("\n=== test_check_cancelled ===\n");
    var mgr = new VLMQueueManager ();
    assert_true ("初始未取消", !mgr.check_cancelled ());
    mgr.cancel ();
    assert_true ("cancel 后 check_cancelled 返回 true", mgr.check_cancelled ());
}

// ─── 测试 10: bg_threads 不泄漏 (C-2/C-3 验证) ────────────────
void test_bg_threads_cleanup () {
    print ("\n=== test_bg_threads_cleanup ===\n");
    var mgr = new VLMQueueManager ();
    mgr.max_concurrency = 4;

    mgr.executor = (path, m) => {
        Thread.usleep (30 * 1000);
        Idle.add (() => {
            m.task_completed (path, "md", PreprocessStatus.COMPLETED, false);
            return Source.REMOVE;
        });
        m.notify_finished (path);
    };

    int total_completed = 0;
    mgr.task_completed.connect ((p, c, s, f) => total_completed++);

    for (int i = 0; i < 20; i++) {
        mgr.enqueue (@"/cleanup/$i");
    }

    // 等待全部完成 + bg_threads 清理 (Idle 回调)
    pump_loop (1500);

    assert_true ("20 个任务完成后无任务", !mgr.has_tasks ());
    assert_eq_int ("20 个任务全部完成 (信号计数)", 20, total_completed);
}

// ─── 测试 11: 多个 manager 实例独立 ───────────────────────────
void test_multiple_managers_independent () {
    print ("\n=== test_multiple_managers_independent ===\n");
    var mgr1 = new VLMQueueManager ();
    var mgr2 = new VLMQueueManager ();

    int c1 = 0, c2 = 0;
    mgr1.executor = immediate_executor;
    mgr2.executor = immediate_executor;
    mgr1.task_completed.connect ((p, c, s, f) => c1++);
    mgr2.task_completed.connect ((p, c, s, f) => c2++);

    mgr1.enqueue ("/m1-a");
    mgr1.enqueue ("/m1-b");
    mgr2.enqueue ("/m2-a");

    pump_loop (400);

    assert_eq_int ("mgr1 完成 2 个", 2, c1);
    assert_eq_int ("mgr2 完成 1 个", 1, c2);
}

public static int main (string[] args) {
    print ("========== VLMQueueManager 测试开始 ==========\n");

    test_basic_execution ();
    test_duplicate_enqueue_ignored ();
    test_max_concurrency ();
    test_wait_for_completion ();
    test_wait_for_completion_timeout ();
    test_cancel_clears_pending ();
    test_pause_resume ();
    test_has_tasks ();
    test_check_cancelled ();
    test_bg_threads_cleanup ();
    test_multiple_managers_independent ();

    print ("\n========== 测试结果 ==========\n");
    print ("PASS: %d, FAIL: %d\n", pass_count, fail_count);
    return fail_count > 0 ? 1 : 0;
}
