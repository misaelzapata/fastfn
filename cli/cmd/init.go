package cmd

import (
	"fmt"
	"log"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"
)

var template string

var initCmd = &cobra.Command{
	Use:   "init [name]",
	Short: "Create a new function structure",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		name := args[0]
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
		case "rust":
			createRustFunction(name, dirPath)
		default:
			log.Fatalf("Unknown template: %s. Supported: node, python, php, rust", template)
		}

		fmt.Printf("Created function '%s' in %s (runtime: %s)\n", name, dirPath, template)
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
		case "rust":
			fmt.Println(" - handler.rs")
		}
		fmt.Println("\nRun 'fastfn dev' in the parent directory to start all functions.")
	},
}

func init() {
	rootCmd.AddCommand(initCmd)
	initCmd.Flags().StringVarP(&template, "template", "t", "node", "Function runtime (node, python, php, rust)")
}

func createNodeFunction(name, dirPath string) {
	// fn.config.json
	configContent := `{
  "runtime": "node",
  "name": "` + name + `",
  "version": "1.0.0",
  "entrypoint": "handler.js"
}`
	writeFile(filepath.Join(dirPath, "fn.config.json"), configContent)

	// handler.js
	handlerContent := `/**
 * @typedef {Object} Context
 * @property {string} request_id
 * @property {Object} debug
 */

/**
 * Handle the request.
 * @param {import('@fastfn/runtime').Request} event - The input event (including context)
 * @returns {Promise<Object>} The response
 */
module.exports.handler = async (event) => {
  const context = event.context || {};
  
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      message: "Hello from FastFn Node!",
      input: event,
      requestId: context.request_id
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
  "entrypoint": "main.py"
}`
	writeFile(filepath.Join(dirPath, "fn.config.json"), configContent)

	// main.py
	mainContent := `from typing import Any, Dict

def handler(event: Dict[str, Any]) -> Dict[str, Any]:
    """
    Handle the request.
    """
    context = event.get("context", {})
    
    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": {
            "message": "Hello from FastFn Python!",
            "input": event,
            "requestId": context.get("request_id")
        }
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

function handler(array $event): array {
    return [
        'status' => 200,
        'headers' => ['Content-Type' => 'application/json'],
        'body' => json_encode([
            'message' => 'Hello from FastFn PHP!',
            'input' => $event
        ]),
    ];
}
`
	writeFile(filepath.Join(dirPath, "handler.php"), handlerContent)
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

pub fn handler(event: Value) -> Value {
    json!({
        "status": 200,
        "headers": { "Content-Type": "application/json" },
        "body": json!({
            "message": "Hello from FastFn Rust!",
            "input": event
        }).to_string()
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
