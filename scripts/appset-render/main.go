// appset-render renders an ApplicationSet template the way the ArgoCD ApplicationSet controller does
// with goTemplate: text/template, sprig's generic functions without the three that read the
// environment, ArgoCD's own toYaml, and the ApplicationSet's goTemplateOptions (missingkey=error
// among them). The versions in go.mod are the ones ArgoCD's go.mod pins for the running controller.
//
// stdin:  {"template": "...", "options": ["missingkey=error"], "params": [{...}, ...]}
// stdout: one {"output": "..."} or {"error": "..."} per parameter set, in order.
package main

import (
	"bytes"
	"encoding/json"
	"os"
	"strings"
	"text/template"

	"github.com/Masterminds/sprig/v3"
	"sigs.k8s.io/yaml"
)

func main() {
	var input struct {
		Template string           `json:"template"`
		Options  []string         `json:"options"`
		Params   []map[string]any `json:"params"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil {
		panic(err)
	}
	funcs := sprig.GenericFuncMap()
	delete(funcs, "env")
	delete(funcs, "expandenv")
	delete(funcs, "getHostByName")
	funcs["toYaml"] = func(v any) (string, error) {
		data, err := yaml.Marshal(v)
		return strings.TrimSuffix(string(data), "\n"), err
	}
	parsed := template.Must(template.New("base").Funcs(funcs).Option(input.Options...).Parse(input.Template))
	results := []map[string]string{}
	for _, params := range input.Params {
		var out bytes.Buffer
		if err := parsed.Execute(&out, params); err != nil {
			results = append(results, map[string]string{"error": err.Error()})
		} else {
			results = append(results, map[string]string{"output": out.String()})
		}
	}
	if err := json.NewEncoder(os.Stdout).Encode(results); err != nil {
		panic(err)
	}
}
