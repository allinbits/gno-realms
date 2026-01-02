package core

import (
	"encoding/base64"
	"strconv"
	"strings"
	"time"

	"gno.land/p/aib/ibc/lightclient"
	"gno.land/p/aib/ibc/lightclient/tendermint"
	"gno.land/p/aib/ibc/types"
	"gno.land/p/aib/jsonpage"
	"gno.land/p/nt/avl"
	"gno.land/p/nt/mux"
	"gno.land/p/nt/seqid"
	"gno.land/p/nt/ufmt"
	"gno.land/p/onbloc/json"
)

func Render(path string) string {
	router := mux.NewRouter()
	router.HandleFunc("", renderHome)
	router.HandleFunc("apps", renderApps)
	router.HandleFunc("clients", renderClients)
	router.HandleFunc("clients/{id}", renderClient)
	router.HandleFunc("clients/{id}/status", renderClientStatus)
	router.HandleFunc("clients/{id}/consensus_states", renderClientConsensusStates)
	router.HandleFunc("clients/{id}/consensus_states/{revision_number}/{revision_height}", renderClientConsensusState)
	router.HandleFunc("clients/{id}/next_sequence_send", renderClientNextSequenceSend)
	router.HandleFunc("clients/{id}/packet_commitments", renderClientPacketCommitments)
	router.HandleFunc("clients/{id}/packet_receipts", renderClientPacketReceipts)
	router.HandleFunc("clients/{id}/packet_acknowledgements", renderClientPacketAcknowledgements)
	router.HandleFunc("clients/{id}/unreceived_packets", renderClientUnreceivedPackets)
	return router.Render(path)
}

func renderHome(w *mux.ResponseWriter, r *mux.Request) {
	// TODO list available endpoints ?
	w.Write(`["Hello IBC!"]`)
}

func renderApps(w *mux.ResponseWriter, r *mux.Request) {
	var nodes []*json.Node
	for port, app := range store.routes {
		nodes = append(nodes, json.ObjectNode("", map[string]*json.Node{
			"port_id":  json.StringNode("", port),
			"pkg_path": json.StringNode("", app.pkgPath),
			"address":  json.StringNode("", app.address.String()),
		}))
	}
	renderNode(w, json.ArrayNode("", nodes))
}

func renderClients(w *mux.ResponseWriter, r *mux.Request) {
	renderNode(w, jsonpage.Render(store.clientByID, r, nil))
}

func renderClient(w *mux.ResponseWriter, r *mux.Request) {
	id := r.GetVar("id")
	c := store.getClient(id)
	if c == nil {
		renderNode(w, nodeErrorClientNotFound(id))
		return
	}
	renderNode(w, c.RenderJSON())
}

func renderClientStatus(w *mux.ResponseWriter, r *mux.Request) {
	id := r.GetVar("id")
	c := store.getClient(id)
	if c == nil {
		renderNode(w, nodeErrorClientNotFound(id))
		return
	}
	renderNode(w, json.ObjectNode("", map[string]*json.Node{
		"status": json.StringNode("", c.lightClient.Status()),
	}))
}

func renderClientConsensusStates(w *mux.ResponseWriter, r *mux.Request) {
	id := r.GetVar("id")
	c := store.getClient(id)
	if c == nil {
		renderNode(w, nodeErrorClientNotFound(id))
		return
	}
	renderNode(w, c.renderConsensusStates(r))
}

func renderClientConsensusState(w *mux.ResponseWriter, r *mux.Request) {
	var (
		id             = r.GetVar("id")
		revisionNumber = r.GetVar("revision_number")
		revisionHeight = r.GetVar("revision_height")
		heightStr      = revisionNumber + "/" + revisionHeight
	)
	height, err := types.ParseHeight(heightStr)
	if err != nil {
		renderNode(w, nodeError("cant parse height %s: %v", heightStr, err))
		return
	}
	c := store.getClient(id)
	if c == nil {
		renderNode(w, nodeErrorClientNotFound(id))
		return
	}
	switch c.typ {
	case lightclient.Tendermint:
		lc := c.lightClient.(*tendermint.TMLightClient)
		cs, found := lc.GetConsensusState(height)
		if !found {
			renderNode(w, nodeError("consensus state not found for height %s", height))
			return
		}
		renderNode(w, renderConsensusState(height, cs))
	}
}

func renderClientNextSequenceSend(w *mux.ResponseWriter, r *mux.Request) {
	id := r.GetVar("id")
	c := store.getClient(id)
	if c == nil {
		renderNode(w, nodeErrorClientNotFound(id))
		return
	}
	w.Write(ufmt.Sprintf(`{"next_sequence_send": %d}"`, int64(c.sendSeq)+1))
}

func renderClientPacketCommitments(w *mux.ResponseWriter, r *mux.Request) {
	id := r.GetVar("id")
	c := store.getClient(id)
	if c == nil {
		renderNode(w, nodeErrorClientNotFound(id))
		return
	}
	renderCommitments(w, r, c.packetCommitmentsBySeq)
}

func renderClientPacketReceipts(w *mux.ResponseWriter, r *mux.Request) {
	id := r.GetVar("id")
	c := store.getClient(id)
	if c == nil {
		renderNode(w, nodeErrorClientNotFound(id))
		return
	}
	renderCommitments(w, r, c.packetReceiptsBySeq)
}

func renderClientPacketAcknowledgements(w *mux.ResponseWriter, r *mux.Request) {
	id := r.GetVar("id")
	c := store.getClient(id)
	if c == nil {
		renderNode(w, nodeErrorClientNotFound(id))
		return
	}
	renderCommitments(w, r, c.packetAcknowledgementsBySeq)
}

func renderCommitments(w *mux.ResponseWriter, r *mux.Request, tree *avl.Tree) {
	renderNode(w, jsonpage.Render(tree, r, func(k string, v any) *json.Node {
		id, _ := seqid.FromBinary(k)
		return json.ObjectNode("", map[string]*json.Node{
			"sequence": json.StringNode("", strconv.FormatUint(uint64(id), 10)),
			"data":     json.StringNode("", base64.StdEncoding.EncodeToString(v.([]byte))),
		})
	}))
}

// renderClientUnreceivedPackets returns, given a list of sequences, the
// sequences for which no counterparty packet commitments have been received.
// This is done by checking if a receipt exists on this chain for the packet
// sequence.
func renderClientUnreceivedPackets(w *mux.ResponseWriter, r *mux.Request) {
	id := r.GetVar("id")
	c := store.getClient(id)
	if c == nil {
		renderNode(w, nodeErrorClientNotFound(id))
		return
	}
	seqs := strings.Split(strings.TrimSpace(r.Query.Get("sequences")), ",")
	var unreceivedSeqs []*json.Node
	for _, seq := range seqs {
		seqi, err := strconv.ParseUint(seq, 10, 64)
		if err != nil {
			renderNode(w, nodeError(ufmt.Sprintf("invalid sequence %q: %v", seq, err)))
			return
		}
		if !c.hasPacketReceipt(seqi) {
			unreceivedSeqs = append(unreceivedSeqs, json.StringNode("", seq))
		}
	}
	renderNode(w, json.ObjectNode("", map[string]*json.Node{
		"height":               renderHeight(types.GetSelfHeight()),
		"unreceived_sequences": json.ArrayNode("", unreceivedSeqs),
	}))
}

// Implements jsonpage.JSONRenderer
func (c *client) RenderJSON() *json.Node {
	m := map[string]*json.Node{
		"id":                     json.StringNode("", c.id),
		"type":                   json.StringNode("", c.typ),
		"creator":                json.StringNode("", c.creator.String()),
		"status":                 json.StringNode("", c.lightClient.Status()),
		"counterparty_client_id": json.StringNode("", c.counterpartyClientID),
	}
	var prefixes []*json.Node
	for _, m := range c.counterpartyMerklePrefix {
		prefixes = append(prefixes, json.StringNode("", string(m)))
	}
	m["counterparty_merke_prefix"] = json.ArrayNode("", prefixes)
	switch c.typ {
	case lightclient.Tendermint:
		lc := c.lightClient.(*tendermint.TMLightClient)
		m["client_state"] = json.ObjectNode("", map[string]*json.Node{
			"chain_id":         json.StringNode("", lc.ClientState.ChainID),
			"latest_height":    renderHeight(lc.ClientState.LatestHeight),
			"frozen_height":    renderHeight(lc.ClientState.FrozenHeight),
			"trust_level":      renderFraction(lc.ClientState.TrustLevel),
			"trusting_period":  renderDuration(lc.ClientState.TrustingPeriod),
			"unbonding_period": renderDuration(lc.ClientState.UnbondingPeriod),
			"max_clock_drift":  renderDuration(lc.ClientState.MaxClockDrift),
			"upgrade_path":     renderStrings(lc.ClientState.UpgradePath),
		})
		lastConsState, found := lc.GetConsensusState(lc.LatestHeight())
		if found {
			m["last_consensus_state"] = renderConsensusState(lc.LatestHeight(), lastConsState)
		}
	}
	return json.ObjectNode("", m)
}

func (c *client) renderConsensusStates(r *mux.Request) *json.Node {
	switch c.typ {
	case lightclient.Tendermint:
		lc := c.lightClient.(*tendermint.TMLightClient)
		return jsonpage.Render(lc.ConsensusStateByHeight, r, func(k string, v any) *json.Node {
			cs := v.(*tendermint.ConsensusState)
			height := types.ParseHeightNatSort(k)
			return renderConsensusState(height, cs)
		})
	}
	return nodeError("unhandled client type %s", c.typ)
}

func renderConsensusState(height types.Height, cs *tendermint.ConsensusState) *json.Node {
	return json.ObjectNode("", map[string]*json.Node{
		"height":               renderHeight(height),
		"timestamp":            json.NumberNode("", float64(cs.Timestamp.Unix())),
		"root":                 json.StringNode("", base64.StdEncoding.EncodeToString(cs.Root.Hash)),
		"next_validators_hash": json.StringNode("", base64.StdEncoding.EncodeToString(cs.NextValidatorsHash)),
	})
}

func renderHeight(h types.Height) *json.Node {
	return json.ObjectNode("", map[string]*json.Node{
		"revision_number": json.NumberNode("", float64(h.RevisionNumber)),
		"revision_height": json.NumberNode("", float64(h.RevisionHeight)),
	})
}

func renderFraction(f tendermint.Fraction) *json.Node {
	return json.ObjectNode("", map[string]*json.Node{
		"numerator":   json.NumberNode("", float64(f.Numerator)),
		"denominator": json.NumberNode("", float64(f.Denominator)),
	})
}

func renderDuration(d time.Duration) *json.Node {
	return json.NumberNode("", d.Seconds())
}

func renderStrings(s []string) *json.Node {
	var nodes []*json.Node
	for _, s := range s {
		nodes = append(nodes, json.StringNode("", s))
	}
	return json.ArrayNode("", nodes)
}

func renderNode(w *mux.ResponseWriter, n *json.Node) {
	bz, err := json.Marshal(n)
	if err != nil {
		panic(err)
	}
	w.Write(string(bz))
}

func nodeErrorClientNotFound(id string) *json.Node {
	return nodeError("client %s not found", id)
}

func nodeError(msg string, args ...any) *json.Node {
	return json.ObjectNode("", map[string]*json.Node{
		"error": json.StringNode("", ufmt.Sprintf(msg, args...)),
	})
}
