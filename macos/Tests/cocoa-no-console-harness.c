/* Portable harness for the Cocoa startup console lookup extracted from the QEMU patch. */
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct { int unused; } DisplaySurface;
typedef struct { DisplaySurface *surface; } QemuConsole;
typedef struct { QemuConsole *con; } QKbdState;
typedef struct { QemuConsole *con; } DisplayChangeListener;

static DisplayChangeListener dcl;
static DisplaySurface *surface;
static QKbdState *kbd;
static QKbdState kbd_state;
static QemuConsole *default_console;

static QemuConsole *qemu_console_lookup_default(void)
{
    return default_console;
}

static QKbdState *qkbd_state_init(QemuConsole *con)
{
    kbd_state.con = con;
    return &kbd_state;
}

static DisplaySurface *qemu_console_surface(QemuConsole *console)
{
    /* The patched ui/console.c reads console->surface with no NULL check. */
    if (!console) {
        fputs("qemu_console_surface() called without a console\n", stderr);
        abort();
    }
    return console->surface;
}

static void cocoa_display_startup(void)
{
/* STARTUP */
}

int main(void)
{
    DisplaySurface device_surface = {0};
    QemuConsole console = { &device_surface };

    /* -nodefaults with no display device: QEMU has no console at all. */
    default_console = NULL;
    surface = &device_surface;
    cocoa_display_startup();
    assert(dcl.con == NULL);
    assert(surface == NULL);
    assert(kbd == &kbd_state && kbd_state.con == NULL);

    /* A graphics device: the surface still comes from its console. */
    default_console = &console;
    cocoa_display_startup();
    assert(dcl.con == &console);
    assert(surface == &device_surface);
    assert(kbd == &kbd_state && kbd_state.con == &console);
    return 0;
}
