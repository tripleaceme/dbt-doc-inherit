{% macro propagate_descriptions() %}
    {#--
        Propagate column descriptions along the dbt DAG.

        Shows a report of which columns can inherit descriptions from upstream.
        To write descriptions to your YAML files, run the Python script:

            python dbt_packages/dbt_doc_inherit/propagate.py

        To preview the report only (no file changes):
            dbt run-operation propagate_descriptions
    --#}

    {% if execute %}

        {# ── Step 1: Build column catalog from graph ── #}
        {% set column_catalog = {} %}

        {% for node in graph.nodes.values() %}
            {% if node.resource_type in ['model', 'seed'] %}
                {% set node_columns = {} %}
                {% for col_name, col in node.columns.items() %}
                    {% do node_columns.update({
                        col_name: {
                            'description': col.description | default('', true),
                            'data_type': col.data_type | default('', true)
                        }
                    }) %}
                {% endfor %}

                {% set file_path = node.patch_path | default(node.original_file_path, true) %}
                {% if file_path and '://' in file_path %}
                    {% set file_path = file_path.split('://')[1] %}
                {% endif %}

                {% do column_catalog.update({
                    node.unique_id: {
                        'name': node.name,
                        'resource_type': node.resource_type,
                        'columns': node_columns,
                        'file_path': file_path,
                        'depends_on': node.depends_on.nodes | default([], true)
                    }
                }) %}
            {% endif %}
        {% endfor %}

        {% for source in graph.sources.values() %}
            {% set source_columns = {} %}
            {% for col_name, col in source.columns.items() %}
                {% do source_columns.update({
                    col_name: {
                        'description': col.description | default('', true),
                        'data_type': col.data_type | default('', true)
                    }
                }) %}
            {% endfor %}

            {% set source_display_name = source.source_name ~ '.' ~ source.name %}

            {% do column_catalog.update({
                source.unique_id: {
                    'name': source_display_name,
                    'resource_type': 'source',
                    'columns': source_columns,
                    'file_path': source.original_file_path | default('', true),
                    'depends_on': []
                }
            }) %}
        {% endfor %}

        {{ log("dbt_doc_inherit: Built catalog with " ~ column_catalog | length ~ " entities.", info=True) }}

        {# ── Step 2: Resolve inheritance for each model/seed ── #}
        {% set report_entries = [] %}
        {% set inherit_pattern = 'Inherited: ' %}

        {% for node_id, node_info in column_catalog.items() %}
            {% if node_info.resource_type in ['model', 'seed'] %}

                {% set parent_column_map = {} %}
                {% for parent_id in node_info.depends_on %}
                    {% if parent_id in column_catalog %}
                        {% set parent = column_catalog[parent_id] %}
                        {% for pcol_name, pcol_info in parent.columns.items() %}
                            {% if pcol_info.description and pcol_info.description | trim | length > 0
                               and not pcol_info.description.startswith(inherit_pattern) %}
                                {% if pcol_name not in parent_column_map %}
                                    {% do parent_column_map.update({pcol_name: []}) %}
                                {% endif %}
                                {% do parent_column_map[pcol_name].append({
                                    'parent_name': parent.name,
                                    'description': pcol_info.description,
                                    'file_path': parent.file_path,
                                    'column_name': pcol_name
                                }) %}
                            {% endif %}
                        {% endfor %}
                    {% endif %}
                {% endfor %}

                {% for col_name, col_info in node_info.columns.items() %}
                    {% set desc = col_info.description | trim %}
                    {% set entry = namespace(
                        status='',
                        inherited_description='',
                        source_model='',
                        source_column='',
                        source_file_path=''
                    ) %}

                    {% if desc.startswith(inherit_pattern) %}
                        {% set directive = desc[inherit_pattern | length:] %}
                        {% set parts = directive.split('.') %}
                        {% if parts | length >= 2 %}
                            {% set target_model = parts[0] %}
                            {% set target_column = parts[1:] | join('.') %}

                            {% set resolved = namespace(found=false) %}
                            {% for cat_id, cat_info in column_catalog.items() %}
                                {% if cat_info.name == target_model or cat_info.name.endswith('.' ~ target_model) %}
                                    {% if target_column in cat_info.columns %}
                                        {% set source_desc = cat_info.columns[target_column].description | trim %}
                                        {% if source_desc | length > 0 and not source_desc.startswith(inherit_pattern) %}
                                            {% set entry.status = 'resolved' %}
                                            {% set entry.inherited_description = source_desc %}
                                            {% set entry.source_model = cat_info.name %}
                                            {% set entry.source_column = target_column %}
                                            {% set entry.source_file_path = cat_info.file_path %}
                                            {% set resolved.found = true %}
                                        {% endif %}
                                    {% endif %}
                                {% endif %}
                            {% endfor %}

                            {% if not resolved.found %}
                                {% set entry.status = 'unresolved' %}
                                {% set entry.inherited_description = '' %}
                                {% set entry.source_model = target_model %}
                                {% set entry.source_column = target_column %}
                            {% endif %}
                        {% else %}
                            {% set entry.status = 'unresolved' %}
                        {% endif %}

                    {% elif desc | length == 0 %}
                        {% if col_name in parent_column_map %}
                            {% set matches = parent_column_map[col_name] %}
                            {% if matches | length == 1 %}
                                {% set match = matches[0] %}
                                {% set entry.status = 'inherited' %}
                                {% set entry.inherited_description = match.description %}
                                {% set entry.source_model = match.parent_name %}
                                {% set entry.source_column = match.column_name %}
                                {% set entry.source_file_path = match.file_path %}
                            {% else %}
                                {% set parent_names = [] %}
                                {% for m in matches %}
                                    {% do parent_names.append(m.parent_name) %}
                                {% endfor %}
                                {% set entry.status = 'ambiguous (' ~ parent_names | join(', ') ~ ')' %}
                                {% set entry.inherited_description = '' %}
                            {% endif %}
                        {% else %}
                            {% set entry.status = 'no_source' %}
                            {% set entry.inherited_description = '' %}
                        {% endif %}

                    {% else %}
                        {% set entry.status = 'already_documented' %}
                        {% set entry.inherited_description = desc %}
                    {% endif %}

                    {% do report_entries.append({
                        'model_name': node_info.name,
                        'column_name': col_name,
                        'inherited_description': entry.inherited_description,
                        'target_file_path': node_info.file_path,
                        'source_model': entry.source_model,
                        'source_column': entry.source_column,
                        'source_file_path': entry.source_file_path,
                        'status': entry.status
                    }) %}
                {% endfor %}

            {% endif %}
        {% endfor %}

        {{ log("dbt_doc_inherit: Processed " ~ report_entries | length ~ " columns across all models.", info=True) }}

        {# ── Step 3: Log formatted report to console ── #}
        {{ log("", info=True) }}
        {{ log("═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════", info=True) }}
        {{ log("  dbt_doc_inherit: Column Inheritance Report", info=True) }}
        {{ log("═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════", info=True) }}
        {{ log("", info=True) }}

        {% set counts = namespace(inherited=0, resolved=0, ambiguous=0, no_source=0, already_documented=0, unresolved=0) %}

        {% for entry in report_entries %}
            {% if entry.status == 'inherited' %}
                {% set counts.inherited = counts.inherited + 1 %}
            {% elif entry.status == 'resolved' %}
                {% set counts.resolved = counts.resolved + 1 %}
            {% elif entry.status.startswith('ambiguous') %}
                {% set counts.ambiguous = counts.ambiguous + 1 %}
            {% elif entry.status == 'no_source' %}
                {% set counts.no_source = counts.no_source + 1 %}
            {% elif entry.status == 'already_documented' %}
                {% set counts.already_documented = counts.already_documented + 1 %}
            {% elif entry.status == 'unresolved' %}
                {% set counts.unresolved = counts.unresolved + 1 %}
            {% endif %}
        {% endfor %}

        {{ log("  Summary: " ~ counts.inherited ~ " inherited | " ~ counts.resolved ~ " resolved | " ~ counts.ambiguous ~ " ambiguous | " ~ counts.no_source ~ " no_source | " ~ counts.unresolved ~ " unresolved | " ~ counts.already_documented ~ " already_documented", info=True) }}
        {{ log("", info=True) }}

        {% set actionable = [] %}
        {% for entry in report_entries %}
            {% if entry.status != 'already_documented' %}
                {% do actionable.append(entry) %}
            {% endif %}
        {% endfor %}

        {% if actionable | length > 0 %}

            {% set w = namespace(col=11, status=6, desc=21, target=11, source=11) %}
            {% for entry in actionable %}
                {% set col_display = entry.model_name ~ '.' ~ entry.column_name %}
                {% set desc_display = entry.inherited_description[:50] if entry.inherited_description else '—' %}
                {% set target_display = entry.target_file_path if entry.target_file_path else '—' %}
                {% set source_display = entry.source_file_path if entry.source_file_path else '—' %}
                {% if col_display | length > w.col %}
                    {% set w.col = col_display | length %}
                {% endif %}
                {% if entry.status | length > w.status %}
                    {% set w.status = entry.status | length %}
                {% endif %}
                {% if desc_display | length > w.desc %}
                    {% set w.desc = desc_display | length %}
                {% endif %}
                {% if target_display | length > w.target %}
                    {% set w.target = target_display | length %}
                {% endif %}
                {% if source_display | length > w.source %}
                    {% set w.source = source_display | length %}
                {% endif %}
            {% endfor %}

            {% set h_col = 'Column' ~ ' ' * (w.col - 6) %}
            {% set h_status = 'Status' ~ ' ' * (w.status - 6) %}
            {% set h_desc = 'Inherited Description' ~ ' ' * (w.desc - 21) %}
            {% set h_target = 'Target File' ~ ' ' * (w.target - 11) %}
            {% set h_source = 'Source File' ~ ' ' * (w.source - 11) %}

            {{ log("  " ~ h_col ~ "  " ~ h_status ~ "  " ~ h_desc ~ "  " ~ h_target ~ "  " ~ h_source, info=True) }}

            {% set sep = namespace(col='', status='', desc='', target='', source='') %}
            {% for i in range(w.col) %}{% set sep.col = sep.col ~ '─' %}{% endfor %}
            {% for i in range(w.status) %}{% set sep.status = sep.status ~ '─' %}{% endfor %}
            {% for i in range(w.desc) %}{% set sep.desc = sep.desc ~ '─' %}{% endfor %}
            {% for i in range(w.target) %}{% set sep.target = sep.target ~ '─' %}{% endfor %}
            {% for i in range(w.source) %}{% set sep.source = sep.source ~ '─' %}{% endfor %}

            {{ log("  " ~ sep.col ~ "  " ~ sep.status ~ "  " ~ sep.desc ~ "  " ~ sep.target ~ "  " ~ sep.source, info=True) }}

            {% for entry in actionable %}
                {% set col_val = entry.model_name ~ '.' ~ entry.column_name %}
                {% set desc_val = entry.inherited_description[:50] if entry.inherited_description else '—' %}
                {% set target_val = entry.target_file_path if entry.target_file_path else '—' %}
                {% set source_val = entry.source_file_path if entry.source_file_path else '—' %}

                {% set col_pad = col_val ~ ' ' * (w.col - col_val | length) %}
                {% set status_pad = entry.status ~ ' ' * (w.status - entry.status | length) %}
                {% set desc_pad = desc_val ~ ' ' * (w.desc - desc_val | length) %}
                {% set target_pad = target_val ~ ' ' * (w.target - target_val | length) %}
                {% set source_pad = source_val ~ ' ' * (w.source - source_val | length) %}

                {{ log("  " ~ col_pad ~ "  " ~ status_pad ~ "  " ~ desc_pad ~ "  " ~ target_pad ~ "  " ~ source_pad, info=True) }}
            {% endfor %}
        {% else %}
            {{ log("  All columns are already documented. Nothing to propagate.", info=True) }}
        {% endif %}

        {{ log("", info=True) }}
        {{ log("═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════", info=True) }}
        {{ log("dbt_doc_inherit: Complete. " ~ report_entries | length ~ " columns processed.", info=True) }}

    {% endif %}
{% endmacro %}
