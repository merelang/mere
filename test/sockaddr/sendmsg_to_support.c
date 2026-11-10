#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#define __APPLE_USE_RFC_3542
#include <stddef.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <unistd.h>

/* Test-only constants and bounded sockets; messages go through the Mere API. */
long long mere_test_message_socket(long long ipv6) {
  int fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_DGRAM, 0);
  if (fd < 0) return -1;
  struct timeval timeout = { 2, 0 };
  int one = 1;
  if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout) != 0 ||
      setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof timeout) != 0 ||
      (ipv6 && setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof one) != 0)) {
    close(fd);
    return -1;
  }
  return fd;
}

long long mere_test_receive_pktinfo(long long fd, long long ipv6) {
  int one = 1;
  return setsockopt((int)fd, ipv6 ? IPPROTO_IPV6 : IPPROTO_IP,
                   ipv6 ? IPV6_RECVPKTINFO : IP_PKTINFO, &one, sizeof one);
}

long long mere_test_pktinfo_level(long long ipv6) {
  return ipv6 ? IPPROTO_IPV6 : IPPROTO_IP;
}

long long mere_test_pktinfo_type(long long ipv6) {
  return ipv6 ? IPV6_PKTINFO : IP_PKTINFO;
}

long long mere_test_pktinfo_index_offset(long long ipv6) {
  return ipv6 ? offsetof(struct in6_pktinfo, ipi6_ifindex)
              : offsetof(struct in_pktinfo, ipi_ifindex);
}
