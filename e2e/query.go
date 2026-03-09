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

// queryGnoGRC20Balance returns the GRC20 token balance for a given IBC hash and address.
func queryGnoGRC20Balance(containerID, addr, denom string) (int64, error) {
	renderArgs := fmt.Sprintf("grc20/%s/balance/%s", denom, addr)
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

// computeIBCDenomHash computes SHA256("transfer/<clientID>/<denom>") as uppercase hex.
func computeIBCDenomHash(clientID, denom string) string {
	path := fmt.Sprintf("transfer/%s/%s", clientID, denom)
	hash := sha256.Sum256([]byte(path))
	return strings.ToUpper(fmt.Sprintf("%x", hash))
}

// queryVAASHighestValsetUpdateID returns the highest valset update ID from VAAS consumer.
func queryVAASHighestValsetUpdateID(containerID string) (uint64, error) {
	content, err := gnoQuery(containerID, "r/aib/ibc/apps/vaas/consumer", "highest_valset_update_id")
	if err != nil {
		return 0, err
	}
	var resp struct {
		HighestValsetUpdateID uint64 `json:"highest_valset_update_id"`
	}
	if err := json.Unmarshal([]byte(content), &resp); err != nil {
		return 0, fmt.Errorf("parse highest valset update ID: %w (raw: %s)", err, content)
	}
	return resp.HighestValsetUpdateID, nil
}

// queryVAASValidatorCount returns the number of validators from VAAS consumer.
func queryVAASValidatorCount(containerID string) (int, error) {
	content, err := gnoQuery(containerID, "r/aib/ibc/apps/vaas/consumer", "validator_count")
	if err != nil {
		return 0, err
	}
	var resp struct {
		ValidatorCount int `json:"validator_count"`
	}
	if err := json.Unmarshal([]byte(content), &resp); err != nil {
		return 0, fmt.Errorf("parse validator count: %w (raw: %s)", err, content)
	}
	return resp.ValidatorCount, nil
}

// queryVAASTotalVotingPower returns the total voting power from VAAS consumer.
func queryVAASTotalVotingPower(containerID string) (int64, error) {
	content, err := gnoQuery(containerID, "r/aib/ibc/apps/vaas/consumer", "total_voting_power")
	if err != nil {
		return 0, err
	}
	var resp struct {
		TotalVotingPower int64 `json:"total_voting_power"`
	}
	if err := json.Unmarshal([]byte(content), &resp); err != nil {
		return 0, fmt.Errorf("parse total voting power: %w (raw: %s)", err, content)
	}
	return resp.TotalVotingPower, nil
}

// queryVAASAllValidators returns all validators from VAAS consumer.
func queryVAASAllValidators(containerID string) ([]struct {
	PubKey string `json:"pub_key"`
	Power  int64  `json:"power"`
}, error) {
	content, err := gnoQuery(containerID, "r/aib/ibc/apps/vaas/consumer", "validators")
	if err != nil {
		return nil, err
	}
	var resp struct {
		Validators []struct {
			PubKey string `json:"pub_key"`
			Power  int64  `json:"power"`
		} `json:"validators"`
	}
	if err := json.Unmarshal([]byte(content), &resp); err != nil {
		return nil, fmt.Errorf("parse validators: %w (raw: %s)", err, content)
	}
	return resp.Validators, nil
}

// queryVAASProviderClientID returns the provider client ID from VAAS consumer.
func queryVAASProviderClientID(containerID string) (string, bool) {
	content, err := gnoQuery(containerID, "r/aib/ibc/apps/vaas/consumer", "provider_client_id")
	if err != nil {
		return "", false
	}
	var resp struct {
		ProviderClientID string `json:"provider_client_id"`
	}
	if err := json.Unmarshal([]byte(content), &resp); err != nil {
		return "", false
	}
	if resp.ProviderClientID == "" {
		return "", false
	}
	return resp.ProviderClientID, true
}
