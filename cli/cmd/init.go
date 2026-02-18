package cmd

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"
)

var template string

var initCmd = &cobra.Command{
	Use:   "init [name]",
	Short: "Create a new function scaffold",
	Long: `Create a new function scaffold under <runtime>/<name>.

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
		runtimeRoot := strings.ToLower(strings.TrimSpace(template))
		dirPath := filepath.Join(".", runtimeRoot, name)

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

		fmt.Printf("Created function '%s' in %s (runtime: %s)\n", name, dirPath, runtimeRoot)
		fmt.Println("Files created:")
		fmt.Println(" - fn.config.json")

		switch template {
		case "python":
			fmt.Println(" - main.py")
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
	// fn.config.json
	configContent := `{
  "runtime": "node",
  "name": "` + name + `",
  "version": "1.0.0",
  "entrypoint": "handler.js",
  "timeout_ms": 2500,
  "max_concurrency": 20,
  "max_body_bytes": 1048576
}`
	writeFile(filepath.Join(dirPath, "fn.config.json"), configContent)

	// handler.js
	handlerContent := `/**
 * @param {Record<string, any>} event
 */
module.exports.handler = async (event) => {
  const query = (event && event.query) || {};
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      message: "Hello from FastFN Node!",
      input: { query }
    })
  };
};
`
	writeFile(filepath.Join(dirPath, "handler.js"), handlerContent)
}

func createPythonFunction(name, dirPath string) {
	// fn.config.json
	configContent := `{
  "runtime": "python",
  "name": "` + name + `",
  "version": "1.0.0",
  "entrypoint": "main.py",
  "timeout_ms": 2500,
  "max_concurrency": 20,
  "max_body_bytes": 1048576
}`
	writeFile(filepath.Join(dirPath, "fn.config.json"), configContent)

	// main.py
	mainContent := `def main(req):
    query = (req.get("query") or {})
    name = query.get("name", "World")
    return {
        "message": f"Hello, {name} from FastFN Python!",
        "query": query,
    }
`
	writeFile(filepath.Join(dirPath, "main.py"), mainContent)

	// requirements.txt
	writeFile(filepath.Join(dirPath, "requirements.txt"), "# Add your dependencies here\n")
}

func createPhpFunction(name, dirPath string) {
	// fn.config.json
	configContent := `{
  "runtime": "php",
  "name": "` + name + `",
  "version": "1.0.0",
  "entrypoint": "handler.php"
}`
	writeFile(filepath.Join(dirPath, "fn.config.json"), configContent)

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
	// fn.config.json
	configContent := `{
  "runtime": "lua",
  "name": "` + name + `",
  "version": "1.0.0",
  "entrypoint": "handler.lua"
}`
	writeFile(filepath.Join(dirPath, "fn.config.json"), configContent)

	// handler.lua
	handlerContent := `local cjson = require("cjson.safe")

function handler(event)
    local query = event.query or {}
    local name = query.name or "World"
    return {
        status = 200,
        headers = { ["Content-Type"] = "application/json" },
        body = cjson.encode({
            message = "Hello, " .. tostring(name) .. " from FastFN Lua!",
            input_query = query
        })
    }
end
`
	writeFile(filepath.Join(dirPath, "handler.lua"), handlerContent)
}

func createRustFunction(name, dirPath string) {
	// fn.config.json
	configContent := `{
  "runtime": "rust",
  "name": "` + name + `",
  "version": "1.0.0",
  "entrypoint": "handler.rs"
}`
	writeFile(filepath.Join(dirPath, "fn.config.json"), configContent)

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
		log.Fatalf("Failed to write to %s: %v", path, err)
	}
}
