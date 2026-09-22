/* Portable harness for the wheel dispatch extracted from the QEMU patch. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

enum { INPUT_EVENT_KIND_BTN, INPUT_EVENT_KIND_REL };
enum { INPUT_BUTTON_WHEEL_UP, INPUT_BUTTON_WHEEL_DOWN, INPUT_BUTTON_LEFT };
enum { INPUT_AXIS_X, INPUT_AXIS_Y, INPUT_AXIS_WHEEL, INPUT_AXIS_HWHEEL };
enum { EV_KEY = 1, EV_REL = 2, REL_WHEEL = 8, REL_HWHEEL = 6,
       REL_WHEEL_HI_RES = 11, REL_HWHEEL_HI_RES = 12,
       VIRTIO_INPUT_CFG_EV_BITS = 0x11 };
typedef struct { uint16_t type, code; uint32_t value; } virtio_input_event;
typedef struct { uint8_t size; union { uint8_t bitmap[128]; } u; } virtio_input_config;
typedef struct { virtio_input_config *rel; } VirtIOInput;
typedef struct { int64_t wheel_remainder, hwheel_remainder; } VirtIOInputHID;
typedef struct {
    int type;
    struct { int button; bool down; } btn;
    struct { int axis, value; } rel;
} QemuInputEvent;

static const unsigned short keymap_button[] = { 0x1a2, 0x1a3, 0x110 };
static const unsigned short axismap_rel[] = { 0, 1, REL_WHEEL_HI_RES, REL_HWHEEL_HI_RES };
static virtio_input_event events[8];
static size_t count;
#define cpu_to_le16(value) ((uint16_t)(value))
#define cpu_to_le32(value) ((uint32_t)(value))
#define qemu_log_mask(...) ((void)0)

virtio_input_config *virtio_input_find_config(VirtIOInput *device,
                                             uint8_t select, uint8_t subsel)
{
    assert(select == VIRTIO_INPUT_CFG_EV_BITS && subsel == EV_REL);
    return device->rel;
}

static void virtio_input_send(VirtIOInput *device, virtio_input_event *event)
{
    (void)device;
    assert(count < sizeof(events) / sizeof(events[0]));
    events[count++] = *event;
}

static void handle(VirtIOInput *vinput, VirtIOInputHID *vhid, QemuInputEvent *evt)
{
    virtio_input_event event;
    count = 0;
    switch (evt->type) {
    /* WHEEL_DISPATCH */
    }
}

static void check(size_t index, int code, int value)
{
    assert(index < count);
    assert(events[index].type == EV_REL);
    assert(events[index].code == code);
    assert((int32_t)events[index].value == value);
}

int main(void)
{
    virtio_input_config config = { .size = 2, .u.bitmap = { 0, (1 << 3) | 1 } };
    VirtIOInput device = { .rel = &config };
    VirtIOInputHID hid = {0};
    QemuInputEvent precise = { .type = INPUT_EVENT_KIND_REL,
                              .rel = { INPUT_AXIS_WHEEL, 30 } };
    QemuInputEvent mouse = { .type = INPUT_EVENT_KIND_BTN,
                            .btn = { INPUT_BUTTON_WHEEL_UP, true } };

    /* A partial trackpad step must not prevent a subsequent mouse detent. */
    handle(&device, &hid, &precise);
    assert(count == 1 && hid.wheel_remainder == 30);
    check(0, REL_WHEEL_HI_RES, 30);
    for (int down = 0; down <= 1; down++) {
        mouse.btn.button = down ? INPUT_BUTTON_WHEEL_DOWN : INPUT_BUTTON_WHEEL_UP;
        mouse.btn.down = true;
        handle(&device, &hid, &mouse);
        assert(count == 2 && hid.wheel_remainder == 30);
        check(0, REL_WHEEL_HI_RES, down ? -120 : 120);
        check(1, REL_WHEEL, down ? -1 : 1);
        mouse.btn.down = false;
        handle(&device, &hid, &mouse);
        for (size_t i = 0; i < count; i++) {
            assert(events[i].type != EV_REL); /* release must not scroll */
        }
    }
    /* Switching back preserves the trackpad's accumulated legacy boundary. */
    precise.rel.value = 90;
    handle(&device, &hid, &precise);
    assert(count == 2 && hid.wheel_remainder == 0);
    check(0, REL_WHEEL_HI_RES, 90);
    check(1, REL_WHEEL, 1);
    precise.rel.axis = INPUT_AXIS_HWHEEL;
    precise.rel.value = -120;
    handle(&device, &hid, &precise);
    assert(count == 2 && hid.hwheel_remainder == 0);
    check(0, REL_HWHEEL_HI_RES, -120);
    check(1, REL_HWHEEL, -1);

    /* Other HID devices must not receive unadvertised high-resolution axes. */
    mouse.btn.down = true;
    for (int mode = 0; mode < 3; mode++) {
        if (mode == 0) config.u.bitmap[1] = 1;
        if (mode == 1) { config.u.bitmap[1] = (1 << 3) | 1; config.size = 1; }
        if (mode == 2) device.rel = NULL;
        handle(&device, &hid, &mouse);
        assert(count == 1);
        check(0, REL_WHEEL, -1);
    }
    mouse.btn.button = INPUT_BUTTON_LEFT;
    handle(&device, &hid, &mouse);
    assert(count == 1 && events[0].type == EV_KEY && events[0].code == 0x110);
    return 0;
}
