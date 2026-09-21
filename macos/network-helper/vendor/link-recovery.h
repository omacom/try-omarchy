#ifndef OMARCHY_LINK_RECOVERY_H
#define OMARCHY_LINK_RECOVERY_H
#include <stdbool.h>

struct link_recovery {
  unsigned int attached_index;
  unsigned int candidate_index;
  unsigned int retry_ticks;
};
enum link_action { LINK_WAIT, LINK_DETACH, LINK_ATTACH };

/* Two observations debounce device enumeration; an index change invalidates
 * the old vmnet attachment even when the interface name stayed the same. */
static enum link_action link_recovery_step(struct link_recovery *state,
    unsigned int index, bool attached, bool failed) {
  if (attached) {
    if (!index || index != state->attached_index || failed) {
      state->candidate_index = 0;
      state->retry_ticks = 0;
      return LINK_DETACH;
    }
    return LINK_WAIT;
  }
  if (state->retry_ticks && --state->retry_ticks) return LINK_WAIT;
  if (!index || index != state->candidate_index) {
    state->candidate_index = index;
    return LINK_WAIT;
  }
  return LINK_ATTACH;
}
#endif
