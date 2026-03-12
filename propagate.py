#!/usr/bin/env python3
"""
dbt-doc-inherit: Propagate column descriptions along the dbt DAG.

Reads target/manifest.json, resolves column inheritance, and writes
descriptions directly into your schema YAML files.

Usage:
    python dbt_packages/dbt_doc_inherit/propagate.py

Run from your dbt project root after `dbt parse` or `dbt run`.
"""

import json
import re
import sys
from pathlib import Path


INHERIT_PATTERN = "Inherited: "


def load_manifest():
    """Load and return the dbt manifest."""
    manifest_path = Path("target/manifest.json")
    if not manifest_path.exists():
        print("Error: target/manifest.json not found.")
        print("Run 'dbt parse' or 'dbt run' first to generate the manifest.")
        sys.exit(1)
    with open(manifest_path) as f:
        return json.load(f)


def build_catalog(manifest):
    """Build a column catalog from the manifest nodes and sources."""
    catalog = {}

    for node_id, node in manifest.get("nodes", {}).items():
        if node.get("resource_type") not in ("model", "seed"):
            continue

        columns = {}
        for col_name, col in node.get("columns", {}).items():
            columns[col_name] = {
                "description": col.get("description", ""),
                "data_type": col.get("data_type", ""),
            }

        file_path = node.get("patch_path") or node.get("original_file_path", "")
        if "://" in file_path:
            file_path = file_path.split("://", 1)[1]

        depends_on = node.get("depends_on", {}).get("nodes", [])

        catalog[node_id] = {
            "name": node["name"],
            "resource_type": node["resource_type"],
            "columns": columns,
            "file_path": file_path,
            "depends_on": depends_on,
        }

    for source_id, source in manifest.get("sources", {}).items():
        columns = {}
        for col_name, col in source.get("columns", {}).items():
            columns[col_name] = {
                "description": col.get("description", ""),
                "data_type": col.get("data_type", ""),
            }

        display_name = f"{source['source_name']}.{source['name']}"
        catalog[source_id] = {
            "name": display_name,
            "resource_type": "source",
            "columns": columns,
            "file_path": source.get("original_file_path", ""),
            "depends_on": [],
        }

    return catalog


def resolve_inheritance(catalog):
    """Resolve column inheritance for all models/seeds."""
    entries = []

    for node_id, node_info in catalog.items():
        if node_info["resource_type"] not in ("model", "seed"):
            continue

        # Build parent column map
        parent_col_map = {}
        for parent_id in node_info["depends_on"]:
            if parent_id not in catalog:
                continue
            parent = catalog[parent_id]
            for pcol_name, pcol_info in parent["columns"].items():
                desc = (pcol_info.get("description") or "").strip()
                if desc and not desc.startswith(INHERIT_PATTERN):
                    parent_col_map.setdefault(pcol_name, []).append({
                        "parent_name": parent["name"],
                        "description": desc,
                        "file_path": parent["file_path"],
                    })

        # Process each column
        for col_name, col_info in node_info["columns"].items():
            desc = (col_info.get("description") or "").strip()
            entry = {
                "model_name": node_info["name"],
                "column_name": col_name,
                "inherited_description": "",
                "target_file_path": node_info["file_path"],
                "source_file_path": "",
                "status": "",
            }

            if desc.startswith(INHERIT_PATTERN):
                # Explicit directive: "Inherited: model.column"
                directive = desc[len(INHERIT_PATTERN):]
                parts = directive.split(".", 1)
                if len(parts) == 2:
                    target_model, target_column = parts
                    found = False
                    for cat_info in catalog.values():
                        name = cat_info["name"]
                        if name == target_model or name.endswith(f".{target_model}"):
                            if target_column in cat_info["columns"]:
                                src_desc = (cat_info["columns"][target_column].get("description") or "").strip()
                                if src_desc and not src_desc.startswith(INHERIT_PATTERN):
                                    entry["status"] = "resolved"
                                    entry["inherited_description"] = src_desc
                                    entry["source_file_path"] = cat_info["file_path"]
                                    found = True
                                    break
                    if not found:
                        entry["status"] = "unresolved"
                else:
                    entry["status"] = "unresolved"

            elif not desc:
                # Empty description — auto-inherit by name
                if col_name in parent_col_map:
                    matches = parent_col_map[col_name]
                    if len(matches) == 1:
                        entry["status"] = "inherited"
                        entry["inherited_description"] = matches[0]["description"]
                        entry["source_file_path"] = matches[0]["file_path"]
                    else:
                        parents = ", ".join(m["parent_name"] for m in matches)
                        entry["status"] = f"ambiguous ({parents})"
                else:
                    entry["status"] = "no_source"
            else:
                entry["status"] = "already_documented"
                entry["inherited_description"] = desc

            entries.append(entry)

    return entries


def write_to_yaml(entries):
    """Write resolved descriptions back to YAML files."""
    # Group writable changes by file
    files_to_update = {}
    for entry in entries:
        if entry["status"] not in ("inherited", "resolved"):
            continue
        fp = entry["target_file_path"]
        files_to_update.setdefault(fp, []).append(entry)

    total_files = 0
    total_cols = 0

    for file_path, updates in files_to_update.items():
        path = Path(file_path)
        if not path.exists():
            print(f"  Warning: {file_path} not found, skipping.")
            continue

        content = path.read_text()
        original = content
        changes = 0

        for update in updates:
            col_name = update["column_name"]
            new_desc = update["inherited_description"].replace("\\", "\\\\").replace('"', '\\"')

            # Case 1: Column has a description line — replace its value
            pattern = rf'(- name: {re.escape(col_name)}\s*\n(\s+)description:\s*)"[^"]*"'
            new_content = re.sub(pattern, rf'\1"{new_desc}"', content, count=1)

            if new_content != content:
                content = new_content
                changes += 1
            else:
                # Case 2: Column exists but has no description line — insert one
                match = re.search(rf'(\s+)(- name: {re.escape(col_name)})\s*\n', content)
                if match:
                    indent = match.group(1) + "  "
                    old_str = match.group(0)
                    new_str = f"{match.group(1)}{match.group(2)}\n{indent}description: \"{new_desc}\"\n"
                    content = content.replace(old_str, new_str, 1)
                    changes += 1

        if changes > 0 and content != original:
            path.write_text(content)
            total_files += 1
            total_cols += changes
            print(f"  Updated {file_path} ({changes} columns)")

    return total_files, total_cols


def print_report(entries):
    """Print a formatted report to the console."""
    # Count by status
    counts = {"inherited": 0, "resolved": 0, "ambiguous": 0, "no_source": 0, "already_documented": 0, "unresolved": 0}
    for e in entries:
        s = e["status"]
        if s in counts:
            counts[s] += 1
        elif s.startswith("ambiguous"):
            counts["ambiguous"] += 1

    # Filter actionable entries
    actionable = [e for e in entries if e["status"] != "already_documented"]

    bar = "=" * 140
    print(f"\n{bar}")
    print("  dbt_doc_inherit: Column Inheritance Report")
    print(bar)
    print()
    print(f"  Summary: {counts['inherited']} inherited | {counts['resolved']} resolved | "
          f"{counts['ambiguous']} ambiguous | {counts['no_source']} no_source | "
          f"{counts['unresolved']} unresolved | {counts['already_documented']} already_documented")
    print()

    if not actionable:
        print("  All columns are already documented. Nothing to propagate.")
        print(f"\n{bar}")
        return

    # Compute column widths
    def col_display(e):
        return f"{e['model_name']}.{e['column_name']}"

    def desc_display(e):
        return (e["inherited_description"][:50] or "—")

    def target_display(e):
        return e["target_file_path"] or "—"

    def source_display(e):
        return e["source_file_path"] or "—"

    w_col = max(6, max(len(col_display(e)) for e in actionable))
    w_status = max(6, max(len(e["status"]) for e in actionable))
    w_desc = max(21, max(len(desc_display(e)) for e in actionable))
    w_target = max(11, max(len(target_display(e)) for e in actionable))
    w_source = max(11, max(len(source_display(e)) for e in actionable))

    # Header
    header = (f"  {'Column':<{w_col}}  {'Status':<{w_status}}  "
              f"{'Inherited Description':<{w_desc}}  {'Target File':<{w_target}}  {'Source File':<{w_source}}")
    separator = f"  {'─' * w_col}  {'─' * w_status}  {'─' * w_desc}  {'─' * w_target}  {'─' * w_source}"

    print(header)
    print(separator)

    for e in actionable:
        row = (f"  {col_display(e):<{w_col}}  {e['status']:<{w_status}}  "
               f"{desc_display(e):<{w_desc}}  {target_display(e):<{w_target}}  {source_display(e):<{w_source}}")
        print(row)

    print(f"\n{bar}")
    print(f"  dbt_doc_inherit: Complete. {len(entries)} columns processed.")


def main():
    print("dbt_doc_inherit: Loading manifest...")
    manifest = load_manifest()

    catalog = build_catalog(manifest)
    print(f"dbt_doc_inherit: Built catalog with {len(catalog)} entities.")

    entries = resolve_inheritance(catalog)
    print(f"dbt_doc_inherit: Processed {len(entries)} columns across all models.")

    # Write changes to YAML files
    writable = [e for e in entries if e["status"] in ("inherited", "resolved")]
    if writable:
        print(f"\n  Writing {len(writable)} descriptions to YAML files...")
        total_files, total_cols = write_to_yaml(entries)
        print(f"  Done: {total_cols} descriptions written across {total_files} file(s).")
    else:
        print("\n  No descriptions to write.")

    # Print report
    print_report(entries)


if __name__ == "__main__":
    main()
