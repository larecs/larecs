{{range .Global}}{{.}}
{{end}}
{{if .Code -}}
def main() raises:
{{range .Code}}    {{.}}
{{end}}
{{- end}}
