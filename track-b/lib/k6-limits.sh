# Resource limits of the k6 container (D36), sourced by k6.sh and check-host.sh so that both use the same defaults.
# CPUs 10-13 are the ones compose.yml leaves free on the local Mac.
K6_CPUSET="${K6_CPUSET:-10-13}"
# 3 GB (D41): k6 used at most 0.95 GB at 2000 students in the pilots of 2026-11-17 and 2026-11-18.
K6_MEMORY="${K6_MEMORY:-3g}"
