/* Keep Erlang's automatic port sessions inside the test supervisor's group.
 * Other programs (including the supervisor) retain normal setsid semantics. */
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

static pid_t isolated_setsid(void) {
  if (strcmp(getprogname(), "erl_child_setup") == 0 ||
      strcmp(getprogname(), "beam.smp") == 0) {
    return getsid(0);
  }
  return setsid();
}

__attribute__((used, section("__DATA,__interpose")))
static const struct {
  const void *replacement;
  const void *original;
} session_guard = {(const void *)isolated_setsid, (const void *)setsid};
