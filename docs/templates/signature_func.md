{{define "signature_func" -}}
{{`{{< declaration >}}`}}
```mojo
{{if and (.IsStatic) (ne .Name "__init__")}}@staticmethod
{{end -}}
{{if .Signature}}{{.Signature}}{{else}}def {{.Name}}{{end}}
```
{{`{{< /declaration >}}`}}
{{- end}}
