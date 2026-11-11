Mojo function{{template "source_link" .}}

{{`{{<expand-all>}}`}}

{{if .Overloads -}}
{{range .Overloads -}}
{{template "overload" . -}}
{{end -}}
{{else -}}
{{template "overload" . -}}
{{- end}}