// mail-eval renders the Go templates of an Alertmanager mail the way Alertmanager does, on planted
// alerts. Alertmanager loads the template files into one text and one html template set, both with
// the option missingkey=zero, and renders a receiver's subject and text with text/template and its
// html with html/template, each on a clone of the set (prometheus/alertmanager template/template.go,
// New, ExecuteTextString and ExecuteHTMLString). This does the same with the standard library alone.
// Alertmanager's own function map (toUpper, safeHtml and the rest) is not registered, so a template
// that calls one of them fails to parse here instead of rendering something Alertmanager may not.
// The data is the shape of Alertmanager's template.Data, with the fields a mail template reads.
//
// stdin:  {"templates": {"<file>": "<source>"}, "renders": [{"text": "<template text>", "html": <bool>, "data": {...}}, ...]}
// stdout: one {"out": "<rendered>", "error": "<error or empty>"} per render, in order.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	htmltemplate "html/template"
	"os"
	texttemplate "text/template"
	"time"
)

// KV is Alertmanager's template.KV: a map of strings, so a missing key reads as "".
type KV map[string]string

type Alert struct {
	Status      string    `json:"status"`
	Labels      KV        `json:"labels"`
	Annotations KV        `json:"annotations"`
	StartsAt    time.Time `json:"startsAt"`
	EndsAt      time.Time `json:"endsAt"`
}

type Data struct {
	Receiver          string  `json:"receiver"`
	Status            string  `json:"status"`
	Alerts            []Alert `json:"alerts"`
	GroupLabels       KV      `json:"groupLabels"`
	CommonLabels      KV      `json:"commonLabels"`
	CommonAnnotations KV      `json:"commonAnnotations"`
	ExternalURL       string  `json:"externalURL"`
}

type render struct {
	Text string `json:"text"`
	HTML bool   `json:"html"`
	Data Data   `json:"data"`
}

func main() {
	var input struct {
		Templates map[string]string `json:"templates"`
		Renders   []render          `json:"renders"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil {
		fmt.Fprintln(os.Stderr, "mail-eval: bad input:", err)
		os.Exit(1)
	}
	text := texttemplate.New("").Option("missingkey=zero")
	html := htmltemplate.New("").Option("missingkey=zero")
	for name, source := range input.Templates {
		if _, err := text.New(name).Parse(source); err != nil {
			fmt.Fprintln(os.Stderr, "mail-eval: template file", name, "does not parse as text:", err)
			os.Exit(1)
		}
		if _, err := html.New(name).Parse(source); err != nil {
			fmt.Fprintln(os.Stderr, "mail-eval: template file", name, "does not parse as html:", err)
			os.Exit(1)
		}
	}
	for _, r := range input.Renders {
		out, err := execute(text, html, r)
		message := ""
		if err != nil {
			message = err.Error()
		}
		line, _ := json.Marshal(map[string]string{"out": out, "error": message})
		fmt.Println(string(line))
	}
}

func execute(text *texttemplate.Template, html *htmltemplate.Template, r render) (string, error) {
	var buffer bytes.Buffer
	if r.HTML {
		clone, err := html.Clone()
		if err != nil {
			return "", err
		}
		parsed, err := clone.New("").Option("missingkey=zero").Parse(r.Text)
		if err != nil {
			return "", err
		}
		err = parsed.Execute(&buffer, r.Data)
		return buffer.String(), err
	}
	clone, err := text.Clone()
	if err != nil {
		return "", err
	}
	parsed, err := clone.New("").Option("missingkey=zero").Parse(r.Text)
	if err != nil {
		return "", err
	}
	err = parsed.Execute(&buffer, r.Data)
	return buffer.String(), err
}
