# dbt-doc-inherit

A dbt package that propagates column descriptions along the DAG, so you define a description once and inherit it downstream.

## The Problem

In dbt, column descriptions must be manually repeated in every model's schema YAML — even when columns pass through unchanged. A `customer_id` column defined at the source layer needs its description copied into staging, intermediate, and mart YAMLs. This is tedious, error-prone, and violates DRY.

## How It Works

`dbt-doc-inherit` provides two mechanisms:

1. **Auto-propagation** — columns with empty descriptions automatically inherit from upstream parents when the column name matches exactly and only one parent has that column documented.

2. **Explicit inheritance** via `inherit_desc()` — for renamed columns or ambiguous cases (JOINs where multiple parents share a column name), you specify exactly where to inherit from.

## Installation

Add to your `packages.yml`:

```yaml
packages:
  - local: /path/to/dbt_doc_inherit
```

Or once published to dbt Hub:

```yaml
packages:
  - package: your_org/dbt_doc_inherit
    version: "1.0.0"
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

This scans your entire project and logs a report showing:
- Which columns can auto-inherit descriptions from upstream
- Which columns need explicit `inherit_desc()` directives
- Which columns are already documented

### 2. Use `inherit_desc()` for renamed or ambiguous columns

When a column is renamed between layers (e.g., `user_id` → `customer_id`), or when multiple parents have the same column name (JOINs), add an explicit directive:

```yaml
# models/marts/schema.yml
models:
  - name: dim_customers
    columns:
      - name: customer_id
        description: "{{ dbt_doc_inherit.inherit_desc('stg_customers', 'user_id') }}"
```

This tells `propagate_descriptions` to look up `user_id` from `stg_customers` and resolve the description.

## Report Format

The console report shows actionable entries:

```
column_name                          | status                | inherited_description              | target_file                    | source_file
─────────────────────────────────────|───────────────────────|────────────────────────────────────|────────────────────────────────|─────────────────────────
dim_customers.customer_id            | inherited             | Unique customer identifier         | models/marts/marts.yml         | models/staging/staging.yml
fct_orders.status                    | ambiguous (orders, ..)| —                                  | models/marts/marts.yml         | —
fct_orders.new_metric                | no_source             | —                                  | models/marts/marts.yml         | —
```

### Status Values

| Status | Meaning |
|--------|---------|
| `inherited` | Auto-propagated by matching column name (one parent match) |
| `resolved` | Resolved from an `inherit_desc()` directive |
| `ambiguous` | Multiple parents have this column — use `inherit_desc()` to specify |
| `no_source` | No upstream parent has this column name |
| `unresolved` | `inherit_desc()` target model or column not found |
| `already_documented` | Column already has its own description (excluded from report) |

## When to Use `inherit_desc()`

Use it when auto-propagation can't determine the correct source:

- **Renamed columns**: `user_id` upstream → `customer_id` downstream
- **Ambiguous columns**: A model JOINs two tables that both have a `status` column
- **Cross-layer references**: Inheriting from a model that isn't a direct parent

```yaml
columns:
  # Renamed column
  - name: customer_id
    description: "{{ dbt_doc_inherit.inherit_desc('stg_customers', 'user_id') }}"

  # Ambiguous column (specify which parent)
  - name: status
    description: "{{ dbt_doc_inherit.inherit_desc('orders', 'status') }}"
```

## Known Limitations

1. **No SQL parsing** — auto-propagation matches by column name only. It cannot determine which parent table a column comes from by parsing SQL. For models with JOINs, use `inherit_desc()` for ambiguous columns.

2. **Placeholder in dbt docs** — `inherit_desc()` returns a placeholder string (e.g., `"Inherited: stg_customers.user_id"`) during YAML parsing. `dbt docs generate` will show this placeholder. The fully resolved description is available in the `propagate_descriptions` console report.

3. **YAML-defined columns only** — the package can only process columns that are listed in your schema YAML files. Columns that exist in the database but aren't in YAML are not visible to the package.

4. **Direct parents only** — auto-propagation checks only direct parent models (via `depends_on`), not grandparents. For multi-hop inheritance, each layer must be documented or use `inherit_desc()` pointing to the original source.

## Compatibility

- dbt Core: `>=1.6.0, <2.0.0`
- Adapters: Any (uses cross-database type macros)
- No external dependencies
