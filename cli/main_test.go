package main

import "testing"

func TestMainCallsExecute(t *testing.T) {
	orig := mainExecute
	t.Cleanup(func() { mainExecute = orig })

	called := false
	mainExecute = func() {
		called = true
	}

	main()

	if !called {
		t.Fatal("expected main to call mainExecute")
	}
}
