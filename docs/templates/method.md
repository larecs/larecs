{{define "method" -}}
### `{{.Name}}`

{{if .Overloads -}}
{{range $index, $overload := .Overloads -}}
{{if gt (len $.Overloads) 1}}{{`{{<html>}}`}}<a id="{{$.Name}}-{{$index}}"></a>{{`{{</html>}}`}}
{{if $index}}---

{{end}}{{end -}}
{{template "overload" $overload -}}
{{end -}}
{{else -}}
{{template "overload" . -}}
{{end -}}
{{- end}}
