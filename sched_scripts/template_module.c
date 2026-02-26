/*
 * How to use: copy the code into arch/x86/kernel/msr.c
 */
#include <linux/spinlock.h>
#include <linux/kthread.h>
#include <linux/delay.h>
#include <linux/rbtree_augmented.h>

/*lockdep test*/
static DEFINE_SPINLOCK(lockA);
static DEFINE_SPINLOCK(lockB);
static DEFINE_SPINLOCK(lockC);

static int t1(void *data)
{
	struct completion *c = data;

	spin_lock(&lockA);
	spin_lock(&lockB);
	spin_lock(&lockC);
	spin_unlock(&lockC);
	spin_unlock(&lockB);
	spin_unlock(&lockA);
	complete(c);

	return 0;
}

static int t2(void *data)
{
	struct completion *c = data;

	spin_lock(&lockB);
	spin_lock(&lockA);
	spin_lock(&lockC);
	spin_unlock(&lockC);
	spin_unlock(&lockA);
	spin_unlock(&lockB);
	complete(c);

	return 0;
}

static int test_dl(void)
{
	struct task_struct *p1, *p2;
	struct completion p1_ready, p2_ready;

	memset(&p1_ready, 0, sizeof(struct completion));
	memset(&p2_ready, 0, sizeof(struct completion));

	init_completion(&p1_ready);
	init_completion(&p2_ready);

	p1 = kthread_run(t1, &p1_ready, "t1");
	mdelay(1);
	p2 = kthread_run(t2, &p2_ready, "t2");
	wait_for_completion(&p1_ready);
	wait_for_completion(&p2_ready);

	return 0;
}

/*rb-tree-augment test*/
#define NODES       3
#define PERF_LOOPS  1

struct test_node {
	struct rb_node rb;

	/* following fields used for testing augmented rbtree functionality */
	int vruntime;
	int deadline;
	int min_deadline;
};

static struct rb_root root = RB_ROOT;
static struct test_node nodes[NODES];

static inline u32 augment_recompute(struct test_node *node, bool exit)
{
	u32 min, tmp_min;

	min = node->min_deadline = node->deadline;
	printk("augment_recompute node 0x%lx, initial min_deadline/min %d set to deadline %d\n",
		(unsigned long)node, node->min_deadline,
		node->deadline);
	if (node->rb.rb_left) {
		struct test_node *left_node = rb_entry(node->rb.rb_left, struct test_node, rb);

		tmp_min = left_node->min_deadline;
		if (tmp_min < min)
			min = tmp_min;
		printk("  augment_recompute left test_node 0x%lx, its min_deadline %d, deadline %d\n",
			(unsigned long)left_node,
			tmp_min,
			left_node->deadline);
	}
	if (node->rb.rb_right) {
		struct test_node *right_node = rb_entry(node->rb.rb_right, struct test_node, rb);

		tmp_min = right_node->min_deadline;
		if (tmp_min < min)
			min = tmp_min;
		printk("  augment_recompute right test_node 0x%lx, its min_deadline %d, deadline %d\n",
			(unsigned long)right_node,
			tmp_min,
			right_node->deadline);
	}
	if (min < node->min_deadline)
		node->min_deadline = min;

	printk("augment_recompute node 0x%lx, adjust min_deadline to %d\n",
		(unsigned long)node, node->min_deadline);
	return node->min_deadline;
}

RB_DECLARE_CALLBACKS(static, augment_callbacks, struct test_node,
			rb, min_deadline, augment_recompute);

static void insert_augmented(struct test_node *node, struct rb_root *root)
{
	struct rb_node **new = &root->rb_node, *rb_parent = NULL;
	u32 vtime = node->vruntime;
	struct test_node *parent;

	while (*new) {
		rb_parent = *new;
		parent = rb_entry(rb_parent, struct test_node, rb);
		if (vtime < parent->vruntime) {
			new = &parent->rb.rb_left;
		} else {
			new = &parent->rb.rb_right;
		}
	}

	printk("insert node 0x%lx, before rb_link_node to parent 0x%lx, min_deadline is %d\n",
		(unsigned long)node, (unsigned long)parent, node->min_deadline);
	node->min_deadline = node->deadline;
	rb_link_node(&node->rb, rb_parent, new);
	printk("insert node 0x%lx, after rb_link_node to parent 0x%lx, min_deadline set to %d\n",
		(unsigned long)node, (unsigned long)parent, node->min_deadline);
	augment_callbacks.propagate(rb_parent, NULL);
	printk("insert node 0x%lx, after propagate parent 0x%lx, min_deadline is %d\n",
		(unsigned long)node, (unsigned long)parent, node->min_deadline);
	rb_insert_augmented(&node->rb, root, &augment_callbacks);
	printk("insert node 0x%lx, after rb_insert_augmented root, min_deadline is %d\n",
		(unsigned long)node, node->min_deadline);
}

static void erase_augmented(struct test_node *node, struct rb_root *root)
{
	printk("erase node 0x%lx, before rb_erase_augmented root, min_deadline is %d, deadline %d\n",
		(unsigned long)node, node->min_deadline,
		node->deadline);
	rb_erase_augmented(&node->rb, root, &augment_callbacks);
	printk("erase node 0x%lx, after rb_erase_augmented root, min_deadline is %d, deadline %d\n",
		(unsigned long)node, node->min_deadline,
		node->deadline);
}

static int test_rb(void)
{
	int i, j, k;
	printk(KERN_ALERT "rbtree testing");

	nodes[0].vruntime = 2;
	nodes[0].deadline = 6;
	nodes[0].min_deadline= 6;

	nodes[1].vruntime = 1;
	nodes[1].deadline = 2;
	nodes[1].min_deadline= 2;

	nodes[2].vruntime = 3;
	nodes[2].deadline = 4;
	nodes[2].min_deadline= 4;

	for (j = 0; j < NODES; j++)
		insert_augmented(nodes + j, &root);

	for (i = 0; i < NODES; i++) {
		printk("After all nodes are inserted, node 0x%lx deadline %d min_deadline %d\n",
			(unsigned long)&nodes[i], nodes[i].deadline, nodes[i].min_deadline);
	}

	erase_augmented(&nodes[1], &root);
	for (k = 0; k < NODES; k++) {
		printk("After nodes[1] is erased, node[%d] 0x%lx deadline %d min_deadline %d\n",
			k,
			(unsigned long)&nodes[k], nodes[k].deadline, nodes[k].min_deadline);
	}

	erase_augmented(&nodes[2], &root);
	for (k = 0; k < NODES; k++) {
		printk("After nodes[1], nodes[2] are erased, node[%d] 0x%lx deadline %d min_deadline %d\n",
			k,
			(unsigned long)&nodes[k], nodes[k].deadline, nodes[k].min_deadline);
	}

	erase_augmented(&nodes[0], &root);
	for (k = 0; k < NODES; k++) {
		printk("After nodes[0], nodes[1], nodes[2] are erased, node[%d] 0x%lx deadline %d min_deadline %d\n",
			k,
			(unsigned long)&nodes[k], nodes[k].deadline, nodes[k].min_deadline);
	}

	return -EAGAIN; /* Fail will directly unload the module */
}
