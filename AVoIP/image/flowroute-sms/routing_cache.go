package main

import (
	"context"
	"errors"
	"net/http"
	"os"
	"time"
)

func (s *server) cacheCatalog(c sipCatalog) {
	s.routingMu.Lock()
	s.routingState = &c
	s.routingDeadline = time.Now().Add(60 * time.Second)
	s.routingMu.Unlock()
}
func (s *server) cachedCatalog() (sipCatalog, time.Time, error) {
	s.routingMu.RLock()
	defer s.routingMu.RUnlock()
	if s.routingState == nil || time.Now().After(s.routingDeadline) {
		return sipCatalog{}, time.Time{}, errors.New("routing snapshot unavailable")
	}
	return *s.routingState, s.routingDeadline, nil
}
func (s *server) refreshCatalog(ctx context.Context) {
	refresh := func() {
		queryCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
		defer cancel()
		r, _ := http.NewRequestWithContext(queryCtx, "GET", "http://local/catalog", nil)
		c, err := s.catalog(r)
		if err == nil {
			err = c.validate()
		}
		if err == nil {
			s.cacheCatalog(c)
			s.logger.Info("routing snapshot refreshed", "site", os.Getenv("AVOIP_SITE"), "version", c.Version)
		} else {
			s.logger.Warn("routing snapshot refresh failed", "error", err)
		}
	}
	refresh()
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			refresh()
		}
	}
}
