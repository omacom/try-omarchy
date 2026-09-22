// SPDX-License-Identifier: GPL-2.0-only
/*
 * Mirror the host Mac's battery into the guest as BAT0/ADP0.
 *
 * A root-only agent writes one whole snapshot per write() to the `state`
 * attribute:
 *
 *   present=1 status=discharging capacity=57 ac=0 time_to_empty=8100 time_to_full=-1
 *   present=0 ac=1
 *
 * One write is one consistent snapshot: consumers can never observe a new
 * percentage beside a stale charging flag. -1 means no estimate. A malformed
 * line is rejected whole and the previous state is retained.
 *
 * Lock ordering: tob_register_lock -> tob_state_lock. get_property() takes
 * only tob_state_lock; power_supply registration calls take only
 * tob_register_lock, never while tob_state_lock is held, because
 * power_supply_unregister() waits for readers holding tob_state_lock.
 */

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/platform_device.h>
#include <linux/power_supply.h>
#include <linux/slab.h>
#include <linux/string.h>

struct tob_state {
	bool present;
	int status;
	int capacity;
	bool ac_online;
	int time_to_empty;
	int time_to_full;
};

static struct platform_device *tob_pdev;
static struct power_supply *tob_ac;
static struct power_supply *tob_bat;
static DEFINE_MUTEX(tob_register_lock);	/* serializes writers + registration */
static DEFINE_MUTEX(tob_state_lock);	/* guards tob_state */
static struct tob_state tob_state = {
	.present = false,
	.status = POWER_SUPPLY_STATUS_UNKNOWN,
	.capacity = 0,
	.ac_online = true,
	.time_to_empty = -1,
	.time_to_full = -1,
};

static const struct {
	const char *token;
	int status;
} tob_status_tokens[] = {
	{ "charging", POWER_SUPPLY_STATUS_CHARGING },
	{ "discharging", POWER_SUPPLY_STATUS_DISCHARGING },
	{ "full", POWER_SUPPLY_STATUS_FULL },
	{ "not-charging", POWER_SUPPLY_STATUS_NOT_CHARGING },
	{ "unknown", POWER_SUPPLY_STATUS_UNKNOWN },
};

static const char *tob_status_token(int status)
{
	size_t index;

	for (index = 0; index < ARRAY_SIZE(tob_status_tokens); index++)
		if (tob_status_tokens[index].status == status)
			return tob_status_tokens[index].token;
	return "unknown";
}

static enum power_supply_property tob_bat_properties[] = {
	POWER_SUPPLY_PROP_STATUS,
	POWER_SUPPLY_PROP_PRESENT,
	POWER_SUPPLY_PROP_CAPACITY,
	POWER_SUPPLY_PROP_TIME_TO_EMPTY_AVG,
	POWER_SUPPLY_PROP_TIME_TO_FULL_AVG,
	POWER_SUPPLY_PROP_TECHNOLOGY,
	POWER_SUPPLY_PROP_MANUFACTURER,
	POWER_SUPPLY_PROP_MODEL_NAME,
};

static enum power_supply_property tob_ac_properties[] = {
	POWER_SUPPLY_PROP_ONLINE,
};

static int tob_bat_get_property(struct power_supply *psy,
				enum power_supply_property psp,
				union power_supply_propval *val)
{
	int error = 0;

	mutex_lock(&tob_state_lock);
	switch (psp) {
	case POWER_SUPPLY_PROP_STATUS:
		val->intval = tob_state.status;
		break;
	case POWER_SUPPLY_PROP_PRESENT:
		val->intval = tob_state.present ? 1 : 0;
		break;
	case POWER_SUPPLY_PROP_CAPACITY:
		val->intval = tob_state.capacity;
		break;
	case POWER_SUPPLY_PROP_TIME_TO_EMPTY_AVG:
		if (tob_state.time_to_empty < 0)
			error = -ENODATA;
		else
			val->intval = tob_state.time_to_empty;
		break;
	case POWER_SUPPLY_PROP_TIME_TO_FULL_AVG:
		if (tob_state.time_to_full < 0)
			error = -ENODATA;
		else
			val->intval = tob_state.time_to_full;
		break;
	case POWER_SUPPLY_PROP_TECHNOLOGY:
		val->intval = POWER_SUPPLY_TECHNOLOGY_LION;
		break;
	case POWER_SUPPLY_PROP_MANUFACTURER:
		val->strval = "Apple";
		break;
	case POWER_SUPPLY_PROP_MODEL_NAME:
		val->strval = "Mac Battery";
		break;
	default:
		error = -EINVAL;
		break;
	}
	mutex_unlock(&tob_state_lock);
	return error;
}

static int tob_ac_get_property(struct power_supply *psy,
			       enum power_supply_property psp,
			       union power_supply_propval *val)
{
	if (psp != POWER_SUPPLY_PROP_ONLINE)
		return -EINVAL;
	mutex_lock(&tob_state_lock);
	val->intval = tob_state.ac_online ? 1 : 0;
	mutex_unlock(&tob_state_lock);
	return 0;
}

static const struct power_supply_desc tob_bat_desc = {
	.name = "BAT0",
	.type = POWER_SUPPLY_TYPE_BATTERY,
	.properties = tob_bat_properties,
	.num_properties = ARRAY_SIZE(tob_bat_properties),
	.get_property = tob_bat_get_property,
};

static const struct power_supply_desc tob_ac_desc = {
	.name = "ADP0",
	.type = POWER_SUPPLY_TYPE_MAINS,
	.properties = tob_ac_properties,
	.num_properties = ARRAY_SIZE(tob_ac_properties),
	.get_property = tob_ac_get_property,
};

static int tob_parse(const char *buf, size_t count, struct tob_state *next)
{
	bool saw_present = false, saw_ac = false;
	bool saw_status = false, saw_capacity = false;
	char *copy, *cursor, *token;
	int error = -EINVAL;

	next->present = false;
	next->status = POWER_SUPPLY_STATUS_UNKNOWN;
	next->capacity = 0;
	next->ac_online = false;
	next->time_to_empty = -1;
	next->time_to_full = -1;

	copy = kstrndup(buf, count, GFP_KERNEL);
	if (!copy)
		return -ENOMEM;
	cursor = copy;
	while ((token = strsep(&cursor, " \n")) != NULL) {
		char *value;

		if (!*token)
			continue;
		value = strchr(token, '=');
		if (!value)
			goto out;
		*value++ = '\0';
		if (!strcmp(token, "present")) {
			if (kstrtobool(value, &next->present))
				goto out;
			saw_present = true;
		} else if (!strcmp(token, "ac")) {
			if (kstrtobool(value, &next->ac_online))
				goto out;
			saw_ac = true;
		} else if (!strcmp(token, "status")) {
			size_t index;

			for (index = 0; index < ARRAY_SIZE(tob_status_tokens); index++)
				if (!strcmp(value, tob_status_tokens[index].token))
					break;
			if (index == ARRAY_SIZE(tob_status_tokens))
				goto out;
			next->status = tob_status_tokens[index].status;
			saw_status = true;
		} else if (!strcmp(token, "capacity")) {
			if (kstrtoint(value, 10, &next->capacity) ||
			    next->capacity < 0 || next->capacity > 100)
				goto out;
			saw_capacity = true;
		} else if (!strcmp(token, "time_to_empty")) {
			if (kstrtoint(value, 10, &next->time_to_empty) ||
			    next->time_to_empty < -1)
				goto out;
		} else if (!strcmp(token, "time_to_full")) {
			if (kstrtoint(value, 10, &next->time_to_full) ||
			    next->time_to_full < -1)
				goto out;
		} else {
			goto out;
		}
	}
	if (!saw_present || !saw_ac)
		goto out;
	if (next->present && (!saw_status || !saw_capacity))
		goto out;
	error = 0;
out:
	kfree(copy);
	return error;
}

static ssize_t state_show(struct device *dev, struct device_attribute *attr,
			  char *buf)
{
	struct tob_state snapshot;

	mutex_lock(&tob_state_lock);
	snapshot = tob_state;
	mutex_unlock(&tob_state_lock);
	if (!snapshot.present)
		return sysfs_emit(buf, "present=0 ac=%d\n",
				  snapshot.ac_online ? 1 : 0);
	return sysfs_emit(buf,
			  "present=1 status=%s capacity=%d ac=%d time_to_empty=%d time_to_full=%d\n",
			  tob_status_token(snapshot.status), snapshot.capacity,
			  snapshot.ac_online ? 1 : 0, snapshot.time_to_empty,
			  snapshot.time_to_full);
}

static ssize_t state_store(struct device *dev, struct device_attribute *attr,
			   const char *buf, size_t count)
{
	struct tob_state next;
	bool ac_changed, bat_changed;
	int error;

	error = tob_parse(buf, count, &next);
	if (error)
		return error;

	mutex_lock(&tob_register_lock);
	mutex_lock(&tob_state_lock);
	ac_changed = next.ac_online != tob_state.ac_online;
	bat_changed = next.present != tob_state.present ||
		      next.status != tob_state.status ||
		      next.capacity != tob_state.capacity ||
		      next.time_to_empty != tob_state.time_to_empty ||
		      next.time_to_full != tob_state.time_to_full;
	tob_state = next;
	mutex_unlock(&tob_state_lock);

	/* Registration outside tob_state_lock: unregister waits for readers. */
	if (next.present && !tob_bat) {
		struct power_supply_config config = {};
		struct power_supply *battery;

		battery = power_supply_register(&tob_pdev->dev, &tob_bat_desc,
						&config);
		if (IS_ERR(battery)) {
			error = PTR_ERR(battery);
			mutex_lock(&tob_state_lock);
			tob_state.present = false;
			mutex_unlock(&tob_state_lock);
			mutex_unlock(&tob_register_lock);
			return error;
		}
		tob_bat = battery;
		bat_changed = false; /* registration already notified */
	} else if (!next.present && tob_bat) {
		power_supply_unregister(tob_bat);
		tob_bat = NULL;
		bat_changed = false;
	}
	if (bat_changed && tob_bat)
		power_supply_changed(tob_bat);
	if (ac_changed && tob_ac)
		power_supply_changed(tob_ac);
	mutex_unlock(&tob_register_lock);
	return count;
}

static DEVICE_ATTR_ADMIN_RW(state);

static int __init tob_init(void)
{
	struct power_supply_config config = {};
	int error;

	tob_pdev = platform_device_register_simple("try-omarchy-battery", -1,
						   NULL, 0);
	if (IS_ERR(tob_pdev))
		return PTR_ERR(tob_pdev);

	error = device_create_file(&tob_pdev->dev, &dev_attr_state);
	if (error)
		goto unregister_pdev;

	tob_ac = power_supply_register(&tob_pdev->dev, &tob_ac_desc, &config);
	if (IS_ERR(tob_ac)) {
		error = PTR_ERR(tob_ac);
		tob_ac = NULL;
		goto remove_file;
	}
	/* BAT0 appears on the first present=1 snapshot; a desktop Mac never
	 * creates it, so the guest bar has nothing to render. */
	return 0;

remove_file:
	device_remove_file(&tob_pdev->dev, &dev_attr_state);
unregister_pdev:
	platform_device_unregister(tob_pdev);
	return error;
}

static void __exit tob_exit(void)
{
	/* Removing the attribute drains in-flight state_store writers, so
	 * nothing can touch the supplies or the platform device below. */
	device_remove_file(&tob_pdev->dev, &dev_attr_state);
	mutex_lock(&tob_register_lock);
	if (tob_bat) {
		power_supply_unregister(tob_bat);
		tob_bat = NULL;
	}
	mutex_unlock(&tob_register_lock);
	power_supply_unregister(tob_ac);
	platform_device_unregister(tob_pdev);
}

module_init(tob_init);
module_exit(tob_exit);

MODULE_AUTHOR("Try Omarchy");
MODULE_DESCRIPTION("Mirror the host Mac's battery as guest BAT0/ADP0");
MODULE_LICENSE("GPL");
MODULE_VERSION("1.0.0");
