// Offline: status producer with made-up permissions and no event tap/devices.
#define main helper_main
#define UBUNTU_GESTURES 1
#include "omacvm-gestures.c"
#undef main
static int permissions(void) { return PERM_AX; }
int main(int argc, char **argv) {
  if (argc != 2) return 2;
  setenv("HOME", argv[1], 1); permFn = permissions;
  for (int i = 0; i < MAX_CLIENTS; i++) clients[i].fd = -1;
  reportStatus(NULL, NULL);
  return 0;
}
