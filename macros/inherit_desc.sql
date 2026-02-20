{% macro inherit_desc(model_name, column_name) %}
    {#--
        Explicit inheritance directive for renamed or ambiguous columns.

        Usage in schema YAML:
            description: "{{ dbt_doc_inherit.inherit_desc('stg_customers', 'user_id') }}"

        Returns a placeholder string during YAML parsing (parse phase).
        The propagate_descriptions run-operation detects this pattern
        during execute phase and resolves the actual description.

        Note: dbt docs generate will show the placeholder text, not the
        resolved description. Use the propagate_descriptions report to
        see the fully resolved descriptions.
    --#}
    {{- return("Inherited: " ~ model_name ~ "." ~ column_name) -}}
{% endmacro %}
