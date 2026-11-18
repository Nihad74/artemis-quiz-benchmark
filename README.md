# Artemis quiz benchmark

Benchmark tools of a master's thesis about the quiz module of [Artemis](https://github.com/ls1intum/Artemis). The
thesis compares the relational persistence of quiz answers and statistics (`43bafcee17c`) with JSON persistence and
statistics calculated on demand (`8325896e0b4`).

## Track B: runtime benchmark

`track-b/` measures one synchronized live quiz under load with [k6](https://k6.io): students join, save, and submit
(Phase 1); after the evaluation, tutors open the statistics pages (Phase 2); then students practise at a fixed rate while
the tutors keep the statistics open, and `freshness.mjs` measures how fast the open pages show each practice result
(Phase 3). Before the quiz, the same students submit a text exercise (`control.js`): this control workflow touches no quiz
code, so a difference there is drift between the two Artemis versions. Both commits run in the same server image, on the
same seeded and migrated database, with fixed CPU sets and memory limits.

| Script | Purpose |
|---|---|
| `prepare.sh` | Clones Artemis, creates a worktree for each commit, applies the evaluation timer from `patches/`, and builds the server images (`build-image.sh`). |
| `check-host.sh` | Checks that the CPU sets and memory limits fit the Docker engine and records the host facts. |
| `migration-check.sh` | Seeds the baseline, migrates the database forward, and checks that the quiz results stay the same. Its output folder is the seed of the runs. |
| `run.sh` | Runs both sides in balanced order (A B, B A, ...), writes the raw files of each run, judges each run (`judge.mjs`), and writes `complete.json` when every side has enough valid runs. |
| `night.sh` | Runs one comparison at all scales overnight with frozen inputs (seed hashes, image ids, settings). |
| `report.py` | Writes a Markdown report from the run folders, including failed runs and the hypothesis checks. |
| `test/checks.sh` | Regression checks of run validity, completion, frozen inputs, and the freshness measurement, without a server. |

### Requirements

Docker with Compose v2, Bash 5 or later (macOS ships Bash 3.2; install it with Homebrew), git, Node 24, `jq`, `curl`, Python 3, and a JDK for Gradle. The default CPU
sets need 14 CPUs in the Docker engine; set `ARTEMIS_CPUSET`, `POSTGRES_CPUSET`, and `K6_CPUSET` on other hosts.

### Usage

```bash
cd track-b
results=~/track-b-results

./prepare.sh ~/artemis-track-b
./check-host.sh "$results/host.json"
EVALUATED_DURATION=300 ./migration-check.sh "$results/seed-2000" 2000 \
    artemis-thesis:43bafcee17c artemis-thesis:9.9.3 artemis-thesis:8325896e0b4
REPETITIONS=5 ./run.sh "$results/seed-2000" "$results/e2e-s2000" 2000 \
    artemis-thesis:43bafcee17c artemis-thesis:9.9.3,artemis-thesis:8325896e0b4
python3 report.py --out "$results/results.md" "$results/e2e-s2000"
```

Campaign runs start every server by its frozen image ID. Compose ignores ambient `.env` files and `COMPOSE_*` variables.
`night.sh` skips only matching campaign sets with five valid runs per side. Incomplete requested scales return nonzero.
Server failures stay separate as evidence (`failure.json`), never latency samples or completed sets; they are not retried
automatically. `NIGHT_CHECK=1 ./night.sh <comparison>` checks completion without starting a measurement.

H2 and H3 statistical verdicts require their specified pair, 2000 students, and five valid runs per side. H3 uses the
initial statistics reads after evaluation, with only five overview and five points observations per run.

The usage line at the top of each script lists its parameters and environment variables.

## Notes

- The credentials in `track-b/compose.yml` and `track-b/seed.mjs` are fixed values for a local test server. The server
  listens on `127.0.0.1` only. Do not use them anywhere else.
- `track-b/patches/` changes Artemis source code, which is MIT licensed by TUM Applied Education Technologies.

## License

[MIT](LICENSE)
