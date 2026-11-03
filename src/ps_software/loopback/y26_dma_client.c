// SPDX-License-Identifier: GPL-2.0-only
/*
 * Small Linux 5.15 DMAengine client for the Y26 AXI-Stream loopback.
 * A bound client pins this module: close applications, unbind, then rmmod.
 * Any failure after DMA starts quarantines resources until a controlled reboot.
 * The target Xilinx provider can hide hardware-stop errors behind a zero return.
 */
#include <linux/build_bug.h>
#include <linux/compat.h>
#include <linux/completion.h>
#include <linux/dma-mapping.h>
#include <linux/dmaengine.h>
#include <linux/err.h>
#include <linux/fs.h>
#include <linux/jiffies.h>
#include <linux/kref.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/slab.h>
#include <linux/uaccess.h>

#include "y26_dma_uapi.h"

#define Y26_DEFAULT_TIMEOUT_MS 1000U
#define Y26_MAX_TIMEOUT_MS 5000U

struct y26_dma_completion {
	struct completion done;
	struct dmaengine_result result;
	bool seen;
};

struct y26_dma_client {
	struct kref refs;
	struct mutex lock;
	bool online;
	bool quarantined;
	struct device *dev;
	struct miscdevice misc;
	struct dma_chan *tx;
	struct dma_chan *rx;
	struct device *tx_dev;
	struct device *rx_dev;
	void *tx_buffer;
	void *rx_buffer;
	dma_addr_t tx_dma;
	dma_addr_t rx_dma;
	struct y26_dma_completion tx_done;
	struct y26_dma_completion rx_done;
};

/* Uncertain hardware completion keeps resources and blocks rebinding until reboot. */
static bool y26_poisoned;

static_assert(sizeof(struct y26_dma_transfer) == 32);
static_assert(sizeof(struct y26_dma_transfer_v2) == 40);

static void y26_free(struct kref *refs)
{
	struct y26_dma_client *client;

	client = container_of(refs, struct y26_dma_client, refs);
	kfree(client);
}

static void y26_complete(void *arg, const struct dmaengine_result *result)
{
	struct y26_dma_completion *done = arg;

	if (result) {
		done->result = *result;
		done->seen = true;
	}
	/* The waiter observes result/seen through completion's release/acquire. */
	complete(&done->done);
}

/* The caller holds lock. Both channels must be quiescent before buffer reuse. */
static int y26_stop(struct y26_dma_client *client)
{
	int rx_error = 0, tx_error = 0;

	if (client->rx)
		rx_error = dmaengine_terminate_sync(client->rx);
	if (client->tx)
		tx_error = dmaengine_terminate_sync(client->tx);
	if (rx_error || tx_error) {
		client->online = false;
		client->quarantined = true;
		WRITE_ONCE(y26_poisoned, true);
		dev_crit(client->dev,
			 "DMA stop failed rx=%d tx=%d; retaining resources/module until reboot\n",
			 rx_error, tx_error);
		return -EIO;
	}
	return 0;
}

static int y26_wait_until(struct completion *done, unsigned long deadline)
{
	unsigned long now;
	long remaining;

	now = jiffies;
	if (time_after_eq(now, deadline))
		return try_wait_for_completion(done) ? 0 : -ETIMEDOUT;
	remaining = wait_for_completion_interruptible_timeout(done, deadline - now);
	if (remaining < 0)
		return -EINTR;
	return remaining ? 0 : -ETIMEDOUT;
}

/* lock serializes the two buffers and keeps remove from freeing DMA resources. */
static int y26_transfer_locked(struct y26_dma_client *client,
			       struct y26_dma_transfer_v2 *request)
{
	struct dma_async_tx_descriptor *descriptor;
	dma_cookie_t rx_cookie = 0, tx_cookie = 0;
	unsigned int timeout_ms = request->timeout_ms;
	unsigned long deadline;
	bool issued = false;
	int error, stop_error;

	if (!timeout_ms)
		timeout_ms = Y26_DEFAULT_TIMEOUT_MS;
	reinit_completion(&client->rx_done.done);
	reinit_completion(&client->tx_done.done);
	client->rx_done.seen = false;
	client->tx_done.seen = false;
	client->rx_done.result.result = DMA_TRANS_ABORTED;
	client->tx_done.result.result = DMA_TRANS_ABORTED;
	memset(client->rx_buffer, 0xa5, request->rx_bytes);

	descriptor = dmaengine_prep_slave_single(client->rx, client->rx_dma,
			request->rx_bytes, DMA_DEV_TO_MEM,
			DMA_CTRL_ACK | DMA_PREP_INTERRUPT);
	if (!descriptor) {
		error = -EIO;
		goto stop;
	}
	descriptor->callback = NULL;
	descriptor->callback_result = y26_complete;
	descriptor->callback_param = &client->rx_done;
	rx_cookie = dmaengine_submit(descriptor);
	if (dma_submit_error(rx_cookie) || rx_cookie < DMA_MIN_COOKIE) {
		error = rx_cookie < 0 ? rx_cookie : -EIO;
		goto stop;
	}

	descriptor = dmaengine_prep_slave_single(client->tx, client->tx_dma,
			request->tx_bytes, DMA_MEM_TO_DEV,
			DMA_CTRL_ACK | DMA_PREP_INTERRUPT);
	if (!descriptor) {
		error = -EIO;
		goto stop;
	}
	descriptor->callback = NULL;
	descriptor->callback_result = y26_complete;
	descriptor->callback_param = &client->tx_done;
	tx_cookie = dmaengine_submit(descriptor);
	if (dma_submit_error(tx_cookie) || tx_cookie < DMA_MIN_COOKIE) {
		error = tx_cookie < 0 ? tx_cookie : -EIO;
		goto stop;
	}

	/* One shared wait budget, and no transmitter start before the receiver. */
	deadline = jiffies + msecs_to_jiffies(timeout_ms);
	dma_wmb();
	issued = true;
	dma_async_issue_pending(client->rx);
	dma_async_issue_pending(client->tx);
	error = y26_wait_until(&client->rx_done.done, deadline);
	if (!error)
		error = y26_wait_until(&client->tx_done.done, deadline);
	if (!error &&
	    (!client->rx_done.seen || !client->tx_done.seen ||
	     client->rx_done.result.result != DMA_TRANS_NOERROR ||
	     client->tx_done.result.result != DMA_TRANS_NOERROR ||
	     dma_async_is_tx_complete(client->rx, rx_cookie, NULL, NULL) != DMA_COMPLETE ||
	     dma_async_is_tx_complete(client->tx, tx_cookie, NULL, NULL) != DMA_COMPLETE))
		error = -EIO;
	if (!error) {
		request->completed = Y26_DMA_DONE_TX | Y26_DMA_DONE_RX;
		dma_rmb();
		return 0;
	}
stop:
	stop_error = y26_stop(client);
	/*
	 * This provider returns zero even when its hardware stop/reset fails.
	 * After issue, no error path may reuse or free these DMA-owned buffers,
	 * nor let late callbacks outlive this object's/module's held references.
	 * Preparation/submission failures before issue need no such quarantine
	 * when terminate_sync succeeds: hardware was not started for this request.
	 */
	if (issued && !client->quarantined) {
		client->online = false;
		client->quarantined = true;
		WRITE_ONCE(y26_poisoned, true);
		dev_crit(client->dev,
			 "DMA failed after start (%d); client quarantined until reboot\n",
			 error);
	}
	if (stop_error)
		return -EIO;
	return error;
}

static long y26_ioctl(struct file *file, unsigned int command, unsigned long arg)
{
	struct y26_dma_client *client = file->private_data;
	struct y26_dma_transfer_v2 request;
	struct y26_dma_transfer legacy;
	void __user *argument = (void __user *)arg;
	int error;

	if (command != Y26_DMA_TRANSFER && command != Y26_DMA_TRANSFER_V2)
		return -ENOTTY;
	if (mutex_lock_interruptible(&client->lock))
		return -EINTR;
	if (!client->online) {
		error = -ENODEV;
		goto unlock;
	}
	memset(&request, 0, sizeof(request));
	if (command == Y26_DMA_TRANSFER) {
		if (copy_from_user(&legacy, argument, sizeof(legacy))) {
			error = -EFAULT;
			goto unlock;
		}
		if (legacy.bytes > Y26_DMA_MAX_BYTES) {
			error = -EINVAL;
			goto unlock;
		}
		request.version = Y26_DMA_ABI_V2;
		request.tx_bytes = legacy.bytes;
		request.rx_bytes = legacy.bytes;
		request.timeout_ms = legacy.timeout_ms;
		request.tx_user = legacy.tx_user;
		request.rx_user = legacy.rx_user;
		request.reserved = legacy.reserved;
	} else if (copy_from_user(&request, argument, sizeof(request))) {
		error = -EFAULT;
		goto unlock;
	}
	if (request.version != Y26_DMA_ABI_V2 ||
	    !y26_dma_v2_valid_lengths(request.tx_bytes, request.rx_bytes) ||
	    request.timeout_ms > Y26_MAX_TIMEOUT_MS ||
	    request.reserved) {
		error = -EINVAL;
		goto unlock;
	}
	if (!request.tx_user || !request.rx_user ||
	    (u64)(unsigned long)request.tx_user != request.tx_user ||
	    (u64)(unsigned long)request.rx_user != request.rx_user) {
		error = -EFAULT;
		goto unlock;
	}
	request.completed = 0;
	if (copy_from_user(client->tx_buffer, u64_to_user_ptr(request.tx_user),
			   request.tx_bytes)) {
		error = -EFAULT;
		goto report;
	}
	error = y26_transfer_locked(client, &request);
	if (!error && copy_to_user(u64_to_user_ptr(request.rx_user),
				  client->rx_buffer, request.rx_bytes))
		error = -EFAULT;
report:
	if (command == Y26_DMA_TRANSFER) {
		legacy.completed = request.completed;
		if (copy_to_user(argument, &legacy, sizeof(legacy)))
			error = -EFAULT;
	} else if (copy_to_user(argument, &request, sizeof(request)))
		error = -EFAULT;
unlock:
	mutex_unlock(&client->lock);
	return error;
}

#ifdef CONFIG_COMPAT
static long y26_compat_ioctl(struct file *file, unsigned int command,
			     unsigned long arg)
{
	return y26_ioctl(file, command, (unsigned long)compat_ptr(arg));
}
#endif

static int y26_open(struct inode *inode, struct file *file)
{
	struct miscdevice *misc = file->private_data;
	struct y26_dma_client *client;
	int error;

	client = container_of(misc, struct y26_dma_client, misc);
	if (mutex_lock_interruptible(&client->lock))
		return -EINTR;
	if (!client->online) {
		error = -ENODEV;
		goto unlock;
	}
	kref_get(&client->refs);
	file->private_data = client;
	error = nonseekable_open(inode, file);
	if (error)
		kref_put(&client->refs, y26_free);
unlock:
	mutex_unlock(&client->lock);
	return error;
}

static int y26_release(struct inode *inode, struct file *file)
{
	struct y26_dma_client *client = file->private_data;

	kref_put(&client->refs, y26_free);
	return 0;
}

static const struct file_operations y26_fops = {
	.owner = THIS_MODULE,
	.open = y26_open,
	.release = y26_release,
	.unlocked_ioctl = y26_ioctl,
#ifdef CONFIG_COMPAT
	.compat_ioctl = y26_compat_ioctl,
#endif
	.llseek = no_llseek,
};

static void y26_release_dma(struct y26_dma_client *client)
{
	if (client->rx_buffer)
		dma_free_coherent(client->rx_dev, Y26_DMA_V2_MAX_BYTES,
				  client->rx_buffer, client->rx_dma);
	if (client->tx_buffer)
		dma_free_coherent(client->tx_dev, Y26_DMA_V2_MAX_BYTES,
				  client->tx_buffer, client->tx_dma);
	client->rx_buffer = NULL;
	client->tx_buffer = NULL;
	if (client->rx)
		dma_release_channel(client->rx);
	if (client->tx)
		dma_release_channel(client->tx);
	client->rx = NULL;
	client->tx = NULL;
	if (client->rx_dev)
		put_device(client->rx_dev);
	if (client->tx_dev)
		put_device(client->tx_dev);
	client->rx_dev = NULL;
	client->tx_dev = NULL;
}

/* Called only after DMA resources are released, and never under client->lock. */
static void y26_release_binding(struct y26_dma_client *client)
{
	struct device *device = client->dev;

	client->dev = NULL;
	put_device(device);
	kref_put(&client->refs, y26_free);
	module_put(THIS_MODULE);
}

static int y26_probe(struct platform_device *pdev)
{
	struct y26_dma_client *client;
	int error;

	if (READ_ONCE(y26_poisoned)) {
		dev_err(&pdev->dev, "prior DMA stop failed; reboot before rebinding\n");
		return -EIO;
	}
	client = kzalloc(sizeof(*client), GFP_KERNEL);
	if (!client)
		return -ENOMEM;
	/* Explicit unbind is required before rmmod while a device is bound. */
	if (!try_module_get(THIS_MODULE)) {
		kfree(client);
		return -ENODEV;
	}
	kref_init(&client->refs);
	mutex_init(&client->lock);
	init_completion(&client->tx_done.done);
	init_completion(&client->rx_done.done);
	client->dev = get_device(&pdev->dev);
	client->tx = dma_request_chan(&pdev->dev, "tx");
	if (IS_ERR(client->tx)) {
		error = PTR_ERR(client->tx);
		client->tx = NULL;
		goto fail;
	}
	client->rx = dma_request_chan(&pdev->dev, "rx");
	if (IS_ERR(client->rx)) {
		error = PTR_ERR(client->rx);
		client->rx = NULL;
		goto fail;
	}
	client->tx_dev = get_device(dmaengine_get_dma_device(client->tx));
	client->rx_dev = get_device(dmaengine_get_dma_device(client->rx));
	client->tx_buffer = dma_alloc_coherent(client->tx_dev, Y26_DMA_V2_MAX_BYTES,
					       &client->tx_dma, GFP_KERNEL);
	if (!client->tx_buffer) {
		error = -ENOMEM;
		goto fail;
	}
	client->rx_buffer = dma_alloc_coherent(client->rx_dev, Y26_DMA_V2_MAX_BYTES,
					       &client->rx_dma, GFP_KERNEL);
	if (!client->rx_buffer) {
		error = -ENOMEM;
		goto fail;
	}
	client->misc.minor = MISC_DYNAMIC_MINOR;
	client->misc.name = "y26_dma_loopback";
	client->misc.fops = &y26_fops;
	client->misc.parent = &pdev->dev;
	client->misc.mode = 0600;
	client->online = true;
	error = misc_register(&client->misc);
	if (error)
		goto fail;
	platform_set_drvdata(pdev, client);
	dev_info(&pdev->dev, "ready: /dev/y26_dma_loopback, ABI v1 %u / v2 %u bytes per direction; unbind before rmmod\n",
		 Y26_DMA_MAX_BYTES, Y26_DMA_V2_MAX_BYTES);
	return 0;
fail:
	client->online = false;
	/* No descriptor is submitted before misc_register succeeds; no DMA owns buffers. */
	y26_release_dma(client);
	y26_release_binding(client);
	return error;
}

static int y26_remove(struct platform_device *pdev)
{
	struct y26_dma_client *client = platform_get_drvdata(pdev);
	bool retained;

	mutex_lock(&client->lock);
	client->online = false;
	if (!client->quarantined && !y26_stop(client))
		y26_release_dma(client);
	retained = client->quarantined;
	mutex_unlock(&client->lock);
	/* Avoid misc_open's global misc mutex -> client mutex lock-order inversion. */
	misc_deregister(&client->misc);
	platform_set_drvdata(pdev, NULL);
	/* Returning an error cannot prevent unbind; retain resources instead. */
	if (retained) {
		dev_crit(client->dev, "unbound in quarantine; DMA memory/channel/module retained\n");
		return 0;
	}
	/* Existing files retain only this object and return ENODEV from ioctl. */
	y26_release_binding(client);
	return 0;
}

static const struct of_device_id y26_matches[] = {
	{ .compatible = "y26,dma-loopback" },
	{ }
};
MODULE_DEVICE_TABLE(of, y26_matches);

static struct platform_driver y26_driver = {
	.probe = y26_probe,
	.remove = y26_remove,
	.driver = {
		.name = "y26-dma-loopback",
		.of_match_table = y26_matches,
	},
};
module_platform_driver(y26_driver);

MODULE_DESCRIPTION("Y26 bounded DMAengine loopback client for Linux 5.15");
MODULE_AUTHOR("YOLO26n FPGA project");
MODULE_LICENSE("GPL");
