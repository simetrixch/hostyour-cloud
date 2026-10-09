// vap-eval evaluates a ValidatingAdmissionPolicy's variables and validations on planted admission
// requests, the way the API server does for a request: the variables in order, each validation on
// them, and a validation that errors counts as a denial, because the policies here fail closed. The
// cel-go version in go.mod is the one Kubernetes v1.35.6 pins, the version the build plane runs, with
// its string extension at version 2 as Kubernetes registers it. Objects are dynamically typed here;
// the API server also checks them against the CRD's schema, which this does not.
//
// The same environment also binds `body`, so the CEL of a Tekton Trigger's cel interceptor runs here
// too: its filter is a validation (a request it denies is a push the trigger ignores) and each of its
// overlays is a variable, read back from "variables".
//
// stdin:  {"policy": <the ValidatingAdmissionPolicy>, "requests": [{"object", "oldObject", "request", "body"}, ...]}
// stdout: one {"denied": ["<message>", ...], "variables": {"<name>": "<value>", ...}} per request, in
//         order; "variables" holds the variables that evaluate to a string. A compile error exits 1.
package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/google/cel-go/cel"
	"github.com/google/cel-go/ext"
)

type expression struct {
	Name       string `json:"name"`
	Expression string `json:"expression"`
	Message    string `json:"message"`
}

func main() {
	var input struct {
		Policy struct {
			Spec struct {
				Variables   []expression `json:"variables"`
				Validations []expression `json:"validations"`
			} `json:"spec"`
		} `json:"policy"`
		Requests []map[string]any `json:"requests"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil {
		fail("could not read the input: %v", err)
	}
	env, err := cel.NewEnv(
		cel.Variable("object", cel.DynType), cel.Variable("oldObject", cel.DynType), cel.Variable("request", cel.DynType), cel.Variable("body", cel.DynType),
		cel.Variable("variables", cel.MapType(cel.StringType, cel.DynType)), ext.Strings(ext.StringsVersion(2)))
	if err != nil {
		fail("could not build the CEL environment: %v", err)
	}
	compile := func(e expression) cel.Program {
		ast, issues := env.Compile(e.Expression)
		if issues.Err() != nil {
			fail("%s does not compile: %v", e.Name+e.Message, issues.Err())
		}
		program, err := env.Program(ast)
		if err != nil {
			fail("%s does not compile: %v", e.Name+e.Message, err)
		}
		return program
	}
	variables := make([]cel.Program, len(input.Policy.Spec.Variables))
	for i, v := range input.Policy.Spec.Variables {
		variables[i] = compile(v)
	}
	validations := make([]cel.Program, len(input.Policy.Spec.Validations))
	for i, v := range input.Policy.Spec.Validations {
		validations[i] = compile(v)
	}
	out := json.NewEncoder(os.Stdout)
	for _, request := range input.Requests {
		values := map[string]any{}
		texts := map[string]string{}
		activation := map[string]any{"object": request["object"], "oldObject": request["oldObject"], "request": request["request"], "body": request["body"], "variables": values}
		for i, v := range input.Policy.Spec.Variables {
			if result, _, err := variables[i].Eval(activation); err == nil {
				values[v.Name] = result
				if text, ok := result.Value().(string); ok {
					texts[v.Name] = text
				}
			}
		}
		denied := []string{}
		for i, v := range input.Policy.Spec.Validations {
			result, _, err := validations[i].Eval(activation)
			if err != nil {
				denied = append(denied, v.Message+" (error: "+err.Error()+")")
			} else if result.Value() != true {
				denied = append(denied, v.Message)
			}
		}
		if err := out.Encode(map[string]any{"denied": denied, "variables": texts}); err != nil {
			fail("could not write the answer: %v", err)
		}
	}
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "vap-eval: "+format+"\n", args...)
	os.Exit(1)
}
