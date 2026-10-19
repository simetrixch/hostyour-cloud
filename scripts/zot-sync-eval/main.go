// Reads {"registries": [<the sync registries of a zot config.json>], "repositories": [<repository names>]} on
// standard input and answers, for each repository, the indexes of the registries zot asks when a pull of it
// misses locally.
//
// It is zot v2.1.22's own decision, reduced to the case this platform configures. SyncImage
// (pkg/extensions/sync/service.go) returns ErrSyncImageFilteredOut, which zot answers as a plain 404
// (pkg/extensions/sync/client_error.go), when a registry has content and GetRepoSource finds no match; that
// is GetContentByLocalRepo (pkg/extensions/sync/content.go), the glob match below, with doublestar at the
// version zot's go.mod pins. A registry without content asks for every repository. A content entry with a
// destination or a stripPrefix would move the pattern, so it is refused instead of guessed at.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"

	glob "github.com/bmatcuk/doublestar/v4"
)

type content struct {
	Prefix      string `json:"prefix"`
	Destination string `json:"destination"`
	StripPrefix bool   `json:"stripPrefix"`
}

type registry struct {
	OnDemand bool      `json:"onDemand"`
	Content  []content `json:"content"`
}

func asked(r registry, repo string) (bool, error) {
	if !r.OnDemand {
		return false, nil
	}
	if len(r.Content) == 0 {
		return true, nil
	}
	for _, c := range r.Content {
		if c.Destination != "" || c.StripPrefix {
			return false, fmt.Errorf("content %q has a destination or a stripPrefix, which this evaluator does not model", c.Prefix)
		}
		matched, err := glob.Match(strings.Trim(strings.Trim(c.Prefix, "/")+"/", "/"), strings.Trim(repo, "/"))
		if err != nil {
			return false, err
		}
		if matched {
			return true, nil
		}
	}
	return false, nil
}

func main() {
	var in struct {
		Registries   []registry `json:"registries"`
		Repositories []string   `json:"repositories"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	out := map[string][]int{}
	for _, repo := range in.Repositories {
		out[repo] = []int{}
		for i, r := range in.Registries {
			ok, err := asked(r, repo)
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			if ok {
				out[repo] = append(out[repo], i)
			}
		}
	}
	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
