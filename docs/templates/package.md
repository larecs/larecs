Mojo package{{template "source_link" .}}

# `{{.Name}}`

{{if eq .Name "larecs"}}Use the [curated reference](../reference) to choose an API and look up compatibility. This module tree contains the full compiler-generated declarations, including implementation utilities.

{{end -}}
{{template "summary" . -}}
{{template "description" . -}}
{{template "aliases" . -}}
{{template "structs" . -}}
{{template "traits" . -}}
{{template "functions" . -}}
{{template "modules" . -}}
{{template "packages" . -}}
