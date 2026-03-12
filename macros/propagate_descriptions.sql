{% macro propagate_descriptions() %}
    {#--
        Propagate column descriptions from source YAML file(s) to a target YAML.

        Args (passed via --args):
            from:  Source YAML file path(s). Comma-separated for multiple sources.
            to:    Target YAML file path (where descriptions are needed)
            type:  "all" (inherit all matching columns) or "missing" (only empty descriptions)

        Usage:
            Single source:
                dbt run-operation propagate_descriptions \
                  --args '{"from": "models/marts/_dim_users.yml", "to": "models/obt/_obt_models.yml", "type": "all"}'

            Multiple sources:
                dbt run-operation propagate_descriptions \
                  --args '{"from": "models/marts/_dim_users.yml,models/marts/_dim_songs.yml,models/marts/_fct_streams.yml", "to": "models/obt/_obt_models.yml", "type": "missing"}'

        For renamed or ambiguous columns, use this placeholder in your YAML:
            description: "Inherited: dim_users.username"

        The macro resolves descriptions from the dbt graph and outputs
        ready-to-paste YAML snippets. Copy the output into your target file.
    --#}

    {% if execute %}

        {% set from_raw  = kwargs.get('from', '') %}
        {% set to_path   = kwargs.get('to', '') %}
        {% set mode      = kwargs.get('type', 'missing') %}
        {% set inherit_pattern = 'Inherited: ' %}

        {# ── Validate arguments ── #}
        {% if not from_raw or not to_path %}
            {% set msg = [] %}
            {% do msg.append("") %}
            {% do msg.append("  Error: 'from' and 'to' arguments are required.") %}
            {% do msg.append("") %}
            {% do msg.append("  Usage:") %}
            {% do msg.append("    dbt run-operation propagate_descriptions \\") %}
            {% do msg.append('      --args \'{"from": "models/marts/_dim_users.yml", "to": "models/obt/_obt_models.yml", "type": "all"}\'') %}
            {% do msg.append("") %}
            {% do msg.append("  Multiple sources:") %}
            {% do msg.append("    dbt run-operation propagate_descriptions \\") %}
            {% do msg.append('      --args \'{"from": "models/marts/_dim_users.yml,models/marts/_dim_songs.yml", "to": "models/obt/_obt_models.yml"}\'') %}
            {% do msg.append("") %}
            {% do msg.append("  Arguments:") %}
            {% do msg.append("    from   Source YAML file path(s), comma-separated for multiple") %}
            {% do msg.append("    to     Target YAML file path (where descriptions are needed)") %}
            {% do msg.append('    type   "all" = inherit all matching columns | "missing" = only empty descriptions (default)') %}
            {% do msg.append("") %}
            {{ print(msg | join('\n')) }}
            {{ return('') }}
        {% endif %}

        {% if mode not in ['all', 'missing'] %}
            {{ print("  Error: 'type' must be 'all' or 'missing'. Got: " ~ mode) }}
            {{ return('') }}
        {% endif %}

        {# ── Parse comma-separated from paths ── #}
        {% set from_paths = [] %}
        {% for p in from_raw.split(',') %}
            {% do from_paths.append(p | trim) %}
        {% endfor %}

        {# ── Step 1: Collect described columns from all 'from' files ── #}
        {% set from_columns = {} %}

        {% for node in graph.nodes.values() %}
            {% if node.resource_type in ['model', 'seed'] %}
                {% set fp = node.patch_path | default(node.original_file_path, true) %}
                {% set np = fp.split('://')[1] if (fp and '://' in fp) else fp %}

                {% set matched = namespace(found=false) %}
                {% for from_path in from_paths %}
                    {% if np and (np == from_path or np.endswith('/' ~ from_path) or from_path.endswith(np)) %}
                        {% set matched.found = true %}
                    {% endif %}
                {% endfor %}

                {% if matched.found %}
                    {% for col_name, col in node.columns.items() %}
                        {% set desc = (col.description | default('', true)) | trim %}
                        {% if desc | length > 0 and not desc.startswith(inherit_pattern) %}
                            {% if col_name not in from_columns %}
                                {% do from_columns.update({col_name: []}) %}
                            {% endif %}
                            {% do from_columns[col_name].append({
                                'model': node.name,
                                'description': desc
                            }) %}
                        {% endif %}
                    {% endfor %}
                {% endif %}
            {% endif %}
        {% endfor %}

        {% for source in graph.sources.values() %}
            {% set fp = source.original_file_path | default('', true) %}

            {% set matched = namespace(found=false) %}
            {% for from_path in from_paths %}
                {% if fp and (fp == from_path or fp.endswith('/' ~ from_path) or from_path.endswith(fp)) %}
                    {% set matched.found = true %}
                {% endif %}
            {% endfor %}

            {% if matched.found %}
                {% set src_display = source.source_name ~ '.' ~ source.name %}
                {% for col_name, col in source.columns.items() %}
                    {% set desc = (col.description | default('', true)) | trim %}
                    {% if desc | length > 0 %}
                        {% if col_name not in from_columns %}
                            {% do from_columns.update({col_name: []}) %}
                        {% endif %}
                        {% do from_columns[col_name].append({
                            'model': src_display,
                            'description': desc
                        }) %}
                    {% endif %}
                {% endfor %}
            {% endif %}
        {% endfor %}

        {# ── Step 2: Build full catalog for "Inherited:" directive resolution ── #}
        {% set full_catalog = {} %}

        {% for node in graph.nodes.values() %}
            {% if node.resource_type in ['model', 'seed'] %}
                {% for col_name, col in node.columns.items() %}
                    {% set desc = (col.description | default('', true)) | trim %}
                    {% if desc | length > 0 and not desc.startswith(inherit_pattern) %}
                        {% do full_catalog.update({node.name ~ '.' ~ col_name: desc}) %}
                    {% endif %}
                {% endfor %}
            {% endif %}
        {% endfor %}

        {% for source in graph.sources.values() %}
            {% set src_display = source.source_name ~ '.' ~ source.name %}
            {% for col_name, col in source.columns.items() %}
                {% set desc = (col.description | default('', true)) | trim %}
                {% if desc | length > 0 %}
                    {% do full_catalog.update({
                        src_display ~ '.' ~ col_name: desc,
                        source.name ~ '.' ~ col_name: desc
                    }) %}
                {% endif %}
            {% endfor %}
        {% endfor %}

        {# ── Step 3: Process target models from the 'to' file ── #}
        {% set results = [] %}

        {% for node in graph.nodes.values() %}
            {% if node.resource_type in ['model', 'seed'] %}
                {% set fp = node.patch_path | default(node.original_file_path, true) %}
                {% set np = fp.split('://')[1] if (fp and '://' in fp) else fp %}

                {% if np and (np == to_path or np.endswith('/' ~ to_path) or to_path.endswith(np)) %}

                    {% for col_name, col in node.columns.items() %}
                        {% set desc = (col.description | default('', true)) | trim %}
                        {% set result = namespace(
                            action='skip',
                            new_desc='',
                            source_ref=''
                        ) %}

                        {# Case 1: "Inherited: model.column" directive #}
                        {% if desc.startswith(inherit_pattern) %}
                            {% set directive = desc[inherit_pattern | length:] %}
                            {% if directive in full_catalog %}
                                {% set result.action = 'resolve' %}
                                {% set result.new_desc = full_catalog[directive] %}
                                {% set result.source_ref = directive %}
                            {% else %}
                                {% set result.action = 'unresolved' %}
                                {% set result.source_ref = directive %}
                            {% endif %}

                        {# Case 2: Empty description — auto-inherit by column name #}
                        {% elif desc | length == 0 %}
                            {% if col_name in from_columns %}
                                {% set matches = from_columns[col_name] %}
                                {% if matches | length == 1 %}
                                    {% set result.action = 'inherit' %}
                                    {% set result.new_desc = matches[0].description %}
                                    {% set result.source_ref = matches[0].model ~ '.' ~ col_name %}
                                {% else %}
                                    {% set model_names = [] %}
                                    {% for m in matches %}
                                        {% do model_names.append(m.model) %}
                                    {% endfor %}
                                    {% set result.action = 'ambiguous' %}
                                    {% set result.source_ref = model_names | join(', ') %}
                                {% endif %}
                            {% else %}
                                {% set result.action = 'no_match' %}
                            {% endif %}

                        {# Case 3: Has description #}
                        {% else %}
                            {% if mode == 'all' and col_name in from_columns %}
                                {% set matches = from_columns[col_name] %}
                                {% if matches | length == 1 %}
                                    {% if matches[0].description != desc %}
                                        {% set result.action = 'override' %}
                                        {% set result.new_desc = matches[0].description %}
                                        {% set result.source_ref = matches[0].model ~ '.' ~ col_name %}
                                    {% endif %}
                                {% endif %}
                            {% endif %}
                        {% endif %}

                        {% if result.action != 'skip' %}
                            {% do results.append({
                                'model': node.name,
                                'column': col_name,
                                'action': result.action,
                                'new_desc': result.new_desc,
                                'source_ref': result.source_ref,
                                'old_desc': desc
                            }) %}
                        {% endif %}
                    {% endfor %}

                {% endif %}
            {% endif %}
        {% endfor %}

        {# ── Step 4: Count results ── #}
        {% set c = namespace(inherit=0, resolve=0, override=0, ambiguous=0, no_match=0, unresolved=0) %}
        {% for r in results %}
            {% if r.action == 'inherit' %}{% set c.inherit = c.inherit + 1 %}
            {% elif r.action == 'resolve' %}{% set c.resolve = c.resolve + 1 %}
            {% elif r.action == 'override' %}{% set c.override = c.override + 1 %}
            {% elif r.action == 'ambiguous' %}{% set c.ambiguous = c.ambiguous + 1 %}
            {% elif r.action == 'no_match' %}{% set c.no_match = c.no_match + 1 %}
            {% elif r.action == 'unresolved' %}{% set c.unresolved = c.unresolved + 1 %}
            {% endif %}
        {% endfor %}

        {% set writable = [] %}
        {% for r in results %}
            {% if r.action in ['inherit', 'resolve', 'override'] %}
                {% do writable.append(r) %}
            {% endif %}
        {% endfor %}

        {# ── Step 5: Build full output using print() (no timestamps) ── #}
        {% set out = [] %}
        {% set bar = "═" * 120 %}
        {% set thin = "─" * 120 %}

        {% do out.append("") %}
        {% do out.append(bar) %}
        {% do out.append("  dbt_doc_inherit: Propagation Report") %}
        {% do out.append(bar) %}
        {% do out.append("") %}
        {% if from_paths | length == 1 %}
            {% do out.append("  From:   " ~ from_paths[0]) %}
        {% else %}
            {% do out.append("  From:") %}
            {% for fp in from_paths %}
                {% do out.append("    - " ~ fp) %}
            {% endfor %}
        {% endif %}
        {% do out.append("  To:     " ~ to_path) %}
        {% do out.append("  Type:   " ~ mode) %}
        {% do out.append("") %}

        {# Report table #}
        {% if results | length > 0 %}
            {% set w = namespace(col=6, action=6, desc=11, src=6) %}
            {% for r in results %}
                {% set cd = r.model ~ '.' ~ r.column %}
                {% set dd = r.new_desc[:50] if r.new_desc else '' %}
                {% if cd | length > w.col %}{% set w.col = cd | length %}{% endif %}
                {% if r.action | length > w.action %}{% set w.action = r.action | length %}{% endif %}
                {% if dd | length > w.desc %}{% set w.desc = dd | length %}{% endif %}
                {% if r.source_ref | length > w.src %}{% set w.src = r.source_ref | length %}{% endif %}
            {% endfor %}

            {# Header #}
            {% do out.append(
                "  " ~ 'Column' ~ ' ' * (w.col - 6)
                ~ "  " ~ 'Action' ~ ' ' * (w.action - 6)
                ~ "  " ~ 'Description' ~ ' ' * (w.desc - 11)
                ~ "  " ~ 'Source' ~ ' ' * (w.src - 6)
            ) %}

            {# Separator #}
            {% set sep = namespace(col='', action='', desc='', src='') %}
            {% for i in range(w.col) %}{% set sep.col = sep.col ~ '─' %}{% endfor %}
            {% for i in range(w.action) %}{% set sep.action = sep.action ~ '─' %}{% endfor %}
            {% for i in range(w.desc) %}{% set sep.desc = sep.desc ~ '─' %}{% endfor %}
            {% for i in range(w.src) %}{% set sep.src = sep.src ~ '─' %}{% endfor %}
            {% do out.append("  " ~ sep.col ~ "  " ~ sep.action ~ "  " ~ sep.desc ~ "  " ~ sep.src) %}

            {# Rows #}
            {% for r in results %}
                {% set cv = r.model ~ '.' ~ r.column %}
                {% set dv = r.new_desc[:50] if r.new_desc else '' %}
                {% do out.append(
                    "  " ~ cv ~ ' ' * (w.col - cv | length)
                    ~ "  " ~ r.action ~ ' ' * (w.action - r.action | length)
                    ~ "  " ~ dv ~ ' ' * (w.desc - dv | length)
                    ~ "  " ~ r.source_ref ~ ' ' * (w.src - r.source_ref | length)
                ) %}
            {% endfor %}
        {% else %}
            {% do out.append("  No columns to process. Ensure your target YAML has '- name: column_name' entries.") %}
        {% endif %}

        {# Summary after the table #}
        {% do out.append("") %}
        {% do out.append("  Source columns available: " ~ from_columns | length) %}
        {% do out.append("  Summary: " ~ c.inherit ~ " inherited | " ~ c.resolve ~ " resolved | " ~ c.override ~ " overridden | " ~ c.ambiguous ~ " ambiguous | " ~ c.no_match ~ " no match | " ~ c.unresolved ~ " unresolved") %}

        {# YAML snippets #}
        {% if writable | length > 0 %}
            {% do out.append("") %}
            {% do out.append(thin) %}
            {% do out.append("  YAML Output — Copy into " ~ to_path ~ ":") %}
            {% do out.append(thin) %}

            {# Group by model #}
            {% set models_seen = [] %}
            {% for r in writable %}
                {% if r.model not in models_seen %}
                    {% do models_seen.append(r.model) %}
                {% endif %}
            {% endfor %}

            {% for model_name in models_seen %}
                {% do out.append('') %}
                {% do out.append('# ── ' ~ model_name ~ ' ──') %}
                {% for r in writable %}
                    {% if r.model == model_name %}
                        {% set escaped = r.new_desc | replace('"', '\\"') %}
                        {% do out.append('- name: ' ~ r.column) %}
                        {% do out.append('  description: "' ~ escaped ~ '"') %}
                    {% endif %}
                {% endfor %}
            {% endfor %}

            {% do out.append("") %}
        {% elif results | length > 0 %}
            {% do out.append("") %}
            {% do out.append("  No descriptions to propagate. Use 'Inherited: model.column' for ambiguous columns.") %}
        {% endif %}

        {% do out.append("") %}
        {% do out.append(bar) %}
        {% do out.append("  dbt_doc_inherit: Complete. " ~ results | length ~ " columns processed, " ~ writable | length ~ " descriptions ready.") %}
        {% do out.append(bar) %}

        {{ print(out | join('\n')) }}

    {% endif %}
{% endmacro %}
