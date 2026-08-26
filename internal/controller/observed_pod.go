// Copyright (c) 2026 Buildkite Pty Ltd
// SPDX-License-Identifier: MIT

package controller

import (
	"time"

	corev1 "k8s.io/api/core/v1"
)

type observedPod struct {
	pod       *corev1.Pod
	busy      bool
	idle      bool
	ready     bool
	stale     bool
	eligible  bool
	idleSince time.Time
}

func countBusy(pods []observedPod) int32 {
	var count int32
	for i := range pods {
		if pods[i].busy {
			count++
		}
	}
	return count
}

func countIdle(pods []observedPod) int32 {
	var count int32
	for i := range pods {
		if pods[i].idle {
			count++
		}
	}
	return count
}

func countReady(pods []observedPod) int32 {
	var count int32
	for i := range pods {
		if pods[i].ready {
			count++
		}
	}
	return count
}

func countStale(pods []observedPod) int32 {
	var count int32
	for i := range pods {
		if pods[i].stale {
			count++
		}
	}
	return count
}

func countCurrent(pods []observedPod) (total int32, busy int32) {
	for i := range pods {
		if pods[i].stale {
			continue
		}
		total++
		if pods[i].busy {
			busy++
		}
	}
	return total, busy
}

func podReady(pod *corev1.Pod) bool {
	for i := range pod.Status.Conditions {
		condition := &pod.Status.Conditions[i]
		if condition.Type == corev1.PodReady {
			return condition.Status == corev1.ConditionTrue
		}
	}
	return false
}
