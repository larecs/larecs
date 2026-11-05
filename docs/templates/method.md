{{define "method" -}}
### `{{.Name}}`

{{if .Overloads -}}
{{range $index, $overload := .Overloads -}}
{{if gt (len $.Overloads) 1}}{{if $index}}---

{{end}}{{`{{<html>}}`}}<a id="{{$.Name}}-{{$index}}"></a>{{`{{</html>}}`}}

{{end -}}
{{template "overload" $overload -}}
{{end -}}
{{else -}}
{{template "overload" . -}}
{{end -}}
{{- end}}
