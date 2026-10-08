package impl

import (
	"encoding/base64"
	"strconv"
	"strings"
	"time"

	"gno.land/p/aib/ibc/lightclient/tendermint/v0"
	"gno.land/p/aib/ibc/lightclient/v0"
	"gno.land/p/aib/ibc/types/v0"
	"gno.land/p/aib/jsonpage/v0"
	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/p/onbloc/json/v0"
	"gno.land/r/aib/ibc/core"
)

// Render serves every path of the core realm: the proxy forwards its Render
// here (see core.Render). The JSON routes under clients/ are read by the
// relayer through vm/qrender; their shape is pinned by the z0c filetest.
func (l *logic) Render(path string) string {
	router := mux.NewRouter()
	NewRenderer(l.store).Register(router)
	return router.Render(path)
}

// Renderer serves the routes of the core realm from a Store. It is exported,
// with its handlers and the JSON helpers below, so a later implementation can
// reuse what it does not change:
//
//	rd := implv0.NewRenderer(store)
//	router.HandleFunc("", myHome) // overrides first: mux matches in registration order
//	rd.Register(router)
//
// A later implementation cannot build a Renderer literal (a realm cannot
// construct another realm's types), hence NewRenderer.
type Renderer struct {
	store core.Store
}

// NewRenderer returns a Renderer reading from s.
func NewRenderer(s core.Store) *Renderer {
	return &Renderer{store: s}
}

// Register installs every route of this implementation on router. Routes
// already registered on router take precedence.
func (rd *Renderer) Register(router *mux.Router) {
	router.HandleFunc("", rd.Home)
	router.HandleFunc("admin", rd.Admin)
	router.HandleFunc("apps", rd.Apps)
	router.HandleFunc("apps/pending", rd.PendingApps)
	router.HandleFunc("clients", rd.Clients)
	router.HandleFunc("clients/{id}", rd.Client)
	router.HandleFunc("clients/{id}/status", rd.ClientStatus)
	router.HandleFunc("clients/{id}/consensus_states", rd.ClientConsensusStates)
	router.HandleFunc("clients/{id}/consensus_states/{revision_number}/{revision_height}", rd.ClientConsensusState)
	router.HandleFunc("clients/{id}/next_sequence_send", rd.ClientNextSequenceSend)
	router.HandleFunc("clients/{id}/packet_commitments", rd.ClientPacketCommitments)
	router.HandleFunc("clients/{id}/packet_commitments/{sequence}", rd.ClientPacketCommitment)
	router.HandleFunc("clients/{id}/packet_receipts", rd.ClientPacketReceipts)
	router.HandleFunc("clients/{id}/packet_receipts/{sequence}", rd.ClientPacketReceipt)
	router.HandleFunc("clients/{id}/packet_acknowledgements", rd.ClientPacketAcknowledgements)
	router.HandleFunc("clients/{id}/packet_acknowledgements/{sequence}", rd.ClientPacketAcknowledgement)
	router.HandleFunc("clients/{id}/unreceived_packets", rd.ClientUnreceivedPackets)
}

func (rd *Renderer) Home(w *mux.ResponseWriter, r *mux.Request) {
	var out strings.Builder
	out.WriteString("# IBC core\n\n")
	out.WriteString("IBC v2 core state and query endpoints.\n\n")
	out.WriteString(RenderImplDisclosure())
	ids := rd.store.ClientIDs()
	out.WriteString(ufmt.Sprintf("## Clients (%d)\n\n", len(ids)))
	if len(ids) > 0 {
		out.WriteString("| Client | St. | Creator | Cpty | Height | Time | CS | Seq | Cmts | Rcpts | Acks |\n")
		out.WriteString("|--------|-----|---------|------|--------|------|----|-----|------|-------|------|\n")
		for _, id := range ids {
			c := rd.store.Client(id)
			lc := c.LightClient()
			var (
				nConsStates int
				heightTime  string
			)
			switch c.Type() {
			case lightclient.Tendermint:
				tm := lc.(*tendermint.TMLightClient)
				nConsStates = tm.ConsensusStateByHeight.Size()
				if cs, found := tm.GetConsensusState(tm.LatestHeight()); found {
					heightTime = cs.Timestamp.UTC().Format(time.RFC3339)
				}
			}
			out.WriteString(ufmt.Sprintf(
				"| [`%s`](/r/aib/ibc/core:clients/%s) | [%s](/r/aib/ibc/core:clients/%s/status) | %s | %s | [%s](/r/aib/ibc/core:clients/%s/consensus_states/%d/%d) | %s | [%d](/r/aib/ibc/core:clients/%s/consensus_states) | [%d](/r/aib/ibc/core:clients/%s/next_sequence_send) | [%d](/r/aib/ibc/core:clients/%s/packet_commitments) | [%d](/r/aib/ibc/core:clients/%s/packet_receipts) | [%d](/r/aib/ibc/core:clients/%s/packet_acknowledgements) |\n",
				id, id,
				lc.Status(), id,
				RenderAddr(c.Creator()),
				c.CounterpartyClientID(),
				lc.LatestHeight().String(), id, lc.LatestHeight().RevisionNumber, lc.LatestHeight().RevisionHeight,
				heightTime,
				nConsStates, id,
				int64(c.NextSequenceSend()), id,
				c.PacketCommitments().Size(), id,
				c.PacketReceipts().Size(), id,
				c.PacketAcknowledgements().Size(), id,
			))
		}
		out.WriteString("\n")
	} else {
		out.WriteString("No clients yet.\n\n")
	}
	ports := rd.store.Ports()
	out.WriteString(ufmt.Sprintf("## Apps (%d)\n\n", len(ports)))
	if len(ports) > 0 {
		out.WriteString("| Port | Pkg | Addr |\n")
		out.WriteString("|------|-----|------|\n")
		for _, port := range ports {
			app := rd.store.Route(port)
			out.WriteString(ufmt.Sprintf("| %s | %s | %s |\n", port, RenderPkgPath(app.PkgPath), RenderAddr(app.Address)))
		}
		out.WriteString("\n")
	} else {
		out.WriteString("No apps registered yet.\n\n")
	}
	out.WriteString("## JSON endpoints\n\n")
	out.WriteString("- [`admin`](/r/aib/ibc/core:admin): authority, pause state and relayers\n")
	out.WriteString("- [`apps`](/r/aib/ibc/core:apps): list registered IBC applications\n")
	out.WriteString("- [`apps/pending`](/r/aib/ibc/core:apps/pending): registrations awaiting the authority's approval\n")
	out.WriteString("- [`clients`](/r/aib/ibc/core:clients): list clients (`?page`, `?limit`)\n")
	out.WriteString("- `clients/{id}`: get client details\n")
	out.WriteString("- `clients/{id}/status`: get client status\n")
	out.WriteString("- `clients/{id}/consensus_states`: list client consensus states (`?page`, `?limit`)\n")
	out.WriteString("- `clients/{id}/consensus_states/{revision_number}/{revision_height}`: get a consensus state by height\n")
	out.WriteString("- `clients/{id}/next_sequence_send`: get the next packet sequence to send\n")
	out.WriteString("- `clients/{id}/packet_commitments`: list packet commitments (`?page`, `?limit`)\n")
	out.WriteString("- `clients/{id}/packet_commitments/{sequence}`: get a packet commitment by sequence\n")
	out.WriteString("- `clients/{id}/packet_receipts`: list packet receipts (`?page`, `?limit`)\n")
	out.WriteString("- `clients/{id}/packet_receipts/{sequence}`: get a packet receipt by sequence\n")
	out.WriteString("- `clients/{id}/packet_acknowledgements`: list packet acknowledgements (`?page`, `?limit`)\n")
	out.WriteString("- `clients/{id}/packet_acknowledgements/{sequence}`: get a packet acknowledgement by sequence\n")
	out.WriteString("- `clients/{id}/unreceived_packets?sequences=1,2,3`: return sequences without a local packet receipt\n\n")
	w.Write(out.String())
}

func (rd *Renderer) Admin(w *mux.ResponseWriter, r *mux.Request) {
	var out strings.Builder
	out.WriteString("## Authority & Relayers\n\n")
	out.WriteString("- **Authority members**:\n")
	for _, m := range core.AuthorityMembers() {
		out.WriteString(ufmt.Sprintf("  - %s\n", RenderAddr(m)))
	}
	out.WriteString(ufmt.Sprintf("- **Paused**: %t\n", core.Paused()))
	out.WriteString(ufmt.Sprintf("- **Implementation**: %s\n", RenderImplRef(core.ImplPath(), core.ImplVersion())))
	out.WriteString("- **Registered implementations**:\n")
	for _, p := range core.RegisteredImplPaths() {
		out.WriteString(ufmt.Sprintf("  - %s\n", RenderPkgPath(p)))
	}
	relayers := core.Relayers()
	if len(relayers) == 0 {
		out.WriteString("- **Relayers**: any (whitelist empty)\n")
	} else {
		out.WriteString("- **Relayers**:\n")
		for _, r := range relayers {
			out.WriteString(ufmt.Sprintf("  - %s\n", RenderAddr(r)))
		}
	}
	w.Write(out.String())
}

func (rd *Renderer) Apps(w *mux.ResponseWriter, r *mux.Request) {
	var nodes []*json.Node
	for _, port := range rd.store.Ports() {
		app := rd.store.Route(port)
		nodes = append(nodes, json.ObjectNode("", map[string]*json.Node{
			"port_id":  json.StringNode("", port),
			"pkg_path": json.StringNode("", app.PkgPath),
			"address":  json.StringNode("", app.Address.String()),
			"paused":   json.BoolNode("", app.Paused),
		}))
	}
	RenderNode(w, json.ArrayNode("", nodes))
}

// renderPendingApps lists the registrations awaiting approval, oldest key
// first. Anyone may add to this set, so the listing is capped; the count is
// always exact.
func (rd *Renderer) PendingApps(w *mux.ResponseWriter, r *mux.Request) {
	const limit = 100
	var nodes []*json.Node
	pending := rd.store.PendingApps()
	pending.IterateByOffset(0, limit, func(_ string, v any) bool {
		a := v.(core.App)
		nodes = append(nodes, json.ObjectNode("", map[string]*json.Node{
			"pkg_path": json.StringNode("", a.PkgPath),
			"address":  json.StringNode("", a.Address.String()),
		}))
		return false
	})
	RenderNode(w, json.ObjectNode("", map[string]*json.Node{
		"total":   json.NumberNode("", float64(pending.Size())),
		"pending": json.ArrayNode("", nodes),
	}))
}

func (rd *Renderer) Clients(w *mux.ResponseWriter, r *mux.Request) {
	RenderNode(w, jsonpage.Render(rd.store.Clients(), r, func(_ string, v any) *json.Node {
		return ClientJSON(v.(core.Client))
	}))
}

func (rd *Renderer) Client(w *mux.ResponseWriter, r *mux.Request) {
	id := r.GetVar("id")
	c := rd.store.Client(id)
	if c == nil {
		RenderNode(w, NodeErrorClientNotFound(id))
		return
	}
	RenderNode(w, ClientJSON(c))
}

func (rd *Renderer) ClientStatus(w *mux.ResponseWriter, r *mux.Request) {
	id := r.GetVar("id")
	c := rd.store.Client(id)
	if c == nil {
		RenderNode(w, NodeErrorClientNotFound(id))
		return
	}
	RenderNode(w, json.ObjectNode("", map[string]*json.Node{
		"status": json.StringNode("", c.LightClient().Status()),
	}))
}

func (rd *Renderer) ClientConsensusStates(w *mux.ResponseWriter, r *mux.Request) {
	id := r.GetVar("id")
	c := rd.store.Client(id)
	if c == nil {
		RenderNode(w, NodeErrorClientNotFound(id))
		return
	}
	RenderNode(w, ConsensusStatesJSON(c, r))
}

func (rd *Renderer) ClientConsensusState(w *mux.ResponseWriter, r *mux.Request) {
	var (
		id             = r.GetVar("id")
		revisionNumber = r.GetVar("revision_number")
		revisionHeight = r.GetVar("revision_height")
		heightStr      = revisionNumber + "/" + revisionHeight
	)
	height, err := types.ParseHeight(heightStr)
	if err != nil {
		RenderNode(w, NodeError("cant parse height %s: %v", heightStr, err))
		return
	}
	c := rd.store.Client(id)
	if c == nil {
		RenderNode(w, NodeErrorClientNotFound(id))
		return
	}
	switch c.Type() {
	case lightclient.Tendermint:
		lc := c.LightClient().(*tendermint.TMLightClient)
		cs, found := lc.GetConsensusState(height)
		if !found {
			RenderNode(w, NodeError("consensus state not found for height %s", height))
			return
		}
		RenderNode(w, RenderConsensusState(height, cs))
	}
}

func (rd *Renderer) ClientNextSequenceSend(w *mux.ResponseWriter, r *mux.Request) {
	id := r.GetVar("id")
	c := rd.store.Client(id)
	if c == nil {
		RenderNode(w, NodeErrorClientNotFound(id))
		return
	}
	w.Write(ufmt.Sprintf(`{"next_sequence_send": %d}`, int64(c.NextSequenceSend())))
}

func (rd *Renderer) ClientPacketCommitments(w *mux.ResponseWriter, r *mux.Request) {
	id := r.GetVar("id")
	c := rd.store.Client(id)
	if c == nil {
		RenderNode(w, NodeErrorClientNotFound(id))
		return
	}
	RenderCommitments(w, r, c.PacketCommitments())
}

func (rd *Renderer) ClientPacketCommitment(w *mux.ResponseWriter, r *mux.Request) {
	id := r.GetVar("id")
	c := rd.store.Client(id)
	if c == nil {
		RenderNode(w, NodeErrorClientNotFound(id))
		return
	}
	RenderCommitment(w, r, c.PacketCommitments())
}

func (rd *Renderer) ClientPacketReceipts(w *mux.ResponseWriter, r *mux.Request) {
	id := r.GetVar("id")
	c := rd.store.Client(id)
	if c == nil {
		RenderNode(w, NodeErrorClientNotFound(id))
		return
	}
	RenderCommitments(w, r, c.PacketReceipts())
}

func (rd *Renderer) ClientPacketReceipt(w *mux.ResponseWriter, r *mux.Request) {
	id := r.GetVar("id")
	c := rd.store.Client(id)
	if c == nil {
		RenderNode(w, NodeErrorClientNotFound(id))
		return
	}
	RenderCommitment(w, r, c.PacketReceipts())
}

func (rd *Renderer) ClientPacketAcknowledgements(w *mux.ResponseWriter, r *mux.Request) {
	id := r.GetVar("id")
	c := rd.store.Client(id)
	if c == nil {
		RenderNode(w, NodeErrorClientNotFound(id))
		return
	}
	RenderCommitments(w, r, c.PacketAcknowledgements())
}

func (rd *Renderer) ClientPacketAcknowledgement(w *mux.ResponseWriter, r *mux.Request) {
	id := r.GetVar("id")
	c := rd.store.Client(id)
	if c == nil {
		RenderNode(w, NodeErrorClientNotFound(id))
		return
	}
	RenderCommitment(w, r, c.PacketAcknowledgements())
}

func RenderCommitment(w *mux.ResponseWriter, r *mux.Request, tree bptree.ITree) {
	seqStr := r.GetVar("sequence")
	seq, err := strconv.ParseUint(seqStr, 10, 64)
	if err != nil {
		RenderNode(w, NodeError("invalid sequence %q: %v", seqStr, err))
		return
	}
	v := tree.Get(seqid.ID(seq).Binary())
	if v == nil {
		RenderNode(w, NodeError("sequence %s not found", seqStr))
		return
	}
	RenderNode(w, CommitmentNode(seq, v.([]byte)))
}

func RenderCommitments(w *mux.ResponseWriter, r *mux.Request, tree bptree.ITree) {
	RenderNode(w, jsonpage.Render(tree, r, func(k string, v any) *json.Node {
		id, _ := seqid.FromBinary(k)
		return CommitmentNode(uint64(id), v.([]byte))
	}))
}

func CommitmentNode(sequence uint64, data []byte) *json.Node {
	return json.ObjectNode("", map[string]*json.Node{
		"sequence": json.StringNode("", strconv.FormatUint(sequence, 10)),
		"data":     json.StringNode("", base64.StdEncoding.EncodeToString(data)),
	})
}

// renderClientUnreceivedPackets returns, given a list of sequences, the
// sequences for which no counterparty packet commitments have been received.
// This is done by checking if a receipt exists on this chain for the packet
// sequence.
func (rd *Renderer) ClientUnreceivedPackets(w *mux.ResponseWriter, r *mux.Request) {
	id := r.GetVar("id")
	c := rd.store.Client(id)
	if c == nil {
		RenderNode(w, NodeErrorClientNotFound(id))
		return
	}
	seqs := strings.Split(strings.TrimSpace(r.Query.Get("sequences")), ",")
	var unreceivedSeqs []*json.Node
	for _, seq := range seqs {
		seqi, err := strconv.ParseUint(seq, 10, 64)
		if err != nil {
			RenderNode(w, NodeError(ufmt.Sprintf("invalid sequence %q: %v", seq, err)))
			return
		}
		if !c.HasPacketReceipt(seqi) {
			unreceivedSeqs = append(unreceivedSeqs, json.StringNode("", seq))
		}
	}
	RenderNode(w, json.ObjectNode("", map[string]*json.Node{
		"height":               RenderHeight(types.GetSelfHeight()),
		"unreceived_sequences": json.ArrayNode("", unreceivedSeqs),
	}))
}

// ClientJSON is the clients/{id} document, also the items of clients.
func ClientJSON(c core.Client) *json.Node {
	m := map[string]*json.Node{
		"id":                     json.StringNode("", c.ID()),
		"type":                   json.StringNode("", c.Type()),
		"creator":                json.StringNode("", c.Creator().String()),
		"status":                 json.StringNode("", c.LightClient().Status()),
		"counterparty_client_id": json.StringNode("", c.CounterpartyClientID()),
	}
	var prefixes []*json.Node
	for _, p := range c.CounterpartyMerklePrefix() {
		prefixes = append(prefixes, json.StringNode("", string(p)))
	}
	m["counterparty_merke_prefix"] = json.ArrayNode("", prefixes)
	switch c.Type() {
	case lightclient.Tendermint:
		lc := c.LightClient().(*tendermint.TMLightClient)
		m["client_state"] = json.ObjectNode("", map[string]*json.Node{
			"chain_id":         json.StringNode("", lc.ClientState.ChainID),
			"latest_height":    RenderHeight(lc.ClientState.LatestHeight),
			"frozen_height":    RenderHeight(lc.ClientState.FrozenHeight),
			"trust_level":      RenderFraction(lc.ClientState.TrustLevel),
			"trusting_period":  RenderDuration(lc.ClientState.TrustingPeriod),
			"unbonding_period": RenderDuration(lc.ClientState.UnbondingPeriod),
			"max_clock_drift":  RenderDuration(lc.ClientState.MaxClockDrift),
			"upgrade_path":     RenderStrings(lc.ClientState.UpgradePath),
		})
		lastConsState, found := lc.GetConsensusState(lc.LatestHeight())
		if found {
			m["last_consensus_state"] = RenderConsensusState(lc.LatestHeight(), lastConsState)
		}
	}
	return json.ObjectNode("", m)
}

func ConsensusStatesJSON(c core.Client, r *mux.Request) *json.Node {
	switch c.Type() {
	case lightclient.Tendermint:
		lc := c.LightClient().(*tendermint.TMLightClient)
		return jsonpage.Render(lc.ConsensusStateByHeight, r, func(k string, v any) *json.Node {
			cs := v.(*tendermint.ConsensusState)
			height := types.ParseHeightNatSort(k)
			return RenderConsensusState(height, cs)
		})
	}
	return NodeError("unhandled client type %s", c.Type())
}

func RenderConsensusState(height types.Height, cs *tendermint.ConsensusState) *json.Node {
	return json.ObjectNode("", map[string]*json.Node{
		"height":               RenderHeight(height),
		"timestamp":            json.NumberNode("", float64(cs.Timestamp.Unix())),
		"root":                 json.StringNode("", base64.StdEncoding.EncodeToString(cs.Root.Hash)),
		"next_validators_hash": json.StringNode("", base64.StdEncoding.EncodeToString(cs.NextValidatorsHash)),
	})
}

func RenderHeight(h types.Height) *json.Node {
	return json.ObjectNode("", map[string]*json.Node{
		"revision_number": json.NumberNode("", float64(h.RevisionNumber)),
		"revision_height": json.NumberNode("", float64(h.RevisionHeight)),
	})
}

func RenderFraction(f tendermint.Fraction) *json.Node {
	return json.ObjectNode("", map[string]*json.Node{
		"numerator":   json.NumberNode("", float64(f.Numerator)),
		"denominator": json.NumberNode("", float64(f.Denominator)),
	})
}

func RenderDuration(d time.Duration) *json.Node {
	return json.NumberNode("", d.Seconds())
}

func RenderStrings(s []string) *json.Node {
	var nodes []*json.Node
	for _, s := range s {
		nodes = append(nodes, json.StringNode("", s))
	}
	return json.ArrayNode("", nodes)
}

// RenderNode writes n as JSON.
func RenderNode(w *mux.ResponseWriter, n *json.Node) {
	bz, err := json.Marshal(n)
	if err != nil {
		panic(err)
	}
	w.Write(string(bz))
}

func NodeErrorClientNotFound(id string) *json.Node {
	return NodeError("client %s not found", id)
}

// NodeError is the JSON error object every route answers on failure.
func NodeError(msg string, args ...any) *json.Node {
	return json.ObjectNode("", map[string]*json.Node{
		"error": json.StringNode("", ufmt.Sprintf(msg, args...)),
	})
}

// RenderImplDisclosure is the upgradeable-realm notice of the home page.
func RenderImplDisclosure() string {
	return ufmt.Sprintf("**Upgradeable realm**: the client and packet lifecycle runs in the implementation %s, replaceable by the authority with `UpdateImpl` (see [`admin`](/r/aib/ibc/core:admin)).\n\n",
		RenderImplRef(core.ImplPath(), core.ImplVersion()))
}

func RenderImplRef(path, version string) string {
	if path == "" {
		return "none installed"
	}
	return ufmt.Sprintf("%s (version %s)", RenderPkgPath(path), version)
}

func RenderPkgPath(path string) string {
	const prefix = "gno.land"
	if strings.HasPrefix(path, prefix) {
		return ufmt.Sprintf("[`%s`](%s)", path, path[len(prefix):])
	}
	return "`" + path + "`"
}

func RenderAddr(addr address) string {
	s := addr.String()
	short := s
	if len(s) > 10 {
		short = s[:6] + "…" + s[len(s)-4:]
	}
	return ufmt.Sprintf("[%s](/u/%s)", short, s)
}
