# dbt-doc-inherit

A dbt package that propagates column descriptions along the DAG — define a description once, inherit it downstream.

## The Problem

dbt has a long-standing gap ([#2995](https://github.com/dbt-labs/dbt-core/issues/2995), [#4312](https://github.com/dbt-labs/dbt-core/issues/4312), [#1158](https://github.com/dbt-labs/dbt-core/issues/1158), [Discussion #6527](https://github.com/dbt-labs/dbt-core/discussions/6527)): column descriptions must be manually repeated across every model, even when columns pass through unchanged. A `customer_id` defined at the source layer needs its description copied into staging, intermediate, and mart YAMLs. This is tedious, error-prone, and violates DRY.

Existing tools like [dbt-osmosis](https://github.com/z3z1ma/dbt-osmosis) and [dbt-colibri](https://github.com/b-ned/dbt-colibri) are Python CLI tools that require `pip install` — they can't be added as a dbt dependency.

`dbt-doc-inherit` fills that gap with two approaches:

1. **`dbt run-operation`** — a pure Jinja macro that resolves descriptions and outputs ready-to-paste YAML (no file writes, no Python needed)
2. **Python script** — reads `target/manifest.json` and writes resolved descriptions directly into your YAML files (recommended for bulk population)

Both approaches support:
- **Auto-propagation** by matching column names
- **Explicit inheritance** for renamed/ambiguous columns via `"Inherited: model.column"` directives
- **Formatted audit reports** showing what was inherited and from where

## Installation

Add to your `packages.yml`:

```yaml
packages:
  - git: "https://github.com/tripleaceme/dbt-doc-inherit.git"
    revision: master
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
| **Requires Python** | No — pure Jinja | Yes — Python 3 (no extra pip packages) |
| **Scope** | You choose source (`from`) and target (`to`) files | Scans entire project DAG automatically |
| **Best for** | Targeted inheritance, quick lookups | Bulk population of an entire project |

### Column Matching

Both approaches use the same resolution logic:

1. **Auto-inherit by name** — if a column in the target has an empty description and the same column name exists in a source model with a description, it inherits automatically
2. **Explicit directive** — for renamed or ambiguous columns, write `description: "Inherited: model_name.column_name"` in your YAML. The package resolves it to the actual description
3. **Ambiguous detection** — if the same column name exists in multiple source models, it's flagged as ambiguous. Use the `"Inherited:"` directive to specify which source to use

### Status Values

| Status | Meaning | Action |
|--------|---------|--------|
| `inherited` | Auto-matched by column name (single source match) | None — description resolved |
| `resolved` | Resolved from an `"Inherited: model.column"` directive | None — description resolved |
| `override` | Source has a different description than the target (type=all) | Review and accept/reject |
| `ambiguous` | Multiple sources have this column name | Add `"Inherited: model.column"` to specify which |
| `no_match` | No source model has this column name | Document manually or check the `from` file |
| `unresolved` | `"Inherited:"` target model or column not found | Check for typos in model/column name |
| `already_documented` | Column already has its own description | Skipped |

---

## Approach 1: `dbt run-operation` (Copy-Paste)

### Basic Usage

```bash
dbt run-operation propagate_descriptions \
  --args '{"from": "models/staging/_stg_users.yml", "to": "models/marts/_dim_users.yml", "type": "missing"}'
```

### Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `from` | Yes | Source YAML file path(s). Comma-separated for multiple sources |
| `to` | Yes | Target YAML file path where descriptions are needed |
| `type` | No | `"missing"` (default) = only empty descriptions. `"all"` = inherit all matching columns, including overrides |

### Multiple Source Files

When your target model inherits from several upstream models, pass multiple `from` paths separated by commas:

```bash
dbt run-operation propagate_descriptions \
  --args '{"from": "models/marts/_dim_users.yml,models/marts/_dim_songs.yml,models/marts/_fct_streams.yml", "to": "models/obt/_obt_models.yml", "type": "missing"}'
```

### Example Output

```
════════════════════════════════════════════════════════════════════════════════════════════════════════
  dbt_doc_inherit: Propagation Report
════════════════════════════════════════════════════════════════════════════════════════════════════════

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
  Summary: 32 inherited | 3 resolved | 0 overridden | 5 ambiguous | 2 no match | 0 unresolved

────────────────────────────────────────────────────────────────────────────────────────────────────────
  YAML Output — Copy into models/obt/_obt_models.yml:
────────────────────────────────────────────────────────────────────────────────────────────────────────

# ── obt_customers ──
- name: email
  description: "User email address"
- name: artist_country
  description: "Standardized country of origin"

════════════════════════════════════════════════════════════════════════════════════════════════════════
  dbt_doc_inherit: Complete. 44 columns processed, 35 descriptions ready.
════════════════════════════════════════════════════════════════════════════════════════════════════════
```

### Workflow

1. **List your columns** in the target YAML with empty descriptions:
   ```yaml
   columns:
     - name: email           # empty — will auto-inherit
     - name: signup_date     # empty — will auto-inherit
     - name: artist_country
       description: "Inherited: dim_artists.country"  # renamed column — explicit directive
   ```

2. **Run the macro:**
   ```bash
   dbt run-operation propagate_descriptions \
     --args '{"from": "models/marts/_dim_users.yml", "to": "models/obt/_obt_models.yml", "type": "missing"}'
   ```

3. **Copy the YAML output** from the terminal into your target YAML file, replacing the empty/`"Inherited:"` entries with the resolved descriptions.

4. **For ambiguous columns**, add an `"Inherited:"` directive specifying which source model to use, then re-run.

---

## Approach 2: Python Script (Auto-Write)

The Python script reads `target/manifest.json` and writes resolved descriptions directly into your YAML files — no copy-pasting required. This is the recommended approach for bulk population.

### Prerequisites

- Python 3 (no additional pip packages needed)
- A fresh `target/manifest.json` (run `dbt parse` or `dbt run` first)

### Basic Usage

```bash
# Generate the manifest first
dbt parse

# Run the script from your dbt project root
python dbt_packages/dbt_doc_inherit/propagate.py
```

### What It Does

1. **Scans the entire DAG** — processes every model and seed in your project
2. **Auto-inherits** descriptions for columns with empty descriptions where a single parent match exists
3. **Resolves `"Inherited:"`** directives — replaces `"Inherited: dim_users.username"` with the actual description
4. **Writes directly** to your YAML files — no copy-paste needed
5. **Prints a report** showing what was inherited, what's ambiguous, and what's unresolved

### Workflow

1. **List your columns** in your YAML files with empty descriptions (same as Approach 1)

2. **Run the script:**
   ```bash
   dbt parse && python dbt_packages/dbt_doc_inherit/propagate.py
   ```

3. **Check the report** — the script tells you which columns were written and which are ambiguous

4. **For ambiguous columns**, add `"Inherited:"` directives to your YAML:
   ```yaml
   - name: artist_name
     description: "Inherited: dim_artists.artist_name"
   ```

5. **Re-run** the script to resolve the directives:
   ```bash
   dbt parse && python dbt_packages/dbt_doc_inherit/propagate.py
   ```
   The script replaces `"Inherited: dim_artists.artist_name"` with the actual description (e.g., `"Artist or band name"`) directly in your YAML file.

### Example

**Before** running the script:
```yaml
columns:
  - name: email              # no description
  - name: artist_country
    description: "Inherited: dim_artists.country"
```

**After** running the script:
```yaml
columns:
  - name: email
    description: "User email address"
  - name: artist_country
    description: "Standardized country of origin"
```

---

## The `"Inherited:"` Directive

For columns where auto-matching by name doesn't work (renamed columns, ambiguous matches), write the directive string directly in your YAML:

```yaml
description: "Inherited: <model_name>.<column_name>"
```

### When to Use It

| Scenario | Example | Why auto-matching fails |
|----------|---------|------------------------|
| **Renamed column** | `user_id` → `customer_id` | Names don't match |
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

### The `inherit_desc()` Macro

For programmatic use in SQL models or other Jinja contexts (not YAML descriptions), the package also provides:

```sql
{{ dbt_doc_inherit.inherit_desc('dim_artists', 'country') }}
{# Returns: "Inherited: dim_artists.country" #}
```

> **Important:** dbt does not evaluate custom package macros in YAML description fields. Always write the `"Inherited: model.column"` string directly — do not use `{{ inherit_desc() }}` in YAML.

---

## Design Decisions

1. **Two approaches, one resolution logic** — both the Jinja macro and Python script use the same column-matching algorithm. Choose whichever fits your workflow.

2. **Name matching only** for auto-propagation — no SQL parsing. For models with JOINs that create ambiguous columns, users specify which source via `"Inherited:"` directives.

3. **YAML-defined columns only** — the package only processes columns declared in your schema YAML. Columns in the database but not in YAML are invisible to the package.

4. **Direct parents only** for auto-matching — auto-propagation checks direct parent models (via `depends_on`). For multi-hop inheritance, use `"Inherited:"` pointing to the original source.

## Known Limitations

1. **No SQL parsing** — auto-propagation matches by column name only. For JOINs that produce duplicate column names across parents, use `"Inherited:"` to disambiguate.

2. **`dbt run-operation` cannot write files** — dbt's Jinja sandbox blocks filesystem access. The macro outputs YAML to the console for manual copy-paste. Use the Python script if you want automatic file writes.

3. **Python script requires `dbt parse` first** — the script reads `target/manifest.json`, which must be up-to-date. Always run `dbt parse` before the script.

4. **`"Inherited:"` shows in `dbt docs`** — if you run `dbt docs generate` before resolving the directives, the placeholder string appears in the docs site. Resolve all directives first.

## Compatibility

- **dbt Core**: `>=1.6.0, <2.0.0`
- **Adapters**: Any (Snowflake, BigQuery, PostgreSQL, Redshift, Databricks, DuckDB, etc.)
- **Dependencies**: None — no external dbt packages required
- **Python script**: Python 3.6+ (standard library only, no pip packages)

## License

MIT
