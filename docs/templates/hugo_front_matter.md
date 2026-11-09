---
type: docs
title: {{if and (eq .Name "larecs") (eq .Kind "package")}}API docs{{else}}{{.Name}}{{end}}
{{if and (eq .Name "larecs") (eq .Kind "package")}}sidebar:
  exclude: true
{{end -}}
---
