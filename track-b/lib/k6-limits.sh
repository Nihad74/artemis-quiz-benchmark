# Resource limits of the k6 container (D36), sourced by k6.sh and check-host.sh so that both use the same defaults.
# CPUs 10-13 are the ones compose.yml leaves free on the local Mac.
K6_CPUSET="${K6_CPUSET:-10-13}"
K6_MEMORY="${K6_MEMORY:-4g}"
