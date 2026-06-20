#include "Systemd.h"

#include <cstddef>  // offsetof
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace systemd {
namespace {

// Send a single datagram to $NOTIFY_SOCKET, mirroring the protocol in
// src/os/systemd.zig. No-op (and never blocks/throws) when the env var is
// absent — the common case for a non-systemd launch.
//
// See: https://www.freedesktop.org/software/systemd/man/latest/sd_notify.html
void send(const char *message) {
  const char *socket_path = ::getenv("NOTIFY_SOCKET");
  if (!socket_path || socket_path[0] == '\0') return;

  // Only AF_UNIX path ('/') or abstract-namespace ('@') addresses are valid.
  if (socket_path[0] != '/' && socket_path[0] != '@') {
    std::fprintf(stderr,
                 "[ghastty] NOTIFY_SOCKET unsupported address: %s\n",
                 socket_path);
    return;
  }

  const size_t path_len = std::strlen(socket_path);

  struct sockaddr_un addr;
  std::memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;

  if (path_len >= sizeof(addr.sun_path)) {
    std::fprintf(stderr, "[ghastty] NOTIFY_SOCKET path is too long\n");
    return;
  }
  std::memcpy(addr.sun_path, socket_path, path_len);
  // Abstract sockets are encoded with a leading NUL byte in sun_path; the
  // '@' in NOTIFY_SOCKET is the placeholder for that NUL.
  socklen_t addr_len;
  if (addr.sun_path[0] == '@') {
    addr.sun_path[0] = '\0';
    addr_len = static_cast<socklen_t>(offsetof(struct sockaddr_un, sun_path) +
                                      path_len);
  } else {
    addr_len = static_cast<socklen_t>(offsetof(struct sockaddr_un, sun_path) +
                                      path_len + 1);
  }

  const int fd = ::socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
  if (fd < 0) {
    std::fprintf(stderr, "[ghastty] sd_notify: socket() failed\n");
    return;
  }

  const size_t msg_len = std::strlen(message);
  const ssize_t n = ::sendto(fd, message, msg_len, MSG_NOSIGNAL,
                             reinterpret_cast<struct sockaddr *>(&addr),
                             addr_len);
  if (n < 0 || static_cast<size_t>(n) < msg_len)
    std::fprintf(stderr, "[ghastty] sd_notify: short/failed write\n");

  ::close(fd);
}

}  // namespace

void notifyReady() { send("READY=1"); }

void notifyReloading() {
  // MONOTONIC_USEC must be the CLOCK_MONOTONIC timestamp (in microseconds) at
  // which the reload began, so systemd can correlate the later READY=1 with
  // this reload rather than a stale one.
  struct timespec ts;
  if (::clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
    // Fall back to RELOADING=1 alone; systemd accepts it (the monotonic
    // correlation is an optimization, not a requirement).
    send("RELOADING=1");
    return;
  }
  const unsigned long long usec =
      static_cast<unsigned long long>(ts.tv_sec) * 1000000ULL +
      static_cast<unsigned long long>(ts.tv_nsec) / 1000ULL;

  char buf[64];
  std::snprintf(buf, sizeof(buf), "RELOADING=1\nMONOTONIC_USEC=%llu", usec);
  send(buf);
}

}  // namespace systemd
