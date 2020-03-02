Index: xx-sources/include/linux/sched.h
===================================================================
--- xx-sources.orig/include/linux/sched.h	2004-10-17 22:17:22.785076584 -0400
+++ xx-sources/include/linux/sched.h	2004-10-17 22:18:02.671013000 -0400
@@ -627,7 +627,7 @@
 
 struct staircase_data {
 	int prio, static_prio;
-	unsigned long runtime, totalrun;
+	unsigned long runtime, totalrun, ns_debit;
 	unsigned int burst;
 
 	unsigned int slice, time_slice;
Index: xx-sources/kernel/staircase-sched.c
===================================================================
--- xx-sources.orig/kernel/staircase-sched.c	2004-10-17 22:17:23.318995416 -0400
+++ xx-sources/kernel/staircase-sched.c	2004-10-17 22:18:02.676012240 -0400
@@ -40,7 +40,7 @@
 
 #include <asm/unistd.h>
 
-#define STAIRCASE_SCHEDULER_VERSION "8.4"
+#define STAIRCASE_SCHEDULER_VERSION "8.K"
 
 /*
  * Convert user-nice values [ -20 ... 0 ... 19 ]
@@ -61,12 +61,10 @@
 #define MAX_USER_PRIO		(USER_PRIO(MAX_PRIO))
 
 /*
- * Some helpers for time to/from microsecond. (>> 10) approximates (/ 1000)
- * to avoid 64 bit division.
+ * Some helpers for converting nanosecond timing to jiffy resolution
  */
-#define NS_TO_US(TIME)		((TIME) >> 10)
-#define JIFFIES_TO_US(TIME)	((TIME) * (1000000 / HZ))
-#define US_TO_JIFFIES(TIME)	((TIME) / (1000000 / HZ))
+#define NS_TO_JIFFIES(TIME)	((TIME) / (1000000000 / HZ))
+#define NSJIFFY			(1000000000 / HZ)	/* One jiffy in ns */
 
 int staircase_sched_compute = 0;
 /*
@@ -74,10 +72,10 @@
  *compute setting is reserved for dedicated computational scheduling
  *and has ten times larger intervals.
  */
-#define _RR_INTERVAL		(10000)		/* microseconds */
+#define _RR_INTERVAL		((10 * HZ / 1000) ? : 1)
 #define RR_INTERVAL()		(_RR_INTERVAL * (1 + 9 * staircase_sched_compute))
 
-#define task_hot(p, now, sd) ((long long) ((now) - (p)->last_ran)	\
+#define task_hot(p, now, sd) ((long long) ((now) - (p)->timestamp)	\
 				< (long long) (sd)->cache_hot_time)
 
 /*
@@ -435,6 +433,25 @@
 #endif /* CONFIG_SCHEDSTATS */
 
 /*
+ * Get nanosecond clock difference without overflowing unsigned long.
+ */
+static unsigned long ns_diff(unsigned long long v1, unsigned long long v2)
+{
+	unsigned long long vdiff;
+	if (unlikely(v1 < v2))
+		/*
+		 * Rarely the clock goes backwards. There should always be
+		 * a positive difference so return 1.
+		 */
+		vdiff = 1;
+	else
+		vdiff = v1 - v2;
+	if (vdiff > (1 << 31))
+		vdiff = 1 << 31;
+	return (unsigned long)vdiff;
+}
+
+/*
  * Adding/removing a task to/from a runqueue:
  */
 static void dequeue_task(struct task_struct *p, runqueue_t *rq)
@@ -442,6 +459,7 @@
 	list_del_init(&p->run_list);
 	if (list_empty(rq->queue + p->staircase_data.prio))
 		__clear_bit(p->staircase_data.prio, rq->bitmap);
+	p->staircase_data.ns_debit = 0;
 }
 
 static void enqueue_task(struct task_struct *p, runqueue_t *rq)
@@ -456,7 +474,7 @@
  * remote queue so we want these tasks to show up at the head of the
  * local queue:
  */
-static inline void enqueue_task_head(struct task_struct *p, runqueue_t *rq)
+static void enqueue_task_head(struct task_struct *p, runqueue_t *rq)
 {
 	list_add(&p->run_list, rq->queue + p->staircase_data.prio);
 	__set_bit(p->staircase_data.prio, rq->bitmap);
@@ -524,6 +542,16 @@
  */
 int staircase_sched_interactive = 1;
 
+static unsigned int rr_interval(task_t * p)
+{
+	unsigned int rr_interval = RR_INTERVAL();
+	int nice = TASK_NICE(p);
+
+	if (nice < 0 && !rt_task(p))
+		rr_interval += -(nice);
+	return rr_interval;
+}
+
 /*
  * effective_prio - dynamic priority dependent on burst.
  * The priority normally decreases by one each RR_INTERVAL.
@@ -534,23 +562,24 @@
 {
 	int prio;
 	unsigned int full_slice, used_slice, first_slice;
-	unsigned int best_burst;
+	unsigned int best_burst, rr;
 	if (rt_task(p))
 		return p->staircase_data.prio;
 
 	best_burst = burst(p);
 	full_slice = slice(p);
+	rr = rr_interval(p);
 	used_slice = full_slice - p->staircase_data.slice;
 	if (p->staircase_data.burst > best_burst)
 		p->staircase_data.burst = best_burst;
-	first_slice = RR_INTERVAL();
+	first_slice = rr;
 	if (staircase_sched_interactive && !staircase_sched_compute && p->mm)
 		first_slice *= (p->staircase_data.burst + 1);
 	prio = MAX_PRIO - 1 - best_burst;
 
 	if (used_slice < first_slice)
 		return prio;
-	prio += 1 + (used_slice - first_slice) / RR_INTERVAL();
+	prio += 1 + (used_slice - first_slice) / rr;
 	if (prio > MAX_PRIO - 1)
 		prio = MAX_PRIO - 1;
 	return prio;
@@ -563,25 +592,25 @@
  */
 static void recalc_task_prio(task_t *p, unsigned long long now)
 {
-	unsigned long long _sleep_time = now - p->timestamp;
-	unsigned long sleep_time = NS_TO_US(_sleep_time);
-	unsigned long rr = RR_INTERVAL();
+	unsigned long sleep_time = ns_diff(now, p->timestamp);
+	unsigned int rr = rr_interval(p);
 	unsigned int best_burst = burst(p);
 	unsigned long minrun = rr * (p->staircase_data.burst + 1) / (best_burst + 1) ? : 1;
 
-	if (p->flags & PF_FORKED || (p->mm &&
-		(p->staircase_data.runtime + sleep_time < minrun || 
+	if (p->flags & PF_FORKED ||
+		(NS_TO_JIFFIES(p->staircase_data.runtime + sleep_time) < minrun || 
 		((!staircase_sched_interactive || staircase_sched_compute) && 
-		p->staircase_data.runtime + sleep_time < rr)))) {
-			unsigned long total_run = p->staircase_data.totalrun + p->staircase_data.runtime;
+		NS_TO_JIFFIES(p->staircase_data.runtime + sleep_time) < rr))) {
+			unsigned long ns_totalrun = p->staircase_data.totalrun + p->staircase_data.runtime;
+			unsigned long total_run = NS_TO_JIFFIES(ns_totalrun);
 			p->flags &= ~PF_FORKED;
 			if (p->staircase_data.slice - total_run < 1) {
 				p->staircase_data.totalrun = 0;
 				dec_burst(p);
 			} else {
 				unsigned int intervals = total_run / rr;
-				unsigned long remainder;
-				p->staircase_data.totalrun = total_run;
+				unsigned int remainder;
+				p->staircase_data.totalrun = ns_totalrun;
 				p->staircase_data.slice -= intervals * rr;
 				if (p->staircase_data.slice <= rr) {
 					p->staircase_data.totalrun = 0;
@@ -593,9 +622,9 @@
 				}
 			}
 	} else {
-		if (p->staircase_data.totalrun > (best_burst - p->staircase_data.burst) * rr)
+		if (NS_TO_JIFFIES(p->staircase_data.totalrun) > (best_burst - p->staircase_data.burst) * rr)
 			dec_burst(p);
-		else if (!((p->flags & PF_UISLEEP) || p->staircase_data.totalrun))
+		else if (!(p->flags & PF_UISLEEP || p->staircase_data.totalrun))
 			inc_burst(p);
 		p->staircase_data.runtime = 0;
 		p->staircase_data.totalrun = 0;
@@ -617,7 +646,7 @@
 	}
 #endif
 	p->staircase_data.slice = slice(p);
-	p->staircase_data.time_slice = RR_INTERVAL();
+	p->staircase_data.time_slice = rr_interval(p);
 	recalc_task_prio(p, now);
 	p->flags &= ~PF_UISLEEP;
 	p->staircase_data.prio = effective_prio(p);
@@ -676,29 +705,6 @@
 	return cpu_curr(task_cpu(p)) == p;
 }
 
-/*
- * cache_delay is the time preemption is delayed in sched_compute mode
- * and is set to 5*cache_decay_ticks
- */
-static int cache_delay = 10 * HZ / 1000;
-
-static void preempt(task_t *task, runqueue_t *rq)
-{
-	task_t *curr = rq->curr;
-
-	if (task->staircase_data.prio > curr->staircase_data.prio)
-		return;
-	else if (task->staircase_data.prio == curr->staircase_data.prio && 
-		(task->staircase_data.totalrun || rt_task(curr)))
-			return;
-	else if (staircase_sched_compute && rq->cache_ticks < cache_delay &&
-		task->mm && !rt_task(task)) {
-			rq->preempted = 1;
-			return;
-	}
-	resched_task(curr);
-}
-
 #ifdef CONFIG_SMP
 enum request_type {
 	REQ_MOVE_TASK,
@@ -857,6 +863,29 @@
 }
 #endif
 
+/*
+ * cache_delay is the time preemption is delayed in sched_compute mode
+ * and is set to 5*cache_decay_ticks on SMP or a nominal 10ms on UP.
+ */
+static int cache_delay = 10 * HZ / 1000;
+
+/*
+ * Check to see if p preempts rq->curr and resched if it does. In compute
+ * mode we do not preempt for at least cache_delay and set rq->preempted.
+ */
+static void preempt(task_t *p, runqueue_t *rq)
+{
+	if (p->staircase_data.prio > rq->curr->staircase_data.prio)
+		return;
+	if (p->staircase_data.prio == rq->curr->staircase_data.prio && (p->staircase_data.totalrun ||
+		rt_task(rq->curr)))
+			return;
+	if (!staircase_sched_compute || rq->cache_ticks >= cache_delay ||
+		!p->mm || rt_task(p))
+			resched_task(rq->curr);
+	rq->preempted = 1;
+}
+
 /***
  * try_to_wake_up - wake up a thread
  * @p: the to-be-woken-up thread
@@ -1046,29 +1075,33 @@
 {
 	unsigned long flags;
 	int this_cpu, cpu;
-	runqueue_t *rq = task_rq_lock(p, &flags);
+	runqueue_t *rq, *this_rq;
+
+	rq = task_rq_lock(p, &flags);
+	cpu = task_cpu(p);
+	this_cpu = smp_processor_id();
 
 	BUG_ON(p->state != TASK_RUNNING);
 
+	schedstat_inc(rq, wunt_cnt);
 	/*
 	 * Forked process gets no burst to prevent fork bombs.
 	 */
 	p->staircase_data.burst = 0;
-	p->parent->flags |= PF_FORKED;
-	cpu = task_cpu(p);
-	this_cpu = smp_processor_id();
-  
-	schedstat_inc(rq, wunt_cnt);
 
 	if (likely(cpu == this_cpu)) {
-		if (unlikely(!task_queued(current)))
-			__activate_task(p, rq);
-		else {
-			list_add_tail(&p->run_list, &current->run_list);
-			rq->nr_running++;
-		}
+		current->flags |= PF_FORKED;
+		__activate_task(p, rq);
+		/*
+		 * We skip the following code due to cpu == this_cpu
+	 	 *
+		 *   task_rq_unlock(rq, &flags);
+		 *   this_rq = task_rq_lock(current, &flags);
+		 */
+		this_rq = rq;
 	} else {
-		runqueue_t *this_rq = cpu_rq(this_cpu);
+		this_rq = cpu_rq(this_cpu);
+
 		/*
 		 * Not the local CPU - must adjust timestamp. This should
 		 * get optimised away in the !CONFIG_SMP case.
@@ -1077,9 +1110,17 @@
 					+ rq->timestamp_last_tick;
 		__activate_task(p, rq);
 		preempt(p, rq);
+
 		schedstat_inc(rq, wunt_moved);
+		/*
+		 * Parent and child are on different CPUs, now get the
+		 * parent runqueue to update the parent's ->flags:
+		 */
+		task_rq_unlock(rq, &flags);
+		this_rq = task_rq_lock(current, &flags);
+		current->flags |= PF_FORKED;
 	}
-	task_rq_unlock(rq, &flags);
+	task_rq_unlock(this_rq, &flags);
 }
 
 /**
@@ -1941,17 +1982,20 @@
 
 static int wake_priority_sleeper(runqueue_t *rq)
 {
+	int ret = 0;
 #ifdef CONFIG_SCHED_SMT
+	spin_lock(&rq->lock);
 	/*
 	 * If an SMT sibling task has been put to sleep for priority
 	 * reasons reschedule the idle task to see if it can now run.
 	 */
 	if (rq->nr_running) {
 		resched_task(rq->idle);
-		return 1;
+		ret = 1;
 	}
+	spin_unlock(&rq->lock);
 #endif
-	return 0;
+	return ret;
 }
 
 /*
@@ -1963,20 +2007,11 @@
 	set_tsk_need_resched(p);
 	dequeue_task(p, rq);
 	p->staircase_data.prio = effective_prio(p);
-	p->staircase_data.time_slice = RR_INTERVAL();
+	p->staircase_data.time_slice = rr_interval(p);
 	enqueue_task(p, rq);
 }
 
 /*
- * Tasks lose burst each time they use up a full slice().
- */
-static void slice_expired(task_t *p, runqueue_t *rq)
-{
-	dec_burst(p);
-	p->staircase_data.slice = slice(p);
-	time_slice_expired(p, rq);
-}
-/*
  * This function gets called by the timer code, with HZ frequency.
  * We call it with interrupts disabled.
  */
@@ -1986,8 +2021,7 @@
 	struct cpu_usage_stat *cpustat = &kstat_this_cpu.cpustat;
 	runqueue_t *rq = this_rq();
 	task_t *p = current;
-	unsigned long long _decrement;
-	long decrement;
+	unsigned long debit;
 
 	rq->timestamp_last_tick = sched_clock();
 
@@ -2018,6 +2052,12 @@
 	else
 		cpustat->user += user_ticks;
 	cpustat->system += sys_ticks;
+
+	/* Task might have expired already, but not scheduled off yet */
+	if (unlikely(!task_queued(p))) {
+		set_tsk_need_resched(p);
+		goto out;
+	}
 	/*
 	 * SCHED_FIFO tasks never run out of timeslice.
 	 */
@@ -2025,26 +2065,30 @@
 		goto out;
 
 	spin_lock(&rq->lock);
-	rq->cache_ticks++;
 
-	decrement = JIFFIES_TO_US(1);
-	_decrement = rq->timestamp_last_tick - p->timestamp;
-	_decrement = NS_TO_US(_decrement);
-	if (_decrement > 0 && _decrement < decrement)
-		decrement = _decrement;
-	if (p->staircase_data.slice > decrement && US_TO_JIFFIES(p->staircase_data.slice - decrement))
-		p->staircase_data.slice -= decrement;
-	else {
-		slice_expired(p, rq);
+	debit = ns_diff(rq->timestamp_last_tick, p->timestamp);
+	p->staircase_data.ns_debit += debit;
+	if (p->staircase_data.ns_debit < NSJIFFY)
+		goto out_unlock;
+	p->staircase_data.ns_debit %= NSJIFFY;
+	/*
+	 * Tasks lose burst each time they use up a full slice().
+	 */
+	if (!--p->staircase_data.slice) {
+		dec_burst(p);
+		p->staircase_data.slice = slice(p);
+		time_slice_expired(p, rq);
 		goto out_unlock;
 	}
-	if (p->staircase_data.time_slice > decrement && 
-		US_TO_JIFFIES(p->staircase_data.time_slice - decrement))
-			p->staircase_data.time_slice -= decrement;
-	else {
+	/*
+	 * Tasks that run out of time_slice but still have slice left get
+	 * requeued with a lower priority && RR_INTERVAL time_slice.
+	 */
+	if (!--p->staircase_data.time_slice) {
 		time_slice_expired(p, rq);
 		goto out_unlock;
- 	}
+	}
+	rq->cache_ticks++;
 	if (rq->preempted && rq->cache_ticks >= cache_delay)
 		set_tsk_need_resched(p);
 out_unlock:
@@ -2183,6 +2227,7 @@
 	runqueue_t *rq;
 	struct list_head *queue;
 	unsigned long long now;
+	unsigned long debit;
 	int cpu, idx;
 
 	WARN_ON(system_state == SYSTEM_BOOTING);
@@ -2208,30 +2253,23 @@
 	prev = current;
 	rq = this_rq();
 
+	/*
+	 * The idle thread is not allowed to schedule!
+	 * Remove this check after it has been exercised a bit.
+	 */
+	if (unlikely(current == rq->idle) && current->state != TASK_RUNNING) {
+		printk(KERN_ERR "bad: scheduling from the idle thread!\n");
+		dump_stack();
+	}
+
 	release_kernel_sem(prev);
 	schedstat_inc(rq, sched_cnt);
 	now = sched_clock();
-	prev->staircase_data.runtime = NS_TO_US(now - prev->timestamp) ? : 1;
-	if (prev->mm && prev->policy != SCHED_FIFO &&
-		prev->state == TASK_RUNNING &&
-		prev->timestamp > rq->timestamp_last_tick) {
-			/*
-			 * We have not run through a scheduler_tick and are
-			 * still running so charge us with the runtime.
-			 */
-			if (unlikely(US_TO_JIFFIES(prev->staircase_data.slice - 
-				prev->staircase_data.runtime) < 1))
-					slice_expired(prev, rq);
-			else if (unlikely(US_TO_JIFFIES(prev->staircase_data.time_slice -
-				prev->staircase_data.runtime) < 1))
-					time_slice_expired(prev, rq);
-			else {
-				 prev->staircase_data.slice -= prev->staircase_data.runtime;
-				 prev->staircase_data.time_slice -= prev->staircase_data.runtime;
-			}
-	}
-	prev->timestamp = now;
+
 	spin_lock_irq(&rq->lock);
+	prev->staircase_data.runtime = ns_diff(now, prev->timestamp);
+	debit = ns_diff(now, rq->timestamp_last_tick) % NSJIFFY;
+	prev->staircase_data.ns_debit += debit;
 
 	if (unlikely(current->flags & PF_DEAD))
 		current->state = __TASK_DEAD;
@@ -2279,7 +2317,6 @@
 			goto go_idle;
 	}
 
-	schedstat_inc(rq, sched_noswitch);
 	idx = sched_find_first_bit(rq->bitmap);
 	queue = rq->queue + idx;
 	next = list_entry(queue->next, task_t, run_list);
@@ -2289,12 +2326,18 @@
 	clear_tsk_need_resched(prev);
 	rcu_qsctr_inc(task_cpu(prev));
 
-	prev->timestamp = prev->last_ran = now;
+	prev->timestamp = now;
 	if (next->flags & PF_YIELDED) {
+		/*
+		 * Tasks that have yield()ed get requeued at normal priority
+		 */
+		int newprio = effective_prio(next);
 		next->flags &= ~PF_YIELDED;
-		dequeue_task(next, rq);
-		next->staircase_data.prio = effective_prio(next);
-		enqueue_task_head(next, rq);
+		if (newprio != next->staircase_data.prio) {
+			dequeue_task(next, rq);
+			next->staircase_data.prio = newprio;
+			enqueue_task(next, rq);
+		}
 	}
 
 	sched_info_switch(prev, next);
@@ -2822,12 +2865,11 @@
 
 	dequeue_task(current, rq);
 	current->staircase_data.slice = slice(current);
-	current->staircase_data.time_slice = RR_INTERVAL();
+	current->staircase_data.time_slice = rr_interval(current);
 	if (likely(!rt_task(current))) {
 		current->flags |= PF_YIELDED;
 		current->staircase_data.prio = MAX_PRIO - 1;
 	}
-	current->staircase_data.burst = 0;
 	enqueue_task(current, rq);
 
 	/*
@@ -2915,7 +2957,6 @@
 
 	idle->staircase_data.prio = MAX_PRIO;
 	idle->state = TASK_RUNNING;
-	idle->staircase_data.burst = 0;
 	set_task_cpu(idle, cpu);
 
 	spin_lock_irqsave(&rq->lock, flags);
@@ -3981,10 +4022,6 @@
 	runqueue_t *rq;
 	int i, j;
 
-#ifdef CONFIG_SMP
-	cache_delay = cache_decay_ticks * 5;
-#endif
-
 	for (i = 0; i < NR_CPUS; i++) {
 		rq = cpu_rq(i);
 		spin_lock_init(&rq->lock);
@@ -3999,6 +4036,7 @@
 		rq->push_cpu = 0;
 		rq->migration_thread = NULL;
 		INIT_LIST_HEAD(&rq->migration_queue);
+		cache_delay = cache_decay_ticks * 5;
 #endif
 		atomic_set(&rq->nr_iowait, 0);
 		for (j = 0; j <= MAX_PRIO; j++)
Index: xx-sources/kernel/workqueue.c
===================================================================
--- xx-sources.orig/kernel/workqueue.c	2004-10-17 22:17:22.500119904 -0400
+++ xx-sources/kernel/workqueue.c	2004-10-17 22:18:02.678011936 -0400
@@ -188,7 +188,10 @@
 
 	current->flags |= PF_NOFREEZE;
 
-	set_user_nice(current, -10);
+	if (current_scheduler->type == SCHED_STAIRCASE)
+		set_user_nice(current, -5);
+	else
+		set_user_nice(current, -10);
 
 	/* Block and flush all signals */
 	sigfillset(&blocked);
