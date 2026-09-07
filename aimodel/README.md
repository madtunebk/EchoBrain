# EchoBrain AI model (Candle, CPU)

Experimental offline value model for Echo `TAKE` choices. It reads the
existing SQLite recorder without modifying it and trains a tiny Candle MLP on
CPU. Telemetry-v2 examples also include 23 effective hero stats; older rows
receive zero-filled stats plus an explicit `stats_available=0` feature.

The trained ensemble is optionally wired into live play: `companion` (see
`companion/src/ai.rs`/`scoring.rs`) loads the ensemble from
`data/ai_ensemble/` and, in `ai` score-mode
(`companion score-mode ai|normal|status`), blends its prediction into
`score_card()`'s heuristic total as one extra, conservatively-weighted
component - a nudge, not a replacement. It only ever applies for the exact
(class, spec) the ensemble was trained on (`class_filter`/`spec_filter` in
each member's `metadata.json`); everything else transparently falls back to
pure heuristic scoring regardless of score-mode. `companion` never retrains
or writes to this directory - only `aimodel` does that, offline.

**This release ships a pre-trained PALADIN/dps ensemble** in
`data/ai_ensemble/` but *not* the `data/session.db` it was trained on -
that's real per-player gameplay history, not something to publish. To train
your own (for Paladin or any other class/spec), play with `companion auto`
for a while to build up your own `data/session.db`, then point `aimodel` at
it - see [Commands](#commands) below.

## Commands

Run from the repository root:

```bash
cargo run --release --manifest-path aimodel/Cargo.toml -- inspect
cargo run --release --manifest-path aimodel/Cargo.toml -- train --epochs 250
cargo run --release --manifest-path aimodel/Cargo.toml -- evaluate
cargo run --release --manifest-path aimodel/Cargo.toml -- predict --decision 123
cargo run --release --manifest-path aimodel/Cargo.toml -- train-ensemble --members 5 --epochs 500
cargo run --release --manifest-path aimodel/Cargo.toml -- evaluate-ensemble --members 5
cargo run --release --manifest-path aimodel/Cargo.toml -- predict-ensemble --members 5 --decision 123
cargo run --release --manifest-path aimodel/Cargo.toml -- compare-ensemble --members 5 --limit 1500
cargo run --release --manifest-path aimodel/Cargo.toml -- generate-synthetic --runs 500 --seed 42
```

Defaults are `data/session.db`, `PALADIN`, `dps`, and `aimodel/model/`.
Override them with `--database`, `--class`, `--spec`, and `--model`/`--out`.
`--db` is retained as a shorter alias for `--database`.

**`companion` reads the ensemble from `data/ai_ensemble/`, not the default
`--out` above** - when retraining the ensemble companion actually uses live,
pass `--out data/ai_ensemble` explicitly (as this session's own ensemble
was): `train-ensemble --members 5 --epochs 500 --out data/ai_ensemble`. The
single-model (`--out aimodel/model` etc.) artifacts are for offline
experimentation only and nothing else reads them.

`train-ensemble` keeps one shared, leakage-safe session split and trains each
member on a different bootstrap resample of the training side. Members are
stored below `member_1/` through `member_5/`. Ensemble prediction prints every
member's result, their mean and standard deviation, and how many members voted
for each board option. A large deviation or split vote means low confidence.
`compare-ensemble` scans recent boards in bulk and reports unanimous/strong
agreement, agreement with the existing heuristic, and the most uncertain
decision IDs. This comparison does not pretend unchosen cards have ground-truth
outcomes; accuracy evaluation remains limited to decisions linked to fights.

`generate-synthetic` defaults to `data/session.synthetic.db`, refuses to
overwrite an existing database, and explicitly refuses the real filename
`session.db`. Synthetic records are only for pipeline/stress tests and must
never be merged into real gameplay data.

For example, with an explicit database path:

```bash
cargo run --release --manifest-path aimodel/Cargo.toml -- \
  train --database data/session.db --epochs 500
```

## What it learns

Each usable example is a confirmed `TAKE` decision whose resulting build has
at least one linked fight. The input contains progression context, card flags,
ownership, and the existing scoring components. The target is
`ln(1 + mean linked fight DPS)`.

The train/validation split is by complete session rather than by row. This
prevents fights and neighboring decisions from the same run appearing on both
sides of the evaluation.

## Important limitation

This is a pipeline and data-quality baseline, not yet a trustworthy picker.
Only cards actually taken have outcome labels, so alternatives on the same
board are counterfactual unknowns. DPS is also affected by level, encounter,
gear, player behavior, and duration. Keep deterministic resource rules in
`companion`; do not enable model-driven reroll/banish/freeze yet.
