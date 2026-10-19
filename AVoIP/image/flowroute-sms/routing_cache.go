package main

import (
	"context"
	"errors"
	"net/http"
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
		if err == nil && c.validate() == nil {
			s.cacheCatalog(c)
		} else {
			s.logger.Warn("routing snapshot refresh failed")
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
