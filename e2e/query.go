package e2e

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/cosmos/cosmos-sdk/types/bech32"
)

// httpGet performs an HTTP GET with retries on 503 errors.
func httpGet(url string) ([]byte, error) {
	const maxRetries = 3
	var lastErr error
	for i := range maxRetries {
		if i > 0 {
			time.Sleep(time.Duration(i) * time.Second)
		}
		resp, err := http.Get(url)
		if err != nil {
			lastErr = err
			continue
		}
		body, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			lastErr = err
			continue
		}
		if resp.StatusCode == http.StatusServiceUnavailable {
			lastErr = fmt.Errorf("HTTP 503 from %s", url)
			continue
		}
		if resp.StatusCode != http.StatusOK {
			return nil, fmt.Errorf("HTTP %d from %s: %s", resp.StatusCode, url, string(body))
		}
		return body, nil
	}
	return nil, lastErr
}

// gnoQuery executes a gnokey query inside the gno container and returns the
// raw render output. gnokey outputs "height: N\ndata: <content>\n", so we
// strip the prefix to get the content.
func gnoQuery(containerID, realmPath, renderArgs string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	data := fmt.Sprintf("gno.land/%s:%s", realmPath, renderArgs)
	stdout, stderr, err := dockerExec(ctx, containerID,
		"gnokey", "query", "vm/qrender",
		"-data", data,
		"-remote", "localhost:26657",
	)
	if err != nil {
		return "", fmt.Errorf("gnokey query %s: %w: %s", data, err, stderr)
	}
	// Parse output: "height: N\ndata: <content>\n"
	// The data may span multiple lines, so find the first "data: " prefix.
	const prefix = "data: "
	idx := strings.Index(stdout, prefix)
	if idx < 0 {
		return "", fmt.Errorf("unexpected gnokey output (no 'data: ' prefix): %s", stdout)
	}
	content := strings.TrimSpace(stdout[idx+len(prefix):])
	return content, nil
}

// queryAtomOneClientStates returns the first client_id from AtomOne REST.
func queryAtomOneClientStates(restURL string) (string, error) {
	body, err := httpGet(restURL + "/ibc/core/client/v1/client_states")
	if err != nil {
		return "", err
	}
	var resp struct {
		ClientStates []struct {
			ClientID string `json:"client_id"`
		} `json:"client_states"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return "", fmt.Errorf("parse client_states: %w", err)
	}
	if len(resp.ClientStates) == 0 {
		return "", fmt.Errorf("no client states found")
	}
	return resp.ClientStates[0].ClientID, nil
}

// queryGnoClients returns the first client ID from Gno via gnokey query.
// Response format: {"items": [{"id": "07-tendermint-1", ...}], "page": 1, "total": 1}
func queryGnoClients(containerID string) (string, error) {
	content, err := gnoQuery(containerID, "r/aib/ibc/core", "clients")
	if err != nil {
		return "", err
	}
	var resp struct {
		Items []struct {
			ID string `json:"id"`
		} `json:"items"`
	}
	if err := json.Unmarshal([]byte(content), &resp); err != nil {
		return "", fmt.Errorf("parse gno clients: %w (raw: %s)", err, content)
	}
	if len(resp.Items) == 0 {
		return "", fmt.Errorf("no clients found on gno")
	}
	return resp.Items[0].ID, nil
}

// queryGnoClientCounterparty returns the counterparty client ID for a given client.
func queryGnoClientCounterparty(containerID, clientID string) (string, error) {
	content, err := gnoQuery(containerID, "r/aib/ibc/core", "clients/"+clientID)
	if err != nil {
		return "", err
	}
	var resp struct {
		CounterpartyClientID string `json:"counterparty_client_id"`
	}
	if err := json.Unmarshal([]byte(content), &resp); err != nil {
		return "", fmt.Errorf("parse client counterparty: %w (raw: %s)", err, content)
	}
	if resp.CounterpartyClientID == "" {
		return "", fmt.Errorf("no counterparty registered for %s", clientID)
	}
	return resp.CounterpartyClientID, nil
}

// queryVoucherBalance returns the voucher token balance for a given IBC denom and address.
func queryVoucherBalance(containerID, addr, denom string) (int64, error) {
	renderArgs := fmt.Sprintf("voucher/%s/balance/%s", denom, addr)
	content, err := gnoQuery(containerID, "r/aib/ibc/apps/transfer", renderArgs)
	if err != nil {
		return 0, err
	}
	var resp struct {
		Balance json.Number `json:"balance"`
	}
	if err := json.Unmarshal([]byte(content), &resp); err != nil {
		return 0, fmt.Errorf("parse GRC20 balance: %w (raw: %s)", err, content)
	}
	bal, err := strconv.ParseInt(string(resp.Balance), 10, 64)
	if err != nil {
		return 0, fmt.Errorf("parse balance number: %w", err)
	}
	return bal, nil
}

// queryGnoBalance returns the native coin balance for a denom on Gno.
func queryGnoBalance(containerID, addr, denom string) (int64, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	stdout, stderr, err := dockerExec(ctx, containerID,
		"gnokey", "query", "bank/balances/"+addr,
		"-remote", "localhost:26657",
	)
	if err != nil {
		return 0, fmt.Errorf("gnokey query bank/balances: %w: %s", err, stderr)
	}
	// Output: "height: N\ndata: \"100ugnot\"\n"
	const prefix = "data: "
	idx := strings.Index(stdout, prefix)
	if idx < 0 {
		return 0, fmt.Errorf("unexpected output (no 'data: ' prefix): %s", stdout)
	}
	data := strings.Trim(strings.TrimSpace(stdout[idx+len(prefix):]), "\"")
	// data is like "9988968600ugnot" or "100ugnot,50foo"
	for coin := range strings.SplitSeq(data, ",") {
		if strings.HasSuffix(coin, denom) {
			amountStr := strings.TrimSuffix(coin, denom)
			return strconv.ParseInt(amountStr, 10, 64)
		}
	}
	return 0, nil
}

// queryAtomOneBalance returns the balance of a specific denom for an address on AtomOne.
func queryAtomOneBalance(restURL, addr, denom string) (int64, error) {
	url := fmt.Sprintf("%s/cosmos/bank/v1beta1/balances/%s/by_denom?denom=%s", restURL, addr, denom)
	body, err := httpGet(url)
	if err != nil {
		return 0, err
	}
	var resp struct {
		Balance struct {
			Amount string `json:"amount"`
		} `json:"balance"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return 0, fmt.Errorf("parse balance: %w", err)
	}
	if resp.Balance.Amount == "" {
		return 0, nil
	}
	return strconv.ParseInt(resp.Balance.Amount, 10, 64)
}

// IBCDenom represents the denom info returned by the ibc-go transfer Denom query.
type IBCDenom struct {
	Base  string    `json:"base"`
	Trace []IBCHop  `json:"trace"`
}

type IBCHop struct {
	PortID    string `json:"port_id"`
	ChannelID string `json:"channel_id"`
}

// queryAtomOneIBCDenom queries the IBC transfer denom info for a given hash on AtomOne.
// Endpoint: /ibc/apps/transfer/v1/denoms/{hash}
func queryAtomOneIBCDenom(restURL, hash string) (*IBCDenom, error) {
	url := fmt.Sprintf("%s/ibc/apps/transfer/v1/denoms/%s", restURL, hash)
	body, err := httpGet(url)
	if err != nil {
		return nil, err
	}
	var resp struct {
		Denom *IBCDenom `json:"denom"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, fmt.Errorf("parse denom response: %w (raw: %s)", err, string(body))
	}
	if resp.Denom == nil {
		return nil, fmt.Errorf("denom not found for hash %s", hash)
	}
	return resp.Denom, nil
}

// gnoEval executes a gnokey query vm/qeval inside the gno container and returns
// the raw result. The expr is a function call like "BalanceOf(\"addr\")".
// The data format is "pkgPath.expr" where pkgPath is the full realm path.
func gnoEval(containerID, realmPath, expr string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	data := fmt.Sprintf("gno.land/%s.%s", realmPath, expr)
	stdout, stderr, err := dockerExec(ctx, containerID,
		"gnokey", "query", "vm/qeval",
		"-data", data,
		"-remote", "localhost:26657",
	)
	if err != nil {
		return "", fmt.Errorf("gnokey qeval %s: %w: %s", data, err, stderr)
	}
	const prefix = "data: "
	idx := strings.Index(stdout, prefix)
	if idx < 0 {
		return "", fmt.Errorf("unexpected gnokey output (no 'data: ' prefix): %s", stdout)
	}
	content := strings.TrimSpace(stdout[idx+len(prefix):])
	return content, nil
}

// GnoDenom represents the denom info returned by the Gno transfer realm render endpoint.
type GnoDenom struct {
	Base  string `json:"base"`
	Path  string `json:"path"`
	Denom string `json:"denom"`
}

// queryGnoIBCDenom queries the Gno transfer realm for IBC denom info.
// Endpoint: denoms/ibc/{hash}
func queryGnoIBCDenom(containerID, ibcDenom string) (*GnoDenom, error) {
	renderArgs := fmt.Sprintf("denoms/%s", ibcDenom)
	content, err := gnoQuery(containerID, "r/aib/ibc/apps/transfer", renderArgs)
	if err != nil {
		return nil, err
	}
	var d GnoDenom
	if err := json.Unmarshal([]byte(content), &d); err != nil {
		return nil, fmt.Errorf("parse denom response: %w (raw: %s)", err, content)
	}
	return &d, nil
}

// queryGnoGRC20Alias queries the transfer realm for the GRC20 denom alias
// by calling transfer.GRC20Alias via vm/qeval.
func queryGnoGRC20Alias(containerID, denom string) (string, error) {
	expr := fmt.Sprintf("GRC20Alias(\"%s\")", denom)
	content, err := gnoEval(containerID, "r/aib/ibc/apps/transfer", expr)
	if err != nil {
		return "", err
	}
	// qeval returns: ("gno.land:r:..." string)
	content = strings.TrimPrefix(content, "(")
	content = strings.TrimSuffix(content, ")")
	// Remove the type suffix and unquote the string value
	parts := strings.Fields(content)
	if len(parts) != 2 {
		return "", fmt.Errorf("unexpected qeval result: %s", content)
	}
	return strings.Trim(parts[0], "\""), nil
}

// queryGnoGRC20TestBalance returns the GRC20 test token balance for an address
// by calling grc20test.BalanceOf via vm/qeval.
func queryGnoGRC20TestBalance(containerID, addr string) (int64, error) {
	expr := fmt.Sprintf("BalanceOf(\"%s\")", addr)
	content, err := gnoEval(containerID, "r/aib/ibc/apps/testing/grc20test", expr)
	if err != nil {
		return 0, err
	}
	// qeval returns: (VALUE TYPE), e.g. (1000 int64)
	content = strings.TrimPrefix(content, "(")
	content = strings.TrimSuffix(content, ")")
	parts := strings.Fields(content)
	if len(parts) != 2 {
		return 0, fmt.Errorf("unexpected qeval result: %s", content)
	}
	return strconv.ParseInt(parts[0], 10, 64)
}

// computeIBCDenomHash computes SHA256("transfer/<clientID>/<denom>") as uppercase hex.
func computeIBCDenomHash(clientID, denom string) string {
	path := fmt.Sprintf("transfer/%s/%s", clientID, denom)
	hash := sha256.Sum256([]byte(path))
	return strings.ToUpper(fmt.Sprintf("%x", hash))
}

// gnoPkgAddress computes the Gno package address for a given package path.
// Replicates Gno's DerivePkgBech32Addr without importing the full Gno module.
func gnoPkgAddress(pkgPath string) string {
	hash := sha256.Sum256([]byte("pkgPath:" + pkgPath))
	addr, err := bech32.ConvertAndEncode("g", hash[:20])
	if err != nil {
		panic(fmt.Sprintf("bech32 encode: %v", err))
	}
	return addr
}
