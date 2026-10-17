package ibcgov

import (
	"chain"
	"encoding/hex"
	"strings"

	"gno.land/p/aib/ibc/lightclient/ethereum/v0"
	"gno.land/r/aib/ibc/apps/transfer"
	"gno.land/r/aib/ibc/core"
)

// The builders of the IBC core's and the transfer app's administration (ADR
// pr6375 R14). Both realms gate every loosening power on a call from this
// realm, so each power waits for its decision's delay here: upgrades,
// relayers, recovery, approvals, client migration and membership 7 days;
// tightening (pause, block, reject, remove) at once; unpauses at once, spent
// under a guardian hold.

// adminParams is a decision that makes one administrative call.
type adminParams struct {
	op   string
	args []string
}

// check is why the administrative call cannot apply on the live state, or "":
// every failure the call itself would raise and that a later state could
// clear, so the decision is spent deterministically instead of aborting and
// staying pending, to run later under its old approval when the state
// changes back (Codex review #15).
func (p *adminParams) check() string {
	a := p.args
	switch p.op {
	case "core update impl":
		return core.CheckUpdateImpl(a[0])
	case "core add relayer":
		if isRelayer(address(a[0])) {
			return a[0] + " is a listed relayer already"
		}
	case "core remove relayer":
		if !isRelayer(address(a[0])) {
			return a[0] + " is not a listed relayer"
		}
	case "core recover client":
		// The core's checks and the light client's, with no change.
		return core.CheckRecoverClient(a[0], a[1])
	case "core approve app":
		if !core.IsAppPending(a[0], a[1]) {
			return "no pending registration of " + a[1] + " for port " + a[0]
		}
		if core.AppPkgPath(a[0]) != "" {
			return "port " + a[0] + " is registered already"
		}
	case "core reject app":
		if !core.IsAppPending(a[0], a[1]) {
			return "no pending registration of " + a[1] + " for port " + a[0]
		}
	case "core pause":
		if core.Paused() {
			return "the core is paused already"
		}
	case "core pause app":
		if core.AppPkgPath(a[0]) == "" {
			return "no app on port " + a[0]
		}
		if core.IsAppPaused(a[0]) {
			return "app " + a[0] + " is paused already"
		}
	case "core add member":
		if core.IsAuthorityMember(address(a[0])) {
			return a[0] + " is a member already"
		}
	case "core remove member":
		if address(a[0]) == chain.PackageAddress(PkgPath) {
			return "this realm stays a member of the core's authority"
		}
		if !core.IsAuthorityMember(address(a[0])) {
			return a[0] + " is not a member"
		}
	case "core migrate client":
		bz, err := hex.DecodeString(a[2])
		if err != nil {
			return "params are not hex"
		}
		if core.ClientType(a[0]) != ethereum.ClientType {
			return a[0] + " is no Ethereum client"
		}
		return core.CheckMigrateClient(a[0], a[1], bz)
	case "transfer update impl":
		return transfer.CheckUpdateImpl(a[0])
	case "transfer block":
		if transfer.IsBlocked(address(a[0])) {
			return a[0] + " is blocked already"
		}
	case "transfer unblock":
		if !transfer.IsBlocked(address(a[0])) {
			return a[0] + " is not blocked"
		}
	case "transfer add member":
		if transfer.IsAuthorityMember(address(a[0])) {
			return a[0] + " is a member already"
		}
	case "transfer remove member":
		if address(a[0]) == chain.PackageAddress(PkgPath) {
			return "this realm stays a member of the transfer app's authority"
		}
		if !transfer.IsAuthorityMember(address(a[0])) {
			return a[0] + " is not a member"
		}
	}
	return ""
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func (p *adminParams) apply(cur realm, t int64) (string, string) {
	if refusal := p.check(); refusal != "" {
		return "", refusal
	}
	a := p.args
	switch p.op {
	case "core update impl":
		core.UpdateImpl(cross(cur), a[0])
	case "core add relayer":
		core.AddRelayer(cross(cur), address(a[0]))
	case "core remove relayer":
		core.RemoveRelayer(cross(cur), address(a[0]))
	case "core recover client":
		core.RecoverClient(cross(cur), a[0], a[1])
	case "core approve app":
		core.ApproveApp(cross(cur), a[0], a[1])
	case "core reject app":
		core.RejectApp(cross(cur), a[0], a[1])
	case "core pause":
		core.Pause(cross(cur))
	case "core pause app":
		core.PauseApp(cross(cur), a[0])
	case "core add member":
		core.AddAuthorityMember(cross(cur), address(a[0]))
	case "core remove member":
		core.RemoveAuthorityMember(cross(cur), address(a[0]))
	case "core migrate client":
		bz, _ := hex.DecodeString(a[2])
		if refusal := core.MigrateClient(cross(cur), a[0], a[1], bz); refusal != "" {
			return "", refusal
		}
		// A migrated verifier is a new trust: the meters of the client's
		// route start empty, as after a replacement (ADR pr6375 §7.1).
		if route := routeKeyOf(a[0]); routes.Has(route) {
			bumpPayoutsEpoch(route, t)
			return p.op + ": route " + route + "'s meters emptied", ""
		}
	case "transfer update impl":
		transfer.UpdateImpl(cross(cur), a[0])
	case "transfer block":
		transfer.BlockAddress(cross(cur), address(a[0]))
	case "transfer unblock":
		transfer.UnblockAddress(cross(cur), address(a[0]))
	case "transfer add member":
		transfer.AddAuthorityMember(cross(cur), address(a[0]))
	case "transfer remove member":
		transfer.RemoveAuthorityMember(cross(cur), address(a[0]))
	default:
		return "", "unknown operation " + p.op
	}
	return p.op, ""
}

// unpauseAdminParams is an unpause of the core or of an app: at once, spent
// under a guardian hold.
type unpauseAdminParams struct{ port string }

func (*unpauseAdminParams) unpause() {}

func (p *unpauseAdminParams) apply(cur realm, t int64) (string, string) {
	if p.port == "" {
		if !core.Paused() {
			return "", "the core is not paused"
		}
		core.Unpause(cross(cur))
		return "core unpaused", ""
	}
	if !core.IsAppPaused(p.port) {
		return "", "app " + p.port + " is not paused"
	}
	core.UnpauseApp(cross(cur), p.port)
	return "app " + p.port + " unpaused", ""
}

func adminRequest(cur realm, op, text string, queued bool, args ...string) Request {
	p := &adminParams{op: op, args: args}
	return propose(cur, op, text, func(cur realm, made, t int64) {
		decide(cur, op, text, p, made, t, queued)
	})
}

// mustAddr is s as a gno address in its canonical (lowercase) spelling: bech32
// also accepts the uppercase one, which the banker credits to the same account
// but which every string comparison and key (seats, the GRC20 ledger, the
// blocklist, relayers) tells apart (transfer.CanonicalAddress).
func mustAddr(s string) address {
	a, ok := transfer.CanonicalAddress(strings.TrimSpace(s))
	if !ok {
		panic("ibcgov: not an address: " + s)
	}
	return a
}

func mustImplPath(prefix, path string) {
	if !strings.HasPrefix(path, prefix+"/impl/v") {
		panic("ibcgov: an implementation lives under " + prefix + "/impl/v<N>, not " + path)
	}
	for _, p := range core.RegisteredImplPaths() {
		if prefix == CorePath && p == path {
			return
		}
	}
	for _, p := range transfer.RegisteredImplPaths() {
		if prefix == TransferPath && p == path {
			return
		}
	}
	panic("ibcgov: no implementation is registered at " + path)
}

// NewCoreUpdateImplRequest activates a registered core implementation after
// 7 days (ADR pr6375 §6.12).
func NewCoreUpdateImplRequest(cur realm, path string) Request {
	mustImplPath(CorePath, path)
	return adminRequest(cur, "core update impl", "core: activate the implementation "+path, true, path)
}

// NewCoreAddRelayerRequest adds a relayer to the core's whitelist after 7
// days. It concerns non-Ethereum clients only: relaying for an Ethereum client
// is permissionless.
func NewCoreAddRelayerRequest(cur realm, addr string) Request {
	a := mustAddr(addr)
	return adminRequest(cur, "core add relayer", "core: add relayer "+string(a), true, string(a))
}

// NewCoreRemoveRelayerRequest removes a relayer from the core's whitelist: at
// once while others remain listed, after 7 days when it is the last one (an
// empty whitelist lets anyone relay). The whitelist is read when the decision
// is recorded, not when the request is built.
func NewCoreRemoveRelayerRequest(cur realm, addr string) Request {
	a := mustAddr(addr)
	if !isRelayer(a) {
		panic("ibcgov: " + addr + " is not a listed relayer")
	}
	op, text := "core remove relayer", "core: remove relayer "+string(a)
	p := &adminParams{op: op, args: []string{string(a)}}
	return propose(cur, op, text, func(cur realm, made, t int64) {
		decide(cur, op, text, p, made, t, !isRelayer(a) || len(core.Relayers()) <= 1)
	})
}

func isRelayer(a address) bool {
	for _, r := range core.Relayers() {
		if r == a {
			return true
		}
	}
	return false
}

// NewRecoverClientRequest recovers a frozen or expired core client from a
// substitute after 7 days (see the core's recover-client.md).
func NewRecoverClientRequest(cur realm, subjectClientID, substituteClientID string) Request {
	if core.ClientType(subjectClientID) == "" || core.ClientType(substituteClientID) == "" {
		panic("ibcgov: unknown client")
	}
	return adminRequest(cur, "core recover client", "core: recover client "+subjectClientID+" from "+substituteClientID, true, subjectClientID, substituteClientID)
}

// NewCoreApproveAppRequest activates a pending app registration after 7 days.
func NewCoreApproveAppRequest(cur realm, portID, pkgPath string) Request {
	if !core.IsAppPending(portID, pkgPath) {
		panic("ibcgov: no pending registration of " + pkgPath + " for port " + portID)
	}
	return adminRequest(cur, "core approve app", "core: approve "+pkgPath+" on port "+portID, true, portID, pkgPath)
}

// NewCoreRejectAppRequest drops a pending app registration at once.
func NewCoreRejectAppRequest(cur realm, portID, pkgPath string) Request {
	if !core.IsAppPending(portID, pkgPath) {
		panic("ibcgov: no pending registration of " + pkgPath + " for port " + portID)
	}
	return adminRequest(cur, "core reject app", "core: reject "+pkgPath+" on port "+portID, false, portID, pkgPath)
}

// NewCorePauseRequest suspends the core's packet path at once (a core bug:
// it blocks refunds too, ADR pr6375 §7.3).
func NewCorePauseRequest(cur realm) Request {
	return adminRequest(cur, "core pause", "core: pause the packet path", false)
}

// NewCoreUnpauseRequest resumes the core's packet path at once; spent under
// a guardian hold.
func NewCoreUnpauseRequest(cur realm) Request {
	text := "core: unpause the packet path"
	p := &unpauseAdminParams{}
	return propose(cur, "core unpause", text, func(cur realm, made, t int64) {
		decide(cur, "core unpause", text, p, made, t, false)
	})
}

// NewCorePauseAppRequest suspends the app on portID at once.
func NewCorePauseAppRequest(cur realm, portID string) Request {
	if core.AppPkgPath(portID) == "" {
		panic("ibcgov: no app on port " + portID)
	}
	return adminRequest(cur, "core pause app", "core: pause the app on port "+portID, false, portID)
}

// NewCoreUnpauseAppRequest resumes the app on portID at once; spent under a
// guardian hold.
func NewCoreUnpauseAppRequest(cur realm, portID string) Request {
	if core.AppPkgPath(portID) == "" {
		panic("ibcgov: no app on port " + portID)
	}
	text := "core: unpause the app on port " + portID
	p := &unpauseAdminParams{port: portID}
	return propose(cur, "core unpause app", text, func(cur realm, made, t int64) {
		decide(cur, "core unpause app", text, p, made, t, false)
	})
}

// NewCoreAddMemberRequest adds a member to the core's authority (the
// tightening operations) after 7 days.
func NewCoreAddMemberRequest(cur realm, addr string) Request {
	a := mustAddr(addr)
	return adminRequest(cur, "core add member", "core: add authority member "+string(a), true, string(a))
}

// NewCoreRemoveMemberRequest removes a member of the core's authority at once.
func NewCoreRemoveMemberRequest(cur realm, addr string) Request {
	a := mustAddr(addr)
	if a == chain.PackageAddress(PkgPath) {
		panic("ibcgov: this realm stays a member of the core's authority")
	}
	if !core.IsAuthorityMember(a) {
		panic("ibcgov: " + addr + " is not a member")
	}
	return adminRequest(cur, "core remove member", "core: remove authority member "+string(a), false, string(a))
}

// NewMigrateClientRequest migrates the verifier of a live core client after
// 7 days (ADR pr6375 R16, §6.12): for migration "ethereum-fork-schedule",
// paramsHex is the hex of ethereum.EncodeForkParameters of the new schedule,
// which the decision's text spells out fork by fork, and it must land before
// the fork epoch; for "ethereum-verifier" (see NewReplaceVerifierRequest),
// paramsHex is the hex of the target verifier version.
func NewMigrateClientRequest(cur realm, clientID, migration, paramsHex string) Request {
	if core.ClientType(clientID) == "" {
		panic("ibcgov: unknown client " + clientID)
	}
	bz, err := hex.DecodeString(paramsHex)
	if err != nil {
		panic("ibcgov: params are hex")
	}
	var text string
	switch migration {
	case "ethereum-fork-schedule":
		if core.ClientType(clientID) != ethereum.ClientType {
			panic("ibcgov: " + clientID + " is not an Ethereum client")
		}
		fp, err := ethereum.DecodeForkParameters(bz)
		if err != nil {
			panic("ibcgov: " + err.Error())
		}
		text = "core: migrate client " + clientID + " to the fork schedule " + forkScheduleText(fp)
	case "ethereum-verifier":
		if core.ClientType(clientID) != ethereum.ClientType {
			panic("ibcgov: " + clientID + " is not an Ethereum client")
		}
		if len(bz) == 0 {
			panic("ibcgov: name the verifier version to convert to")
		}
		text = "core: convert the verifier of client " + clientID + " (" + core.VerifierVersion(clientID) + ") to " + string(bz) + " with the active core implementation's conversion"
	default:
		panic("ibcgov: unknown migration " + migration)
	}
	return adminRequest(cur, "core migrate client", text, true, clientID, migration, hex.EncodeToString(bz))
}

// NewReplaceVerifierRequest converts the verifier of the live Ethereum
// client clientID to the verifier version toVersion after 7 days (ADR
// pr6375 R16, §6.12), with the conversion the active core implementation
// compiles in (installed beforehand by a governed implementation upgrade).
// The client keeps its id, every trusted consensus state and its packet
// state; its trust generation advances and its route's payout meters start
// empty. An Expired client is converted too and stays Expired (an ordinary
// governed recovery follows). When it executes, a conversion the active
// implementation does not declare, a client neither Active nor Expired
// (Frozen), or a converted verifier failing its checks spends the decision.
func NewReplaceVerifierRequest(cur realm, clientID, toVersion string) Request {
	return NewMigrateClientRequest(cur, clientID, "ethereum-verifier", hex.EncodeToString([]byte(toVersion)))
}

func forkScheduleText(p ethereum.ForkParameters) string {
	f := func(name string, x ethereum.Fork) string {
		return name + "=" + hex.EncodeToString(x.Version[:]) + "@" + u64s(x.Epoch)
	}
	return "genesis=" + hex.EncodeToString(p.GenesisForkVersion[:]) + "@slot" + u64s(p.GenesisSlot) + "," +
		strings.Join([]string{
			f("altair", p.Altair), f("bellatrix", p.Bellatrix), f("capella", p.Capella), f("deneb", p.Deneb),
			f("electra", p.Electra), f("fulu", p.Fulu), f("gloas", p.Gloas),
		}, ",")
}

// NewTransferUpdateImplRequest activates a registered transfer implementation
// after 7 days.
func NewTransferUpdateImplRequest(cur realm, path string) Request {
	mustImplPath(TransferPath, path)
	return adminRequest(cur, "transfer update impl", "transfer: activate the implementation "+path, true, path)
}

// NewTransferBlockRequest blocks an address in the transfer app at once.
func NewTransferBlockRequest(cur realm, addr string) Request {
	a := mustAddr(addr)
	return adminRequest(cur, "transfer block", "transfer: block "+string(a), false, string(a))
}

// NewTransferUnblockRequest unblocks an address in the transfer app after 7
// days.
func NewTransferUnblockRequest(cur realm, addr string) Request {
	a := mustAddr(addr)
	if !transfer.IsBlocked(a) {
		panic("ibcgov: " + addr + " is not blocked")
	}
	return adminRequest(cur, "transfer unblock", "transfer: unblock "+string(a), true, string(a))
}

// NewTransferAddMemberRequest adds a member to the transfer app's authority
// after 7 days.
func NewTransferAddMemberRequest(cur realm, addr string) Request {
	a := mustAddr(addr)
	return adminRequest(cur, "transfer add member", "transfer: add authority member "+string(a), true, string(a))
}

// NewTransferRemoveMemberRequest removes a member of the transfer app's
// authority at once.
func NewTransferRemoveMemberRequest(cur realm, addr string) Request {
	a := mustAddr(addr)
	if a == chain.PackageAddress(PkgPath) {
		panic("ibcgov: this realm stays a member of the transfer app's authority")
	}
	if !transfer.IsAuthorityMember(a) {
		panic("ibcgov: " + addr + " is not a member")
	}
	return adminRequest(cur, "transfer remove member", "transfer: remove authority member "+string(a), false, string(a))
}
