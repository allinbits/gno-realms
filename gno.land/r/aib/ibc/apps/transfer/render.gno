package transfer

// Render is forwarded to the implementation, JSON routes included (see
// r/aib/ibc/core/render.gno for the reasoning). The routes the e2e suite and
// tooling read, listed on Logic.Render, are pinned by the z0e filetest.
func Render(path string) string {
	if impl == nil {
		return "# IBC transfer\n\nNo implementation installed.\n"
	}
	return impl.Render(path)
}
