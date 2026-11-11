{{define "aliases" -}}
{{if .Aliases}}## Aliases

{{range .Aliases -}}
{{`{{<html>}}`}}<a id="{{.Name}}"></a>{{`{{</html>}}`}}

### `{{.Name}}`

{{if .Summary}}{{.Summary}}

{{end -}}
```mojo
{{.Signature}}{{if ne .Value "fn_literal"}}{{if .Type}}: {{.Type}}{{end}} = {{.Value}}{{end}}
```

{{if .Description}}{{.Description}}

{{end -}}
{{end}}
{{end}}
{{- end}}
