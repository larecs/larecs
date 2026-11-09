{{define "aliases" -}}
{{if .Aliases}}## Aliases

{{range .Aliases -}}
{{`{{<html>}}`}}<a id="{{.Name}}"></a>{{`{{</html>}}`}}

### `{{.Name}}`

{{if .Summary}}{{.Summary}}

{{end -}}
```mojo
{{.Signature}}{{if .Type}}: {{.Type}}{{end}} = {{.Value}}
```

{{if .Description}}{{.Description}}

{{end -}}
{{end}}
{{end}}
{{- end}}
