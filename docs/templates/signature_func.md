{{define "signature_func" -}}
{{`{{< declaration encoded="`}}{{if and (.IsStatic) (ne .Name "__init__")}}%40staticmethod%0A{{end}}{{if .Signature}}{{urlquery .Signature}}{{else}}def+{{urlquery .Name}}{{end}}{{`" />}}`}}
{{- end}}
