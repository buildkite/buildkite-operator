// Copyright (c) 2026 Buildkite Pty Ltd
// SPDX-License-Identifier: MIT

package controller

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
)

// AgentStatus is the job occupancy reported by a Buildkite agent.
type AgentStatus string

const (
	AgentStatusIdle AgentStatus = "idle"
	AgentStatusBusy AgentStatus = "busy"
)

// AgentStatusChecker reads the current job occupancy of an agent Pod.
type AgentStatusChecker interface {
	Check(ctx context.Context, podIP string, port int32) (AgentStatus, error)
}

// HTTPAgentStatusChecker reads a Buildkite agent's /status.json endpoint.
type HTTPAgentStatusChecker struct {
	Client *http.Client
}

// Check returns the aggregate status reported by the agent at podIP.
func (c *HTTPAgentStatusChecker) Check(ctx context.Context, podIP string, port int32) (AgentStatus, error) {
	statusURL := url.URL{
		Scheme: "http",
		Host:   net.JoinHostPort(podIP, strconv.Itoa(int(port))),
		Path:   "/status.json",
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, statusURL.String(), nil)
	if err != nil {
		return "", fmt.Errorf("building status request: %w", err)
	}

	httpClient := c.Client
	if httpClient == nil {
		httpClient = http.DefaultClient
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("requesting agent status: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("agent status returned HTTP %d", resp.StatusCode)
	}

	var response struct {
		AggregateStatus AgentStatus `json:"aggregate_status"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&response); err != nil {
		return "", fmt.Errorf("decoding agent status: %w", err)
	}
	if response.AggregateStatus != AgentStatusIdle && response.AggregateStatus != AgentStatusBusy {
		return "", fmt.Errorf("agent returned unknown aggregate status %q", response.AggregateStatus)
	}
	return response.AggregateStatus, nil
}
