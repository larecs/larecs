{{define "overload" -}}
{{if .Summary}}{{.Summary}}

{{end -}}
{{template "signature_func" .}}

{{template "description" . -}}
{{template "func_parameters" . -}}
{{template "func_args" . -}}
{{template "func_returns" . -}}
{{template "func_raises" . -}}
{{template "func_constraints" . -}}
{{end}}
