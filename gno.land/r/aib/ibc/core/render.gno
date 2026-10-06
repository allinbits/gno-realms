package core

// Render is forwarded to the implementation: the pages for humans and the
// JSON routes alike. Forwarding the JSON routes rather than freezing them
// here keeps them upgradeable with the verifier they read (a frozen
// consensus-state route could not follow a migration to a new light-client
// type). The routes the relayer consumes, listed on Logic.Render, are a
// compatibility contract pinned by the z0c filetest.
func Render(path string) string {
	if impl == nil {
		return "# IBC core\n\nNo implementation installed.\n"
	}
	return impl.Render(path)
}
