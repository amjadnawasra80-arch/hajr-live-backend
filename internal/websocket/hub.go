package websocket

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"net/url"
	"strings"
	"sync/atomic"
	"time"

	gws "github.com/gorilla/websocket"
)

// Envelope is the JSON frame the server pushes to every connected client.
// "From" is always set by the server from the authenticated JWT, never by the client.
type Envelope struct {
	Type string          `json:"type"`
	From string          `json:"from,omitempty"`
	Data json.RawMessage `json:"data,omitempty"`
	TS   time.Time       `json:"ts"`
}

// Hub keeps the set of active clients and fans messages out to all of them.
// All client-set mutation happens inside Run's single goroutine (no locks needed).
type Hub struct {
	clients    map[*Client]struct{}
	register   chan *Client
	unregister chan *Client
	broadcast  chan []byte
	done       chan struct{}
	count      atomic.Int64
	upgrader   gws.Upgrader
}

// NewHub creates a Hub. allowedOrigins lists extra browser origins permitted to
// connect (e.g. "https://app.hajr.live"); same-origin and non-browser clients
// (no Origin header, such as mobile apps) are always allowed.
func NewHub(allowedOrigins []string) *Hub {
	allowed := make(map[string]struct{}, len(allowedOrigins))
	for _, o := range allowedOrigins {
		if o = strings.TrimSpace(o); o != "" {
			allowed[strings.ToLower(o)] = struct{}{}
		}
	}

	return &Hub{
		clients:    make(map[*Client]struct{}),
		register:   make(chan *Client),
		unregister: make(chan *Client),
		broadcast:  make(chan []byte, 256),
		done:       make(chan struct{}),
		upgrader: gws.Upgrader{
			ReadBufferSize:  1024,
			WriteBufferSize: 1024,
			CheckOrigin: func(r *http.Request) bool {
				origin := r.Header.Get("Origin")
				if origin == "" {
					return true
				}
				if _, ok := allowed[strings.ToLower(origin)]; ok {
					return true
				}
				u, err := url.Parse(origin)
				return err == nil && strings.EqualFold(u.Host, r.Host)
			},
		},
	}
}

// Run processes register/unregister/broadcast events until ctx is cancelled,
// then disconnects every client. Call it in its own goroutine.
func (h *Hub) Run(ctx context.Context) {
	defer close(h.done)
	for {
		select {
		case <-ctx.Done():
			for c := range h.clients {
				c.close()
				delete(h.clients, c)
			}
			h.count.Store(0)
			log.Println("[ws] hub stopped")
			return

		case c := <-h.register:
			h.clients[c] = struct{}{}
			h.count.Store(int64(len(h.clients)))

		case c := <-h.unregister:
			if _, ok := h.clients[c]; ok {
				delete(h.clients, c)
				c.close()
				h.count.Store(int64(len(h.clients)))
			}

		case msg := <-h.broadcast:
			for c := range h.clients {
				select {
				case c.send <- msg:
				default:
					// Slow consumer: drop it rather than stall the whole hub.
					delete(h.clients, c)
					c.close()
				}
			}
			h.count.Store(int64(len(h.clients)))
		}
	}
}

// Broadcast queues a raw message for every connected client.
func (h *Hub) Broadcast(msg []byte) {
	select {
	case h.broadcast <- msg:
	case <-h.done:
	}
}

// BroadcastEvent marshals and broadcasts an Envelope (use this for live gifts, system events, etc.).
func (h *Hub) BroadcastEvent(typ, from string, data any) error {
	raw, err := json.Marshal(data)
	if err != nil {
		return err
	}
	msg, err := json.Marshal(Envelope{Type: typ, From: from, Data: raw, TS: time.Now().UTC()})
	if err != nil {
		return err
	}
	h.Broadcast(msg)
	return nil
}

// ClientCount returns the number of currently connected clients.
func (h *Hub) ClientCount() int64 { return h.count.Load() }
