package main

import (
	appstesting "gno.land/r/aib/ibc/apps/testing"
	"gno.land/r/aib/ibc/core"
)

// RegisterApp fails because portID contains invalid characters (parentheses)
func main() {
	core.RegisterApp(cross, "invalid(port)", appstesting.NewApp(cross))
}

// Error:
// invalid portID: validate port identifier: identifier invalid(port) must contain only alphanumeric or the following characters: '.', '_', '+', '-', '#', '/', '[', ']', '<', '>'
