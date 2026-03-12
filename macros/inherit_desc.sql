{% macro inherit_desc(model_name, column_name) %}
    {#--
        Generate an inheritance directive for renamed or ambiguous columns.

        dbt does not evaluate custom macros in YAML description fields.
        Instead, write the directive string directly in your schema YAML:

            description: "Inherited: dim_users.username"

        The propagate_descriptions macro detects the "Inherited: " prefix
        and resolves it to the actual description from the referenced model.

        This macro is provided for programmatic use in SQL models or
        other Jinja contexts where macro evaluation is supported.

        Examples:
            In YAML (use the string directly):
                - name: user_display_name
                  description: "Inherited: dim_users.username"

            In SQL/Jinja (use the macro):
                {{ dbt_doc_inherit.inherit_desc('dim_users', 'username') }}
    --#}
    {{- return("Inherited: " ~ model_name ~ "." ~ column_name) -}}
{% endmacro %}
