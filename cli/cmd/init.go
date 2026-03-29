package cmd

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"
)

var template string
var jsonMarshalIndent = json.MarshalIndent
var initFatalf = log.Fatalf

type initTemplateConfig struct {
	Runtime        string `json:"runtime"`
	Name           string `json:"name"`
	Version        string `json:"version,omitempty"`
	Entrypoint     string `json:"entrypoint"`
	TimeoutMS      int    `json:"timeout_ms,omitempty"`
	MaxConcurrency int    `json:"max_concurrency,omitempty"`
	MaxBodyBytes   int    `json:"max_body_bytes,omitempty"`
}

var initCmd = &cobra.Command{
	Use:   "init [name]",
	Short: "Create a new function scaffold",
	Long: `Create a new function scaffold under <name>/.

Generated files include fn.config.json and runtime-specific entry files.
Stable templates: node, python, php, lua.
Experimental template: rust.
Go runtime is experimental and currently created manually (file-based routing).
Experimental runtimes are disabled by default unless FN_RUNTIMES explicitly includes them.`,
	Example: `  fastfn init hello -t node
  fastfn init risk-score -t python
  fastfn init export-report -t php
  fastfn init quick-hook -t lua
  fastfn init profile -t rust`,
	Args: cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		name := args[0]
		template = strings.ToLower(strings.TrimSpace(template))
		dirPath := filepath.Join(".", name)

		// 1. Create directory
		if err := os.MkdirAll(dirPath, 0755); err != nil {
			log.Fatalf("Failed to create directory %s: %v", dirPath, err)
		}

		// 2. Generate files based on template
		switch template {
		case "python":
			createPythonFunction(name, dirPath)
		case "node":
			createNodeFunction(name, dirPath)
		case "php":
			createPhpFunction(name, dirPath)
		case "lua":
			createLuaFunction(name, dirPath)
		case "rust":
			createRustFunction(name, dirPath)
		default:
			log.Fatalf("Unknown template: %s. Supported templates: node, python, php, lua, rust (experimental)", template)
		}

		fmt.Printf("Created function '%s' in %s (runtime: %s)\n", name, dirPath, template)
		fmt.Println("Files created:")
		fmt.Println(" - fn.config.json")

		switch template {
		case "python":
			fmt.Println(" - handler.py")
			fmt.Println(" - requirements.txt")
		case "node":
			fmt.Println(" - handler.js")
		case "php":
			fmt.Println(" - handler.php")
		case "lua":
			fmt.Println(" - handler.lua")
		case "rust":
			fmt.Println(" - handler.rs")
		}
		fmt.Println("\nRun 'fastfn dev' in the project root to auto-discover this function.")
	},
}

func init() {
	rootCmd.AddCommand(initCmd)
	initCmd.Flags().StringVarP(&template, "template", "t", "node", "Runtime template: node|python|php|lua|rust (rust is experimental)")
}

func createNodeFunction(name, dirPath string) {
	writeConfigFile(filepath.Join(dirPath, "fn.config.json"), initTemplateConfig{
		Runtime:        "node",
		Name:           name,
		Version:        "1.0.0",
		Entrypoint:     "handler.js",
		TimeoutMS:      2500,
		MaxConcurrency: 20,
		MaxBodyBytes:   1048576,
	})

	// handler.js
	handlerContent := `/**
 * @param {Record<string, any>} event
 */
module.exports.handler = async (event) => {
  const query = (event && event.query) || {};
  const params = (event && event.params) || {};
  const version = (event && event.version) || "default";
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      message: "Hello from FastFN Node!",
      version,
      query,
      params,
      wildcard: typeof params.wildcard === "string" ? params.wildcard : ""
    })
  };
};
`
	writeFile(filepath.Join(dirPath, "handler.js"), handlerContent)
}

func createPythonFunction(name, dirPath string) {
	writeConfigFile(filepath.Join(dirPath, "fn.config.json"), initTemplateConfig{
		Runtime:        "python",
		Name:           name,
		Version:        "1.0.0",
		Entrypoint:     "handler.py",
		TimeoutMS:      2500,
		MaxConcurrency: 20,
		MaxBodyBytes:   1048576,
	})

	// handler.py
	handlerContent := `def handler(event):
    query = (event.get("query") or {})
    params = (event.get("params") or {})
    name = query.get("name", "World")
    version = str(event.get("version") or "default")
    return {
        "message": f"Hello, {name} from FastFN Python!",
        "version": version,
        "query": query,
        "params": params,
        "wildcard": params.get("wildcard", ""),
    }
`
	writeFile(filepath.Join(dirPath, "handler.py"), handlerContent)

	// requirements.txt
	writeFile(filepath.Join(dirPath, "requirements.txt"), "# Add your dependencies here\n")
}

func createPhpFunction(name, dirPath string) {
	writeConfigFile(filepath.Join(dirPath, "fn.config.json"), initTemplateConfig{
		Runtime:    "php",
		Name:       name,
		Version:    "1.0.0",
		Entrypoint: "handler.php",
	})

	// handler.php
	handlerContent := `<?php

function handler(array $context): array {
    // Return array -> JSON automatically
    return [
        'message' => 'Hello from FastFN PHP!',
        'input' => $context
    ];
}
`
	writeFile(filepath.Join(dirPath, "handler.php"), handlerContent)
}

func createLuaFunction(name, dirPath string) {
	writeConfigFile(filepath.Join(dirPath, "fn.config.json"), initTemplateConfig{
		Runtime:    "lua",
		Name:       name,
		Version:    "1.0.0",
		Entrypoint: "handler.lua",
	})

	// handler.lua
	handlerContent := `local cjson = require("cjson.safe")

function handler(event)
    local query = event.query or {}
    local params = event.params or {}
    local name = query.name or "World"
    local version = event.version or "default"
    return {
        status = 200,
        headers = { ["Content-Type"] = "application/json" },
        body = cjson.encode({
            message = "Hello, " .. tostring(name) .. " from FastFN Lua!",
            version = version,
            query = query,
            params = params,
            wildcard = params.wildcard or ""
        })
    }
end
`
	writeFile(filepath.Join(dirPath, "handler.lua"), handlerContent)
}

func createRustFunction(name, dirPath string) {
	writeConfigFile(filepath.Join(dirPath, "fn.config.json"), initTemplateConfig{
		Runtime:    "rust",
		Name:       name,
		Version:    "1.0.0",
		Entrypoint: "handler.rs",
	})

	// handler.rs
	handlerContent := `use serde_json::{json, Value};

pub fn handler(context: Value) -> Value {
    // Return JSON value directly
    json!({
        "message": "Hello from FastFN Rust!",
        "input": context
    })
}
`
	writeFile(filepath.Join(dirPath, "handler.rs"), handlerContent)
}

func writeFile(path, content string) {
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		initFatalf("Failed to write to %s: %v", path, err)
	}
}

func writeConfigFile(path string, cfg initTemplateConfig) {
	data, err := jsonMarshalIndent(cfg, "", "  ")
	if err != nil {
		initFatalf("Failed to encode config for %s: %v", path, err)
	}
	writeFile(path, string(data))
}
