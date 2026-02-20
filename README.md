# dbt-doc-inherit

A pure dbt package that propagates column descriptions along the DAG — define a description once, inherit it downstream.

## The Problem

dbt has a long-standing gap ([#2995](https://github.com/dbt-labs/dbt-core/issues/2995), [#4312](https://github.com/dbt-labs/dbt-core/issues/4312), [#1158](https://github.com/dbt-labs/dbt-core/issues/1158), [Discussion #6527](https://github.com/dbt-labs/dbt-core/discussions/6527)): column descriptions must be manually repeated across every model, even when columns pass through unchanged. A `customer_id` defined at the source layer needs its description copied into staging, intermediate, and mart YAMLs. This is tedious, error-prone, and violates DRY.

No `packages.yml`-installable solution exists today. Existing tools like [dbt-osmosis](https://github.com/z3z1ma/dbt-osmosis) and [dbt-colibri](https://github.com/b-ned/dbt-colibri) are Python CLI tools that require `pip install` — they can't be added as a dbt dependency.

`dbt-doc-inherit` fills that gap as a **pure dbt package**:

- **Auto-propagates** descriptions by matching column names along the DAG
- **Supports explicit inheritance** for renamed/ambiguous columns via `inherit_desc()`
- **Outputs a formatted audit report** when `dbt run-operation propagate_descriptions` is executed

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

## Quick Start

### 1. Run the propagation report

```bash
dbt run-operation propagate_descriptions
```

This scans your entire project's DAG and logs a console report showing:
- Which columns can auto-inherit descriptions from upstream
- Which columns are ambiguous and need explicit `inherit_desc()` directives
- Which columns have no upstream source
- Which columns are already documented

### 2. Use `inherit_desc()` for renamed or ambiguous columns

When a column is renamed between layers (e.g., `user_id` → `customer_id`), or when multiple parents have the same column name (JOINs), add an explicit directive in your schema YAML:

```yaml
# models/marts/schema.yml
models:
  - name: dim_customers
    columns:
      - name: customer_id
        description: "{{ dbt_doc_inherit.inherit_desc('stg_customers', 'user_id') }}"
```

This tells `propagate_descriptions` to look up the `user_id` description from `stg_customers` and resolve it in the report.

### 3. Review and act

The report tells you exactly what can be inherited and from where. Use it to:
- Confirm auto-inherited descriptions are correct
- Fix `unresolved` directives (typo in model/column name)
- Add `inherit_desc()` for any `ambiguous` columns

## `inherit_desc()` Syntax

```
{{ dbt_doc_inherit.inherit_desc('<model_name>', '<column_name>') }}
```

| Parameter | Description | Example |
|-----------|-------------|---------|
| `model_name` | Name of the upstream model or `source_name.table_name` for sources | `stg_customers`, `raw.orders` |
| `column_name` | Name of the column in the upstream model | `user_id`, `status` |

### When to use it

| Scenario | Example | Why auto-propagation fails |
|----------|---------|---------------------------|
| **Renamed column** | `user_id` → `customer_id` | Names don't match |
| **Ambiguous column** | `status` exists in both `orders` and `delivery` after a JOIN | Multiple parents have the same column |
| **Cross-layer reference** | Inherit from a grandparent model | Auto-propagation only checks direct parents |

```yaml
columns:
  # Renamed column
  - name: customer_id
    description: "{{ dbt_doc_inherit.inherit_desc('stg_customers', 'user_id') }}"

  # Ambiguous column — specify which parent
  - name: status
    description: "{{ dbt_doc_inherit.inherit_desc('orders', 'status') }}"

  # Source column
  - name: order_date
    description: "{{ dbt_doc_inherit.inherit_desc('raw.orders', 'order_date') }}"
```

## Report Format

The console output from `propagate_descriptions` shows actionable entries (columns that are already documented are excluded):

```
═══════════════════════════════════════════════════════════════════════════════════════════════
  dbt_doc_inherit: Column Inheritance Report
═══════════════════════════════════════════════════════════════════════════════════════════════

  Summary: 12 inherited | 3 resolved | 2 ambiguous | 1 no_source | 0 unresolved | 45 already_documented

  column_name                          | status                | inherited_description              | target_file                    | source_file
  ─────────────────────────────────────|───────────────────────|────────────────────────────────────|────────────────────────────────|─────────────────────────
  dim_customers.customer_id            | resolved              | Unique customer identifier         | models/marts/marts.yml         | models/staging/staging.yml
  fct_orders.order_id                  | inherited             | Primary key for orders             | models/marts/marts.yml         | models/staging/staging.yml
  fct_orders.status                    | ambiguous (orders,..) | —                                  | models/marts/marts.yml         | —
  fct_orders.new_metric                | no_source             | —                                  | models/marts/marts.yml         | —

═══════════════════════════════════════════════════════════════════════════════════════════════
```

### Status Values

| Status | Meaning | Action needed |
|--------|---------|---------------|
| `inherited` | Auto-propagated by matching column name (one parent match) | None — description found |
| `resolved` | Resolved from an `inherit_desc()` directive | None — description found |
| `ambiguous` | Multiple parents have this column with descriptions | Add `inherit_desc()` to specify which parent |
| `no_source` | No upstream parent has this column name documented | Document it manually or add `inherit_desc()` |
| `unresolved` | `inherit_desc()` target model or column not found | Check for typos in model/column name |
| `already_documented` | Column already has its own description | None — excluded from report |

## Design Decisions

1. **`inherit_desc()` in YAML** — returns a placeholder `"Inherited: model.column"` during the parse phase. The `propagate_descriptions` run-operation detects and resolves these during the execute phase. **Caveat**: `dbt docs generate` will show the placeholder text, not the resolved description. The resolved description is only visible in the console report.

2. **Name matching only** for auto-propagation — no SQL parsing (that would require Python/SQLGlot, making this a CLI tool instead of a dbt package). For models with JOINs, users must use `inherit_desc()` for ambiguous or renamed columns.

3. **Console-only output** — the report is logged to the terminal for the developer to review. No database tables are created.

## Known Limitations

1. **No SQL parsing** — auto-propagation matches by column name only. It cannot parse SQL to determine which parent table a column originates from (e.g., `SELECT or.status FROM orders or JOIN delivery de ...`). For models with JOINs, use `inherit_desc()` for any ambiguous columns.

2. **Placeholder in dbt docs** — `inherit_desc()` returns a placeholder string (e.g., `"Inherited: stg_customers.user_id"`) during YAML parsing. `dbt docs generate` will display this placeholder. The fully resolved description is available in the `propagate_descriptions` console report.

3. **YAML-defined columns only** — the package can only process columns that are listed in your schema YAML files. Columns that exist in the database but aren't declared in YAML are invisible to the package.

4. **Direct parents only** — auto-propagation checks only direct parent models (via `depends_on`), not grandparents. For multi-hop inheritance, either document each intermediate layer or use `inherit_desc()` pointing to the original source.

## Compatibility

- **dbt Core**: `>=1.6.0, <2.0.0`
- **Adapters**: Any (Snowflake, BigQuery, PostgreSQL, Redshift, Databricks, DuckDB, etc.)
- **Dependencies**: None — pure Jinja, no external packages
