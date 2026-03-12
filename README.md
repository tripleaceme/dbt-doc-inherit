# dbt-doc-inherit

A dbt package that propagates column descriptions along the DAG — define a description once, inherit it downstream.

## The Problem

dbt has a long-standing gap ([#2995](https://github.com/dbt-labs/dbt-core/issues/2995), [#4312](https://github.com/dbt-labs/dbt-core/issues/4312), [#1158](https://github.com/dbt-labs/dbt-core/issues/1158), [Discussion #6527](https://github.com/dbt-labs/dbt-core/discussions/6527)): column descriptions must be manually repeated across every model, even when columns pass through unchanged. A `customer_id` defined at the source layer needs its description copied into staging, intermediate, and mart YAMLs. This is tedious, error-prone, and violates DRY.

Existing tools like [dbt-osmosis](https://github.com/z3z1ma/dbt-osmosis) and [dbt-colibri](https://github.com/b-ned/dbt-colibri) are Python CLI tools that require `pip install`, they can't be added as a dbt dependency.

`dbt-doc-inherit` fills that gap with two approaches:

1. **`dbt run-operation`** — a pure Jinja macro that resolves descriptions and outputs ready-to-paste YAML (no file writes, no Python needed)
2. **Python script** — reads `target/manifest.json` and writes resolved descriptions directly into your YAML files (recommended for bulk population)

Both approaches support:
- **Auto-propagation** by matching column names
- **Explicit inheritance** for renamed/ambiguous columns via `"Inherited: model.column"` directives
- **Formatted audit reports** showing what was inherited and from where

## Installation

Add to your `packages.yml` using either option:

**Option 1: dbt Hub (recommended)**

```yaml
packages:
  - package: tripleaceme/dbt_doc_inherit
    version: [">=1.0.0", "<2.0.0"]
```

**Option 2: Git**

```yaml
packages:
  - git: "https://github.com/tripleaceme/dbt-doc-inherit.git"
    revision: v1.0.0  # or master for latest
```

Then run:

```bash
dbt deps
```

## How It Works

### The Two Approaches

| | `dbt run-operation` | Python script |
|---|---|---|
| **Command** | `dbt run-operation propagate_descriptions --args '{...}'` | `python dbt_packages/dbt_doc_inherit/propagate.py` |
| **Writes to YAML** | No — outputs YAML for you to copy-paste | Yes — writes directly to your YAML files |
| **Requires Python** | No  | Yes — Python 3 (no extra pip packages) |
| **Scope** | You choose source (`from`) and target (`to`) files | Scans entire project DAG automatically |
| **Best for** | Targeted inheritance, quick lookups | Bulk population of an entire project |

### Column Matching

Both approaches use the same resolution logic:

1. **Auto-inherit by name** — if a column in the target has an empty description and the same column name exists in a source model with a description, it inherits automatically
2. **Explicit directive** — for renamed or ambiguous columns, Use `description: "Inherited: model_name.column_name"` in your YAML. The package resolves it to the actual description
3. **Ambiguous detection** — if the same column name exists in multiple source models, it's flagged as ambiguous. Use the `description: "Inherited: model_name.column_name"` directive to specify which source to use

### Status Values

| Status | Meaning | Action |
|--------|---------|--------|
| `inherited` | Auto-matched by column name (single source match) | None — description resolved |
| `resolved` | Resolved from an `"Inherited: model.column"` directive | None — description resolved |
| `override` | Source has a different description than the target (type=all, run-operation only) | Review and accept/reject |
| `ambiguous` | Multiple sources have this column name | Add `"Inherited: model.column"` to specify which |
| `no_match` / `no_source` | No source model has this column name | Document manually or check the `from` file |
| `unresolved` | `"Inherited:"` target model or column not found | Check for typos in model/column name |
| `already_documented` | Column already has its own description | Skipped (hidden from reports) |

---
## The `"Inherited:"` Directive

For columns where auto-matching by name doesn't work (renamed columns, ambiguous matches), write the directive string directly in your YAML:

```yaml
description: "Inherited: <model_name>.<column_name>"
```

### When to Use It

| Scenario | Example | Why auto-matching fails |
|----------|---------|------------------------|
| **Renamed column** | `user_id` -> `customer_id` | Names don't match |
| **Ambiguous column** | `artist_name` exists in `dim_songs`, `fct_streams`, and `dim_artists` | Multiple parents have the same column |
| **Prefixed column** | `artist_total_albums` comes from `dim_artists.total_albums` | Names don't match |

### Examples

```yaml
columns:
  # Renamed column — user_id in source, customer_id here
  - name: customer_id
    description: "Inherited: stg_users.user_id"

  # Ambiguous — specify which parent model
  - name: artist_name
    description: "Inherited: dim_artists.artist_name"

  # Prefixed column — OBT renamed total_albums to artist_total_albums
  - name: artist_total_albums
    description: "Inherited: dim_artists.total_albums"

  # Source table reference
  - name: order_date
    description: "Inherited: raw_orders.order_date"
```

> **Note:** The `"Inherited:"` string is a temporary placeholder. After running either approach, it gets replaced with the actual description from the referenced model.

---

## Approach 1: `dbt run-operation` (Copy-Paste)

### Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `from` | Yes | Source YAML file path(s). Comma-separated for multiple sources |
| `to` | Yes | Target YAML file path where descriptions are needed |
| `type` | Depends | `"missing"` (default) = only empty descriptions. `"all"` = inherit all matching columns from source including overriding matching columns in destination |


### Single Source File

When your target model inherits from one upstream model:

```bash
dbt run-operation propagate_descriptions \
  --args '{"from": "path/to/source.yml", "to": "path/to/target.yml", "type": "missing"}'
```

### Workflow

1. **Run the macro:**
   ```bash
   dbt run-operation propagate_descriptions \
     --args '{"from": "models/marts/_dim_users.yml", "to": "models/obt/_obt_models.yml", "type": "missing"}'
   ```

### Example Output (Single Source)

```
════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
  dbt_doc_inherit: Propagation Report
════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════

  From:   models/staging/_dim_users.yml
  To:     models/marts/_obt_models.yml
  Type:   missing

  Column                     Action     Description                              Source
  ───────────────────────  ─────────  ─────────────────────────────────────────  ──────────────────────
  dim_users.email            inherit    User email address                        stg_users.email
  dim_users.signup_date      inherit    Timestamp when user signed up             stg_users.signup_date
  dim_users.new_metric       no_match

  Source columns available: 9
  Summary: 2 inherited | 0 resolved | 0 overridden | 0 ambiguous | 1 no match | 0 unresolved

────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  YAML Output — Copy into models/marts/_obt_models.yml:
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

# ── dim_users ──
- name: email
  description: "User email address"
- name: signup_date
  description: "Timestamp when user signed up"

════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
  dbt_doc_inherit: Complete. 3 columns processed, 2 descriptions ready.
════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
```

2. **Use the `Inherited:` directive** for ambiguous or renamed columns, then re-run:
   ```yaml
   columns:
     - name: email
       description: "User email address"
     - name: signup_date
       description: "Timestamp when user signed up"
     - name: artist_country
       description: "Inherited: dim_artists.country"  # renamed column
   ```


### Multiple Source Files

When your target model inherits from several upstream models (e.g., an OBT joining users, songs, and streams), pass multiple `from` paths separated by commas:

```bash
dbt run-operation propagate_descriptions \
  --args '{"from": "models/marts/_dim_users.yml,models/marts/_dim_songs.yml,models/marts/_fct_streams.yml", "to": "models/obt/_obt_models.yml", "type": "missing"}'
```

### Example Output (Multiple Sources)

```
════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
  dbt_doc_inherit: Propagation Report
════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════

  From:
    - models/marts/_dim_users.yml
    - models/marts/_dim_songs.yml
    - models/marts/_fct_streams.yml
  To:     models/obt/_obt_models.yml
  Type:   missing

  Column                                   Action     Description                              Source
  ───────────────────────────────────────  ─────────  ─────────────────────────────────────────  ──────────────────────
  obt_customers.email                      inherit    User email address                        dim_users.email
  obt_customers.artist_country             resolve    Standardized country of origin            dim_artists.country
  obt_customers.status                     ambiguous                                            dim_songs, fct_streams
  obt_customers.new_metric                 no_match

  Source columns available: 47
  Summary: 1 inherited | 1 resolved | 0 overridden | 1 ambiguous | 1 no match | 0 unresolved

────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  YAML Output — Copy into models/obt/_obt_models.yml:
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────

# ── obt_customers ──
- name: email
  description: "User email address"
- name: artist_country
  description: "Standardized country of origin"

════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
  dbt_doc_inherit: Complete. 44 columns processed, 35 descriptions ready.
════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
```


---

## Approach 2: Python Script (Auto-Write)

The Python script reads `target/manifest.json` and writes resolved descriptions directly into your YAML files — no copy-pasting required. **This is the recommended approach for bulk population.**

### Prerequisites

- Python 3.6+ (no additional pip packages needed — standard library only)
- A fresh `target/manifest.json` (run `dbt parse` or `dbt run` first)

### Basic Usage

```bash
# Generate the manifest first, then run the script
dbt parse && python dbt_packages/dbt_doc_inherit/propagate.py
```

### What It Does

1. **Scans the entire DAG** — processes every model and seed in your project
2. **Auto-inherits** descriptions for columns with empty descriptions where a single parent match exists
3. **Resolves `"Inherited:"`** directives — replaces `"Inherited: dim_users.username"` with the actual description
4. **Writes directly** to your YAML files — no copy-paste needed
5. **Prints a report** showing only actionable columns (inherited, resolved, ambiguous, unresolved). Already-documented columns are skipped
6. **Idempotent** — safe to run multiple times. Re-running after all descriptions are populated produces zero file changes

### Example Output

First run (descriptions need writing):

```
dbt_doc_inherit: Loading manifest...
dbt_doc_inherit: Built catalog with 32 entities.
dbt_doc_inherit: Processed 192 columns across all models.
  Updated models/obt/_obt_models.yml (2 columns)

  Done: 2 descriptions written across 1 file(s).

============================================================================================================================================
  dbt_doc_inherit: Column Inheritance Report
============================================================================================================================================

  Summary: 2 inherited | 0 resolved | 0 ambiguous | 0 no_source | 0 unresolved

  Column                                  Status     Inherited Description                               Target File                 Source File
  ──────────────────────────────────────  ─────────  ──────────────────────────────────────────────────  ──────────────────────────  ───────────────────────────
  obt_song_performance.is_explicit        inherited  Whether song has explicit content                   models/obt/_obt_models.yml  models/marts/_dim_songs.yml
  obt_song_performance.duration_category  inherited  Duration classification: Short (<3min), Medium (3-  models/obt/_obt_models.yml  models/marts/_dim_songs.yml

============================================================================================================================================
  dbt_doc_inherit: Complete. 2 columns processed (190 already documented, skipped).
```

Subsequent run (everything up to date):

```
dbt_doc_inherit: Loading manifest...
dbt_doc_inherit: Built catalog with 32 entities.
dbt_doc_inherit: Processed 192 columns across all models.

  No descriptions to write.

============================================================================================================================================
  dbt_doc_inherit: Column Inheritance Report
============================================================================================================================================

  Summary: 0 inherited | 0 resolved | 0 ambiguous | 0 no_source | 0 unresolved

  All columns are already documented. Nothing to propagate.

============================================================================================================================================
```


---

## Design Decisions

1. **Two approaches, one resolution logic** — both the Jinja macro and Python script use the same column-matching algorithm. Choose whichever fits your workflow.

2. **Name matching only** for auto-propagation — no SQL parsing. For models with JOINs that create ambiguous columns, users specify which source via `"Inherited:"` directives.

3. **YAML-defined columns only** — the package only processes columns declared in your schema YAML. Columns in the database but not in YAML are invisible to the package.

4. **Direct parents only** for auto-matching — auto-propagation checks direct parent models (via `depends_on`). For multi-hop inheritance, use `"Inherited:"` pointing to the original source.

5. **Model-scoped YAML writes** — the Python script identifies the correct model section in YAML files before writing, ensuring columns with duplicate names across models in the same file are updated correctly.

6. **Python script requires `dbt parse` first** — the script reads `target/manifest.json`, which must be up-to-date. Always run `dbt parse` before the script.

7. **`"Inherited:"` shows in `dbt docs`** — if you run `dbt docs generate` before resolving the directives, the placeholder string appears in the docs site. Resolve all directives first.


## Compatibility

- **dbt Core**: `>=1.6.0, <2.0.0`
- **Adapters**: Any (Snowflake, BigQuery, PostgreSQL, Redshift, Databricks, DuckDB, etc.)
- **Python script**: Python 3.6+

## License

MIT
