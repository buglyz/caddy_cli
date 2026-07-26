package main

import (
	"fmt"
	"os"

	"github.com/buglyz/caddy_cli/internal/caddyctl"
)

func main() {
	app, err := caddyctl.New(os.Stdin, os.Stdout, os.Stderr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "错误: %v\n", err)
		os.Exit(1)
	}
	if err := app.Run(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "错误: %v\n", err)
		os.Exit(1)
	}
}
