// Applies a Loki `replace` stage to log lines the way Alloy does: the expression is RE2, and what a
// match replaces is each of its capture groups, never the whole match. Reads
// {"expression": ..., "replace": ..., "lines": [...]} from stdin and writes the lines it leaves.
package main

import (
	"encoding/json"
	"os"
	"regexp"
	"strings"
)

func main() {
	var input struct {
		Expression string   `json:"expression"`
		Replace    string   `json:"replace"`
		Lines      []string `json:"lines"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil {
		panic(err)
	}
	expression, err := regexp.Compile(input.Expression)
	if err != nil {
		panic(err)
	}
	left := make([]string, len(input.Lines))
	for at, line := range input.Lines {
		var out strings.Builder
		kept := 0
		for _, match := range expression.FindAllStringSubmatchIndex(line, -1) {
			for group := 1; group*2 < len(match); group++ {
				if match[group*2] < 0 {
					continue
				}
				out.WriteString(line[kept:match[group*2]])
				out.WriteString(input.Replace)
				kept = match[group*2+1]
			}
		}
		out.WriteString(line[kept:])
		left[at] = out.String()
	}
	if err := json.NewEncoder(os.Stdout).Encode(left); err != nil {
		panic(err)
	}
}
