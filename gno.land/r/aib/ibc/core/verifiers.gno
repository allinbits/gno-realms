package core

import (
	"strings"

	"gno.land/p/aib/ibc/lightclient/v0"
	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nt/ufmt/v0"
)

// verifierPathPrefix is the namespace verifier registrations come from.
const verifierPathPrefix = corePkgPath + "/verifiers/"

// verifierReg is a verifier version a governed replacement can convert a
// live client to (ADR pr6375 R16): what it declared, as plain values, and its
// conversion, which runs only at the replacement's installation.
type verifierReg struct {
	clientType string
	version    string
	from       []string
	convert    func(lightclient.Interface) lightclient.Interface
}

// verifiers holds the registered verifier versions, keyed by the path of the
// realm that registered them. A registration is permanent.
var verifiers = bptree.NewBPTree32() // path -> *verifierReg

// VersionedVerifier is a verifier that names its package and version.
type VersionedVerifier interface {
	VerifierVersion() string
}

// SnapshotVerifier is a verifier that hands a detached deep copy of itself,
// which a replacement converts and checks before anything live changes.
type SnapshotVerifier interface {
	Snapshot() lightclient.Interface
}

// RegisterVerifier records a verifier version clients of clientType can be
// converted to, from a realm under corePkgPath + "/verifiers/" (the aib
// namespace), normally from its init. version names the new verifier; from
// lists the verifier versions it converts; convert must be a function of the
// new verifier's /p/ package, so the converted verifier is allocated in this
// realm: it takes the client's current verifier and returns the new one,
// keeping its client state and every consensus state. Registration changes
// no client: a governed MigrateClient with migration "ethereum-verifier"
// does, after its delay.
func RegisterVerifier(cur realm, clientType, version string, from []string, convert func(lightclient.Interface) lightclient.Interface) {
	caller := cur.Previous().PkgPath()
	if !strings.HasPrefix(caller, verifierPathPrefix) {
		panic(ufmt.Sprintf("RegisterVerifier: caller %s is not under %s", caller, verifierPathPrefix))
	}
	if convert == nil || clientType == "" || version == "" || len(from) == 0 {
		panic("RegisterVerifier: a client type, a version, the versions it converts and a conversion")
	}
	if verifiers.Has(caller) {
		panic("RegisterVerifier: " + caller + " is registered already")
	}
	verifiers.Set(caller, &verifierReg{clientType: clientType, version: version, from: append([]string{}, from...), convert: convert})
}

// RegisteredVerifierPaths lists the registered verifier versions' paths.
func RegisteredVerifierPaths() []string {
	paths := make([]string, 0, verifiers.Size())
	verifiers.IterateByOffset(0, verifiers.Size(), func(k string, _ any) bool {
		paths = append(paths, k)
		return false
	})
	return paths
}

// VerifierVersion is the version clientID's verifier names, "" if the
// client is unknown or its verifier names none.
func VerifierVersion(clientID string) string {
	c := store.getClient(clientID)
	if c == nil {
		return ""
	}
	return verifierVersionOf(c.lightClient)
}

func verifierVersionOf(lc lightclient.Interface) string {
	if v, ok := lc.(VersionedVerifier); ok {
		return v.VerifierVersion()
	}
	return ""
}

// CheckVerifierReplacement is why clientID's verifier cannot be replaced by
// the version registered at path now, or "", with no change and without
// running the conversion: from the registration's declared values and the
// client's own state alone.
func CheckVerifierReplacement(clientID, path string) string {
	v := verifiers.Get(path)
	if v == nil {
		return "no verifier registered at " + path
	}
	reg := v.(*verifierReg)
	c := store.getClient(clientID)
	switch {
	case c == nil:
		return "unknown client " + clientID
	case store.isRetired(clientID):
		return "client " + clientID + " is retired"
	case c.typ != reg.clientType:
		return "client " + clientID + " is a " + c.typ + " client, not " + reg.clientType
	case c.lightClient.Status() != lightclient.Active:
		return "client " + clientID + " is " + string(c.lightClient.Status()) + ", not Active"
	}
	if _, ok := c.lightClient.(SnapshotVerifier); !ok {
		return "client " + clientID + "'s verifier gives no snapshot to convert"
	}
	cur := verifierVersionOf(c.lightClient)
	if cur == reg.version {
		return "client " + clientID + "'s verifier is " + reg.version + " already"
	}
	for _, f := range reg.from {
		if f == cur {
			return ""
		}
	}
	return reg.version + " does not convert a " + cur + " verifier"
}

// VerifierConversion is the conversion registered at path and the version it
// produces, for the implementation that installs a governed replacement.
func VerifierConversion(path string) (func(lightclient.Interface) lightclient.Interface, string, bool) {
	v := verifiers.Get(path)
	if v == nil {
		return nil, "", false
	}
	reg := v.(*verifierReg)
	return reg.convert, reg.version, true
}
