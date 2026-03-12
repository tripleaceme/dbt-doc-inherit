{% macro inherit_desc(model_name, column_name) %}
    {#--
        Explicit inheritance directive for renamed or ambiguous columns.

        dbt does not support custom macros in YAML description fields.
        Instead, use the placeholder string directly in your schema YAML:

            description: "Inherited: dim_users.username"

        The propagate_descriptions run-operation detects this "Inherited: "
        pattern and resolves it to the actual description from the source model.

        This macro is kept for programmatic use (e.g. in SQL models or
        other macros) but should NOT be called in YAML description fields.
    --#}
    {{- return("Inherited: " ~ model_name ~ "." ~ column_name) -}}
{% endmacro %}
